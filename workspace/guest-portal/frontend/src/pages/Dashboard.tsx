import { useData, useLogout, useMe } from '../api'
import Calendar from '../components/Calendar'
import DebtsPanel from '../components/DebtsPanel'

function staleText(generatedAt: string | null): string {
  if (!generatedAt) return ''
  const then = new Date(generatedAt).getTime()
  const s = Math.max(0, (Date.now() - then) / 1000)
  if (s < 90) return '剛更新'
  if (s < 3600) return `${Math.round(s / 60)} 分前更新`
  if (s < 86400) return `${Math.round(s / 3600)} 小時前更新`
  return `${Math.round(s / 86400)} 天前更新`
}

export default function Dashboard() {
  const me = useMe()
  const data = useData(me.isSuccess)
  const logout = useLogout()

  const person = me.data?.person ?? ''

  return (
    <div className="mx-auto max-w-lg px-4 pb-10 pt-5">
      <header className="mb-5 flex items-baseline justify-between">
        <div>
          <h1 className="font-serif text-lg text-text">行程共享</h1>
          {person && <p className="text-[12px] text-muted">{person},你好</p>}
        </div>
        <button
          onClick={() => logout.mutate()}
          className="rounded-btn border border-line px-3 py-1 text-[12px] text-muted hover:text-text"
        >
          登出
        </button>
      </header>

      {data.isLoading && <div className="py-10 text-center text-sm text-muted">載入中…</div>}

      {data.isError && (
        <div className="rounded-card border border-line bg-panel px-4 py-6 text-center text-sm text-muted">
          資料尚未就緒,請稍後重新整理。
        </div>
      )}

      {data.isSuccess && (
        <div className="space-y-4">
          <Calendar items={data.data.calendar} />
          <DebtsPanel debts={data.data.debts} person={person} />
          <p className="pt-1 text-center text-[11px] text-unk">
            {staleText(data.data.generated_at)}
            {data.data.generated_at ? ' · ' : ''}資料每 30 分鐘同步一次
          </p>
        </div>
      )}
    </div>
  )
}
