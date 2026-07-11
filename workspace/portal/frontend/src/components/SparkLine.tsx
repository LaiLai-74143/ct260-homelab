import type { HostState } from '../types'

/**
 * 卡片迷你趨勢線(0.17.0):純 SVG 折線+面積,等距取樣、無軸無互動,
 * preserveAspectRatio none 隨卡面伸縮;顏色跟卡片狀態燈(範本 v0.17 使用者定案,
 * 偏離 0.8.0 Spark「線色一律 muted」原則——迷你線的役割是「一眼看升降」,
 * 與設備頁 uPlot 真圖表不同役)。數據不足兩點不畫(誠實缺席,不擺直線)。
 */
export default function SparkLine({ data, state }: { data: [number, number][]; state: HostState }) {
  if (data.length < 2) return null
  const w = 100
  const h = 28
  const ys = data.map((d) => d[1])
  const mn = Math.min(...ys)
  const rg = Math.max(...ys) - mn || 1
  const pts = data
    .map((d, i) => `${((i / (data.length - 1)) * w).toFixed(1)},${(h - 3 - ((d[1] - mn) / rg) * (h - 8)).toFixed(1)}`)
    .join(' ')
  return (
    <svg className={`spark ${state}`} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden>
      <polygon className="ar" points={`0,${h} ${pts} ${w},${h}`} />
      <polyline className="ln" points={pts} />
    </svg>
  )
}
