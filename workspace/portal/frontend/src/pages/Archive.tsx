import { useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useArchive, useArchiveCreateMutation } from '../api'
import PageHead from '../components/PageHead'
import Reveal from '../components/Reveal'
import PageSkeleton from '../components/Skeleton'
import { useToast } from '../components/Toast'
import type { ArchiveItem } from '../types'

/** 六部固定字典(SoT=CT260 archive-svc TOPICS;順序即顯示順序)。
    export 供閱讀器/命令面板共用(比照 Services.linkOf 先例)。 */
export const ARCHIVE_TOPICS: { id: string; label: string }[] = [
  { id: 'officials', label: '吏·名籍' },
  { id: 'treasury', label: '戶·府庫' },
  { id: 'rites', label: '禮·典章' },
  { id: 'military', label: '兵·行令' },
  { id: 'justice', label: '刑·稽核' },
  { id: 'works', label: '工·營造' },
]

export function topicLabel(id: string): string {
  return ARCHIVE_TOPICS.find((t) => t.id === id)?.label ?? id
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, '')
  } catch {
    return ''
  }
}

function Row({ i, dibao }: { i: ArchiveItem; dibao?: boolean }) {
  return (
    <Link
      to={`/archive/${i.id}`}
      viewTransition
      className="card-hover mb-2 block rounded-card border border-line bg-panel px-4 py-3"
    >
      <div className="flex items-baseline gap-2.5">
        {dibao && (
          <span className="w-6 shrink-0 text-center font-mono text-[13px] font-semibold text-amber">
            {i.score ?? '—'}
          </span>
        )}
        <span className="min-w-0 flex-1 truncate text-[14px] font-medium">{i.title}</span>
        <span className="hidden shrink-0 font-mono text-[10.5px] text-muted md:inline">
          {dibao ? (i.feed ?? '') : (i.source_url ? hostOf(i.source_url) : '')}
        </span>
        <span className="shrink-0 font-mono text-[10.5px] text-muted">{i.created_at.slice(5, 10)}</span>
      </div>
      <div className={`mt-1 truncate text-[12.5px] text-muted ${dibao ? 'ml-[34px]' : ''}`}>{i.summary}</div>
    </Link>
  )
}

/** 拾遺歸檔(0.18.0;0.19.0 加邸報;0.19.1 邸報改六部分區):剪藏=手動收藏按六部分組;
    邸報=dibao-ingest 自動呈報,同樣六部分區、組內按門下省評分排,准了才收編進剪藏庫 */
export default function Archive() {
  const [sp, setSp] = useSearchParams()
  const tab: 'manual' | 'rss' = sp.get('tab') === 'rss' ? 'rss' : 'manual'
  const ar = useArchive(tab)
  const create = useArchiveCreateMutation()
  const toast = useToast()
  const [input, setInput] = useState('')
  const [q, setQ] = useState('')

  const submit = () => {
    const v = input.trim()
    if (!v || create.isPending) return
    create.mutate({ input: v }, {
      onSuccess: ({ data }) => {
        setInput('')
        toast('ok', `已歸入 ${topicLabel(data.item.topic_id)}:${data.item.title}`)
      },
      onError: (e) => { toast('err', `歸檔失敗:${e.error}${e.hint ? ` — ${e.hint}` : ''}`) },
    })
  }

  const kept = useMemo(() => {
    const items = ar.data?.items ?? []
    const needle = q.trim().toLowerCase()
    return needle
      ? items.filter((i) => (i.title + i.summary).toLowerCase().includes(needle))
      : items
  }, [ar.data, q])

  // 兩視圖同為六部分組(0.19.1:邸報也分區,不再平鋪);
  // 剪藏組內=新到舊、邸報組內=分數高到低(伺服端已排,分組不打亂組內序)
  const groups = useMemo(() => (
    ARCHIVE_TOPICS
      .map((t) => ({ ...t, items: kept.filter((i) => i.topic_id === t.id) }))
      .filter((g) => g.items.length > 0)
  ), [kept])

  return (
    <>
      <PageHead title="拾遺歸檔" right={ar.data ? `${ar.data.total} 篇` : ''} />

      {/* 剪藏/邸報 切換(邸報=自動呈報,14 天滾動;准了才進剪藏庫) */}
      <div className="mb-3 flex gap-2">
        {([['manual', '剪藏 · 六部'], ['rss', '邸報 · 呈報']] as const).map(([k, label]) => (
          <button
            key={k}
            onClick={() => setSp(k === 'rss' ? { tab: 'rss' } : {})}
            className={`btn-press rounded-btn border px-3 py-1.5 text-[12.5px] transition-colors duration-150 ${
              tab === k ? 'border-amber text-amber' : 'border-line text-muted hover:border-amber hover:text-amber'
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      {tab === 'manual' && (
        <>
          {/* 收藏輸入列:Enter 或〔收藏〕送出;等待期間鎖定(服務端單飛,同時只歸一筆) */}
          <div className="mb-3 flex gap-2">
            <input
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') submit() }}
              placeholder="貼上網址或一段文字,AI 歸入六部…"
              disabled={create.isPending || (ar.data ? !ar.data.allowed : false)}
              className="w-full flex-1 rounded-card border border-line bg-panel px-3.5 py-2 text-[13px] text-text placeholder:text-muted/60 focus:border-amber focus:outline-none disabled:opacity-55"
            />
            <button
              onClick={submit}
              disabled={create.isPending || !input.trim()}
              className="btn-press shrink-0 rounded-btn border border-amber px-3.5 py-1.5 text-[12.5px] text-amber transition-colors duration-150 hover:bg-amber/10 disabled:cursor-not-allowed disabled:opacity-45"
            >
              {create.isPending ? '歸檔中…' : '收藏'}
            </button>
          </div>
          {create.isPending && (
            <div className="mb-3 rounded-card border border-line bg-panel px-4 py-2.5 text-[12.5px] text-muted">
              抓取原文+AI 歸納中(網頁剪藏最長約一分半)…
            </div>
          )}
        </>
      )}

      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="搜尋標題/摘要…"
        className="mb-3.5 w-full rounded-card border border-line bg-panel px-3.5 py-2 font-mono text-[13px] text-text placeholder:text-muted/60 focus:border-amber focus:outline-none md:max-w-[340px]"
      />

      {ar.isError && !ar.data && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到拾遺歸檔——檢查 BFF /api/archive 或 CT260 archive-svc(:5003)。
        </div>
      )}
      {!ar.data && !ar.isError && <PageSkeleton rows={5} />}

      {/* 六部分組;stagger 打在容器,搜尋過濾時不重播;key=tab 讓切換視圖重播入場 */}
      <Reveal stagger key={tab}>
        {groups.map((g) => (
          <section key={g.id} className="mb-4">
            <div className="mb-2 ml-0.5 font-serif text-[13px] font-bold tracking-[.14em] text-muted">
              {g.label}
              <span className="ml-2 font-mono text-[10.5px] font-normal">{g.items.length}</span>
            </div>
            {g.items.map((i) => <Row key={i.id} i={i} dibao={tab === 'rss'} />)}
          </section>
        ))}
      </Reveal>

      {ar.data && ar.data.total === 0 && (
        <div className="rounded-card border border-dashed border-line p-8 text-center text-[13.5px] text-muted">
          {tab === 'manual'
            ? '六部虛位以待——貼上第一條網址或一段文字試試。'
            : '邸報無呈——等 dibao-ingest 下一班(05:20/17:20)送件。'}
        </div>
      )}
      {ar.data && ar.data.total > 0 && kept.length === 0 && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          沒有符合「{q}」的{tab === 'manual' ? '收藏' : '呈報'}。
        </div>
      )}

      {tab === 'rss' && kept.length > 0 && (
        <div className="mt-2 text-center font-mono text-[10.5px] text-muted">
          邸報 14 天滾動清理;要留的進閱讀器按〔准〕收編入六部。
          <Link to="/m/archive" viewTransition className="ml-1 hover:text-amber">回剪藏 →</Link>
        </div>
      )}
    </>
  )
}
