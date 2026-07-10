import { useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'

/** 啟動時取一次即可(同 Num.tsx):OS 層偏好極少中途翻轉 */
const REDUCED = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

/** 滾動進場(0.11.0):板塊滑入視口時一次性 fade+上滑(展示頁式過渡)。
    stagger=容器不動、子元素級聯(把 Reveal 直接當網格容器用,className 傳 grid 類)。
    豁免即「不掛 class」而非「掛了再殺」:reduced-motion、kiosk(牆板 20s 輪播
    remount 會反覆重播)、無 IntersectionObserver——三者內容都直接可見,
    不存在 JS 沒跑導致內容藏死的狀態。進場只播一次(unobserve),回滑不重播。 */
export default function Reveal({ children, stagger = false, className = '' }: {
  children: ReactNode
  stagger?: boolean
  className?: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const skip = REDUCED
    || typeof IntersectionObserver === 'undefined'
    || window.location.pathname.startsWith('/kiosk')
  const [shown, setShown] = useState(skip)

  useEffect(() => {
    if (skip || shown) return
    const el = ref.current
    if (!el) { setShown(true); return }
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) { setShown(true); io.disconnect() }
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 })
    io.observe(el)
    return () => io.disconnect()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const cls = skip ? '' : `${stagger ? 'reveal-stagger' : 'reveal'} ${shown ? 'reveal-in' : ''}`
  return (
    <div ref={ref} className={`${cls} ${className}`.trim()}>
      {children}
    </div>
  )
}
