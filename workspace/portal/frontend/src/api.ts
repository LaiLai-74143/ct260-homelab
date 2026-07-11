import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import type { ActionResult, ActionsInfo, Alerts, Brief, ChatConfirmResult, ChatMessage, ChatProposal, ChatReply, ClawdInfo, ClawdReply, Game, GameActionResult, GuestListResult, GuestOpResult, HostDetail, Life, LifeChatInfo, Overview, Power, Security, Services, Spark } from './types'

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

/** L0 卡片迷你趨勢(0.17.0):24h/1h 桶,5 分鐘刷一次就夠 */
export function useSpark() {
  return useQuery<Spark>({
    queryKey: ['spark'],
    queryFn: () => getJson('/api/spark'),
    refetchInterval: 5 * 60_000,
    staleTime: 60_000,
  })
}

// ---- M2 hooks(刷新週期照 docs/M2-架構.md §2) ----

/** enabled=false 供命令面板首開前不拉(0.17.0):同 key 共享快取,
    Services 頁掛著時輪詢由該頁的實例驅動 */
export function useServices(enabled = true) {
  return useQuery<Services>({
    queryKey: ['services'],
    queryFn: () => getJson('/api/services'),
    refetchInterval: 30_000,
    staleTime: 15_000,
    enabled,
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

/** 過渡態(啟停中)輪詢 30s→5s,讓真實狀態快點落地(絲滑包 D4) */
const GAME_TRANSIENT = new Set(['starting', 'stopping', 'busy'])

export function useGame() {
  return useQuery<Game>({
    queryKey: ['game'],
    queryFn: () => getJson('/api/game'),
    refetchInterval: (q) => (GAME_TRANSIENT.has(q.state.data?.instance_state ?? '') ? 5_000 : 30_000),
    staleTime: 15_000,
  })
}

/** MCSM 控制:open/stop/restart → BFF /api/game/action → MCSM protected_instance。
    retry 0(開/停/重啟不可自動重試);成功後刷新 /api/game 讓狀態卡跟上。
    X-Requested-With=自訂 header 強制 CORS preflight,跨站惡意頁帶不了(CSRF 防護) */
export function useGameActionMutation() {
  const qc = useQueryClient()
  return useMutation<{ status: number; data: GameActionResult }, ActionHttpError, { action: string }, { prev?: Game }>({
    retry: 0,
    mutationFn: ({ action }) => postJson('/api/game/action', { action },
      { 'X-Requested-With': 'XMLHttpRequest' }),
    // 樂觀更新(絲滑包 D4,體感 bug 修復):按下即把 instance_state 轉過渡態,
    // 前端立刻顯示「啟動中…」,不枯等 MCSM 往返;失敗回滾快照,settled 拉真實狀態
    onMutate: async ({ action }) => {
      await qc.cancelQueries({ queryKey: ['game'] })
      const prev = qc.getQueryData<Game>(['game'])
      const next = action === 'open' ? 'starting' : action === 'stop' ? 'stopping' : 'busy'
      if (prev) qc.setQueryData<Game>(['game'], { ...prev, instance_state: next })
      return { prev }
    },
    onError: (_e, _v, ctx) => { if (ctx?.prev) qc.setQueryData(['game'], ctx.prev) },
    onSettled: () => { qc.invalidateQueries({ queryKey: ['game'] }) },
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

async function postJson<T>(path: string, body: unknown, headers: Record<string, string> = {}): Promise<{ status: number; data: T }> {
  // webhook 同步執行最長 120s → 前端上限 130s,與 BFF httpx timeout 對齊
  const r = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
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

/** 能力探測:enabled(已配置)/ allowed(本請求可操作)/ 動作字典。
    fetch=false 供命令面板首開前不拉(0.17.0) */
export function useActions(fetch = true) {
  return useQuery<ActionsInfo>({
    queryKey: ['actions'],
    queryFn: () => getJson('/api/actions'),
    staleTime: 5 * 60_000,
    enabled: fetch,
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

// ---- 生活助理(待辦49;BFF /api/life/chat → CT260 life-chat Sonnet 5) ----

/** 能力探測:enabled(已配置)/ allowed(本請求可對話) */
export function useLifeChatInfo() {
  return useQuery<LifeChatInfo>({
    queryKey: ['lifeChatInfo'],
    queryFn: () => getJson('/api/life/chat'),
    staleTime: 5 * 60_000,
  })
}

/** 對話:retry 0(限速 6/分+單飛,絕不自動重試);歷史由呼叫端整串帶上(無 session) */
export function useLifeChatMutation() {
  return useMutation<{ status: number; data: ChatReply }, ActionHttpError, { messages: ChatMessage[] }>({
    retry: 0,
    mutationFn: (body) => postJson('/api/life/chat', body),
  })
}

/** 提案確認執行:五欄位原樣帶回;成功後刷新生活數據(借貸件數可能變) */
export function useLifeConfirmMutation() {
  const qc = useQueryClient()
  return useMutation<{ status: number; data: ChatConfirmResult }, ActionHttpError, ChatProposal>({
    retry: 0,
    mutationFn: (p) => postJson('/api/life/confirm', p),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['life'] }) },
  })
}

// ---- 吉祥物問答(portal 0.16.0;右鍵 Clawd → BFF /api/clawd/chat → CT260 life-chat /clawd) ----

/** 能力探測:enabled(已配置)/ allowed(本請求可對話);開對話框時才 fetch */
export function useClawdInfo(open: boolean) {
  return useQuery<ClawdInfo>({
    queryKey: ['clawdInfo'],
    queryFn: () => getJson('/api/clawd/chat'),
    staleTime: 5 * 60_000,
    enabled: open,
  })
}

/** 問答:retry 0(限速 6/分與生活助理共池);單一 question,無歷史=每問全新 */
export function useClawdMutation() {
  return useMutation<{ status: number; data: ClawdReply }, ActionHttpError, { question: string }>({
    retry: 0,
    mutationFn: (body) => postJson('/api/clawd/chat', body),
  })
}

// ---- guest-portal 帳號管理(待辦50;BFF /api/life/guest → CT260 life-chat → hl-guest svc) ----

/** 帳號清單(只回人名/狀態/建立日,無雜湊) */
export function useGuestAccounts() {
  return useQuery<GuestListResult>({
    queryKey: ['guestAccounts'],
    queryFn: () => getJson('/api/life/guest'),
    staleTime: 30_000,
    retry: false,
  })
}

/** 帳號操作(add/passwd/enable/disable/rm);成功後刷新清單 */
export function useGuestMutation() {
  const qc = useQueryClient()
  return useMutation<{ status: number; data: GuestOpResult }, ActionHttpError, Record<string, unknown>>({
    retry: 0,
    mutationFn: (body) => postJson('/api/life/guest', body),
    onSettled: () => { qc.invalidateQueries({ queryKey: ['guestAccounts'] }) },
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
