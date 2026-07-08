import { useEffect, useRef } from 'react'
import uPlot from 'uplot'
import 'uplot/dist/uPlot.min.css'

/**
 * sparkline(§5 選型 uPlot):單序列、無軸無圖例,線色一律 muted、
 * 顏色語義只留給狀態燈——圖是資訊不是裝飾。
 */
export default function Spark({ data, height = 54 }: { data: [number, number][]; height?: number }) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el || data.length < 2) return
    const xs = data.map((d) => d[0])
    const ys = data.map((d) => d[1])
    const chart = new uPlot({
      width: el.clientWidth || 200,
      height,
      cursor: { show: false },
      legend: { show: false },
      axes: [{ show: false }, { show: false }],
      scales: { x: { time: true } },
      // #8A94A3 = --muted token(uPlot 需字面值,不能吃 CSS var);改 token 時同步此處
      series: [{}, { stroke: '#8A94A3', width: 1.5, fill: 'rgba(138,148,163,0.08)', points: { show: false } }],
    }, [xs, ys], el)
    // resize 用 setSize,不整棵重建(RO 初始回呼也不會造成雙重建)
    const ro = new ResizeObserver(() => {
      if (el.clientWidth > 0) chart.setSize({ width: el.clientWidth, height })
    })
    ro.observe(el)
    return () => { ro.disconnect(); chart.destroy() }
  }, [data, height])

  if (data.length < 2) {
    // 單點畫不出線段,與空數據同樣誠實顯示
    return <div className="flex items-center justify-center font-mono text-[11px] text-muted" style={{ height }}>無數據</div>
  }
  return <div ref={ref} />
}
