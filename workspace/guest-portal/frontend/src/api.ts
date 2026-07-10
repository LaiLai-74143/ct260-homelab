import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { GuestData, Me } from './types'

async function getJson<T>(path: string): Promise<T> {
  const r = await fetch(path, { credentials: 'same-origin' })
  if (!r.ok) {
    let hint = ''
    try {
      const e = await r.json()
      hint = e.hint || e.error || ''
    } catch { /* 非 JSON 錯誤體 */ }
    const err = new Error(hint || `HTTP ${r.status}`) as Error & { status?: number }
    err.status = r.status
    throw err
  }
  return r.json()
}

async function postJson<T>(path: string, body: unknown): Promise<T> {
  const r = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const text = await r.text()
  let data: unknown = null
  try { data = text ? JSON.parse(text) : null } catch { /* 非 JSON */ }
  if (!r.ok) {
    const e = data as { error?: string; hint?: string } | null
    const err = new Error(e?.error || `HTTP ${r.status}`) as Error & { status?: number; hint?: string }
    err.status = r.status
    err.hint = e?.hint
    throw err
  }
  return data as T
}

/** 目前登入者;401 視為未登入(不 retry,交由畫面導向登入頁) */
export function useMe() {
  return useQuery<Me>({
    queryKey: ['me'],
    queryFn: () => getJson<Me>('/api/me'),
    retry: false,
    staleTime: 60_000,
  })
}

export function useData(enabled: boolean) {
  return useQuery<GuestData>({
    queryKey: ['data'],
    queryFn: () => getJson<GuestData>('/api/data'),
    enabled,
    retry: false,
    refetchInterval: 5 * 60_000,
    staleTime: 60_000,
  })
}

export function useLogin() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { username: string; password: string }) =>
      postJson<{ ok: boolean; person: string }>('/api/login', v),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['me'] })
      qc.invalidateQueries({ queryKey: ['data'] })
    },
  })
}

export function useLogout() {
  return useMutation({
    mutationFn: () => postJson<{ ok: boolean }>('/api/logout', {}),
    // 整頁重載回到乾淨狀態:cookie 已刪 → 重載後 /api/me 401 → 顯示登入頁。
    // 比 qc.clear() 可靠(v5 refetch 時保留舊 success 資料會卡在 Dashboard)。
    onSuccess: () => { window.location.assign('/') },
  })
}
