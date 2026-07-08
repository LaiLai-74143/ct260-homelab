// API 契約 —— 《入口大廳設計報告-3》§8
export type HostState = 'ok' | 'warn' | 'crit' | 'unk'

export interface Host {
  slug: string
  name: string
  vlan: string
  up: HostState
  cpu: number | null
  mem: number | null
  disk: number | null
  uptime: string
  note?: string
}

/** M2 前未接數據的模塊卡:fixtures(M0)提供示意值;M1 真數據模式不含此欄 → 卡面誠實顯示待接 */
export interface ModuleStub {
  key: string
  big: string
  bigUnit?: string
  sub: string
  state: HostState
}

export interface Overview {
  summary: { state: HostState; text: string }
  hosts: Host[]
  services_ok: { ok: number; total: number } | null
  alerts_firing: number
  targets: { up: number; total: number }
  modules?: ModuleStub[]
  generated_at: string
}

export interface AlertItem {
  name: string
  severity: 'critical' | 'warning' | 'info'
  description: string
  instance?: string
  since: string
}

export interface SilenceItem {
  comment: string
  ends_at: string
  matchers: string
}

export interface Alerts {
  firing: AlertItem[]
  pending: AlertItem[]
  silences: SilenceItem[]
  /** M2:近 24h firing 數 [[unix_ts, n], …](Prometheus ALERTS range) */
  timeline_24h?: [number, number][]
  generated_at: string
}

export interface BriefSection {
  h: string
  body: string
}

export interface Brief {
  issue_no: number
  date: string
  title: string
  sections: BriefSection[]
  generated_at: string
}

export interface ApiError {
  error: string
  hint?: string
}

// ---- M2 契約(docs/M2-架構.md §3) ----

export interface ServiceItem {
  name: string
  url: string | null
  url_hl?: string | null
  pc40: boolean
  phone: boolean
  host?: string | null
  kuma_ok: boolean | null
  note?: string | null
}

export interface Services {
  groups: { group: string; items: ServiceItem[] }[]
  kuma_note?: string | null
  generated_at: string
}

export interface Security {
  autoban_today: number
  autoban_trend_24h: [number, number][]
  tripwire: { today: number; last_hit: string | null; days_clean: number | null }
  cowrie: { offline?: boolean; hint?: string; count?: number; top_src?: { ip: string; n: number }[] }
  generated_at: string
}

export interface Power {
  pending?: boolean
  hint?: string
  on_battery?: boolean
  charge?: number
  load?: number
  runtime_s?: number
  events_7d?: { ts: string; text: string }[]
  generated_at: string
}

export interface Game {
  server_up: boolean
  instance_state: string
  players_online: number | null
  player_names: string[] | null
  hosts: { name: string; up: boolean; cpu: number | null; mem: number | null }[]
  note?: string | null
  generated_at: string
}

export interface Life {
  pending?: boolean
  hint?: string
  redacted?: boolean
  calendar_today?: { time: string; title: string | null }[]
  debts_open?: { count: number; total: number | null }
  stale_seconds?: number | null
  generated_at: string
}

export interface HostDetail {
  slug: string
  name: string
  vlan: string
  bare: boolean
  metrics_6h: { cpu: [number, number][]; mem: [number, number][]; disk: [number, number][]; net: [number, number][] }
  services: string[]
  related_alerts: AlertItem[]
  log_tail: { ts: string; line: string }[] | null
  loki?: string | null
  grafana_url: string
  generated_at: string
}
