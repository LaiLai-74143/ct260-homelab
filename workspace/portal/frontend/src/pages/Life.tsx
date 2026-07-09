import { useLife } from '../api'
import Dot from '../components/Dot'
import LifeChat from '../components/LifeChat'
import PageHead from '../components/PageHead'

function staleText(s?: number | null): string {
  if (s == null) return ''
  if (s < 90) return '剛更新'
  if (s < 3600) return `${Math.round(s / 60)} 分前更新`
  return `${Math.round(s / 3600)} 小時前更新`
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
          <section className="mb-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
            <div className="mb-2 font-mono text-[11px] tracking-[.12em] text-muted">借貸未結</div>
            <div className="font-mono text-2xl font-semibold">
              {d.debts_open?.count ?? 0}<span className="text-[13px] font-normal text-muted"> 筆</span>
              {d.debts_open?.total != null && d.debts_open.total > 0 && (
                <span className="ml-3 text-[15px]">NT$ {d.debts_open.total.toLocaleString()}</span>
              )}
            </div>
          </section>
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

      {/* 生活助理:Sonnet 5 對話框(唯讀工具+寫入提案單,僅 portal.hl) */}
      <LifeChat />
    </>
  )
}
