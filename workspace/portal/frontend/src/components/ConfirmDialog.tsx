import { useEffect } from 'react'

/** 二次確認(M3 §7):寫明將執行什麼;danger 動作追加琥珀警告行;Esc/遮罩=取消 */
export default function ConfirmDialog({
  open, text, danger, onConfirm, onCancel,
}: {
  open: boolean
  text: string
  danger?: string
  onConfirm: () => void
  onCancel: () => void
}) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onCancel() }
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [open, onCancel])

  if (!open) return null
  return (
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center bg-bg/80 px-6"
      role="dialog"
      aria-modal="true"
      onClick={onCancel}
    >
      <div
        className="route-fade w-full max-w-[380px] rounded-card border border-line bg-panel p-5"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="font-serif text-[15px] font-bold">確認執行</div>
        <div className="mt-2.5 text-[13.5px]">將執行:{text}</div>
        {danger && <div className="mt-2 text-[12.5px] text-warn">⚠ {danger}</div>}
        <div className="mt-4 flex justify-end gap-2">
          <button
            autoFocus
            onClick={onCancel}
            className="rounded-btn border border-line px-3 py-1.5 text-[12.5px] text-muted transition-colors duration-150 hover:text-text"
          >
            取消
          </button>
          <button
            onClick={onConfirm}
            className="rounded-btn border border-amber px-3 py-1.5 text-[12.5px] text-amber transition-colors duration-150 hover:bg-amber/10"
          >
            確認執行
          </button>
        </div>
      </div>
    </div>
  )
}
