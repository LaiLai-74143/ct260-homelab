import { usePower } from '../api'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'

function fmtRuntime(s?: number): string {
  if (s == null) return '—'
  return `${Math.floor(s / 60)} 分`
}

export default function Power() {
  const pw = usePower()
  const d = pw.data

  return (
    <>
      <PageHead title="電力" />
      {pw.isError && !d && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到電力數據——檢查 BFF /api/power。
        </div>
      )}
      {d?.pending && (
        // 誠實態(待辦49 決策2):數據源未接就明說 + 給出路,不隱藏、不擺假數據(§7)
        <div className="rounded-card border border-dashed border-line px-5 py-10 text-center">
          <div className="mb-2 flex items-center justify-center gap-2 font-serif text-lg font-bold">
            <Dot state="unk" /> 數據源未接
          </div>
          <div className="mx-auto max-w-[36em] text-[13.5px] text-muted">{d.hint}</div>
        </div>
      )}
      {d && !d.pending && (
        <>
          <div className="mb-3.5 grid grid-cols-2 gap-2.5 md:grid-cols-3">
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 flex items-center gap-2 text-[12px] text-muted">
                <Dot state={d.on_battery ? 'crit' : 'ok'} />電源
              </div>
              <div className="font-mono text-2xl font-semibold">{d.on_battery ? '電池' : '市電'}</div>
            </div>
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 flex items-center gap-2 text-[12px] text-muted">
                {d.battery_low && <Dot state="crit" />}電池
              </div>
              <div className="font-mono text-2xl font-semibold">{d.charge ?? '—'}<span className="text-[13px] font-normal text-muted">%</span></div>
            </div>
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 text-[12px] text-muted">估計續航</div>
              <div className="font-mono text-2xl font-semibold">{fmtRuntime(d.runtime_s)}</div>
            </div>
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 text-[12px] text-muted">負載</div>
              <div className="font-mono text-2xl font-semibold">{d.load ?? '—'}<span className="text-[13px] font-normal text-muted">%</span></div>
            </div>
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 text-[12px] text-muted">估計功耗</div>
              <div className="font-mono text-2xl font-semibold">{d.watts ?? '—'}<span className="text-[13px] font-normal text-muted"> W</span></div>
            </div>
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 text-[12px] text-muted">輸入電壓</div>
              <div className="font-mono text-2xl font-semibold">{d.input_v ?? '—'}<span className="text-[13px] font-normal text-muted"> V</span></div>
            </div>
          </div>
          <section className="rounded-card border border-line bg-panel px-4 py-3.5">
            <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">近 7 天事件</div>
            {(d.events_7d ?? []).length === 0 && <div className="text-[13px] text-muted">無事件。</div>}
            {(d.events_7d ?? []).map((e) => (
              <div key={e.ts + e.text} className="border-b border-line/60 py-1.5 text-[12.5px] last:border-0">
                <span className="font-mono text-muted">{e.ts}</span> {e.text}
              </div>
            ))}
          </section>
        </>
      )}
    </>
  )
}
