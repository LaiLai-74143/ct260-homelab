import { Link } from 'react-router-dom'
import { useOverview } from '../api'
import Bar from '../components/Bar'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'

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
    </>
  )
}
