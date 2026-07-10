import { Link } from 'react-router-dom'
import Dot from './Dot'
import Num from './Num'
import type { HostState } from '../types'

export interface ModuleCardData {
  route: string
  name: string
  big: string
  bigUnit?: string
  sub: string
  state: HostState
}

export default function ModuleCard({ m }: { m: ModuleCardData }) {
  return (
    <Link
      to={m.route}
      viewTransition
      className="block cursor-pointer rounded-card border border-line bg-panel p-[13px] transition-colors duration-150 hover:border-amber md:px-[18px] md:py-4"
    >
      <div className="mb-2.5 flex items-center justify-between">
        <span className="text-[15px] font-bold">{m.name}</span>
        <Dot state={m.state} />
      </div>
      <div className="mb-0.5 font-mono text-xl font-semibold md:text-2xl">
        {/* SSE 覆寫快取 → 值變時 count-up+微閃(D3),讓「即時」看得見 */}
        <Num value={m.big} unit={m.bigUnit} />
      </div>
      <div className="text-[12.5px] text-muted">{m.sub}</div>
    </Link>
  )
}
