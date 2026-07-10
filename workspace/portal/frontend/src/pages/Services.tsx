import { useEffect, useMemo, useRef, useState } from 'react'
import { IS_HL, useServices } from '../api'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'
import Reveal from '../components/Reveal'
import PageSkeleton from '../components/Skeleton'
import type { ServiceItem } from '../types'

/** 依存取場景(§5 可達性矩陣)決定可點連結;不可達=灰化+提示,不做死鏈。
 *  非 http(s) 位址(如 MC 連線位址)屬資訊展示,不做超連結。 */
function linkOf(i: ServiceItem): string | null {
  const u = IS_HL ? (i.url_hl ?? (i.phone ? i.url : null)) : (i.pc40 ? i.url : null)
  return u && /^https?:\/\//.test(u) ? u : null
}

function Row({ i }: { i: ServiceItem }) {
  const href = linkOf(i)
  const reachable = !!href
  return (
    <div className={`mb-2 flex items-center gap-3 rounded-card border border-line bg-panel px-4 py-3 ${reachable ? '' : 'opacity-55'}`}>
      <Dot state={i.kuma_ok === null ? 'unk' : i.kuma_ok ? 'ok' : 'crit'} />
      <div className="min-w-0 flex-1">
        <span className="text-[14px] font-medium">{i.name}</span>
        {i.note && <span className="ml-2 text-[11.5px] text-muted">{i.note}</span>}
        {!reachable && !i.note && (
          <span className="ml-2 text-[11.5px] text-muted">{IS_HL ? '手機場景不可直達' : 'PC40 未放行'}</span>
        )}
      </div>
      {i.url && <span className="hidden font-mono text-[11px] text-muted md:inline">{i.url.replace(/^https?:\/\//, '')}</span>}
      {reachable ? (
        <a href={href} target="_blank" rel="noreferrer"
           className="rounded-btn border border-line px-2.5 py-1 font-mono text-[11.5px] text-muted transition-colors duration-150 hover:border-amber hover:text-amber">
          開啟 ↗
        </a>
      ) : (
        <span className="rounded-btn border border-line px-2.5 py-1 font-mono text-[11.5px] text-muted/60">不可達</span>
      )}
    </div>
  )
}

export default function Services() {
  const sv = useServices()
  const [q, setQ] = useState('')
  const input = useRef<HTMLInputElement>(null)

  // `/` 聚焦搜尋(§7 鍵盤)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === '/' && !(e.target instanceof HTMLInputElement)) {
        e.preventDefault()
        input.current?.focus()
      }
    }
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [])

  const groups = useMemo(() => {
    const gs = sv.data?.groups ?? []
    if (!q.trim()) return gs
    const needle = q.trim().toLowerCase()
    return gs
      .map((g) => ({ ...g, items: g.items.filter((i) => (i.name + g.group).toLowerCase().includes(needle)) }))
      .filter((g) => g.items.length > 0)
  }, [sv.data, q])

  const kumaCount = useMemo(() => {
    const items = (sv.data?.groups ?? []).flatMap((g) => g.items).filter((i) => i.kuma_ok !== null)
    return items.length ? `${items.filter((i) => i.kuma_ok).length}/${items.length} 綠燈` : ''
  }, [sv.data])

  return (
    <>
      <PageHead title="服務目錄" right={kumaCount} />
      <input
        ref={input}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="搜尋服務(按 / 聚焦)"
        className="mb-3.5 w-full rounded-card border border-line bg-panel px-3.5 py-2 font-mono text-[13px] text-text placeholder:text-muted/60 focus:border-amber focus:outline-none md:max-w-[340px]"
      />
      {sv.data?.kuma_note && (
        <div className="mb-3 rounded-card border border-line bg-panel px-4 py-2.5 text-[12.5px] text-muted">
          {sv.data.kuma_note}
        </div>
      )}
      {sv.isError && !sv.data && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到服務目錄——檢查 BFF /api/services。
        </div>
      )}
      {!sv.data && !sv.isError && <PageSkeleton rows={5} />}
      {/* stagger 打在 groups 容器:過濾打字時容器已 shown,新出現的組不重播 */}
      <Reveal stagger>
      {groups.map((g) => (
        <section key={g.group} className="mb-4">
          <div className="mb-2 ml-0.5 font-mono text-[11px] tracking-[.12em] text-muted">{g.group.toUpperCase?.() || g.group}</div>
          {g.items.map((i) => <Row key={i.name} i={i} />)}
        </section>
      ))}
      </Reveal>
      {sv.data && groups.length === 0 && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          沒有符合「{q}」的服務。
        </div>
      )}
    </>
  )
}
