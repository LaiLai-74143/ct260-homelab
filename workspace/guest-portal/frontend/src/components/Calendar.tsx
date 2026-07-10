import type { CalItem } from '../types'
import { fmtDate, groupByDate } from '../lib'

/** 14 天行事曆時間軸:依日分組,今日高亮 */
export default function Calendar({ items }: { items: CalItem[] }) {
  const today = new Date()
  const groups = groupByDate(items)

  return (
    <section className="rounded-card border border-line bg-panel">
      <div className="border-b border-line px-4 py-3">
        <span className="font-mono text-[11px] tracking-[.12em] text-muted">近期行程</span>
      </div>
      {groups.length === 0 && (
        <div className="px-4 py-6 text-center text-sm text-muted">近兩週沒有安排的行程。</div>
      )}
      {groups.map((g) => {
        const { md, wd, isToday } = fmtDate(g.date, today)
        return (
          <div key={g.date} className="flex gap-3 border-b border-line/60 px-4 py-3 last:border-b-0">
            <div className="w-14 shrink-0 text-right">
              <div className={`font-mono text-[15px] ${isToday ? 'text-amber font-semibold' : 'text-text'}`}>{md}</div>
              <div className={`text-[11px] ${isToday ? 'text-amber' : 'text-muted'}`}>週{wd}{isToday ? '·今天' : ''}</div>
            </div>
            <div className="min-w-0 flex-1 space-y-1.5">
              {g.items.map((it, i) => (
                <div key={i} className="flex items-baseline gap-2.5">
                  <span className="w-12 shrink-0 font-mono text-[12px] text-muted">{it.time}</span>
                  <span className="min-w-0 flex-1 text-[13.5px] text-text">{it.title}</span>
                </div>
              ))}
            </div>
          </div>
        )
      })}
    </section>
  )
}
