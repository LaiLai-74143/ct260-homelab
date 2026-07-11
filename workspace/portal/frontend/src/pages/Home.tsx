import { useAlerts, useBrief, useDataLag, useOverview } from '../api'
import StatusBanner from '../components/StatusBanner'
import BriefCard from '../components/BriefCard'
import Mascot from '../components/Mascot'
import ModuleCard, { type ModuleCardData } from '../components/ModuleCard'
import Reveal from '../components/Reveal'
import PageSkeleton from '../components/Skeleton'
import { MODULES } from '../modules'
import { SITE_GROUPS } from '../sites'
import type { ModuleStub } from '../types'

/** BFF 完全失聯:離線畫面給出路而非情緒(§7) */
function Offline({ lastSuccess }: { lastSuccess: string | null }) {
  return (
    <div className="rounded-card border border-dashed border-line px-5 py-10 text-center">
      <div className="mb-2 font-serif text-lg font-bold">連不上 BFF</div>
      <div className="text-[13.5px] text-muted">
        最後成功:{lastSuccess ? new Date(lastSuccess).toLocaleString('zh-TW', { hour12: false }) : '本次尚無'}
      </div>
      <div className="mt-3 text-[13.5px] text-muted">
        檢查 CT201(10.80.80.11)portal 容器;或走 Tailscale 直連 Grafana 排障。
      </div>
    </div>
  )
}

export default function Home() {
  const ov = useOverview()
  const al = useAlerts()
  const br = useBrief()
  const lag = useDataLag(ov.data?.generated_at, ov.isError)

  if (ov.isError && !ov.data) {
    return <Offline lastSuccess={null} />
  }

  const stubOf = (key: string): ModuleStub | undefined => ov.data?.modules?.find((m) => m.key === key)

  const cards: ModuleCardData[] = MODULES.filter((m) => m.key !== 'home').map((m) => {
    if (m.key === 'devices') {
      const t = ov.data?.targets
      const bad = t ? t.total - t.up : 0
      return {
        route: m.route, name: m.label, state: bad > 0 ? 'warn' : 'ok',
        big: t ? `${t.up}` : '—', bigUnit: t ? `/${t.total}` : '',
        sub: t ? (bad > 0 ? `${bad} 個 target 離線` : '全數在線') : '讀取中…',
      }
    }
    if (m.key === 'alerts') {
      const f = al.data?.firing ?? []
      const crit = f.filter((a) => a.severity === 'critical').length
      return {
        route: m.route, name: m.label, state: crit > 0 ? 'crit' : f.length > 0 ? 'warn' : 'ok',
        big: `${f.length}`,
        sub: `${crit} critical · ${f.length - crit} warning · ${al.data?.silences.length ?? 0} silences`,
      }
    }
    const s = stubOf(m.key)
    if (s) return { route: m.route, name: m.label, state: s.state, big: s.big, bigUnit: s.bigUnit, sub: s.sub }
    // 誠實原則:無數據來源就標待接,不顯示假數字
    return { route: m.route, name: m.label, state: 'unk', big: '—', sub: 'M2 待接' }
  })

  return (
    <>
      {/* 首屏骨架(D2):overview 未到前不畫假數據(舊版首繪會閃「0 告警/M2 待接」);
          只蓋 banner+模塊卡——下方 SITES 為靜態 import,不必等 API(審查 CONFIRMED) */}
      {!ov.data ? (
        <PageSkeleton banner tiles={7} />
      ) : (
        <>
          {/* 告警橫幅不進 Reveal:緊急資訊不能被進場動畫延遲 */}
          <StatusBanner state={ov.data.summary.state} text={ov.data.summary.text} lag={lag} />
          {br.data && <Reveal><BriefCard brief={br.data} /></Reveal>}
          {br.isError && (
            <div className="mb-[22px] rounded-card border border-line bg-panel p-4 text-[13.5px] text-muted">
              晨報尚未送達(brief.json 待 CT260 投遞)。
            </div>
          )}
          <div className="mb-2.5 ml-0.5 font-mono text-[11px] tracking-[.12em] text-muted">MODULES</div>
          <Reveal stagger className="grid grid-cols-2 gap-2.5 md:gap-3.5 xl:grid-cols-3">
            {cards.map((c) => <ModuleCard key={c.route} m={c} />)}
            {/* 吉祥物 Clawd(0.12.0):7 張模塊卡後補格——2 欄補滿第 4 列、
                3 欄跨兩格補滿第 3 列(使用者:「右邊有點空」) */}
            <Mascot className="xl:col-span-2" />
          </Reveal>
        </>
      )}

      {/* 常用網站(Homepage bookmarks 搬遷,Homepage 退役前置) */}
      <Reveal>
      <div className="mb-2.5 ml-0.5 mt-6 font-mono text-[11px] tracking-[.12em] text-muted">SITES · 常用網站</div>
      <div className="rounded-card border border-line bg-panel px-4 py-2.5">
        {SITE_GROUPS.map((g) => (
          <div key={g.label} className="flex flex-wrap items-center gap-1.5 border-b border-line py-2 last:border-b-0">
            <span className="w-full shrink-0 font-mono text-[10px] tracking-wide text-muted sm:w-[104px]">{g.label}</span>
            {g.sites.map((s) => (
              <a
                key={s.name}
                href={s.href}
                target="_blank"
                rel="noreferrer"
                className="rounded-btn border border-line px-2.5 py-1 text-[12.5px] transition-colors duration-150 hover:border-amber"
              >
                <span className="mr-1.5 font-mono text-[10px] text-muted">{s.abbr}</span>
                {s.name}
              </a>
            ))}
          </div>
        ))}
      </div>
      </Reveal>
    </>
  )
}
