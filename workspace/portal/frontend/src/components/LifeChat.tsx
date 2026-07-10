import { useEffect, useRef, useState } from 'react'
import { useLifeChatInfo, useLifeChatMutation, useLifeConfirmMutation } from '../api'
import type { ChatMessage, ChatProposal } from '../types'

/** 提案確認卡:寫入動作唯一通道——模型只開單,使用者按確認,CT260 服務端執行 */
function ProposalCard({ p, busy, onConfirm, onCancel }: {
  p: ChatProposal
  busy: boolean
  onConfirm: () => void
  onCancel: () => void
}) {
  return (
    <div className="self-start w-full max-w-[92%] rounded-card border border-amber/45 px-3.5 py-3">
      <div className="mb-1 text-[13.5px] font-semibold">{p.summary}</div>
      <div className="mb-2.5 font-mono text-[11.5px] text-muted">
        {p.action}(
        {Object.entries(p.args).map(([k, v]) => `${k}=${String(v)}`).join(', ')}
        )
      </div>
      <div className="flex gap-2">
        <button
          onClick={onConfirm}
          disabled={busy}
          className="btn-press rounded-btn border border-amber px-3 py-1.5 text-[12.5px] transition-colors duration-150 hover:bg-amber/10 disabled:opacity-50"
        >
          {busy ? '執行中…' : '確認執行'}
        </button>
        <button
          onClick={onCancel}
          disabled={busy}
          className="btn-press rounded-btn border border-line px-3 py-1.5 text-[12.5px] text-muted transition-colors duration-150 hover:border-amber disabled:opacity-50"
        >
          取消
        </button>
      </div>
    </div>
  )
}

export default function LifeChat() {
  const info = useLifeChatInfo()
  const chat = useLifeChatMutation()
  const confirm = useLifeConfirmMutation()
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [proposals, setProposals] = useState<ChatProposal[]>([])
  const [input, setInput] = useState('')
  const [error, setError] = useState('')
  const [confirmingSig, setConfirmingSig] = useState<string | null>(null)
  const endRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'nearest' })
  }, [messages, proposals, chat.isPending])

  if (!info.data?.enabled) return null
  if (!info.data.allowed) {
    return (
      <div className="mt-3.5 rounded-card border border-dashed border-line px-4 py-3 text-[12.5px] text-muted">
        生活助理(行事曆/記帳對話)僅在 portal.hl 登入後提供。
      </div>
    )
  }

  const send = () => {
    const text = input.trim()
    if (!text || chat.isPending) return
    const next: ChatMessage[] = [...messages, { role: 'user', content: text }]
    setMessages(next)
    setInput('')
    setError('')
    setProposals([]) // 新一輪對話作廢舊提案(簽名仍在服務端 15 分鐘窗內,但 UI 不留)
    chat.mutate({ messages: next }, {
      onSuccess: ({ data }) => {
        setMessages((m) => [...m, { role: 'assistant', content: data.reply }])
        setProposals(data.proposals)
        if (data.rejected?.length) setError(`${data.rejected.length} 個提案被服務端拒絕(schema 不符)`)
      },
      onError: (e) => setError(`${e.error}${e.hint ? `——${e.hint}` : ''}`),
    })
  }

  const runConfirm = (p: ChatProposal) => {
    setConfirmingSig(p.sig)
    setError('')
    confirm.mutate(p, {
      onSuccess: ({ data }) => {
        setMessages((m) => [...m, { role: 'assistant', content: `✅ ${data.result}` }])
        setProposals((ps) => ps.filter((x) => x.sig !== p.sig))
      },
      onError: (e) => setError(`${e.error}${e.hint ? `——${e.hint}` : ''}`),
      onSettled: () => setConfirmingSig(null),
    })
  }

  return (
    <section className="mt-3.5 rounded-card border border-line bg-panel px-4 py-3.5">
      <div className="mb-2 flex items-baseline justify-between">
        <div className="font-mono text-[11px] tracking-[.12em] text-muted">生活助理 · SONNET 5</div>
        <div className="text-[11px] text-muted">只管行事曆與記帳</div>
      </div>

      <div className="flex max-h-[380px] flex-col gap-2 overflow-y-auto">
        {messages.length === 0 && !chat.isPending && (
          <div className="py-3 text-[12.5px] text-muted">
            問我行程或借貸,例:「明天有什麼行程?」「記一筆:小明欠我 300」。
            寫入動作會先出確認卡,你按確認才執行(執行後回發 TG 留痕)。
          </div>
        )}
        {messages.map((m, i) => (
          <div
            key={i}
            className={`max-w-[85%] whitespace-pre-wrap rounded-card border px-3 py-2 text-[13.5px] ${
              m.role === 'user' ? 'self-end border-amber/40 bg-amber/10' : 'self-start border-line'
            }`}
          >
            {m.content}
          </div>
        ))}
        {proposals.map((p) => (
          <ProposalCard
            key={p.sig}
            p={p}
            busy={confirmingSig === p.sig}
            onConfirm={() => runConfirm(p)}
            onCancel={() => setProposals((ps) => ps.filter((x) => x.sig !== p.sig))}
          />
        ))}
        {chat.isPending && (
          <div className="self-start rounded-card border border-line px-3 py-2 text-[13.5px] text-muted">
            思考中…(讀取工具查數據可能要十幾秒)
          </div>
        )}
        <div ref={endRef} />
      </div>

      {error && (
        <div className="mt-2 rounded-card border border-warn/45 px-3 py-2 text-[12.5px]">{error}</div>
      )}

      <div className="mt-2.5 flex gap-2">
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') send() }}
          maxLength={4000}
          placeholder="輸入訊息…"
          className="min-w-0 flex-1 rounded-btn border border-line bg-transparent px-3 py-2 text-[13.5px] outline-none transition-colors duration-150 focus:border-amber"
        />
        <button
          onClick={send}
          disabled={chat.isPending || !input.trim()}
          className="btn-press shrink-0 rounded-btn border border-line px-3.5 py-2 text-[13.5px] transition-colors duration-150 hover:border-amber disabled:opacity-50"
        >
          送出
        </button>
      </div>
    </section>
  )
}
