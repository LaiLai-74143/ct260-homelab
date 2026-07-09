/** Grafana d-solo 單面板嵌入(0.8.1 改走 BFF 同源反代)。
    src=/grafana/d-solo/...(portal 自己的網域)→ BFF 反代到 Grafana :3002 匿名讀。
    同源=無混合內容、無跨網域 cookie、iframe 裡不碰 Authelia,portal.hl 與 :8088 一致。
    (0.7.0 曾直指 grafana.hl,portal.hl 因跨子網域 SameSite cookie 被擋而失敗;見 grafana_proxy.py)
    空白框=BFF 連不到 Grafana,或 Grafana 匿名 Viewer 未開(finish-grafana-embed.sh)。 */
export default function GrafanaPanel({ dash, panelId, title, h = 280, from = 'now-6h', className = '' }: {
  dash: string
  panelId: number
  title: string
  /** iframe 高度 px(Grafana 格高 1 單位≈30px) */
  h?: number
  from?: string
  className?: string
}) {
  const src = `/grafana/d-solo/${dash}?orgId=1&panelId=${panelId}&from=${from}&to=now&theme=dark&refresh=1m`
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
