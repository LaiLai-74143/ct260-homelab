import { useState } from 'react'
import { useGuestAccounts, useGuestMutation } from '../api'
import type { GuestAccount } from '../types'

/** guest-portal 帳號管理面板(待辦50;僅 portal.hl 內網,經 Authelia)。
    身分證字號/密碼經 BFF→CT260→hl-guest svc 雜湊寫入 NocoDB,前端不留、不回顯雜湊。 */
export default function GuestPanel() {
  const list = useGuestAccounts()
  const m = useGuestMutation()
  const [open, setOpen] = useState(false)
  const [id, setId] = useState('')
  const [person, setPerson] = useState('')
  const [pw, setPw] = useState('')
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)

  const accounts: GuestAccount[] = list.data?.accounts ?? []
  const busy = m.isPending

  function run(body: Record<string, unknown>, okText: string, clear?: () => void) {
    setMsg(null)
    m.mutate(body, {
      onSuccess: ({ data }) => {
        if (data.ok) { setMsg({ ok: true, text: okText }); clear?.() }
        else setMsg({ ok: false, text: data.error || '操作失敗' })
      },
      onError: (e) => setMsg({ ok: false, text: e.error || '連線失敗' }),
    })
  }

  function submitAdd(e: React.FormEvent) {
    e.preventDefault()
    if (!id.trim() || !person.trim() || !pw) return
    run({ op: 'add', login_id: id.trim(), person: person.trim(), password: pw },
        `已為「${person.trim()}」建立帳號`, () => { setId(''); setPerson(''); setPw('') })
  }

  return (
    <section className="mb-3.5 rounded-card border border-line bg-panel">
      <button onClick={() => setOpen((o) => !o)} aria-expanded={open}
              className="flex w-full items-baseline justify-between px-4 py-3.5 text-left">
        <span className="font-mono text-[11px] tracking-[.12em] text-muted">行程共享 · 帳號管理</span>
        <span className="font-mono text-[11px] text-muted">
          {accounts.length} 個{open ? ' · 收合 ▴' : ' · 展開 ▾'}
        </span>
      </button>

      {open && (
        <div className="border-t border-line px-4 py-3">
          {/* 清單 */}
          {list.isLoading && <div className="py-2 text-[12.5px] text-muted">載入中…</div>}
          {list.isError && <div className="py-2 text-[12.5px] text-crit">讀取失敗(需 portal.hl 登入)</div>}
          {list.data && accounts.length === 0 && (
            <div className="py-2 text-[12.5px] text-muted">尚無帳號,用下方表單新增。</div>
          )}
          {accounts.map((a) => (
            <div key={a.person} className="flex items-center gap-2 border-b border-line/60 py-2 last:border-b-0 text-[13.5px]">
              <span className={`shrink-0 rounded-btn border px-1.5 py-0.5 font-mono text-[11px] ${
                a.enabled ? 'border-ok/50 text-ok' : 'border-line text-muted'}`}>
                {a.enabled ? '啟用' : '停用'}
              </span>
              <span className="min-w-0 flex-1 truncate">{a.person}
                <span className="ml-2 font-mono text-[11px] text-muted">{a.created}</span>
              </span>
              <div className="flex shrink-0 gap-1.5 font-mono text-[11px]">
                <button disabled={busy} onClick={() => run({ op: a.enabled ? 'disable' : 'enable', person: a.person },
                          `已${a.enabled ? '停用' : '啟用'}「${a.person}」`)}
                        className="btn-press rounded-btn border border-line px-2 py-0.5 text-muted hover:text-text disabled:opacity-40">
                  {a.enabled ? '停用' : '啟用'}
                </button>
                <button disabled={busy} onClick={() => {
                          const np = prompt(`重設「${a.person}」的密碼(管制標籤號),留空取消:`)
                          if (np) run({ op: 'passwd', person: a.person, password: np }, `已重設「${a.person}」密碼`)
                        }}
                        className="btn-press rounded-btn border border-line px-2 py-0.5 text-muted hover:text-text disabled:opacity-40">
                  改密碼
                </button>
                <button disabled={busy} onClick={() => {
                          if (confirm(`移除「${a.person}」的登入?(記賬資料保留)`)) run({ op: 'rm', person: a.person }, `已移除「${a.person}」登入`)
                        }}
                        className="btn-press rounded-btn border border-line px-2 py-0.5 text-crit/80 hover:text-crit disabled:opacity-40">
                  移除
                </button>
              </div>
            </div>
          ))}

          {/* 新增表單 */}
          <form onSubmit={submitAdd} className="mt-3 space-y-2">
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
              <input value={id} onChange={(e) => setId(e.target.value)} placeholder="身分證字號"
                     autoComplete="off"
                     className="rounded-btn border border-line bg-bg px-2.5 py-1.5 text-[13px] focus:border-amber focus:outline-none" />
              <input value={person} onChange={(e) => setPerson(e.target.value)} placeholder="記賬人名"
                     autoComplete="off"
                     className="rounded-btn border border-line bg-bg px-2.5 py-1.5 text-[13px] focus:border-amber focus:outline-none" />
              <input value={pw} onChange={(e) => setPw(e.target.value)} placeholder="密碼(管制標籤號)"
                     type="password" autoComplete="new-password"
                     className="rounded-btn border border-line bg-bg px-2.5 py-1.5 text-[13px] focus:border-amber focus:outline-none" />
            </div>
            <button type="submit" disabled={busy || !id.trim() || !person.trim() || !pw}
                    className="btn-press w-full rounded-btn bg-amber py-1.5 text-[13px] font-medium text-bg disabled:opacity-40">
              {busy ? '處理中…' : '新增帳號'}
            </button>
          </form>

          {msg && (
            <div className={`mt-2 text-[12.5px] ${msg.ok ? 'text-ok' : 'text-crit'}`} role="status">{msg.text}</div>
          )}
          <p className="mt-2 text-[11px] text-unk">
            記賬人名不存在會自動建員。身分證字號與密碼皆雜湊儲存,無法回顯;忘記密碼用「改密碼」重設。
          </p>
        </div>
      )}
    </section>
  )
}
