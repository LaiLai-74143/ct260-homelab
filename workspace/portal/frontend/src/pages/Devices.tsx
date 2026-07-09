import { Link } from 'react-router-dom'
import { grafanaUrl, useOverview } from '../api'
import Bar from '../components/Bar'
import Dot from '../components/Dot'
import GrafanaPanel from '../components/GrafanaPanel'
import PageHead from '../components/PageHead'

const DEV_DASH = 'http://10.80.80.11:3002/d/homelab-overview/homelab-overview'
// d-solo 用 uid/slug;panelId 對照 ForAI/grafana-overview-gen.py 流水號(部署腳本驗 id 存在)
const DEV_SOLO = 'homelab-overview/homelab-overview'

/** embeds=false:kiosk 輪播用——每輪 key remount 會全量重載 iframe,牆板也未必走得通兩條可達路 */
export default function Devices({ embeds = true }: { embeds?: boolean }) {
  const ov = useOverview()
  const hosts = ov.data?.hosts ?? []
  const t = ov.data?.targets

  return (
    <>
      <PageHead title="設備總覽" right={t ? `${t.up}/${t.total} targets up` : ''} />
      {ov.isError && !ov.data && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到設備數據——檢查 BFF /api/overview。
        </div>
      )}
      <div className="grid grid-cols-2 gap-2.5 xl:grid-cols-4 md:grid-cols-3 md:gap-3">
        {hosts.map((h) => (
          <Link
            key={h.slug}
            to={`/host/${h.slug}`}
            className={`block rounded-card border border-line bg-panel px-3.5 py-[13px] transition-colors duration-150 hover:border-amber ${h.up === 'unk' ? 'opacity-55' : ''}`}
          >
            <div className="mb-0.5 flex items-center gap-2">
              <Dot state={h.up} />
              <span className="font-mono text-[13.5px] font-semibold">{h.name}</span>
              <span className="ml-auto rounded-btn border border-line px-[5px] py-px font-mono text-[10px] text-muted">{h.vlan}</span>
            </div>
            <div className="mb-[9px] text-[11.5px] text-muted">{h.note ?? ''}</div>
            <Bar k="cpu" v={h.cpu} />
            <Bar k="mem" v={h.mem} />
            <Bar k="disk" v={h.disk} />
            <div className="mt-[7px] font-mono text-[10px] text-muted">uptime {h.uptime}</div>
          </Link>
        ))}
      </div>

      {/* 嵌入圖表(2026-07-09 使用者點名改版):拔掉現況型 bargauge,只留趨勢折線。
          上方主機卡牆已呈現即時值;此區看走勢——CPU/記憶體/磁碟讀寫/網路/溫度,沿
          dashboard 預設 6h。panelId 對照 grafana-overview-gen.py 流水號(生成器檔頭有警語)*/}
      {embeds && (
      <section className="mt-3.5">
        <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">
          GRAFANA 趨勢圖表(6 小時;空白=SSO 未登入或連不到 Grafana)
        </div>
        <div className="grid grid-cols-1 gap-2.5 md:grid-cols-2">
          <GrafanaPanel dash={DEV_SOLO} panelId={13} title="CPU 使用率趨勢" h={280} />
          <GrafanaPanel dash={DEV_SOLO} panelId={14} title="記憶體使用率趨勢" h={280} />
          <GrafanaPanel dash={DEV_SOLO} panelId={17} title="磁碟讀取速率趨勢" h={280} />
          <GrafanaPanel dash={DEV_SOLO} panelId={18} title="磁碟寫入速率趨勢" h={280} />
          <GrafanaPanel dash={DEV_SOLO} panelId={15} title="網路接收流量趨勢" h={280} />
          <GrafanaPanel dash={DEV_SOLO} panelId={20} title="溫度趨勢" h={280} />
        </div>
      </section>
      )}

      {/* 完整視圖入口:即時 bargauge 比較、網路傳送/swap 趨勢與設備總覽表在 dashboard 本尊 */}
      <a href={grafanaUrl(DEV_DASH)} target="_blank" rel="noreferrer"
         className="mt-3.5 block rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px] transition-colors duration-150 hover:border-amber">
        設備圖表與趨勢(CPU/記憶體/磁碟/溫度)→ <span className="font-mono text-[12px] text-muted">Grafana 設備總覽 (Homelab) ↗</span>
      </a>
    </>
  )
}
