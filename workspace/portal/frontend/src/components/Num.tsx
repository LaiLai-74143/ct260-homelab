import { useEffect, useRef, useState } from 'react'

/** 啟動時取一次即可:OS 層偏好極少中途翻轉,省去每實例掛 listener */
const REDUCED = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

/** 大數字(絲滑包 D3):值變時 count-up ~400ms + 一次性琥珀微閃(data-flash);
    非數值(—、中文狀態字)直接切換、只閃不滾;reduced-motion 跳值不閃。
    微閃靠換 key 重建 span 重播 CSS 動畫,首載(flash=0)不閃。 */
export default function Num({ value, unit, className }: { value: string; unit?: string; className?: string }) {
  const [shown, setShown] = useState(value)
  const [flash, setFlash] = useState(0)
  const prev = useRef(value)
  const raf = useRef(0)

  useEffect(() => {
    if (value === prev.current) return
    // 先殺舊動畫再分流:否則數值→非數值時殘留的 tick 閉包會把剛設好的「—」
    // 蓋回過期數字(0.10.0 審查 CONFIRMED)
    cancelAnimationFrame(raf.current)
    // 從畫面當前值(可能是上一輪滾動中的中繼值)起跳,連續變動不跳點
    const from = Number(shown)
    const to = Number(value)
    prev.current = value
    if (!REDUCED) setFlash((f) => f + 1)
    // 兩端都是有限數才滾動;count-up 過程定格目標值的小數位數,避免位數抖動
    if (REDUCED || !Number.isFinite(from) || !Number.isFinite(to)) { setShown(value); return }
    const dec = (value.split('.')[1] ?? '').length
    const t0 = performance.now()
    const tick = (t: number) => {
      const p = Math.min(1, (t - t0) / 400)
      const eased = 1 - (1 - p) ** 3
      setShown(p >= 1 ? value : (from + (to - from) * eased).toFixed(dec))
      if (p < 1) raf.current = requestAnimationFrame(tick)
    }
    raf.current = requestAnimationFrame(tick)
  }, [value])
  useEffect(() => () => cancelAnimationFrame(raf.current), [])

  return (
    <span key={flash} className={`${flash > 0 ? 'data-flash' : ''} ${className ?? ''}`.trim()}>
      {shown}
      {unit && <span className="text-[13px] font-normal text-muted">{unit}</span>}
    </span>
  )
}
