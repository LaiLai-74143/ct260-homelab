import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useActionMutation, useActions, useAlerts, useArchive, useServices } from '../api'
import { MODULES } from '../modules'
import { SITE_GROUPS } from '../sites'
import { linkOf } from '../pages/Services'
import { topicLabel } from '../pages/Archive'
import { useEnv } from '../env'
import ConfirmDialog from './ConfirmDialog'
import { useToast } from './Toast'

/** g+字母 快速跳頁表(範本 v0.17 定案;g d 由「大廳」改指「設備」,大廳=g h) */
const KEYJUMP: Record<string, string> = {
  h: '/', d: '/m/devices', a: '/m/alerts', s: '/m/services',
  c: '/m/security', p: '/m/power', m: '/m/game', l: '/m/life',
  r: '/m/archive',
}
const JUMPKEY = Object.fromEntries(Object.entries(KEYJUMP).map(([k, r]) => [r, k]))

interface Item {
  g: '模塊' | '動作' | '服務' | '網站' | '拾遺'
  ic: string
  t: string
  /** 額外搜尋鍵(與 t 併入模糊匹配) */
  k: string
  hint?: string
  run: () => void
}

/** 子序列模糊匹配:分數越小越靠前;不中回 -1(範本 v0.17 原樣) */
function fuzzy(q: string, hay: string): number {
  if (!q) return 0
  let i = -1
  let score = 0
  for (const ch of q) {
    i = hay.indexOf(ch, i + 1)
    if (i < 0) return -1
    score += i
  }
  return score
}

function Kbd({ children }: { children: string }) {
  return (
    <kbd className="rounded-btn border border-b-2 border-line bg-white/[.03] px-1 font-mono text-[10px]">
      {children}
    </kbd>
  )
}

/**
 * ⌘K 命令面板(0.17.0 P0):模糊搜尋 模塊+服務目錄+常用網站+動作。
 * ⌘K / Ctrl+K / 「/」喚起;g+字母 快速跳頁;banner 的「⌘K 搜尋」鈕與
 * 自訂事件 cmdk-open 是無鍵盤(手機)入口。
 * 動作接線:靜音走既有 ConfirmDialog+useActionMutation(文案與 AlertActions
 * 一致);戳 Clawd 發 clawd-poke 自訂事件;夜間切換走 EnvProvider。
 * 資料查詢(services/actions)首次開啟才 enabled,不替閒置頁面加輪詢。
 */
export default function CommandPalette() {
  const nav = useNavigate()
  const toast = useToast()
  const { night, toggleNight } = useEnv()
  const [open, setOpen] = useState(false)
  const [ever, setEver] = useState(false) // 首次開啟後才拉 services/actions
  const [q, setQ] = useState('')
  const [sel, setSel] = useState(0)
  const [confirm, setConfirm] = useState<{ action: string; param: string; label: string } | null>(null)
  const gAt = useRef(0)
  const listRef = useRef<HTMLDivElement>(null)

  const al = useAlerts()
  const sv = useServices(ever)
  const ac = useActions(ever)
  const ar = useArchive('manual', ever) // ⌘K 只搜剪藏庫;邸報流水不進面板
  const mut = useActionMutation()

  const doOpen = () => { setEver(true); setQ(''); setSel(0); setOpen(true) }

  // 全域鍵盤:⌘K 恆通(輸入框內也要能開);其餘捷徑避讓輸入框與對話框
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        if (open) setOpen(false)
        else doOpen()
        return
      }
      if (open) return // 開著時 Esc/方向鍵由面板自己的 onKeyDown 接
      const el = e.target as HTMLElement | null
      if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) return
      if (el?.closest?.('[role="dialog"]')) return
      if (e.key === '/') { e.preventDefault(); doOpen(); return }
      if (e.key === 'g' && !e.metaKey && !e.ctrlKey) { gAt.current = Date.now(); return }
      if (gAt.current && Date.now() - gAt.current < 900 && KEYJUMP[e.key]) {
        nav(KEYJUMP[e.key], { viewTransition: true })
      }
      gAt.current = 0
    }
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [open, nav])

  // 無鍵盤入口:banner「⌘K 搜尋」鈕發 cmdk-open
  useEffect(() => {
    const h = () => doOpen()
    window.addEventListener('cmdk-open', h)
    return () => window.removeEventListener('cmdk-open', h)
  }, [])

  const items = useMemo<Item[]>(() => {
    if (!open) return []
    const out: Item[] = [
      ...MODULES.map((m): Item => ({
        g: '模塊', ic: m.icon, t: m.label, k: m.key,
        hint: JUMPKEY[m.route] ? `g ${JUMPKEY[m.route]}` : undefined,
        run: () => nav(m.route, { viewTransition: true }),
      })),
    ]
    // 動作:靜音(僅 firing 且本請求可操作)、戳 Clawd、夜間切換
    if (ac.data?.enabled && ac.data.allowed) {
      for (const a of al.data?.firing ?? []) {
        const label = `靜音 ${a.name} 1 小時`
        out.push({
          g: '動作', ic: '▲', t: label, k: `mute silence 靜音 ${a.name}`,
          run: () => setConfirm({ action: 'silence-1h', param: a.name, label }),
        })
      }
    }
    out.push(
      { g: '動作', ic: '◍', t: '戳一下 Clawd', k: 'poke clawd 吉祥物', run: () => window.dispatchEvent(new CustomEvent('clawd-poke')) },
      { g: '動作', ic: '☾', t: night ? '切回日間(夜間預覽中)' : '切換夜間模式預覽', k: 'night dark 夜間', run: toggleNight },
    )
    for (const g of sv.data?.groups ?? []) {
      for (const i of g.items) {
        const url = linkOf(i) // 與服務目錄同一套可達性判定,不出死鏈
        if (!url) continue
        out.push({
          g: '服務', ic: '↗', t: i.name, k: `${g.group} ${i.host ?? ''}`, hint: g.group,
          run: () => window.open(url, '_blank', 'noopener'),
        })
      }
    }
    for (const g of SITE_GROUPS) {
      for (const s of g.sites) {
        out.push({
          g: '網站', ic: '↗', t: s.name, k: `${s.abbr} ${g.label}`, hint: g.label,
          run: () => window.open(s.href, '_blank', 'noopener'),
        })
      }
    }
    // 拾遺收藏(0.18.0):標題+摘要可搜,選中直開閱讀器;未配置/讀取失敗=誠實缺席
    for (const doc of ar.data?.items ?? []) {
      out.push({
        g: '拾遺', ic: '▤', t: doc.title, k: `${doc.summary.slice(0, 40)} archive`,
        hint: topicLabel(doc.topic_id),
        run: () => nav(`/archive/${doc.id}`, { viewTransition: true }),
      })
    }
    return out
  }, [open, nav, al.data, sv.data, ac.data, ar.data, night, toggleNight])

  const shown = useMemo(() => {
    const needle = q.trim().toLowerCase()
    const scored = items
      .map((it) => ({ it, s: fuzzy(needle, `${it.t} ${it.k}`.toLowerCase()) }))
      .filter((x) => x.s >= 0)
    if (needle) scored.sort((a, b) => a.s - b.s)
    return scored.map((x) => x.it)
  }, [items, q])

  useEffect(() => { setSel(0) }, [q, open])
  useEffect(() => {
    listRef.current?.querySelector('[data-sel="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [sel])

  const runItem = (it: Item | undefined) => {
    if (!it) return
    setOpen(false)
    if (it.g === '動作' && mut.isPending) { toast('err', '有動作執行中,稍候再試'); return }
    it.run()
  }

  const fire = (c: { action: string; param: string; label: string }) => {
    setConfirm(null)
    mut.mutate({ action: c.action, param: c.param }, {
      onSuccess: ({ status, data }) => {
        toast('ok', status === 202 ? (data.hint || `已送出:${c.label}`) : `已${c.label}`)
      },
      onError: (e) => { toast('err', `${c.label} 失敗:${e.error}${e.hint ? ` — ${e.hint}` : ''}`) },
    })
  }

  return (
    <>
      {open && (
        <div
          className="fixed inset-0 z-[80] flex items-start justify-center bg-bg/55 px-3 pt-[16vh] backdrop-blur-sm"
          role="dialog"
          aria-label="命令面板"
          onClick={() => setOpen(false)}
        >
          <div
            className="dialog-in w-[560px] max-w-full overflow-hidden rounded-card border border-line bg-panel shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <input
              autoFocus
              value={q}
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') setOpen(false)
                else if (e.key === 'ArrowDown') { e.preventDefault(); setSel((s) => (shown.length ? (s + 1) % shown.length : 0)) }
                else if (e.key === 'ArrowUp') { e.preventDefault(); setSel((s) => (shown.length ? (s - 1 + shown.length) % shown.length : 0)) }
                else if (e.key === 'Enter') { e.preventDefault(); runItem(shown[sel]) }
              }}
              placeholder="搜尋模塊、服務、網站、動作…"
              autoComplete="off"
              spellCheck={false}
              className="w-full border-b border-line bg-transparent px-4 py-3.5 text-[15px] outline-none placeholder:text-muted"
            />
            <div ref={listRef} className="max-h-[340px] overflow-y-auto p-1.5">
              {shown.length === 0 && (
                <div className="px-3 py-4 text-center text-[13px] text-muted">沒有符合的結果。</div>
              )}
              {shown.map((it, i) => {
                const groupHead = i === 0 || shown[i - 1].g !== it.g
                return (
                  <div key={`${it.g}:${it.t}:${i}`}>
                    {groupHead && (
                      <div className="px-2.5 pb-1 pt-2 font-mono text-[10px] tracking-[.14em] text-muted">{it.g}</div>
                    )}
                    <div
                      data-sel={i === sel || undefined}
                      onClick={() => runItem(it)}
                      onPointerMove={() => { if (i !== sel) setSel(i) }}
                      className={`flex cursor-pointer items-center gap-2.5 rounded-card border-l-2 px-2.5 py-[9px] text-[13.5px] ${
                        i === sel ? 'border-amber bg-amber/[.08]' : 'border-transparent'
                      }`}
                    >
                      <span className={`w-4 text-center font-mono text-xs ${i === sel ? 'text-amber' : 'text-muted'}`}>{it.ic}</span>
                      <span className="min-w-0 flex-1 truncate">{it.t}</span>
                      {it.hint && <span className="shrink-0 font-mono text-[10.5px] text-muted">{it.hint}</span>}
                    </div>
                  </div>
                )
              })}
            </div>
            <div className="flex items-center gap-3.5 border-t border-line px-3.5 py-2 font-mono text-[10.5px] text-muted">
              <span><Kbd>↑↓</Kbd> 選擇</span>
              <span><Kbd>↵</Kbd> 執行</span>
              <span><Kbd>esc</Kbd> 關閉</span>
              <span className="ml-auto"><Kbd>g</Kbd>+字母 快速跳頁</span>
            </div>
          </div>
        </div>
      )}
      <ConfirmDialog
        open={confirm !== null}
        text={confirm?.label ?? ''}
        onConfirm={() => confirm && fire(confirm)}
        onCancel={() => setConfirm(null)}
      />
    </>
  )
}
