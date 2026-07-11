import { useEffect, useRef, useState } from 'react'
import { useAlerts } from '../api'
import ClawdChat from './ClawdChat'

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

/** 六動作(0.15.0:視覺對齊 clawd-on-desk 桌面版——格點 15×16、體色、直縫眼、
    四腿、側臂、地面陰影與各狀態動畫參數皆取自其 SVG 實測值;素材 All Rights
    Reserved 不可取用,圖形全自繪。感知對象是 portal 全站真實狀態):
    idle 待機(呼吸+眨眼+眼神跟隨) / happy 開心(被戳:大跳+揮臂+^^+星光) /
    juggle 雜耍(三球拋物線+搖擺) / notify 通知(warning firing,徽章疊加) /
    error 報錯(critical firing:趴地+××眼+冒煙+ERROR 閃字) /
    sleep 睡覺(23:00–07:00 無 crit:趴地+閉眼縫+像素 Z)。
    優先序:happy > error > sleep > juggle > idle。
    ?clawd=<mood> 可強制預覽(驗收/走查用)。 */
const MOODS = ['idle', 'happy', 'juggle', 'notify', 'error', 'sleep'] as const
type Mood = (typeof MOODS)[number]

function forcedMood(): Mood | null {
  const q = new URLSearchParams(window.location.search).get('clawd')
  return (MOODS as readonly string[]).includes(q ?? '') ? (q as Mood) : null
}

/** 雜耍球:實心球+高光+陰影(軌跡由 .clawd-packet 動畫給;inline transform 是
    reduced-motion 殺動畫後的停靠點,動畫運行時會被覆蓋) */
function Packet({ fill, delay, park }: { fill: string; delay?: string; park: string }) {
  return (
    <g className="clawd-packet" style={{ animationDelay: delay, transform: park }}>
      <circle cx="0" cy="0" r="1.2" fill={fill} />
      <circle cx="-0.35" cy="-0.35" r="0.45" fill="var(--text)" opacity="0.6" />
      <circle cx="0.3" cy="0.4" r="0.6" fill="#000" opacity="0.2" />
    </g>
  )
}

/** 像素星光:中心點+外圈四臂分兩拍閃(happy 專用) */
function Sparkle({ at, delay }: { at: string; delay?: string }) {
  return (
    <g transform={at} fill="var(--amber)" aria-hidden>
      <rect className="clawd-spark-c" x="-0.5" y="-0.5" width="1" height="1" style={{ animationDelay: delay }} />
      <path
        className="clawd-spark-o"
        style={{ animationDelay: delay }}
        d="M -0.5,-1.5 h1 v1 h-1 z M -0.5,0.5 h1 v1 h-1 z M -1.5,-0.5 h1 v1 h-1 z M 0.5,-0.5 h1 v1 h-1 z"
      />
    </g>
  )
}

/** 吉祥物 Clawd:六動作狀態機,fixed 漂浮全頁(掛 Layout,kiosk 不走 Layout
    自然豁免)。台詞泡泡沿用固定活區容器、一次性動效走 class 開關(0.12.0 審查
    教訓:不 key remount、不汰換活區節點);動效全進 reduced-motion 殺名單,
    JS 側 REDUCED 擋排程/開心跳/眼睛跟隨——reduced 下退化為靜態姿勢差分
    (error 仍看得到趴地+××眼+恆亮 ERROR,狀態語義不丟;煙/Z 基態透明自然隱形)。 */
export default function Mascot() {
  const al = useAlerts()
  const [poke, setPoke] = useState(0)
  const [bubble, setBubble] = useState(false)
  const [happy, setHappy] = useState(false)
  const [woke, setWoke] = useState(false)
  const [juggling, setJuggling] = useState(false)
  const [chatOpen, setChatOpen] = useState(false)
  const [hour, setHour] = useState(() => new Date().getHours())
  const [eye, setEye] = useState<[number, number]>([0, 0])
  const svgRef = useRef<SVGSVGElement>(null)
  const raf = useRef(0)
  const bubbleT = useRef(0)
  const happyT = useRef(0)

  // 雜耍排程:首次 7s,之後每 16s 一輪 3.6s(mood 優先序低,error/sleep 時被蓋掉)
  useEffect(() => {
    if (REDUCED) return
    let endT = 0
    const play = () => {
      setJuggling(true)
      endT = window.setTimeout(() => setJuggling(false), 3600)
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

  // 眼神跟隨滑鼠(rAF 節流+同值守衛;半格量化+0.2s transition=平滑滑動)
  useEffect(() => {
    if (REDUCED) return
    const onMove = (e: MouseEvent) => {
      cancelAnimationFrame(raf.current)
      raf.current = requestAnimationFrame(() => {
        const el = svgRef.current
        if (!el) return
        const r = el.getBoundingClientRect()
        const dx = Math.max(-1.5, Math.min(1.5, Math.round((e.clientX - (r.left + r.width / 2)) / 100) * 0.5))
        const dy = Math.max(-1, Math.min(1, Math.round((e.clientY - (r.top + r.height / 2)) / 100) * 0.5))
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
  const showNotify = forced === 'notify' || (forced === null && warn > 0 && mood !== 'error' && mood !== 'happy' && mood !== 'sleep')

  const doPoke = () => {
    setPoke((p) => p + 1)
    setBubble(true)
    setWoke(mood === 'sleep')
    if (!REDUCED) {
      setHappy(true)
      clearTimeout(happyT.current)
      happyT.current = window.setTimeout(() => setHappy(false), 2500)
    }
    clearTimeout(bubbleT.current)
    bubbleT.current = window.setTimeout(() => setBubble(false), 3500)
  }
  const quip = woke && bubble ? '……吵醒我了。' : QUIPS[poke % QUIPS.length]

  const sploot = mood === 'error' || mood === 'sleep'
  const look = { transform: `translate(${eye[0]}px, ${eye[1]}px)` }

  return (
    <div data-mood={mood}
         className="pointer-events-none fixed bottom-[calc(72px+env(safe-area-inset-bottom))] right-3 z-40 md:bottom-[18vh] md:right-5">
      <div className="relative">
        {/* 台詞泡泡:活區容器固定掛載(display 切換,不汰換節點);問答框開著時讓位 */}
        <div
          role="status"
          className={`absolute bottom-full right-0 mb-2 w-max max-w-[190px] rounded-card border border-line bg-panel px-2.5 py-1.5 text-[11.5px] leading-snug shadow-lg ${bubble && !chatOpen ? 'toast-in' : 'hidden'}`}
        >
          {bubble && !chatOpen ? quip : ''}
        </div>

        {/* 右鍵問答框(0.16.0):條件掛載=關閉即銷毀,配合「每問全新」語義 */}
        {chatOpen && <ClawdChat onClose={() => setChatOpen(false)} />}

        <button
          type="button"
          onClick={doPoke}
          onContextMenu={(e) => { e.preventDefault(); setChatOpen(true) }}
          aria-label="戳一下 Clawd"
          title="Clawd(左鍵戳一下,右鍵問問題)"
          className="pointer-events-auto block cursor-pointer rounded-btn"
        >
          {/* happy 大跳掛外層 span,與 svg 內動畫分元素不互搶 */}
          <span className={`block ${mood === 'happy' ? 'clawd-bounce' : ''}`.trim()}>
            <svg
              ref={svgRef}
              viewBox="-1 -8 17 24"
              shapeRendering="crispEdges"
              aria-hidden
              className="h-auto w-[68px] md:w-[76px]"
            >
              <defs>
                {/* 像素 Z(睡覺用,大小兩款) */}
                <g id="clawd-pz">
                  <rect x="0" y="0" width="4" height="1" /><rect x="2" y="1" width="1" height="1" />
                  <rect x="1" y="2" width="1" height="1" /><rect x="0" y="3" width="4" height="1" />
                </g>
                <g id="clawd-pz-s">
                  <rect x="0" y="0" width="3" height="1" /><rect x="1" y="1" width="1" height="1" />
                  <rect x="0" y="2" width="3" height="1" />
                </g>
              </defs>

              {/* 地面陰影(趴地時加寬) */}
              <rect x={sploot ? -1 : 3} y="15" width={sploot ? 17 : 9} height="1" fill="#000" opacity="0.5" />

              {/* 通知:琥珀「!」徽章(頭頂,彈跳;疊加非獨占) */}
              {showNotify && (
                <g className="clawd-badge" fill="var(--amber)">
                  <rect x="12" y="-1" width="1" height="2" />
                  <rect x="12" y="2" width="1" height="1" />
                </g>
              )}

              {/* ---- 站姿(idle / juggle / notify / happy) ---- */}
              {!sploot && (
                <>
                  {/* 雜耍球:--crit/--amber/--ok 三色,同軌錯相位 */}
                  {mood === 'juggle' && (
                    <>
                      <Packet fill="var(--crit)" park="translate(2px, 10px)" />
                      <Packet fill="var(--amber)" delay="-0.4s" park="translate(8px, -1px)" />
                      <Packet fill="var(--ok)" delay="-0.8s" park="translate(14px, 10px)" />
                    </>
                  )}
                  {/* 星光(happy) */}
                  {mood === 'happy' && (
                    <>
                      <Sparkle at="translate(0 2)" />
                      <Sparkle at="translate(15 4)" delay="0.7s" />
                    </>
                  )}
                  {/* 四腿(靜止,呼吸/搖擺不帶動=原版分層) */}
                  <g fill="var(--clawd)">
                    <rect x="3" y="13" width="1" height="2" />
                    <rect x="5" y="13" width="1" height="2" />
                    <rect x="9" y="13" width="1" height="2" />
                    <rect x="11" y="13" width="1" height="2" />
                  </g>
                  {/* 上身:雜耍時外加搖擺層;呼吸恆掛 */}
                  <g className={mood === 'juggle' ? 'clawd-rock' : undefined}>
                    <g className="clawd-breathe-idle">
                      <rect x="2" y="6" width="11" height="7" fill="var(--clawd)" />
                      {/* 側臂:happy 揮舞 / juggle 接拋 / 其餘垂放 */}
                      <g className={mood === 'happy' ? 'clawd-wave-l' : mood === 'juggle' ? 'clawd-arm-jl' : undefined}>
                        <rect x="0" y="9" width="2" height="2" fill="var(--clawd)" />
                      </g>
                      <g className={mood === 'happy' ? 'clawd-wave-r' : mood === 'juggle' ? 'clawd-arm-jr' : undefined}>
                        <rect x="13" y="9" width="2" height="2" fill="var(--clawd)" />
                      </g>
                      {/* 眼睛:happy=^^;其餘=1×2 直縫(外層跟隨/追球,內層眨眼) */}
                      {mood === 'happy' ? (
                        <g fill="var(--bg)">
                          <rect x="3" y="9" width="1" height="1" /><rect x="4" y="8" width="1" height="1" /><rect x="5" y="9" width="1" height="1" />
                          <rect x="9" y="9" width="1" height="1" /><rect x="10" y="8" width="1" height="1" /><rect x="11" y="9" width="1" height="1" />
                        </g>
                      ) : (
                        <g
                          className={mood === 'juggle' ? 'clawd-eyetrack' : 'clawd-eyefollow'}
                          style={mood === 'juggle' ? undefined : look}
                          fill="var(--bg)"
                        >
                          <g className="clawd-blink">
                            <rect x="4" y="8" width="1" height="2" />
                            <rect x="10" y="8" width="1" height="2" />
                          </g>
                        </g>
                      )}
                    </g>
                  </g>
                </>
              )}

              {/* ---- 趴地(error:冒煙+××眼+搧風臂;sleep:深呼吸+閉眼縫+像素 Z) ---- */}
              {mood === 'error' && (
                <>
                  <g fill="var(--muted)">
                    <g className="clawd-smoke">
                      <rect x="-1" y="-1" width="2" height="2" rx="0.5" opacity="0.9" />
                      <rect x="0" y="-2" width="2" height="2" rx="0.5" opacity="0.55" />
                    </g>
                    <g className="clawd-smoke" style={{ animationDelay: '1s', translate: '-2px 0' }}>
                      <rect x="-1" y="-1" width="2" height="2" rx="0.5" opacity="0.9" />
                      <rect x="0" y="-2" width="2" height="2" rx="0.5" opacity="0.55" />
                    </g>
                    <g className="clawd-smoke" style={{ animationDelay: '2s', translate: '2px 0' }}>
                      <rect x="-1" y="-1" width="2" height="2" rx="0.5" opacity="0.9" />
                      <rect x="0" y="-2" width="2" height="2" rx="0.5" opacity="0.55" />
                    </g>
                  </g>
                  <g className="clawd-heavy">
                    <g fill="var(--clawd)">
                      {/* 腿朝上翹(趴倒) */}
                      <rect x="3" y="9" width="1" height="1" />
                      <rect x="5" y="9" width="1" height="1" />
                      <rect x="9" y="9" width="1" height="1" />
                      <rect x="11" y="9" width="1" height="1" />
                      {/* 壓扁軀幹+左臂攤地 */}
                      <rect x="1" y="10" width="13" height="5" />
                      <rect x="-1" y="13" width="2" height="2" />
                    </g>
                    {/* 右臂搧風 */}
                    <g className="clawd-fan">
                      <rect x="13" y="11" width="2" height="2" fill="var(--clawd)" />
                    </g>
                    {/* ××眼 */}
                    <g fill="var(--bg)">
                      <rect x="3" y="12" width="0.6" height="2.2" transform="rotate(45 3.3 13.1)" />
                      <rect x="3" y="12" width="0.6" height="2.2" transform="rotate(-45 3.3 13.1)" />
                      <rect x="10" y="12" width="0.6" height="2.2" transform="rotate(45 10.3 13.1)" />
                      <rect x="10" y="12" width="0.6" height="2.2" transform="rotate(-45 10.3 13.1)" />
                    </g>
                  </g>
                  <text
                    x="7.5" y="5" textAnchor="middle" fontSize="3.5" fontWeight="700"
                    fill="var(--crit)" className="clawd-errflash font-mono"
                  >
                    ERROR
                  </text>
                </>
              )}
              {mood === 'sleep' && (
                <>
                  <g fill="var(--muted)">
                    <use href="#clawd-pz" className="clawd-z1" />
                    <use href="#clawd-pz-s" className="clawd-z2" opacity="0.8" />
                    <use href="#clawd-pz" className="clawd-z3" opacity="0.6" />
                  </g>
                  <g className="clawd-sleep-breathe">
                    <g fill="var(--clawd)">
                      <rect x="3" y="9" width="1" height="1" />
                      <rect x="5" y="9" width="1" height="1" />
                      <rect x="9" y="9" width="1" height="1" />
                      <rect x="11" y="9" width="1" height="1" />
                      <rect x="1" y="10" width="13" height="5" />
                      {/* 雙臂攤地 */}
                      <rect x="-1" y="13" width="2" height="2" />
                      <rect x="14" y="13" width="2" height="2" />
                    </g>
                    {/* 閉眼細縫 */}
                    <g fill="var(--bg)">
                      <rect x="3.5" y="12.5" width="2" height="0.4" />
                      <rect x="9.5" y="12.5" width="2" height="0.4" />
                    </g>
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
