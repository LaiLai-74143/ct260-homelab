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

/** 大廳吉祥物 Clawd(0.12.0,使用者點名):像素小螃蟹,補模塊格右側空位。
    待機:浮動+眨眼+右螯招手+✻ 閃爍;瞳孔跟隨游標;點擊跳一下+換台詞。
    動效全走 CSS class(已進 reduced-motion 殺名單);JS 側 REDUCED 再擋
    游標跟隨與跳躍 class。純裝飾:不掛數據來源;無 fixed 子元素,可安全
    住在任何容器(不觸 ConfirmDialog 的 containing block 不變式)。 */
export default function Mascot({ className = '' }: { className?: string }) {
  const [poke, setPoke] = useState(0)
  const [jumping, setJumping] = useState(false)
  const [eye, setEye] = useState<[number, number]>([0, 0])
  const svgRef = useRef<SVGSVGElement>(null)
  const raf = useRef(0)

  useEffect(() => {
    if (REDUCED || window.location.pathname.startsWith('/kiosk')) return
    const onMove = (e: MouseEvent) => {
      // rAF 節流:每幀最多算一次;同值不 setState,滑鼠掃過不觸發重繪風暴
      cancelAnimationFrame(raf.current)
      raf.current = requestAnimationFrame(() => {
        const el = svgRef.current
        if (!el) return
        const r = el.getBoundingClientRect()
        const dx = Math.max(-1, Math.min(1, Math.round((e.clientX - (r.left + r.width / 2)) / 80)))
        const dy = Math.max(-1, Math.min(1, Math.round((e.clientY - (r.top + r.height * 0.45)) / 80)))
        setEye((p) => (p[0] === dx && p[1] === dy ? p : [dx, dy]))
      })
    }
    window.addEventListener('mousemove', onMove)
    return () => {
      window.removeEventListener('mousemove', onMove)
      cancelAnimationFrame(raf.current)
    }
  }, [])

  // kiosk 牆板複用 <Home />,吉祥物不上牆:不可互動+常駐動效變噪音
  // (render 時判定,同 Reveal——SPA 內切換路由也正確)
  if (window.location.pathname.startsWith('/kiosk')) return null

  // 瞳孔位移走 SVG transform 屬性,與眼睛群組的 CSS 眨眼動畫(不同元素)互不干擾
  const pupil = `translate(${eye[0]} ${eye[1]})`

  return (
    <div
      className={`flex flex-col items-center gap-2 rounded-card border border-line bg-panel p-[13px] text-center md:flex-row md:gap-4 md:px-[18px] md:py-4 md:text-left ${className}`.trim()}
    >
      <button
        type="button"
        onClick={() => { setPoke((p) => p + 1); if (!REDUCED) setJumping(true) }}
        aria-label="戳一下 Clawd"
        title="戳一下"
        className="shrink-0 cursor-pointer rounded-btn"
      >
        {/* 跳躍掛外層 span、浮動掛 svg——transform 動畫分屬不同元素不互搶(0.11.0 教訓)。
            重播不可換 key:remount 會連根重掛整棵 svg,把 bob/眨眼/招手三個常駐動畫
            全部重置歸零,連續戳=螃蟹永不眨眼(0.12.0 審查 CONFIRMED)——
            改 class 開關+onAnimationEnd 收尾;跳到一半再點不重啟,跳完自然歸位 */}
        <span
          className={`inline-block ${jumping ? 'clawd-jump' : ''}`.trim()}
          onAnimationEnd={(e) => { if (e.animationName === 'clawd-jump') setJumping(false) }}
        >
          <svg
            ref={svgRef}
            viewBox="0 0 32 18"
            shapeRendering="crispEdges"
            aria-hidden
            className="clawd-bob h-auto w-[84px] md:w-[100px]"
          >
            {/* 左螯(定)——像素陰影色用 --warn(語義 token 兼深琥珀,不引入新色) */}
            <g fill="var(--warn)">
              <rect x="2" y="9" width="4" height="2" />
              <rect x="0" y="3" width="5" height="6" />
            </g>
            <rect x="0" y="5" width="2" height="2" fill="var(--bg)" />
            {/* 右螯(招手) */}
            <g className="clawd-claw" fill="var(--warn)">
              <rect x="26" y="9" width="4" height="2" />
              <rect x="27" y="3" width="5" height="6" />
              <rect x="30" y="5" width="2" height="2" fill="var(--bg)" />
            </g>
            {/* 身體 */}
            <g fill="var(--amber)">
              <rect x="9" y="2" width="14" height="2" />
              <rect x="7" y="4" width="18" height="2" />
              <rect x="6" y="6" width="20" height="8" />
              <rect x="8" y="14" width="16" height="2" />
            </g>
            {/* 腳 */}
            <g fill="var(--warn)">
              <rect x="8" y="16" width="2" height="2" />
              <rect x="13" y="16" width="2" height="2" />
              <rect x="17" y="16" width="2" height="2" />
              <rect x="22" y="16" width="2" height="2" />
            </g>
            {/* 眼睛(整組眨)+瞳孔(跟游標) */}
            <g className="clawd-eye">
              <rect x="11" y="6" width="4" height="5" fill="var(--text)" />
              <rect className="clawd-pupil" x="12" y="8" width="2" height="2" fill="var(--bg)" transform={pupil} />
            </g>
            <g className="clawd-eye">
              <rect x="17" y="6" width="4" height="5" fill="var(--text)" />
              <rect className="clawd-pupil" x="18" y="8" width="2" height="2" fill="var(--bg)" transform={pupil} />
            </g>
            {/* 嘴 */}
            <rect x="15" y="12" width="2" height="1" fill="var(--bg)" />
          </svg>
        </span>
      </button>

      <div className="min-w-0 flex-1">
        <div className="mb-1 flex items-center justify-center gap-2 font-mono text-[10px] tracking-[.12em] text-muted md:justify-between">
          CLAWD · 站點吉祥物
          <span className="spark-twinkle text-[13px] text-amber" aria-hidden>✻</span>
        </div>
        {/* 台詞:活區容器固定(role="status" 不隨 key 汰換,同 Toast.tsx 模式——
            讀屏靠內容變化播報,汰換整個活區節點會漏/重複播報,0.12.0 審查 minor);
            內層 span 換 key 重播 toast-in(已在殺名單);min-h 預留兩行,換句不跳版 */}
        <div role="status" className="min-h-[2.4em] text-[12.5px] leading-snug">
          <span key={poke} className="toast-in inline-block">{QUIPS[poke % QUIPS.length]}</span>
        </div>
        <div className="mt-1 truncate font-mono text-[11px] text-muted">
          $ clawd --{poke > 0 ? 'poke' : 'idle'}
          <span className="cursor-blink" aria-hidden>▊</span>
        </div>
      </div>
    </div>
  )
}
