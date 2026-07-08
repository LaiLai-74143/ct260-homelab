import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import type { ActionResult, ActionsInfo, Alerts, Brief, Game, HostDetail, Life, Overview, Power, Security, Services } from './types'

/** 存取場景:手機/遠端經 *.hl(Caddy+Authelia),PC40 走內網 IP —— 服務目錄據此選連結 */
export const IS_HL = window.location.hostname.endsWith('hl.lailai74143.com')

/** Grafana 基底依場景切換(跳轉連結用) */
export function grafanaUrl(lanUrl: string): string {
  return IS_HL ? lanUrl.replace('http://10.80.80.11:3002', 'https://grafana.hl.lailai74143.com') : lanUrl
}

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

// ---- M2 hooks(刷新週期照 docs/M2-架構.md §2) ----

export function useServices() {
  return useQuery<Services>({
    queryKey: ['services'],
    queryFn: () => getJson('/api/services'),
    refetchInterval: 30_000,
    staleTime: 15_000,
  })
}

export function useSecurity() {
  return useQuery<Security>({
    queryKey: ['security'],
    queryFn: () => getJson('/api/security'),
    refetchInterval: 60_000,
    staleTime: 30_000,
  })
}

export function usePower() {
  return useQuery<Power>({
    queryKey: ['power'],
    queryFn: () => getJson('/api/power'),
    refetchInterval: 60_000,
    staleTime: 30_000,
  })
}

export function useGame() {
  return useQuery<Game>({
    queryKey: ['game'],
    queryFn: () => getJson('/api/game'),
    refetchInterval: 30_000,
    staleTime: 15_000,
  })
}

/** 生活:進頁時拉(§2),不設輪詢——資料由 CT260 每 30 分推一次 */
export function useLife() {
  return useQuery<Life>({
    queryKey: ['life'],
    queryFn: () => getJson('/api/life'),
    staleTime: 5 * 60_000,
  })
}

export function useHostDetail(slug: string | undefined) {
  return useQuery<HostDetail>({
    queryKey: ['host', slug],
    queryFn: () => getJson(`/api/host/${slug}`),
    enabled: !!slug,
    refetchInterval: 60_000,
    staleTime: 30_000,
  })
}

// ---- M3 動作(待辦49;BFF POST /api/action → CT260 webhook 白名單) ----

/** 動作錯誤:保留 status 供 429/202 分流與專用文案 */
export interface ActionHttpError {
  status: number
  error: string
  hint?: string
}

async function postJson<T>(path: string, body: unknown): Promise<{ status: number; data: T }> {
  // webhook 同步執行最長 120s → 前端上限 130s,與 BFF httpx timeout 對齊
  const r = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(130_000),
  })
  let data: unknown = null
  try { data = await r.json() } catch { /* 非 JSON 錯誤體 */ }
  if (!r.ok) {
    const e = (data ?? {}) as { error?: string; hint?: string }
    throw { status: r.status, error: e.error || `HTTP ${r.status}`, hint: e.hint || '' } satisfies ActionHttpError
  }
  return { status: r.status, data: data as T }
}

/** 能力探測:enabled(已配置)/ allowed(本請求可操作)/ 動作字典 */
export function useActions() {
  return useQuery<ActionsInfo>({
    queryKey: ['actions'],
    queryFn: () => getJson('/api/actions'),
    staleTime: 5 * 60_000,
  })
}

/** 動作執行:retry 明文 0——限速 6/分與手機 ntfy 按鈕共用,絕不自動重試 */
export function useActionMutation() {
  const qc = useQueryClient()
  return useMutation<{ status: number; data: ActionResult }, ActionHttpError, { action: string; param?: string | null }>({
    retry: 0,
    mutationFn: ({ action, param }) => postJson('/api/action', { action, param: param ?? null }),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['alerts'] }) },
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
