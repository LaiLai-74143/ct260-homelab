import { useState } from 'react'
import { useEnv } from '../env'
import type { Brief, BriefSection } from '../types'

const WEEKDAYS = ['日', '一', '二', '三', '四', '五', '六']

function weekdayOf(date: string): string {
  // date 已是台北當地日,直接以 UTC 午夜解析再讀 getUTCDay;舊寫法 +08:00 午夜
  // =前一 UTC 日 16:00,getUTCDay 恆少一天(0.17.0 審查 CONFIRMED,每期都錯)
  const d = new Date(`${date}T00:00:00Z`)
  return Number.isNaN(d.getTime()) ? '' : ` · 週${WEEKDAYS[d.getUTCDay()]}`
}

/** 「今日訊息」條列解析(0.17.0 排版整齊):產生器契約(homelab-notify.py
    RSS_SYSTEM_PROMPT)=「要點(來源)」以半形「;」相連的單段文字。
    尾端 (來源) 抽成右欄;>14 字不當來源(AI 濃縮失敗的尾註不誤抓);
    不足兩條(誠實註記文)回 [] 讓呼叫端退回段落排版 */
function newsItems(body: string): { text: string; src: string | null }[] {
  const parts = body.split(';').map((s) => s.trim()).filter(Boolean)
  if (parts.length < 2) return []
  return parts.map((s) => {
    const m = s.match(/^(.*?)[((]([^()()]{1,14})[))][。.]?$/)
    return m ? { text: m[1].trim(), src: m[2] } : { text: s.replace(/[。.]$/, ''), src: null }
  })
}

function Section({ s }: { s: BriefSection }) {
  const items = s.h === '今日訊息' ? newsItems(s.body) : []
  if (items.length === 0) {
    return (
      <p className="mb-2.5">
        <b className="font-bold text-amber">{s.h}</b>——{s.body}
      </p>
    )
  }
  return (
    <div className="mb-2.5">
      <b className="font-bold text-amber">{s.h}</b>
      <div className="mt-1">
        {items.map((it, i) => (
          <div key={i} className="flex items-baseline gap-2.5 border-b border-line/50 py-[5px] last:border-b-0">
            <span className="shrink-0 font-mono text-[10px] text-muted">{String(i + 1).padStart(2, '0')}</span>
            <span className="min-w-0 flex-1 text-[13.5px] leading-snug">{it.text}</span>
            {it.src && <span className="shrink-0 font-mono text-[10.5px] text-muted">{it.src}</span>}
          </div>
        ))}
      </div>
    </div>
  )
}

/**
 * 晨報刊頭 —— 本站簽名元素(§6):Noto Serif TC 刊頭、期號、琥珀細線、印刷品質感。
 * 手機預設收起只露首段(§6 RWD),桌面預設展開。
 * 0.17.0:crit 時刊頭掛 INCIDENT 徽章、夜間期號前出月相;「今日訊息」段條列排版。
 */
export default function BriefCard({ brief }: { brief: Brief }) {
  const { crit, night } = useEnv()
  const [open, setOpen] = useState(() => window.innerWidth >= 768)
  const [head, ...rest] = brief.sections

  return (
    <section className="relative mb-[22px] rounded-card border border-line bg-panel px-4 pb-[14px] pt-4 md:px-6 md:pb-[18px] md:pt-[22px]">
      <div className="flex flex-wrap items-baseline justify-between gap-1.5">
        <h1 className="font-serif text-[21px] font-black tracking-[.14em] md:text-[26px]">
          {brief.title}
          {crit && (
            <span className="critbar-pulse ml-2.5 inline-block rounded-btn border border-crit/50 px-1.5 py-px align-[4px] font-mono text-[10px] font-normal tracking-[.14em] text-crit">
              INCIDENT
            </span>
          )}
        </h1>
        <span className="font-mono text-[11.5px] tracking-[.04em] text-muted">
          {night ? '☾ ' : ''}第 {brief.issue_no} 期 · {brief.date}{weekdayOf(brief.date)}
        </span>
      </div>
      <div className="brief-rule my-3 md:mb-[14px]" />
      <div className="text-[14.5px]">
        {head && <Section s={head} />}
        {open && rest.map((s) => <Section key={s.h} s={s} />)}
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
