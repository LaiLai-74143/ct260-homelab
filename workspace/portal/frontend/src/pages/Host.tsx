import { useParams } from 'react-router-dom'
import PageHead from '../components/PageHead'

/** L2 主機詳情(M2 實作)——M0/M1 僅保留路由 */
export default function Host() {
  const { name } = useParams()
  return (
    <>
      <PageHead title={name ?? '主機'} />
      <div className="rounded-card border border-dashed border-line px-5 py-10 text-center text-[13.5px] text-muted">
        主機詳情屬 M2 實作範圍(指標 sparkline / 掛載服務 / 相關告警 / 日誌尾巴)
        <span className="mt-1.5 block font-mono text-[11px]">GET /api/host/{name}</span>
      </div>
    </>
  )
}
