import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import type { Alerts, Brief, Overview } from './types'

async function getJson<T>(path: string): Promise<T> {
  const r = await fetch(path)
  if (!r.ok) {
    let hint = ''
    try {
      const e = await r.json()
      hint = e.hint || e.error || ''
    } catch { /* 非 JSON 錯誤體 */ }
    throw new Error(hint || `HTTP ${r.status}`)
  }
  return r.json()
}

export function useOverview() {
  return useQuery<Overview>({
    queryKey: ['overview'],
    queryFn: () => getJson('/api/overview'),
    refetchInterval: 15_000,
    staleTime: 10_000,
  })
}

export function useAlerts() {
  return useQuery<Alerts>({
    queryKey: ['alerts'],
    queryFn: () => getJson('/api/alerts'),
    refetchInterval: 15_000,
    staleTime: 10_000,
  })
}

export function useBrief() {
  return useQuery<Brief>({
    queryKey: ['brief'],
    queryFn: () => getJson('/api/brief?d=today'),
    refetchInterval: 5 * 60_000,
    staleTime: 60_000,
  })
}

/** SSE:BFF 推 overview/alerts 事件即時覆寫快取;斷線由 EventSource 自動重連 */
export function useStream() {
  const qc = useQueryClient()
  useEffect(() => {
    const es = new EventSource('/api/stream')
    es.addEventListener('overview', (ev) => {
      try { qc.setQueryData(['overview'], JSON.parse((ev as MessageEvent).data)) } catch { /* 略過壞 payload */ }
    })
    es.addEventListener('alerts', (ev) => {
      try { qc.setQueryData(['alerts'], JSON.parse((ev as MessageEvent).data)) } catch { /* 略過壞 payload */ }
    })
    return () => es.close()
  }, [qc])
}

/**
 * 數據延遲秒數(§7):以 overview 的 generated_at 對照現在。
 * >60s 顯示「數據延遲 Xs」;查詢完全失敗回 -1(呼叫端切離線畫面)。
 */
export function useDataLag(generatedAt: string | undefined, failed: boolean): number {
  const [lag, setLag] = useState(0)
  useEffect(() => {
    const tick = () => {
      if (!generatedAt) return
      setLag(Math.max(0, Math.round((Date.now() - new Date(generatedAt).getTime()) / 1000)))
    }
    tick()
    const h = setInterval(tick, 5_000)
    return () => clearInterval(h)
  }, [generatedAt])
  if (failed) return -1
  return lag
}
