import { useState } from 'react'
import { useActionMutation } from '../api'
import type { ActionsInfo, AlertItem } from '../types'
import ConfirmDialog from './ConfirmDialog'
import { useToast } from './Toast'

interface Btn {
  action: string
  param: string | null
  /** 按鈕短文案 */
  short: string
  /** 完整動作描述(確認框「將執行:X」與 toast「已X」共用,命名一致 §7) */
  label: string
  danger?: string
  strong?: boolean
}

/**
 * 單一告警列的動作按鈕排(M3;僅 firing 列掛)。
 * busy=頁面級單飛鎖:全站同時只允許一個動作在飛(與 webhook 全域限速 6/分 對齊)。
 */
export default function AlertActions({
  alert, info, busy, onBusy,
}: {
  alert: AlertItem
  info: ActionsInfo
  busy: boolean
  onBusy: (b: boolean) => void
}) {
  const toast = useToast()
  const mut = useActionMutation()
  const [confirm, setConfirm] = useState<Btn | null>(null)
  const [pending, setPending] = useState<string | null>(null)
  const [sentSilence, setSentSilence] = useState(false)

  const mapped = info.alert_map[alert.name]
  if (info.scope === 'mapped-only' && !mapped) return null

  const btns: Btn[] = []
  if (mapped && info.actions[mapped]) {
    const spec = info.actions[mapped]
    btns.push({ action: mapped, param: null, short: spec.desc, label: spec.desc, danger: spec.danger, strong: true })
  }
  btns.push(
    { action: 'silence-1h', param: alert.name, short: '靜音 1h', label: `靜音 ${alert.name} 1 小時` },
    { action: 'silence-24h', param: alert.name, short: '靜音 24h', label: `靜音 ${alert.name} 24 小時` },
  )

  const fire = (b: Btn) => {
    setConfirm(null)
    setPending(b.action)
    onBusy(true)
    mut.mutate({ action: b.action, param: b.param }, {
      onSettled: () => { setPending(null); onBusy(false) },
      onSuccess: ({ status, data }) => {
        if (status === 202) {
          toast('ok', data.hint || `已送出:${b.label}`)
          return
        }
        toast('ok', `已${b.label}`)
        // AM 靜音生效 + 快取 TTL 有 5–20s 延遲,列消失前給 optimistic 標記,避免「按了沒反應」
        if (b.action.startsWith('silence-')) setSentSilence(true)
      },
      onError: (e) => {
        toast('err', `${b.label} 失敗:${e.error}${e.hint ? ` — ${e.hint}` : ''}`)
      },
    })
  }

  return (
    <div className="mt-2 flex flex-wrap items-center gap-1.5">
      {btns.map((b) => (
        <button
          key={b.action}
          disabled={busy || sentSilence}
          onClick={() => setConfirm(b)}
          className={`btn-press rounded-btn border px-2 py-1 font-mono text-[11px] transition-colors duration-150 disabled:cursor-not-allowed disabled:opacity-40 ${
            b.strong
              ? 'border-amber/60 text-amber hover:enabled:bg-amber/10'
              : 'border-line text-muted hover:enabled:border-amber hover:enabled:text-text'
          }`}
        >
          {pending === b.action ? '執行中…' : b.short}
        </button>
      ))}
      {sentSilence && <span className="font-mono text-[11px] text-muted">已送出靜音,等列表更新…</span>}
      <ConfirmDialog
        open={confirm !== null}
        text={confirm?.label ?? ''}
        danger={confirm?.danger}
        onConfirm={() => confirm && fire(confirm)}
        onCancel={() => setConfirm(null)}
      />
    </div>
  )
}
