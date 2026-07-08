import { useParams } from 'react-router-dom'
import { grafanaUrl, useHostDetail } from '../api'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'
import Spark from '../components/Spark'
import type { AlertItem } from '../types'

function MetricCard({ label, unit, data }: { label: string; unit: string; data: [number, number][] }) {
  const last = data.length ? data[data.length - 1][1] : null
  return (
    <div className="rounded-card border border-line bg-panel px-3.5 py-3">
      <div className="mb-1 flex items-baseline justify-between">
        <span className="font-mono text-[11px] tracking-[.12em] text-muted">{label}</span>
        <span className="font-mono text-[15px] font-semibold">
          {last ?? '—'}<span className="text-[11px] font-normal text-muted">{unit}</span>
        </span>
      </div>
      <Spark data={data} />
    </div>
  )
}

function sevState(s: AlertItem['severity']) {
  return s === 'critical' ? 'crit' : s === 'warning' ? 'warn' : 'unk'
}

/** L2 主機詳情(§3):近 6h 指標 sparkline + 掛載服務 + 相關告警 + Loki 日誌尾巴 */
export default function Host() {
  const { name } = useParams()
  const hd = useHostDetail(name)
  const d = hd.data

  return (
    <>
      <PageHead
        title={d?.name ?? name ?? '主機'}
        right={d && (
          <a href={grafanaUrl(d.grafana_url)} target="_blank" rel="noreferrer" className="hover:text-amber">
            Grafana ↗
          </a>
        )}
      />
      {hd.isError && !d && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到 /api/host/{name}——主機名不對或 BFF 未回應。
        </div>
      )}
      {d && (
        <>
          {d.bare ? (
            <div className="mb-3.5 rounded-card border border-dashed border-line px-4 py-5 text-center text-[13.5px] text-muted">
              此機為 textfile/SNMP/pve 視角數據源,無 node_exporter 指標圖。
            </div>
          ) : (
            <div className="mb-3.5 grid grid-cols-1 gap-2.5 md:grid-cols-2 xl:grid-cols-4">
              <MetricCard label="CPU" unit="%" data={d.metrics_6h.cpu} />
              <MetricCard label="RAM" unit="%" data={d.metrics_6h.mem} />
              <MetricCard label="DISK /" unit="%" data={d.metrics_6h.disk} />
              <MetricCard label="NET" unit=" KB/s" data={d.metrics_6h.net} />
            </div>
          )}

          {d.services.length > 0 && (
            <section className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">掛載服務</div>
              <div className="flex flex-wrap gap-2">
                {d.services.map((s) => (
                  <span key={s} className="rounded-btn border border-line px-2.5 py-1 text-[12.5px]">{s}</span>
                ))}
              </div>
            </section>
          )}

          <section className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
            <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">相關告警</div>
            {d.related_alerts.length === 0 && (
              <div className="flex items-center gap-2 text-[13px] text-muted"><Dot state="ok" /> 無 firing 告警指向本機。</div>
            )}
            {d.related_alerts.map((a) => (
              <div key={a.name + a.instance} className="flex items-start gap-2.5 border-b border-line/60 py-2 last:border-0">
                <Dot state={sevState(a.severity)} className="mt-1.5" />
                <div className="min-w-0 flex-1">
                  <div className="font-mono text-[13px] font-semibold">{a.name}</div>
                  <div className="text-[12px] text-muted">{a.description}</div>
                </div>
                <span className="font-mono text-[11px] text-muted">{a.since}</span>
              </div>
            ))}
          </section>

          <section className="rounded-card border border-line bg-panel px-4 py-3.5">
            <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">日誌尾巴(近 15 分鐘,Loki)</div>
            {d.log_tail === null && (
              <div className="text-[13px] text-muted">
                {d.loki ? 'Loki 查詢失敗——稍後重試或開 Grafana Explore。' : '此機未接 promtail,無日誌尾巴。'}
              </div>
            )}
            {d.log_tail && d.log_tail.length === 0 && (
              <div className="text-[13px] text-muted">近 15 分鐘無日誌。</div>
            )}
            {d.log_tail && d.log_tail.length > 0 && (
              <div className="max-h-[320px] overflow-y-auto">
                {d.log_tail.map((l, idx) => (
                  <div key={l.ts + idx} className="flex gap-2.5 border-b border-line/40 py-[3px] font-mono text-[11.5px] last:border-0">
                    <span className="shrink-0 text-muted">{l.ts.slice(11, 19)}</span>
                    <span className="min-w-0 break-all">{l.line}</span>
                  </div>
                ))}
              </div>
            )}
          </section>
        </>
      )}
    </>
  )
}
