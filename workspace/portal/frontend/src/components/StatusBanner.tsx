import Dot from './Dot'
import type { HostState } from '../types'

export default function StatusBanner({
  state, text, lag,
}: { state: HostState; text: string; lag: number }) {
  return (
    <div
      className={`mb-[18px] flex items-center gap-[10px] rounded-card border bg-panel px-4 py-[11px] text-sm ${
        state === 'crit' ? 'border-crit/45' : state === 'warn' ? 'border-warn/45' : 'border-line'
      }`}
    >
      <Dot state={state} />
      <span>{text}</span>
      {/* 命令面板無鍵盤入口(0.17.0):手機沒有 ⌘K,這顆鈕就是入口 */}
      <button
        type="button"
        onClick={() => window.dispatchEvent(new CustomEvent('cmdk-open'))}
        className="btn-press ml-auto rounded-btn border border-line px-2 py-0.5 font-mono text-[11px] text-muted transition-colors duration-150 hover:border-amber hover:text-text"
      >
        ⌘K 搜尋
      </button>
      {lag > 60 && (
        <span className="font-mono text-[11px] text-muted">數據延遲 {lag}s</span>
      )}
    </div>
  )
}
