import { Link } from 'react-router-dom'
import Dot from './Dot'
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
      className="block cursor-pointer rounded-card border border-line bg-panel p-[13px] transition-colors duration-150 hover:border-amber md:px-[18px] md:py-4"
    >
      <div className="mb-2.5 flex items-center justify-between">
        <span className="text-[15px] font-bold">{m.name}</span>
        <Dot state={m.state} />
      </div>
      <div className="mb-0.5 font-mono text-xl font-semibold md:text-2xl">
        {m.big}
        {m.bigUnit && <span className="text-[13px] font-normal text-muted">{m.bigUnit}</span>}
      </div>
      <div className="text-[12.5px] text-muted">{m.sub}</div>
    </Link>
  )
}
