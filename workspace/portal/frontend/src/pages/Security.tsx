import { grafanaUrl, useSecurity } from '../api'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'
import Spark from '../components/Spark'

const SEC_DASH = 'http://10.80.80.11:3002/d/openwrt-portscan-autoban/openwrt-portscan-autoban'

function Tile({ label, big, unit, state }: { label: string; big: string; unit?: string; state?: 'ok' | 'warn' | 'crit' | 'unk' }) {
  return (
    <div className="rounded-card border border-line bg-panel px-4 py-3.5">
      <div className="mb-1 flex items-center gap-2 text-[12px] text-muted">
        {state && <Dot state={state} />}{label}
      </div>
      <div className="font-mono text-2xl font-semibold">
        {big}{unit && <span className="text-[13px] font-normal text-muted">{unit}</span>}
      </div>
    </div>
  )
}

export default function Security() {
  const se = useSecurity()
  const d = se.data

  return (
    <>
      <PageHead title="安全面板" right={d ? `更新 ${d.generated_at.slice(11, 19)}Z` : ''} />
      {se.isError && !d && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到安全數據——檢查 BFF /api/security。
        </div>
      )}
      {d && (
        <>
          <div className="mb-3.5 grid grid-cols-2 gap-2.5 md:grid-cols-3">
            <Tile label="autoban 封鎖中 IP" big={String(d.autoban_today)} unit=" 個"
                  state={d.autoban_today > 0 ? 'ok' : 'unk'} />
            <Tile label="SSH22 絆線(今日)" big={String(d.tripwire.today)} unit=" 事件"
                  state={d.tripwire.today > 0 ? 'warn' : 'ok'} />
            <Tile label="絆線零事件"
                  big={d.tripwire.days_clean == null ? '—' : d.tripwire.days_clean >= 30 ? '≥30' : String(d.tripwire.days_clean)}
                  unit={d.tripwire.days_clean == null ? '(無數據)' : ' 天'}
                  state={d.tripwire.days_clean == null ? 'unk' : 'ok'} />
          </div>

          <section className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
            <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">AUTOBAN 24H 趨勢(封鎖中 IP 數)</div>
            <Spark data={d.autoban_trend_24h} height={64} />
          </section>

          <section className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
            <div className="mb-2 flex items-center gap-2 font-mono text-[11px] tracking-[.12em] text-muted">
              COWRIE 蜜罐
              {d.cowrie.offline && <Dot state="unk" />}
            </div>
            {d.cowrie.offline ? (
              // 誠實態(§2):資料源離線就明說,不擺舊數據裝正常
              <div className="text-[13.5px] text-muted">{d.cowrie.hint}</div>
            ) : (
              <>
                <div className="mb-2 font-mono text-xl font-semibold">
                  {d.cowrie.count}<span className="text-[13px] font-normal text-muted"> 次攻擊(24h)</span>
                </div>
                {(d.cowrie.top_src ?? []).map((s) => (
                  <div key={s.ip} className="flex justify-between border-b border-line/60 py-1 font-mono text-[12.5px] last:border-0">
                    <span>{s.ip}</span><span className="text-muted">{s.n}</span>
                  </div>
                ))}
              </>
            )}
          </section>

          {/* 攻擊地圖:連結卡(待辦49 決策3——不 iframe,免改現役 grafana.ini) */}
          <a href={grafanaUrl(SEC_DASH)} target="_blank" rel="noreferrer"
             className="block rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px] transition-colors duration-150 hover:border-amber">
            攻擊地圖與完整安全視圖 → <span className="font-mono text-[12px] text-muted">Grafana openwrt-portscan-autoban ↗</span>
          </a>
        </>
      )}
    </>
  )
}
