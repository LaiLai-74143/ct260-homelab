import { useState } from 'react'
import { IS_HL, useGame, useGameActionMutation } from '../api'
import Bar from '../components/Bar'
import ConfirmDialog from '../components/ConfirmDialog'
import Dot from '../components/Dot'
import Num from '../components/Num'
import PageHead from '../components/PageHead'
import PageSkeleton from '../components/Skeleton'
import { useToast } from '../components/Toast'
import type { Game as GameData } from '../types'

const MCSM_BASE = 'http://10.70.70.20:23333'

/** MCSM 實例狀態 → 顯示文案(busy/starting/stopping=過渡態,控制鍵暫收) */
const STATE_TEXT: Record<string, string> = {
  running: '運行中', stopped: '已停機', starting: '啟動中…', stopping: '停止中…', busy: '處理中…',
}

/** MCSM 控制鍵(open/stop/restart,走 protected_instance 優雅開停,非殺 Java 進程)。
    單飛:一動作在飛時全排 disabled;stop/restart 帶 danger 走確認框。 */
function GameControls({ d }: { d: GameData }) {
  const ctl = d.control
  const toast = useToast()
  const mut = useGameActionMutation()
  const [confirm, setConfirm] = useState<{ action: string; desc: string; danger?: string } | null>(null)
  const [pending, setPending] = useState<string | null>(null)

  if (!ctl?.enabled) {
    return (
      <div className="mb-3.5 rounded-card border border-dashed border-line px-4 py-3 text-[12.5px] text-muted">
        伺服器控制未配置(portal.env 補 MCSM_CTRL_KEY 後生效)。
      </div>
    )
  }
  if (!ctl.allowed) {
    return (
      <div className="mb-3.5 rounded-card border border-dashed border-line px-4 py-3 text-[12.5px] text-muted">
        控制鍵僅開放 portal.hl 登入或 PC40 使用。
      </div>
    )
  }

  // 停機顯示啟動;運行顯示停止+重啟(白名單三動作,不含 kill/檔案);
  // 過渡態(starting/stopping/busy)收起全部按鍵等狀態落定
  const keys = d.instance_state === 'running' ? ['stop', 'restart']
    : d.instance_state === 'stopped' ? ['open'] : []
  const busy = pending !== null

  if (keys.length === 0) {
    return (
      <div className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3 text-[12.5px] text-muted">
        伺服器控制:{STATE_TEXT[d.instance_state] ?? d.instance_state}(狀態切換中,稍候自動更新)
      </div>
    )
  }

  const fire = (action: string, desc: string) => {
    setConfirm(null)
    setPending(action)
    mut.mutate({ action }, {
      onSettled: () => setPending(null),
      onSuccess: () => toast('ok', `已送出:${desc}(MCSM 執行中,狀態稍後更新)`),
      onError: (e) => toast('err', `${desc}失敗:${e.error}${e.hint ? ` — ${e.hint}` : ''}`),
    })
  }

  return (
    <div className="mb-3.5 flex flex-wrap items-center gap-2">
      <span className="mr-1 font-mono text-[11px] tracking-[.12em] text-muted">伺服器控制</span>
      {keys.map((k) => {
        const spec = ctl.actions[k]
        if (!spec) return null
        const strong = k === 'open'
        return (
          <button
            key={k}
            disabled={busy}
            onClick={() => setConfirm({ action: k, desc: spec.desc, danger: spec.danger })}
            className={`btn-press rounded-btn border px-3 py-1.5 font-mono text-[12px] transition-colors duration-150 disabled:cursor-not-allowed disabled:opacity-40 ${
              strong
                ? 'border-ok/60 text-ok hover:enabled:bg-ok/10'
                : 'border-amber/60 text-amber hover:enabled:bg-amber/10'
            }`}
          >
            {pending === k ? '執行中…' : spec.desc}
          </button>
        )
      })}
      <ConfirmDialog
        open={confirm !== null}
        text={confirm?.desc ?? ''}
        danger={confirm?.danger}
        onConfirm={() => confirm && fire(confirm.action, confirm.desc)}
        onCancel={() => setConfirm(null)}
      />
    </div>
  )
}

/** MCSM 網頁終端機:LAN/PC40(http)直接 iframe;portal.hl(HTTPS)無法內嵌 http 終端
    (混合內容),不顯示任何東西,由頁尾單一 MCSM 面板連結進入(0.8.2 拔提示行)。 */
function GameTerminal({ d }: { d: GameData }) {
  if (IS_HL || !d.instance_uuid || !d.daemon_id) return null
  const termUrl = `${MCSM_BASE}/#/instances/terminal?daemonId=${d.daemon_id}&instanceId=${d.instance_uuid}`

  return (
    <section className="mt-3.5">
      <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">
        MCSM 網頁終端機(需先於 MCSM 面板登入;空白=未登入或連不到)
      </div>
      <iframe
        src={termUrl}
        title="MCSM 網頁終端機"
        loading="lazy"
        className="w-full rounded-card border border-line bg-panel"
        style={{ height: 460 }}
      />
    </section>
  )
}

export default function Game() {
  const gm = useGame()
  const d = gm.data

  return (
    <>
      <PageHead title="遊戲" right="mc.lailai74143.com" />
      {gm.isError && !d && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到遊戲數據——檢查 BFF /api/game。
        </div>
      )}
      {!d && !gm.isError && <PageSkeleton tiles={2} rows={2} />}
      {d && (
        <>
          <div className="mb-3.5 grid grid-cols-2 gap-2.5">
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 flex items-center gap-2 text-[12px] text-muted">
                <Dot state={
                  d.instance_state === 'running' ? (d.server_up ? 'ok' : 'crit')
                  : d.instance_state === 'stopped' ? 'unk' : 'warn'} />
                Minecraft 伺服器
              </div>
              <div className="font-mono text-2xl font-semibold">
                {/* instance_state=MCSM 權威狀態;running 但 exporter down=主機異常;
                    Num 非數值不滾動、只在狀態變時微閃(含 D4 樂觀切換那一下) */}
                <Num value={d.instance_state === 'running' && !d.server_up ? '異常'
                  : STATE_TEXT[d.instance_state] ?? '異常'} />
              </div>
              <div className="mt-1 font-mono text-[11px] text-muted">MCSM {d.instance_state}</div>
            </div>
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 text-[12px] text-muted">在線玩家</div>
              <div className="font-mono text-2xl font-semibold">
                <Num value={String(d.players_online ?? '—')} />
              </div>
              {d.players_online === null && (
                <div className="mt-1 text-[11.5px] text-muted">{d.note}</div>
              )}
              {(d.player_names ?? []).length > 0 && (
                <div className="mt-1 font-mono text-[11.5px] text-muted">{d.player_names!.join(' · ')}</div>
              )}
            </div>
          </div>

          {/* 控制鍵(2026-07-09 使用者點名):走 MCSM 優雅開/停/重啟,非粗暴殺進程 */}
          <GameControls d={d} />

          <div className="grid grid-cols-1 gap-2.5 md:grid-cols-2">
            {d.hosts.map((h) => (
              <div key={h.name} className={`rounded-card border border-line bg-panel px-3.5 py-[13px] ${h.up ? '' : 'opacity-55'}`}>
                <div className="mb-2 flex items-center gap-2">
                  <Dot state={h.up ? 'ok' : 'unk'} />
                  <span className="font-mono text-[13.5px] font-semibold">{h.name}</span>
                </div>
                <Bar k="cpu" v={h.cpu} />
                <Bar k="mem" v={h.mem} />
              </div>
            ))}
          </div>

          {/* MCSM 網頁終端機(2026-07-09 使用者點名):LAN 嵌入,portal.hl 連結 */}
          <GameTerminal d={d} />

          {/* 唯一 MCSM 入口:面板(實例管理+網頁終端都在裡面);PC40 直達,手機發證後可達 */}
          <a href={MCSM_BASE} target="_blank" rel="noreferrer"
             className="mt-3.5 block rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px] transition-colors duration-150 hover:border-amber">
            MCSManager 面板(實例管理／網頁終端)→ <span className="font-mono text-[12px] text-muted">10.70.70.20:23333 ↗</span>
          </a>
        </>
      )}
    </>
  )
}
