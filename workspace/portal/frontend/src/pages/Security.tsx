import { grafanaUrl, useSecurity } from '../api'
import Dot from '../components/Dot'
import GrafanaPanel from '../components/GrafanaPanel'
import Num from '../components/Num'
import PageHead from '../components/PageHead'
import PageSkeleton from '../components/Skeleton'
import Spark from '../components/Spark'

const SEC_DASH = 'http://10.80.80.11:3002/d/openwrt-portscan-autoban/openwrt-portscan-autoban'
// d-solo 用 uid/slug;panelId 對照 grafana-edit/openwrt-portscan-autoban.json(部署腳本驗 id 存在)
const SEC_SOLO = 'openwrt-portscan-autoban/openwrt-portscan-autoban'

function Tile({ label, big, unit, state }: { label: string; big: string; unit?: string; state?: 'ok' | 'warn' | 'crit' | 'unk' }) {
  return (
    <div className="rounded-card border border-line bg-panel px-4 py-3.5">
      <div className="mb-1 flex items-center gap-2 text-[12px] text-muted">
        {state && <Dot state={state} />}{label}
      </div>
      <div className="font-mono text-2xl font-semibold">
        <Num value={big} unit={unit} />
      </div>
    </div>
  )
}

/** embeds=false:kiosk 輪播用——每輪 key remount 會全量重載 iframe,牆板也未必走得通兩條可達路 */
export default function Security({ embeds = true }: { embeds?: boolean }) {
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
      {!d && !se.isError && <PageSkeleton tiles={3} rows={2} />}
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
                  <Num value={String(d.cowrie.count)} unit=" 次攻擊(24h)" />
                </div>
                {(d.cowrie.top_src ?? []).map((s) => (
                  <div key={s.ip} className="flex justify-between border-b border-line/60 py-1 font-mono text-[12.5px] last:border-0">
                    <span>{s.ip}</span><span className="text-muted">{s.n}</span>
                  </div>
                ))}
              </>
            )}
          </section>

        </>
      )}

      {/* 嵌入圖表(2026-07-09 使用者點名,翻掉決策3):攻擊地圖+防火牆審計雙趨勢。
          不依賴 BFF,放 {d && …} 外——/api/security 掛掉時圖表照常(審查確認項)。
          時間範圍拉 24h 與上方 AUTOBAN 24H 卡對齊(dashboard 本身預設 6h) */}
      {embeds && (
        <section className="mb-3.5">
          <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">
            GRAFANA 即時圖表(空白=SSO 未登入或連不到 Grafana)
          </div>
          <div className="grid grid-cols-1 gap-2.5 md:grid-cols-2">
            <GrafanaPanel dash={SEC_SOLO} panelId={10} title="攻擊來源世界地圖" from="now-24h"
                          h={360} className="md:col-span-2" />
            <GrafanaPanel dash={SEC_SOLO} panelId={7} title="封鎖中 IP 趨勢" from="now-24h" h={240} />
            <GrafanaPanel dash={SEC_SOLO} panelId={6} title="防火牆誘捕記錄速率" from="now-24h" h={240} />
          </div>
        </section>
      )}

      {/* 完整視圖入口:防火牆審計與攻擊地圖同屬 openwrt-portscan-autoban 一張 dashboard */}
      <a href={grafanaUrl(SEC_DASH)} target="_blank" rel="noreferrer"
         className="block rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px] transition-colors duration-150 hover:border-amber">
        防火牆審計、攻擊地圖與完整安全視圖 → <span className="font-mono text-[12px] text-muted">Grafana OpenWrt 防火牆審計與 Cowrie 蜜罐 ↗</span>
      </a>
    </>
  )
}
