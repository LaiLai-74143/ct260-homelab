import { useEffect, useRef } from 'react'

/** 同 Num/Reveal:啟動時取一次即可 */
const REDUCED = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

const GRID = 44
const DOTS = 14

/**
 * 背景氛圍層(0.17.0 P1):極淡網格+沿格線緩慢流動的光點(呼應 Clawd 的
 * juggle 封包梗)。掛牆常駐的頁面不能燒 CPU——約束全在這:
 * ・~30fps 上限、dpr 封頂 2、分頁 hidden 即停 rAF;
 * ・REDUCED 只畫一次靜態網格,不起 rAF;
 * ・crit 時封包轉紅、夜間再降亮度(逐幀讀 html class,與 EnvProvider 聯動)。
 * z-index 0 疊在 body 背景之上、內容(z≥1 或 DOM 序在後的定位元素)之下。
 */
export default function Ambient() {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const cv = ref.current
    const ctx = cv?.getContext('2d')
    if (!cv || !ctx) return
    let W = 0
    let H = 0
    let raf = 0
    let last = 0
    let dots: { horiz: boolean; c: number; p: number; v: number }[] = []

    const drawGrid = () => {
      ctx.clearRect(0, 0, W, H)
      ctx.strokeStyle = 'rgba(138,148,163,.05)'
      ctx.lineWidth = 1
      ctx.beginPath()
      for (let x = GRID; x < W; x += GRID) { ctx.moveTo(x, 0); ctx.lineTo(x, H) }
      for (let y = GRID; y < H; y += GRID) { ctx.moveTo(0, y); ctx.lineTo(W, y) }
      ctx.stroke()
    }

    const frame = (t: number) => {
      const gap = t - last
      if (gap < 33) { raf = requestAnimationFrame(frame); return } // ~30fps 封頂
      const dt = Math.min(100, gap)
      last = t
      drawGrid()
      const cls = document.documentElement.classList
      const col = cls.contains('crit') ? '229,83,75' : '232,163,61'
      const a = cls.contains('night') ? 0.14 : 0.22
      ctx.shadowBlur = 8
      ctx.shadowColor = `rgba(${col},.6)`
      ctx.fillStyle = `rgba(${col},${a})`
      for (const d of dots) {
        d.p += (d.v * dt) / 1000
        const lim = d.horiz ? W : H
        if (d.p < 0) d.p += lim
        if (d.p > lim) d.p -= lim
        ctx.beginPath()
        ctx.arc(d.horiz ? d.p : d.c, d.horiz ? d.c : d.p, 1.6, 0, 7)
        ctx.fill()
      }
      ctx.shadowBlur = 0
      raf = requestAnimationFrame(frame)
    }

    const size = () => {
      const dpr = Math.min(2, window.devicePixelRatio || 1)
      W = window.innerWidth
      H = window.innerHeight
      cv.width = W * dpr
      cv.height = H * dpr
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      // 封包:各沿隨機一條格線單向漂移(速度 20–65px/s、方向隨機)
      dots = Array.from({ length: DOTS }, () => {
        const horiz = Math.random() < 0.55
        const span = horiz ? H : W
        return {
          horiz,
          c: GRID * Math.max(1, Math.floor(Math.random() * (span / GRID))),
          p: Math.random() * (horiz ? W : H),
          v: (20 + Math.random() * 45) * (Math.random() < 0.5 ? -1 : 1),
        }
      })
      if (REDUCED) drawGrid()
    }

    const onVis = () => {
      if (REDUCED) return
      // 先無條件 cancel 再視情況重排:隱藏分頁裡掛載排下的 rAF 只是被延後不是取消,
      // 切回前景時不 cancel 會養出第二條迴圈=雙倍重繪(0.17.0 審查 CONFIRMED)
      cancelAnimationFrame(raf)
      if (!document.hidden) { last = performance.now(); raf = requestAnimationFrame(frame) }
    }

    window.addEventListener('resize', size)
    document.addEventListener('visibilitychange', onVis)
    size()
    if (!REDUCED && !document.hidden) { last = performance.now(); raf = requestAnimationFrame(frame) }
    return () => {
      window.removeEventListener('resize', size)
      document.removeEventListener('visibilitychange', onVis)
      cancelAnimationFrame(raf)
    }
  }, [])

  return <canvas ref={ref} aria-hidden className="pointer-events-none fixed inset-0 z-0" />
}
