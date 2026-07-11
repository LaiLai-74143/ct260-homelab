import { useEffect, useRef, useState } from 'react'
import { useAlerts } from '../api'

/** 同 Num/Reveal:啟動時取一次即可,OS 層偏好極少中途翻轉 */
const REDUCED = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

/** 台詞:純裝飾;點擊依序輪播(睡覺時被戳有專屬台詞) */
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

/** 六動作(借鏡 clawd-on-desk 的狀態機,素材 All Rights Reserved 不可取用,
    全部自繪;原專案感知 AI 助手狀態,這裡改感知 portal 全站真實狀態):
    idle 待機 / happy 開心(被戳) / juggle 三球雜耍(定時) /
    notify 通知(warning firing,徽章疊加) / error 報錯(critical firing) /
    sleep 睡覺(23:00–07:00 無 crit)。優先序:happy > error > sleep > juggle > idle。
    ?clawd=<mood> 可強制預覽(驗收/走查用)。 */
const MOODS = ['idle', 'happy', 'juggle', 'notify', 'error', 'sleep'] as const
type Mood = (typeof MOODS)[number]

function forcedMood(): Mood | null {
  const q = new URLSearchParams(window.location.search).get('clawd')
  return (MOODS as readonly string[]).includes(q ?? '') ? (q as Mood) : null
}

/** 白像素球(雜耍用) */
function Ball({ className = '', delay = '0s' }: { className?: string; delay?: string }) {
  return (
    <svg viewBox="0 0 8 8" shapeRendering="crispEdges" aria-hidden
         className={`clawd-ball absolute h-auto w-[14px] ${className}`} style={{ animationDelay: delay }}>
      <rect x="2" y="0" width="4" height="8" fill="var(--text)" />
      <rect x="0" y="2" width="8" height="4" fill="var(--text)" />
      <rect x="1" y="1" width="6" height="6" fill="var(--text)" />
      <rect x="3" y="3" width="2" height="2" fill="var(--bg)" />
      <rect x="1" y="2" width="1" height="1" fill="var(--bg)" />
      <rect x="6" y="5" width="1" height="1" fill="var(--bg)" />
    </svg>
  )
}

/** 吉祥物 Clawd 0.14.0:官方像素形象+六動作狀態機,fixed 漂浮全頁(掛 Layout,
    kiosk 不走 Layout 自然豁免)。跳躍/台詞泡泡沿用 class 開關+固定活區容器
    (0.12.0 審查教訓:不 key remount、不汰換活區節點);動效全進 reduced-motion
    殺名單,JS 側 REDUCED 擋排程/跳躍/眼睛跟隨——reduced 下六動作退化為靜態
    表情差分(error 仍看得到紅!與××眼,狀態語義不丟)。 */
export default function Mascot() {
  const al = useAlerts()
  const [poke, setPoke] = useState(0)
  const [jumping, setJumping] = useState(false)
  const [bubble, setBubble] = useState(false)
  const [happy, setHappy] = useState(false)
  const [juggling, setJuggling] = useState(false)
  const [hour, setHour] = useState(() => new Date().getHours())
  const [eye, setEye] = useState<[number, number]>([0, 0])
  const svgRef = useRef<SVGSVGElement>(null)
  const raf = useRef(0)
  const bubbleT = useRef(0)
  const happyT = useRef(0)

  // 雜耍排程:首次 7s,之後每 16s 一輪 3.2s(mood 優先序低,error/sleep 時被蓋掉)
  useEffect(() => {
    if (REDUCED) return
    let endT = 0
    const play = () => {
      setJuggling(true)
      endT = window.setTimeout(() => setJuggling(false), 3200)
    }
    const first = window.setTimeout(play, 7000)
    const iv = window.setInterval(play, 16000)
    return () => { clearTimeout(first); clearTimeout(endT); clearInterval(iv) }
  }, [])

  // 睡覺判定用時鐘(每分鐘對表)
  useEffect(() => {
    const iv = window.setInterval(() => setHour(new Date().getHours()), 60_000)
    return () => clearInterval(iv)
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

  useEffect(() => () => { clearTimeout(bubbleT.current); clearTimeout(happyT.current) }, [])

  // ---- 六動作狀態機 ----
  const firing = al.data?.firing ?? []
  const crit = firing.filter((a) => a.severity === 'critical').length
  const warn = firing.length - crit
  const night = hour >= 23 || hour < 7
  const forced = forcedMood()
  const mood: Mood = forced ?? (
    happy ? 'happy'
    : crit > 0 ? 'error'
    : night ? 'sleep'
    : juggling ? 'juggle'
    : 'idle'
  )
  // notify 是徽章疊加非獨占動作(homelab 常駐 1 條 warning 很正常,不鎖死本體)
  const showNotify = forced === 'notify' || (forced === null && warn > 0 && mood !== 'error' && mood !== 'happy')

  const wasAsleep = mood === 'sleep'
  const doPoke = () => {
    setPoke((p) => p + 1)
    setBubble(true)
    if (!REDUCED) {
      setJumping(true)
      setHappy(true)
      clearTimeout(happyT.current)
      happyT.current = window.setTimeout(() => setHappy(false), 2500)
    }
    clearTimeout(bubbleT.current)
    bubbleT.current = window.setTimeout(() => setBubble(false), 3500)
  }
  const quip = wasAsleep && bubble ? '……吵醒我了。' : QUIPS[poke % QUIPS.length]

  const bodyClass =
    mood === 'error' ? 'clawd-shake'
    : mood === 'sleep' ? 'clawd-breathe'
    : mood === 'juggle' ? 'clawd-kick'
    : 'clawd-idle'

  // 眼睛位移走 SVG transform 屬性;眨眼 CSS 動畫掛外層 g——不同元素互不干擾
  const look = `translate(${eye[0]} ${eye[1]})`

  return (
    <div data-mood={mood}
         className="pointer-events-none fixed bottom-[calc(72px+env(safe-area-inset-bottom))] right-3 z-40 md:bottom-[18vh] md:right-5">
      <div className="relative">
        {/* 台詞泡泡:活區容器固定掛載(display 切換,不汰換節點) */}
        <div
          role="status"
          className={`absolute bottom-full right-0 mb-2 w-max max-w-[190px] rounded-card border border-line bg-panel px-2.5 py-1.5 text-[11.5px] leading-snug shadow-lg ${bubble ? 'toast-in' : 'hidden'}`}
        >
          {bubble ? quip : ''}
        </div>

        {/* 三球雜耍(cascade:同弧線錯相位) */}
        {mood === 'juggle' && (
          <>
            <Ball className="-top-7 right-[6px]" />
            <Ball className="-top-7 right-[26px]" delay="0.35s" />
            <Ball className="-top-7 right-[46px]" delay="0.7s" />
          </>
        )}

        {/* 睡覺 zzz */}
        {mood === 'sleep' && (
          <div className="absolute -top-6 right-0 font-mono text-muted" aria-hidden>
            <span className="clawd-zzz inline-block text-[12px]">z</span>
            <span className="clawd-zzz ml-0.5 inline-block text-[10px]" style={{ animationDelay: '0.6s' }}>z</span>
            <span className="clawd-zzz ml-0.5 inline-block text-[9px]" style={{ animationDelay: '1.2s' }}>z</span>
          </div>
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
              viewBox="0 -6 14 18"
              shapeRendering="crispEdges"
              aria-hidden
              className={`h-auto w-[56px] md:w-[64px] ${bodyClass}`}
            >
              {/* 報錯:紅色「!」+ 通知:琥珀「!」(頭頂徽章,彈跳) */}
              {mood === 'error' && (
                <g className="clawd-badge" fill="var(--crit)">
                  <rect x="6" y="-6" width="2" height="3" />
                  <rect x="6" y="-2" width="2" height="1" />
                </g>
              )}
              {showNotify && mood !== 'error' && (
                <g className="clawd-badge" fill="var(--amber)">
                  <rect x="11" y="-5" width="1" height="2" />
                  <rect x="11" y="-2" width="1" height="1" />
                </g>
              )}
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
              {/* 眼睛四態:happy=^^、error=××、sleep=閉眼線、其餘=方眼(眨+跟滑鼠) */}
              {mood === 'happy' && (
                <g fill="var(--bg)">
                  <rect x="3" y="4" width="1" height="1" /><rect x="4" y="3" width="1" height="1" /><rect x="5" y="4" width="1" height="1" />
                  <rect x="9" y="4" width="1" height="1" /><rect x="10" y="3" width="1" height="1" /><rect x="11" y="4" width="1" height="1" />
                </g>
              )}
              {mood === 'error' && (
                <g fill="var(--bg)">
                  <rect x="3" y="3" width="1" height="1" /><rect x="5" y="3" width="1" height="1" /><rect x="4" y="4" width="1" height="1" /><rect x="3" y="5" width="1" height="1" /><rect x="5" y="5" width="1" height="1" />
                  <rect x="9" y="3" width="1" height="1" /><rect x="11" y="3" width="1" height="1" /><rect x="10" y="4" width="1" height="1" /><rect x="9" y="5" width="1" height="1" /><rect x="11" y="5" width="1" height="1" />
                </g>
              )}
              {mood === 'sleep' && (
                <g fill="var(--bg)">
                  <rect x="3" y="4" width="3" height="1" />
                  <rect x="9" y="4" width="3" height="1" />
                </g>
              )}
              {mood !== 'happy' && mood !== 'error' && mood !== 'sleep' && (
                <>
                  <g className="clawd-eye">
                    <rect className="clawd-pupil" x="3" y="3" width="2" height="2" fill="var(--bg)" transform={look} />
                  </g>
                  <g className="clawd-eye">
                    <rect className="clawd-pupil" x="9" y="3" width="2" height="2" fill="var(--bg)" transform={look} />
                  </g>
                </>
              )}
            </svg>
          </span>
        </button>
      </div>
    </div>
  )
}
