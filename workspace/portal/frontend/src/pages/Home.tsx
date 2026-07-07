import { useAlerts, useBrief, useDataLag, useOverview } from '../api'
import StatusBanner from '../components/StatusBanner'
import BriefCard from '../components/BriefCard'
import ModuleCard, { type ModuleCardData } from '../components/ModuleCard'
import { MODULES } from '../modules'
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
      {ov.data && <StatusBanner state={ov.data.summary.state} text={ov.data.summary.text} lag={lag} />}
      {br.data && <BriefCard brief={br.data} />}
      {br.isError && (
        <div className="mb-[22px] rounded-card border border-line bg-panel p-4 text-[13.5px] text-muted">
          晨報尚未送達(brief.json 待 CT260 投遞)。
        </div>
      )}
      <div className="mb-2.5 ml-0.5 font-mono text-[11px] tracking-[.12em] text-muted">MODULES</div>
      <div className="grid grid-cols-2 gap-2.5 md:gap-3.5 xl:grid-cols-3">
        {cards.map((c) => <ModuleCard key={c.route} m={c} />)}
      </div>
    </>
  )
}
