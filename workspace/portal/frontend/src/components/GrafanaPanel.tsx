import { grafanaUrl } from '../api'

/** Grafana d-solo 單面板嵌入(2026-07-09 使用者點名,翻掉待辦49 決策3「不 iframe」)。
    前提:CT201 Grafana 開 GF_SECURITY_ALLOW_EMBEDDING+匿名 Viewer(finish-grafana-embed.sh)
    ——iframe 內沒有 Grafana 登入態,匿名沒開只會渲染出登入頁。
    雙路同 grafanaUrl:portal.hl 頁嵌 grafana.hl(同站,Authelia session cookie 直帶);
    LAN :8088 頁嵌 :3002 直連(PC40 已放行)。空白框=瀏覽器連不到 Grafana(非 BFF 問題)。 */
export default function GrafanaPanel({ dash, panelId, title, h = 280, from = 'now-6h', className = '' }: {
  dash: string
  panelId: number
  title: string
  /** iframe 高度 px(Grafana 格高 1 單位≈30px) */
  h?: number
  from?: string
  className?: string
}) {
  const src = grafanaUrl(
    `http://10.80.80.11:3002/d-solo/${dash}?orgId=1&panelId=${panelId}&from=${from}&to=now&theme=dark&refresh=1m`,
  )
  return (
    <iframe
      src={src}
      title={title}
      loading="lazy"
      className={`w-full rounded-card border border-line bg-panel ${className}`}
      style={{ height: h }}
    />
  )
}
