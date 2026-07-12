import { useEffect, useRef, useState } from 'react'
import { useClawdInfo, useClawdMutation } from '../api'

/** 吉祥物問答框(0.16.0):右鍵 Clawd 叫出,錨在吉祥物上方。
    Plan 型唯讀(CT260 claude -p Sonnet 5,Read 限 ForAI 文件),每問全新——
    API 只收單一 question 不收歷史;畫面上的問答串純顯示用,關閉即銷毀
    (元件條件掛載,state 隨 unmount 歸零)。 */
export default function ClawdChat({ onClose }: { onClose: () => void }) {
  const info = useClawdInfo(true)
  const ask = useClawdMutation()
  const [log, setLog] = useState<{ q: string; a: string }[]>([])
  const [input, setInput] = useState('')
  const [error, setError] = useState('')
  const endRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    inputRef.current?.focus()
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'nearest' })
  }, [log, ask.isPending])

  const send = () => {
    const q = input.trim()
    if (!q || ask.isPending) return
    setInput('')
    setError('')
    ask.mutate({ question: q }, {
      onSuccess: ({ data }) => setLog((l) => [...l, { q, a: data.reply }]),
      onError: (e) => setError(`${e.error}${e.hint ? `——${e.hint}` : ''}`),
    })
  }

  const ready = info.data?.enabled && info.data?.allowed

  return (
    <div
      role="dialog"
      aria-label="Clawd 問答"
      className="dialog-in pointer-events-auto absolute bottom-full right-0 mb-2 flex w-[320px] max-w-[calc(100vw-24px)] flex-col rounded-card border border-line bg-panel shadow-lg"
    >
      <div className="flex items-baseline justify-between border-b border-line px-3 py-2">
        <div className="font-mono text-[11px] tracking-[.12em] text-muted">CLAWD · SONNET 5 · 唯讀</div>
        <button
          onClick={onClose}
          aria-label="關閉問答"
          className="btn-press -mr-1 rounded-btn px-1.5 text-[13px] text-muted transition-colors duration-150 hover:text-text"
        >
          ✕
        </button>
      </div>

      {info.isLoading && (
        <div className="px-3 py-3 text-[12.5px] text-muted">連線中…</div>
      )}
      {info.data && !info.data.enabled && (
        <div className="px-3 py-3 text-[12.5px] text-muted">
          問答未配置(portal.env 缺 LIFE_CHAT_URL/LIFE_CHAT_TOKEN)。
        </div>
      )}
      {info.data?.enabled && !info.data.allowed && (
        <div className="px-3 py-3 text-[12.5px] text-muted">
          Clawd 問答僅在 portal.hl 登入後提供;直達 :8088 為唯讀瀏覽。
        </div>
      )}

      {ready && (
        <>
          <div className="flex max-h-[300px] flex-col gap-2 overflow-y-auto px-3 py-2.5">
            {log.length === 0 && !ask.isPending && (
              <div className="text-[12.5px] leading-relaxed text-muted">
                問我這個家的事——網路、服務、監控、備份都行(我翻 ForAI 文件回答,唯讀)。
                每次對話都是全新的,我不留記憶;要延續脈絡請一次講全。
              </div>
            )}
            {log.map((x, i) => (
              <div key={i} className="flex flex-col gap-2">
                <div className="max-w-[85%] self-end whitespace-pre-wrap rounded-card border border-amber/40 bg-amber/10 px-3 py-2 text-[13px]">
                  {x.q}
                </div>
                <div className="max-w-[92%] self-start whitespace-pre-wrap rounded-card border border-line px-3 py-2 text-[13px]">
                  {x.a}
                </div>
              </div>
            ))}
            {ask.isPending && (
              <div className="self-start rounded-card border border-line px-3 py-2 text-[13px] text-muted">
                翻文件中…(可能要十幾秒)
              </div>
            )}
            <div ref={endRef} />
          </div>

          {error && (
            <div className="mx-3 mb-2 rounded-card border border-warn/45 px-3 py-2 text-[12px]">{error}</div>
          )}

          <div className="flex items-end gap-2 border-t border-line px-3 py-2.5">
            <textarea
              ref={inputRef}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key !== 'Enter') return
                // 手機軟鍵盤 Enter=換行;桌面 Enter=送出、Shift+Enter=換行
                const mobile = window.matchMedia('(pointer: coarse)').matches
                if (mobile || e.shiftKey) return
                e.preventDefault()
                send()
              }}
              maxLength={2000}
              rows={2}
              placeholder="問一句…"
              className="min-w-0 flex-1 resize-y rounded-btn border border-line bg-transparent px-3 py-1.5 text-[13px] outline-none transition-colors duration-150 focus:border-amber"
            />
            <button
              onClick={send}
              disabled={ask.isPending || !input.trim()}
              className="btn-press shrink-0 rounded-btn border border-line px-3 py-1.5 text-[13px] transition-colors duration-150 hover:border-amber disabled:opacity-50"
            >
              問
            </button>
          </div>
        </>
      )}
    </div>
  )
}
