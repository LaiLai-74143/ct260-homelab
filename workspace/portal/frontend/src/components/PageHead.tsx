import { Link } from 'react-router-dom'
import type { ReactNode } from 'react'

export default function PageHead({ title, right }: { title: string; right?: ReactNode }) {
  return (
    <div className="mb-4 mt-0.5 flex items-baseline gap-3.5">
      <Link to="/" className="font-mono text-xs text-muted hover:text-amber">← 大廳</Link>
      <h2 className="font-serif text-[21px] font-bold tracking-[.06em]">{title}</h2>
      {right && <span className="ml-auto font-mono text-xs text-muted">{right}</span>}
    </div>
  )
}
