import { createContext, useCallback, useContext, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import Dot from './Dot'

/** toast 回饋(M3 §7):右下堆疊;<768 升到 tabbar 上方;ok 5s / err 8s 自動消失 */
type Push = (kind: 'ok' | 'err', text: string) => void

interface ToastItem {
  id: number
  kind: 'ok' | 'err'
  text: string
}

const ToastCtx = createContext<Push>(() => {})

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([])
  const seq = useRef(0)

  const push = useCallback<Push>((kind, text) => {
    const id = ++seq.current
    setItems((s) => [...s, { id, kind, text }])
    setTimeout(() => setItems((s) => s.filter((t) => t.id !== id)), kind === 'err' ? 8_000 : 5_000)
  }, [])

  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div
        className="pointer-events-none fixed right-3 z-[60] flex flex-col gap-2 bottom-[calc(56px+env(safe-area-inset-bottom))] md:bottom-4"
        role="status"
        aria-live="polite"
      >
        {items.map((t) => (
          <div
            key={t.id}
            className="route-fade flex max-w-[320px] items-start gap-2.5 rounded-card border border-line bg-panel px-3.5 py-2.5 text-[12.5px]"
          >
            <Dot state={t.kind === 'ok' ? 'ok' : 'crit'} className="mt-1" />
            <span className="min-w-0 break-words">{t.text}</span>
          </div>
        ))}
      </div>
    </ToastCtx.Provider>
  )
}

export function useToast(): Push {
  return useContext(ToastCtx)
}
