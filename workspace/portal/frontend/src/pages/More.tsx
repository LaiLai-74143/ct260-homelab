import { Link } from 'react-router-dom'
import PageHead from '../components/PageHead'
import { MODULES } from '../modules'

/** 手機底部 tab 第四格「更多」:其餘模塊入口 */
export default function More() {
  return (
    <>
      <PageHead title="更多" />
      <div className="grid grid-cols-2 gap-2.5">
        {MODULES.filter((m) => !['home', 'devices', 'alerts'].includes(m.key)).map((m) => (
          <Link
            key={m.key}
            to={m.route}
            className="flex items-center gap-2.5 rounded-card border border-line bg-panel px-4 py-3.5 text-sm transition-colors duration-150 hover:border-amber"
          >
            <span className="font-mono text-xs text-muted">{m.icon}</span>
            {m.label}
          </Link>
        ))}
      </div>
    </>
  )
}
