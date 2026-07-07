import type { HostState } from '../types'

const COLOR: Record<HostState, string> = {
  ok: 'bg-ok',
  warn: 'bg-warn',
  crit: 'bg-crit dot-crit-breathe',
  unk: 'bg-unk',
}

/** 狀態燈 = 8px 圓點(§6):ok 綠、warn 琥珀、crit 紅(呼吸)、unknown 灰 */
export default function Dot({ state, className = '' }: { state: HostState; className?: string }) {
  return <span aria-hidden className={`inline-block h-2 w-2 shrink-0 rounded-full ${COLOR[state]} ${className}`} />
}
