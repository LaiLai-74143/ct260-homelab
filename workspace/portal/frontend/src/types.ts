// API 契約 —— 《入口大廳設計報告-3》§8
export type HostState = 'ok' | 'warn' | 'crit' | 'unk'

export interface Host {
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
