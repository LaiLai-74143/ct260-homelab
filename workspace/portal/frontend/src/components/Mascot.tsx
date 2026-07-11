import { useEffect, useRef, useState } from 'react'

/** 同 Num/Reveal:啟動時取一次即可,OS 層偏好極少中途翻轉 */
const REDUCED = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

/** 台詞:純裝飾、不引用即時數據(避免與真實狀態打架);點擊依序輪播 */
const QUIPS = [
  '嗨,我是 Clawd,本站吉祥物。',
  '值班中。全站狀態盡收眼底。',
  '嗶。今天防火牆也很硬。',
  '你戳我?我在盯 Prometheus。',
  '綠燈就是最好的消息。',
  '本站由 Claude Code 施工。',
  '再戳就 git blame 你。',
  '目標:crit 保持 0。',
]

/** 吉祥物 Clawd 0.13.0(使用者點名改版):Claude Code 官方像素形象(橘色小方塊+
    黑方眼+側耳+白腳),fixed 漂浮於全頁面(掛 Layout,kiosk 不掛 Layout 故自然豁免)。
    待機:蹲下起立循環+眨眼+眼睛跟隨滑鼠;偶爾顛足球(官方小動畫梗,首次 ~7s、
    之後每 16s 一輪 3.2s);點擊跳一下+台詞泡泡。
    跳躍重播用 class 開關+onAnimationEnd,不換 key(0.12.0 審查教訓:remount 連坐
    重置子孫常駐動畫);動效全進 reduced-motion 殺名單,JS 側 REDUCED 擋足球排程/
    跳躍/眼睛跟隨。外層 pointer-events-none 只留按鈕可點,不擋頁面內容。 */
export default function Mascot() {
  const [poke, setPoke] = useState(0)
  const [jumping, setJumping] = useState(false)
  const [bubble, setBubble] = useState(false)
  const [playing, setPlaying] = useState(false)
  const [eye, setEye] = useState<[number, number]>([0, 0])
  const svgRef = useRef<SVGSVGElement>(null)
  const raf = useRef(0)
  const bubbleT = useRef(0)

  // 偶爾玩足球:首次 7s,之後每 16s 顛球 3.2s
  useEffect(() => {
    if (REDUCED) return
    let endT = 0
    const kick = () => {
      setPlaying(true)
      endT = window.setTimeout(() => setPlaying(false), 3200)
    }
    const first = window.setTimeout(kick, 7000)
    const iv = window.setInterval(kick, 16000)
    return () => { clearTimeout(first); clearTimeout(endT); clearInterval(iv) }
  }, [])

  // 眼睛跟隨滑鼠(rAF 節流+同值守衛;半格步進保持像素感)
  useEffect(() => {
    if (REDUCED) return
    const onMove = (e: MouseEvent) => {
      cancelAnimationFrame(raf.current)
      raf.current = requestAnimationFrame(() => {
        const el = svgRef.current
        if (!el) return
        const r = el.getBoundingClientRect()
        const dx = Math.max(-1, Math.min(1, Math.round((e.clientX - (r.left + r.width / 2)) / 120))) * 0.5
        const dy = Math.max(-1, Math.min(1, Math.round((e.clientY - (r.top + r.height / 2)) / 120))) * 0.5
        setEye((p) => (p[0] === dx && p[1] === dy ? p : [dx, dy]))
      })
    }
    window.addEventListener('mousemove', onMove)
    return () => {
      window.removeEventListener('mousemove', onMove)
      cancelAnimationFrame(raf.current)
    }
  }, [])

  useEffect(() => () => clearTimeout(bubbleT.current), [])

  const doPoke = () => {
    setPoke((p) => p + 1)
    setBubble(true)
    if (!REDUCED) setJumping(true)
    clearTimeout(bubbleT.current)
    bubbleT.current = window.setTimeout(() => setBubble(false), 3500)
  }

  // 眼睛位移走 SVG transform 屬性;眨眼 CSS 動畫掛外層 g——不同元素互不干擾
  const look = `translate(${eye[0]} ${eye[1]})`

  return (
    <div className="pointer-events-none fixed bottom-[calc(72px+env(safe-area-inset-bottom))] right-3 z-40 md:bottom-[18vh] md:right-5">
      <div className="relative">
        {/* 台詞泡泡:活區容器固定掛載(display 切換,不汰換節點) */}
        <div
          role="status"
          className={`absolute bottom-full right-0 mb-2 w-max max-w-[190px] rounded-card border border-line bg-panel px-2.5 py-1.5 text-[11.5px] leading-snug shadow-lg ${bubble ? 'toast-in' : 'hidden'}`}
        >
          {bubble ? QUIPS[poke % QUIPS.length] : ''}
        </div>

        {/* 足球(顛球中才出現):白像素球,與 clawd-kick 跳動同週期 */}
        {playing && (
          <svg viewBox="0 0 8 8" shapeRendering="crispEdges" aria-hidden
               className="clawd-ball absolute bottom-0 right-[46px] h-auto w-[18px]">
            <rect x="2" y="0" width="4" height="8" fill="var(--text)" />
            <rect x="0" y="2" width="8" height="4" fill="var(--text)" />
            <rect x="1" y="1" width="6" height="6" fill="var(--text)" />
            <rect x="3" y="3" width="2" height="2" fill="var(--bg)" />
            <rect x="1" y="2" width="1" height="1" fill="var(--bg)" />
            <rect x="6" y="5" width="1" height="1" fill="var(--bg)" />
          </svg>
        )}

        <button
          type="button"
          onClick={doPoke}
          aria-label="戳一下 Clawd"
          title="Clawd"
          className="pointer-events-auto block cursor-pointer rounded-btn"
        >
          <span
            className={`block ${jumping ? 'clawd-jump' : ''}`.trim()}
            onAnimationEnd={(e) => { if (e.animationName === 'clawd-jump') setJumping(false) }}
          >
            <svg
              ref={svgRef}
              viewBox="0 0 14 12"
              shapeRendering="crispEdges"
              aria-hidden
              className={`h-auto w-[56px] md:w-[64px] ${playing ? 'clawd-kick' : 'clawd-idle'}`}
            >
              {/* 身體:官方橘 --clawd;三段疊出 1px 圓角,不覆畫、不透底 */}
              <g fill="var(--clawd)">
                <rect x="2" y="0" width="10" height="1" />
                <rect x="1" y="1" width="12" height="9" />
                <rect x="2" y="10" width="10" height="1" />
                {/* 側耳 */}
                <rect x="0" y="3" width="1" height="2" />
                <rect x="13" y="3" width="1" height="2" />
              </g>
              {/* 白腳:嵌進身體底部的兩道槽 */}
              <g fill="var(--text)">
                <rect x="3" y="8" width="2" height="3" />
                <rect x="9" y="8" width="2" height="3" />
              </g>
              {/* 黑方眼(整組眨)+跟隨滑鼠 */}
              <g className="clawd-eye">
                <rect className="clawd-pupil" x="3" y="3" width="2" height="2" fill="var(--bg)" transform={look} />
              </g>
              <g className="clawd-eye">
                <rect className="clawd-pupil" x="9" y="3" width="2" height="2" fill="var(--bg)" transform={look} />
              </g>
            </svg>
          </span>
        </button>
      </div>
    </div>
  )
}
