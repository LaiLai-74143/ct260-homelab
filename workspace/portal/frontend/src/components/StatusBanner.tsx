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
      {lag > 60 && (
        <span className="ml-auto font-mono text-[11px] text-muted">數據延遲 {lag}s</span>
      )}
    </div>
  )
}
