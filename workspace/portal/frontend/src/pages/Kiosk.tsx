import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useStream } from '../api'
import Home from './Home'
import Devices from './Devices'
import Security from './Security'

/**
 * M4 kiosk(§6 RWD/kiosk 條文):無導航、深黑底,自動輪播「大廳→設備→安全」,
 * 供牆面平板(待辦44)直接開 /kiosk 使用。頂層路由繞過 Layout,自持 useStream()。
 */
const SCREENS = [
  { key: 'home', label: '大廳', el: <Home /> },
  { key: 'devices', label: '設備', el: <Devices /> },
  { key: 'security', label: '安全', el: <Security /> },
]

const DEFAULT_INTERVAL_S = 20

/** ?interval=30 可調(秒);非法值回預設,下限 5s 防手滑打字 */
function parseInterval(raw: string | null): number {
  const n = Number(raw)
  if (!raw || !Number.isFinite(n) || n < 5) return DEFAULT_INTERVAL_S
  return Math.floor(n)
}

export default function Kiosk() {
  const [params] = useSearchParams()
  const intervalMs = parseInterval(params.get('interval')) * 1000
  const [i, setI] = useState(0)
  const [paused, setPaused] = useState(false)
  useStream()

  // 換屏是內容更新非裝飾動效,reduced-motion 下輪播照轉、只去掉淡入(瞬切)
  const reduced = useMemo(() => matchMedia('(prefers-reduced-motion: reduce)').matches, [])

  const prev = () => setI((v) => (v + SCREENS.length - 1) % SCREENS.length)
  const next = () => setI((v) => (v + 1) % SCREENS.length)

  // setTimeout 以 i 為 key:手動切屏自然重置計時,暫停即停
  useEffect(() => {
    if (paused) return
    const h = setTimeout(next, intervalMs)
    return () => clearTimeout(h)
  }, [i, paused, intervalMs])

  // 鍵盤 ←/→/空白 與 tap 三分區同義(驗收與除錯用)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'ArrowLeft') prev()
      if (e.key === 'ArrowRight') next()
      if (e.key === ' ') {
        e.preventDefault()
        setPaused((p) => !p)
      }
    }
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [])

  return (
    <div className="kiosk-root relative min-h-screen">
      {/* 內容層:整頁重用既有頁面;pointer-events-none 防牆板誤觸跳路由 */}
      <div
        key={i}
        className={`pointer-events-none mx-auto max-w-[1180px] px-6 py-6 ${reduced ? '' : 'route-fade'}`}
      >
        {SCREENS[i].el}
      </div>

      {/* 觸控層:左 1/3 上一屏 · 中 1/3 暫停/續播 · 右 1/3 下一屏 */}
      <div className="fixed inset-0 z-10 grid grid-cols-3">
        <button aria-label="上一屏" onClick={prev} />
        <button aria-label={paused ? '續播' : '暫停'} onClick={() => setPaused((p) => !p)} />
        <button aria-label="下一屏" onClick={next} />
      </div>

      {/* 指示層:三圓點(active=amber)+ 暫停標記;僅指示,taps 由觸控層接手 */}
      <footer className="pointer-events-none fixed inset-x-0 bottom-3 z-20 flex items-center justify-center gap-2">
        {SCREENS.map((s, n) => (
          <span
            key={s.key}
            className={`h-2 w-2 rounded-full ${n === i ? 'bg-amber' : 'bg-line'}`}
          />
        ))}
        {paused && <span className="ml-2 font-mono text-[11px] text-muted">‖ 已暫停</span>}
      </footer>
    </div>
  )
}
