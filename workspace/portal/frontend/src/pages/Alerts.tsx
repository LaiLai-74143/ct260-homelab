import { useAlerts } from '../api'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'
import Timeline from '../components/Timeline'
import type { AlertItem } from '../types'

function sevState(s: AlertItem['severity']) {
  return s === 'critical' ? 'crit' : s === 'warning' ? 'warn' : 'unk'
}

function Row({ a, pending }: { a: AlertItem; pending?: boolean }) {
  return (
    <div className={`mb-2.5 flex items-start gap-3 rounded-card border border-line bg-panel px-4 py-3.5 ${pending ? 'opacity-70' : ''}`}>
      <Dot state={sevState(a.severity)} className="mt-1.5" />
      <div className="min-w-0 flex-1">
        <div className="font-mono text-[13.5px] font-semibold">
          {a.name}
          {pending && <span className="ml-2 font-normal text-muted">(pending)</span>}
        </div>
        <div className="mt-[3px] text-[12.5px] text-muted">{a.description}{a.instance ? ` · ${a.instance}` : ''}</div>
      </div>
      <span className="whitespace-nowrap font-mono text-[11px] text-muted">{a.since}</span>
    </div>
  )
}

export default function Alerts() {
  const al = useAlerts()
  const firing = al.data?.firing ?? []
  const pending = al.data?.pending ?? []
  const silences = al.data?.silences ?? []

  return (
    <>
      <PageHead title="告警中心" right={al.data ? `firing ${firing.length} · silences ${silences.length}` : ''} />
      {al.isError && !al.data && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到告警數據——檢查 BFF /api/alerts。
        </div>
      )}
      {al.data && firing.length === 0 && pending.length === 0 && (
        <div className="mb-2.5 flex items-center gap-3 rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px]">
          <Dot state="ok" /> 目前無 firing / pending 告警。
        </div>
      )}
      {firing.map((a) => <Row key={`f-${a.name}-${a.instance}`} a={a} />)}
      {pending.map((a) => <Row key={`p-${a.name}-${a.instance}`} a={a} pending />)}

      {silences.length > 0 && (
        <>
          <div className="mb-2 mt-5 ml-0.5 font-mono text-[11px] tracking-[.12em] text-muted">ACTIVE SILENCES</div>
          {silences.map((s) => (
            <div key={s.comment + s.ends_at} className="mb-2 rounded-card border border-line bg-panel px-4 py-3 text-[12.5px] text-muted">
              <span className="font-mono">{s.matchers}</span> — {s.comment}
              <span className="ml-2 font-mono text-[11px]">至 {s.ends_at}</span>
            </div>
          ))}
        </>
      )}

      <section className="mt-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
        <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">近 24H 告警時間軸(firing 數)</div>
        <Timeline data={al.data?.timeline_24h ?? []} />
      </section>
    </>
  )
}
