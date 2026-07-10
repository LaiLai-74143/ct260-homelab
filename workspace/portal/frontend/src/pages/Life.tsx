import { useState } from 'react'
import { IS_HL, useLife } from '../api'
import Dot from '../components/Dot'
import GuestPanel from '../components/GuestPanel'
import LifeChat from '../components/LifeChat'
import PageHead from '../components/PageHead'
import PageSkeleton from '../components/Skeleton'
import type { DebtTx, Life as LifeData } from '../types'

function staleText(s?: number | null): string {
  if (s == null) return ''
  if (s < 90) return '剛更新'
  if (s < 3600) return `${Math.round(s / 60)} 分前更新`
  return `${Math.round(s / 3600)} 小時前更新`
}

function money(amount: number, currency: string): string {
  return currency === 'TWD' ? `NT$ ${amount.toLocaleString()}` : `${amount.toLocaleString()} ${currency}`
}

/** 交易描述:買了什麼(item)優先於助理自動生成的 summary;
    「我借出 65」這類只複誦金額的樣板 summary 在有 item 時不重複顯示 */
function txDesc(t: DebtTx): string {
  const boiler = /^我?(借出|借入|欠)\s*[\d,.]+\s*(元|塊)?$/
  return [
    t.amount != null ? t.item : null, // amount==null 時金額欄位已顯示 item,不重複
    t.summary && !(t.item && boiler.test(t.summary)) ? t.summary : null,
    t.notes,
  ].filter(Boolean).join(' · ')
}

/** 本地(裝置時區)日期字串——toISOString 是 UTC,UTC+8 凌晨會漏標逾期 */
function localToday(): string {
  const n = new Date()
  return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, '0')}-${String(n.getDate()).padStart(2, '0')}`
}

const WEEK = ['日', '一', '二', '三', '四', '五', '六']

/** 近期行程卡(明日起 14 天,依日分組;redacted 時 title=null 顯示登入提示) */
function UpcomingCard({ items }: { items?: LifeData['calendar_upcoming'] }) {
  const list = items ?? []
  // 依日分組(保序;資料源已按時間排序)
  const groups: { date: string; rows: NonNullable<LifeData['calendar_upcoming']> }[] = []
  for (const it of list) {
    const g = groups[groups.length - 1]
    if (g && g.date === it.date) g.rows.push(it)
    else groups.push({ date: it.date, rows: [it] })
  }
  return (
    <section className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
      <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">近期行程</div>
      {groups.length === 0 && <div className="text-[13.5px] text-muted">未來兩週沒有安排的行程。</div>}
      {groups.map((g) => {
        const dt = new Date(g.date + 'T00:00:00')
        const md = `${dt.getMonth() + 1}/${dt.getDate()}`
        const wd = WEEK[dt.getDay()]
        return (
          <div key={g.date} className="flex gap-3 border-b border-line/60 py-2 last:border-b-0">
            <div className="w-14 shrink-0 text-right">
              <span className="font-mono text-[13px]">{md}</span>
              <span className="ml-1 text-[11px] text-muted">{wd}</span>
            </div>
            <div className="min-w-0 flex-1 space-y-1">
              {g.rows.map((e, i) => (
                <div key={e.time + i} className="flex items-baseline gap-2.5 text-[13.5px]">
                  <span className="w-12 shrink-0 font-mono text-[12px] text-muted">{e.time || '—'}</span>
                  <span className={`min-w-0 flex-1 truncate ${e.title == null ? 'text-muted' : ''}`}>
                    {e.title ?? '•••（登入後可見）'}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )
      })}
    </section>
  )
}

/** 借貸未結卡:筆數+全體互抵後淨額,點開列逐人淨額(同人多筆合併成一列) */
function DebtsCard({ d }: { d: LifeData }) {
  const [open, setOpen] = useState(false)
  const [openWho, setOpenWho] = useState<string | null>(null)
  const debts = d.debts_open
  const count = debts?.count ?? 0
  const net = debts?.total
  // 有不可互抵的往來(物品/外幣/金額未填):淨額 0 不代表兩清
  const hasOther = debts?.persons?.some((p) => p.items?.length) ?? false
  const expandable = count > 0
  const today = localToday()

  const head = (
    <>
      <div className="mb-2 flex items-baseline justify-between">
        <span className="font-mono text-[11px] tracking-[.12em] text-muted">借貸未結</span>
        {expandable && (
          <span className="font-mono text-[11px] text-muted">{open ? '收合 ▴' : '逐人明細 ▾'}</span>
        )}
      </div>
      <div className="flex flex-wrap items-baseline gap-x-5 gap-y-1">
        <span className="font-mono text-2xl font-semibold">
          {count}<span className="text-[13px] font-normal text-muted"> 筆</span>
        </span>
        {net != null && count > 0 && (
          <span className="whitespace-nowrap">
            <span className={`font-mono text-[17px] font-semibold ${net < 0 ? 'text-amber' : ''}`}>
              {net === 0 ? (hasOther ? '金額已互抵' : '已互抵兩清') : money(Math.abs(net), 'TWD')}
            </span>
            {(net !== 0 || hasOther || debts?.foreign) && (
              <span className="ml-1.5 text-[11.5px] text-muted">
                {net > 0 ? '淨待收·他人欠我' : net < 0 ? '淨待還·我欠他人' : '另有非現金往來'}
                {debts?.foreign ? '(僅計 NT$,外幣見明細)' : ''}
              </span>
            )}
          </span>
        )}
      </div>
    </>
  )

  return (
    <section className="mb-3.5 rounded-card border border-line bg-panel">
      {expandable ? (
        <button onClick={() => setOpen((o) => !o)} aria-expanded={open}
                className="w-full px-4 py-3.5 text-left">
          {head}
        </button>
      ) : (
        <div className="px-4 py-3.5">{head}</div>
      )}
      {open && (
        <div className="border-t border-line">
          {(debts?.persons ?? []).map((p, i) => {
            const rowKey = `${p.who}#${i}` // 多個不明對象 who 皆為 "?",不能拿 who 當鍵
            return (
            <div key={rowKey} className="border-b border-line/60 last:border-b-0">
              {/* 第二層:點人列展開該人交易紀錄(未結全列+最近已結) */}
              <button
                onClick={() => setOpenWho((w) => (w === rowKey ? null : rowKey))}
                aria-expanded={openWho === rowKey}
                className="flex w-full items-start gap-3 px-4 py-2.5 text-left text-[13.5px]"
              >
                <span className={`mt-0.5 shrink-0 rounded-btn border px-1.5 py-0.5 font-mono text-[11px] ${
                  p.net < 0 ? 'border-amber/60 text-amber' : 'border-line text-muted'}`}>
                  {p.net < 0 ? '待還' : p.net > 0 ? '待收' : p.items?.length ? '未結' : '兩清'}
                </span>
                <div className="min-w-0 flex-1">
                  <div>
                    {p.who}
                    <span className="ml-2 font-mono">
                      {p.net !== 0 ? money(Math.abs(p.net), 'TWD') : (p.items?.length ? '' : 'NT$ 0')}
                    </span>
                  </div>
                  <div className="truncate text-[12px] text-muted">
                    {p.count > 1 ? `${p.count} 筆互抵` : `${p.count} 筆`}
                    {p.due ? ` · 最近到期 ${p.due.slice(0, 10)}${p.due.slice(0, 10) < today ? '(逾期)' : ''}` : ''}
                    {p.items?.length ? ` · ${p.items.join('、')}` : ''}
                  </div>
                </div>
                <span className="mt-0.5 shrink-0 font-mono text-[11px] text-muted">
                  {openWho === rowKey ? '▴' : '▾'}
                </span>
              </button>
              {openWho === rowKey && (
                <div className="pb-1.5">
                  {(p.tx ?? []).map((t) => (
                    <div key={t.id} className="flex items-baseline gap-2.5 py-1 pl-12 pr-4 text-[12.5px]">
                      <span className={`shrink-0 font-mono text-[11px] ${
                        t.settled ? 'text-muted/70' : t.dir === '待還' ? 'text-amber' : 'text-muted'}`}>
                        {t.settled ? '已結' : t.dir}
                      </span>
                      <span className={`font-mono ${t.settled ? 'text-muted/70 line-through' : ''}`}>
                        {t.amount != null ? money(t.amount, t.currency)
                          : t.kind === '金錢' ? '金額未填' : (t.item ?? '物品')}
                      </span>
                      <span className="min-w-0 flex-1 truncate text-muted">
                        {txDesc(t)}
                        {t.due
                          ? ` · 到期 ${t.due.slice(0, 10)}${!t.settled && t.due.slice(0, 10) < today ? '(逾期)' : ''}`
                          : t.date ? ` · ${t.date.slice(0, 10)}` : ''}
                      </span>
                    </div>
                  ))}
                  {(p.tx ?? []).length === 0 && (
                    <div className="py-1 pl-12 pr-4 text-[12px] text-muted">無交易明細(等 CT260 下一輪投遞)。</div>
                  )}
                  <div className="py-1 pl-12 pr-4 text-[11px] text-muted">
                    已結僅列最近 10 筆;完整歷史見記帳(NocoDB)。
                  </div>
                </div>
              )}
            </div>
          )})}
          {debts?.persons == null && (
            // persons 缺席兩種來源要分開講:未認證=登入提示;已認證=舊格式檔還沒被新投遞蓋掉
            <div className="px-4 py-3 text-[12.5px] text-muted">
              {d.redacted
                ? '明細(對象與金額)需經 portal.hl 登入後查看。'
                : '來源資料尚無明細,等 CT260 下一輪投遞(每 30 分鐘)。'}
            </div>
          )}
          {debts?.truncated && (
            <div className="px-4 py-2 text-[11.5px] text-muted">未結超過 100 筆:卡面淨額為全量,逐人明細僅含最近到期前 100 筆;完整資料見記帳(NocoDB)。</div>
          )}
        </div>
      )}
    </section>
  )
}

export default function Life() {
  const lf = useLife()
  const d = lf.data
  const stale = (d?.stale_seconds ?? 0) > 2 * 3600

  return (
    <>
      <PageHead title="生活" right={d && !d.pending ? staleText(d.stale_seconds) : ''} />
      {lf.isError && !d && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到生活數據——檢查 BFF /api/life。
        </div>
      )}
      {!d && !lf.isError && <PageSkeleton rows={3} />}
      {d?.pending && (
        // 誠實態:資料是 CT260 推送的(推不是拉),還沒到就等
        <div className="rounded-card border border-dashed border-line px-5 py-10 text-center">
          <div className="mb-2 flex items-center justify-center gap-2 font-serif text-lg font-bold">
            <Dot state="unk" /> 資料尚未投遞
          </div>
          <div className="mx-auto max-w-[36em] text-[13.5px] text-muted">{d.hint}</div>
        </div>
      )}
      {d && !d.pending && (
        <>
          {stale && (
            <div className="mb-3 flex items-center gap-2 rounded-card border border-warn/45 bg-panel px-4 py-2.5 text-[12.5px]">
              <Dot state="warn" /> 資料已 {staleText(d.stale_seconds)}——CT260 投遞可能中斷,顯示的是最後一次成功內容。
            </div>
          )}
          {d.redacted && (
            // 兩層詳略:直達 :8088 只見件數;完整內容經 portal.hl 登入
            <div className="mb-3 flex items-center gap-2 rounded-card border border-line bg-panel px-4 py-2.5 text-[12.5px] text-muted">
              <span className="font-mono">🔒</span> 僅顯示件數;行程標題與借貸金額需經 portal.hl 登入後查看。
            </div>
          )}
          <section className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
            <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">今日行程</div>
            {(d.calendar_today ?? []).length === 0 && <div className="text-[13.5px] text-muted">今日無行程。</div>}
            {(d.calendar_today ?? []).map((e, i) => (
              <div key={e.time + i} className="flex gap-3 border-b border-line/60 py-1.5 text-[13.5px] last:border-0">
                <span className="w-12 shrink-0 font-mono text-[12.5px] text-amber">{e.time || '—'}</span>
                <span className={e.title == null ? 'text-muted' : ''}>{e.title ?? '•••（登入後可見）'}</span>
              </div>
            ))}
          </section>
          <UpcomingCard items={d.calendar_upcoming} />
          <DebtsCard d={d} />
          <div className="rounded-card border border-dashed border-line px-4 py-3 text-[12.5px] text-muted">
            RSS 訊息:待辦 30 落地後接入,本期不留假位。
          </div>
        </>
      )}

      {/* 跳轉入口:portal 唯讀,新增/編輯去源頭(行事曆=Google Calendar;記帳=NocoDB 借貸) */}
      <div className="mt-3.5 grid grid-cols-1 gap-2.5 md:grid-cols-2">
        <a href="https://calendar.google.com/" target="_blank" rel="noreferrer"
           className="block rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px] transition-colors duration-150 hover:border-amber">
          行事曆(Google Calendar)→ <span className="font-mono text-[12px] text-muted">calendar.google.com ↗</span>
        </a>
        <a href="http://192.168.20.70:8080" target="_blank" rel="noreferrer"
           className="block rounded-card border border-line bg-panel px-4 py-3.5 text-[13.5px] transition-colors duration-150 hover:border-amber">
          記帳(NocoDB)→ <span className="font-mono text-[12px] text-muted">192.168.20.70:8080 ↗</span>
        </a>
      </div>

      {/* 行程共享帳號管理(待辦50;僅 portal.hl 顯示,BFF 再驗 Remote-User) */}
      {IS_HL && <GuestPanel />}

      {/* 生活助理:Sonnet 5 對話框(唯讀工具+寫入提案單,僅 portal.hl) */}
      <LifeChat />
    </>
  )
}
