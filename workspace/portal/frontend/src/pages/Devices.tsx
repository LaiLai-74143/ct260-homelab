import { Link } from 'react-router-dom'
import { grafanaUrl, useOverview } from '../api'
import Bar from '../components/Bar'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'

const DEV_DASH = 'http://10.80.80.11:3002/d/homelab-overview/homelab-overview'

export default function Devices() {
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

      {/* 圖表入口:Grafana 設備總覽(11 台 bargauge 比較+CPU/記憶體/網路/磁碟趨勢) */}
      <a href={grafanaUrl(DEV_DASH)} target="_blank" rel="noreferrer"
         className="mt-3.5 block rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px] transition-colors duration-150 hover:border-amber">
        設備圖表與趨勢(CPU/記憶體/磁碟/溫度)→ <span className="font-mono text-[12px] text-muted">Grafana 設備總覽 (Homelab) ↗</span>
      </a>
    </>
  )
}
