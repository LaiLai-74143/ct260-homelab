import type { CalItem } from './types'

/** 金額格式化,沿用入口大廳生活頁樣式 */
export function money(amount: number, currency = 'TWD'): string {
  const sym = currency === 'TWD' ? 'NT$' : currency + ' '
  return sym + amount.toLocaleString('en-US')
}

const WEEK = ['日', '一', '二', '三', '四', '五', '六']

/** "2026-07-10" → { md: "7/10", wd: "四", isToday: bool } */
export function fmtDate(iso: string, today: Date): { md: string; wd: string; isToday: boolean } {
  const d = new Date(iso + 'T00:00:00')
  const md = `${d.getMonth() + 1}/${d.getDate()}`
  const wd = WEEK[d.getDay()]
  const isToday =
    d.getFullYear() === today.getFullYear() &&
    d.getMonth() === today.getMonth() &&
    d.getDate() === today.getDate()
  return { md, wd, isToday }
}

/** 依日期分組行事曆(保序) */
export function groupByDate(items: CalItem[]): { date: string; items: CalItem[] }[] {
  const out: { date: string; items: CalItem[] }[] = []
  const idx = new Map<string, number>()
  for (const it of items) {
    if (!idx.has(it.date)) {
      idx.set(it.date, out.length)
      out.push({ date: it.date, items: [] })
    }
    out[idx.get(it.date)!].items.push(it)
  }
  return out
}
