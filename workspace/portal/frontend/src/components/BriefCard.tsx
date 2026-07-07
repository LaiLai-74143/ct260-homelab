import { useState } from 'react'
import type { Brief } from '../types'

const WEEKDAYS = ['日', '一', '二', '三', '四', '五', '六']

function weekdayOf(date: string): string {
  const d = new Date(`${date}T00:00:00+08:00`)
  return Number.isNaN(d.getTime()) ? '' : ` · 週${WEEKDAYS[d.getUTCDay()]}`
}

/**
 * 晨報刊頭 —— 本站簽名元素(§6):Noto Serif TC 刊頭、期號、琥珀細線、印刷品質感。
 * 手機預設收起只露首段(§6 RWD),桌面預設展開。
 */
export default function BriefCard({ brief }: { brief: Brief }) {
  const [open, setOpen] = useState(() => window.innerWidth >= 768)
  const [head, ...rest] = brief.sections

  return (
    <section className="relative mb-[22px] rounded-card border border-line bg-panel px-4 pb-[14px] pt-4 md:px-6 md:pb-[18px] md:pt-[22px]">
      <div className="flex flex-wrap items-baseline justify-between gap-1.5">
        <h1 className="font-serif text-[21px] font-black tracking-[.14em] md:text-[26px]">{brief.title}</h1>
        <span className="font-mono text-[11.5px] tracking-[.04em] text-muted">
          第 {brief.issue_no} 期 · {brief.date}{weekdayOf(brief.date)}
        </span>
      </div>
      <div className="brief-rule my-3 md:mb-[14px]" />
      <div className="text-[14.5px]">
        {head && (
          <p className="mb-2.5">
            <b className="font-bold text-amber">{head.h}</b>——{head.body}
          </p>
        )}
        {open && rest.map((s) => (
          <p key={s.h} className="mb-2.5">
            <b className="font-bold text-amber">{s.h}</b>——{s.body}
          </p>
        ))}
      </div>
      {rest.length > 0 && (
        <button
          type="button"
          className="cursor-pointer pt-1 font-mono text-xs text-muted hover:text-amber"
          onClick={() => setOpen(!open)}
        >
          {open ? '▲ 收合全文' : '▼ 展開全文'}
        </button>
      )}
      <div className="mt-2 font-mono text-[10.5px] text-muted">{brief.generated_at}</div>
    </section>
  )
}
