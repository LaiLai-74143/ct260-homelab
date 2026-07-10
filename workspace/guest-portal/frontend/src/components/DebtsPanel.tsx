import { useState } from 'react'
import type { Debts, OpenTx, SettledTx } from '../types'
import { money } from '../lib'

function localToday(): string {
  const n = new Date()
  return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, '0')}-${String(n.getDate()).padStart(2, '0')}`
}

/** dir 站在「訪客(這位朋友)」視角:they_owe=朋友欠我(屋主)→ 對朋友是「待還」;
    i_owe=我(屋主)欠朋友 → 對朋友是「待收」。net 亦為屋主視角:>0 屋主待收=朋友待還。 */
function txLine(t: OpenTx | SettledTx, settled: boolean, today: string) {
  const isSettled = settled
  const due = 'due' in t ? t.due : null
  const overdue = !isSettled && due && due.slice(0, 10) < today
  const label = isSettled ? '已結' : t.dir === 'i_owe' ? '待收' : '待還'
  const desc = [t.item, t.notes].filter(Boolean).join(' · ')
  return (
    <div key={`${isSettled ? 's' : 'o'}-${t.id}`} className="flex items-baseline gap-2.5 px-4 py-1.5 text-[12.5px]">
      <span className={`shrink-0 font-mono text-[11px] ${
        isSettled ? 'text-muted/70' : t.dir === 'i_owe' ? 'text-ok' : 'text-amber'}`}>
        {label}
      </span>
      <span className={`shrink-0 font-mono ${isSettled ? 'text-muted/70 line-through' : ''}`}>
        {money(t.amount, 'TWD')}
      </span>
      <span className="min-w-0 flex-1 truncate text-muted">
        {desc || '(無說明)'}
        {due ? ` · 到期 ${due.slice(0, 10)}${overdue ? '(逾期)' : ''}`
          : t.date ? ` · ${t.date.slice(0, 10)}` : ''}
        {isSettled && 'settled_date' in t && t.settled_date ? ` · 已結於 ${t.settled_date.slice(0, 10)}` : ''}
      </span>
    </div>
  )
}

/** 借貸面板(單人視角):淨額摘要 + 未結明細 + 最近已結(可收合) */
export default function DebtsPanel({ debts, person }: { debts: Debts; person: string }) {
  const [showSettled, setShowSettled] = useState(false)
  const today = localToday()
  const net = debts.net  // 屋主視角:>0 朋友欠我;<0 我欠朋友
  const hasOpen = debts.open.length > 0

  return (
    <section className="rounded-card border border-line bg-panel">
      <div className="border-b border-line px-4 py-3">
        <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">與你的往來</div>
        {net === 0 && !hasOpen ? (
          <div className="text-[15px] text-muted">目前兩清,沒有未結款項。</div>
        ) : (
          <div className="flex items-baseline gap-2">
            <span className={`font-mono text-2xl font-semibold ${net < 0 ? 'text-amber' : net > 0 ? 'text-ok' : ''}`}>
              {net === 0 ? '金額已互抵' : money(Math.abs(net), debts.currency)}
            </span>
            {net !== 0 && (
              <span className="text-[12px] text-muted">
                {net > 0 ? `${person}(你)需還給我` : `我需還給 ${person}(你)`}
              </span>
            )}
          </div>
        )}
      </div>

      {hasOpen && (
        <div className="border-b border-line/60 py-1">
          <div className="px-4 py-1 font-mono text-[10.5px] tracking-wider text-unk">未結</div>
          {debts.open.map((t) => txLine(t, false, today))}
        </div>
      )}

      {debts.settled.length > 0 && (
        <div className="py-1">
          <button
            onClick={() => setShowSettled((s) => !s)}
            aria-expanded={showSettled}
            className="flex w-full items-center justify-between px-4 py-1.5 text-left"
          >
            <span className="font-mono text-[10.5px] tracking-wider text-unk">
              最近已結({debts.settled.length})
            </span>
            <span className="font-mono text-[11px] text-muted">{showSettled ? '收合 ▴' : '展開 ▾'}</span>
          </button>
          {showSettled && debts.settled.map((t) => txLine(t, true, today))}
          {showSettled && (
            <div className="px-4 py-1.5 text-[11px] text-unk">僅列最近 10 筆已結款項。</div>
          )}
        </div>
      )}

      {!hasOpen && debts.settled.length === 0 && net === 0 && (
        <div className="px-4 py-4 text-center text-sm text-muted">沒有任何往來紀錄。</div>
      )}
    </section>
  )
}
