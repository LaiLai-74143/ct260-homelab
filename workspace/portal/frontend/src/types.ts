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
  battery_low?: boolean
  charge?: number
  load?: number
  runtime_s?: number
  input_v?: number
  watts?: number
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

/** 單筆交易(逐人列點開的第二層明細) */
export interface DebtTx {
  id: number
  dir: '待收' | '待還'
  kind: string
  amount: number | null
  currency: string
  item?: string | null
  date?: string | null
  due?: string | null
  summary?: string | null
  /** 追記(部分動支等 update_transaction 寫這裡) */
  notes?: string | null
  settled: boolean
}

/** 逐人淨額一列(同人多筆互抵;redacted 時整組 persons=null——含對象與金額,僅 portal.hl) */
export interface DebtPerson {
  who: string
  /** 簽名淨額(TWD):>0 待收(他人欠我)、<0 待還(我欠他人)、0=兩清或僅物品 */
  net: number
  /** 該人未結筆數(互抵來源筆數) */
  count: number
  /** 該人最近的到期日 */
  due?: string | null
  /** 物品往來(不能互抵),如「待收 電鑽」 */
  items?: string[]
  /** 該人交易紀錄:未結全列+最近已結(≤10 筆,settled 標記) */
  tx?: DebtTx[]
}

export interface Life {
  pending?: boolean
  hint?: string
  redacted?: boolean
  calendar_today?: { time: string; title: string | null }[]
  debts_open?: {
    count: number
    /** 全體互抵後淨額(TWD 簽名值);redacted 時 null */
    total: number | null
    persons?: DebtPerson[] | null
    /** 有非 TWD 未結金錢借貸:淨額僅含 NT$,前端須註明 */
    foreign?: boolean
    truncated?: boolean
  }
  stale_seconds?: number | null
  generated_at: string
}

// ---- M3 動作契約(待辦49 M3;BFF actions.py) ----

export interface ActionSpec {
  desc: string
  /** 該動作收的參數語義(僅 silence-* = alertname) */
  param?: string
  /** 確認框追加的琥珀警告行 */
  danger?: string
}

export interface ActionsInfo {
  /** live 下 WEBHOOK_URL+token 已配置;false 時前端完全不提動作 */
  enabled: boolean
  /** 本請求可否操作(僅 portal.hl 帶 Remote-User 時 true,使用者裁決 2026-07-08) */
  allowed: boolean
  scope: 'all-firing' | 'mapped-only'
  actions: Record<string, ActionSpec>
  /** 告警名 → 預定義處置動作(鏡像自 CT260 NTFY_ACTION_MAP) */
  alert_map: Record<string, string>
  generated_at: string
}

export interface ActionResult {
  ok: boolean
  action: string
  rc?: number
  out?: string
  desc?: string
  /** fire-and-forget(pct-reboot-201)= 202 已受理,結果見 TG */
  accepted?: boolean
  hint?: string
  mock?: boolean
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

// ---- 生活助理(待辦49 生活對話框;BFF /api/life/chat|confirm → CT260 life-chat :5002) ----

export interface ChatMessage {
  role: 'user' | 'assistant'
  content: string
}

/** 提案單:五欄位原樣帶回 /api/life/confirm,sig 由 CT260 端 HMAC 簽發 */
export interface ChatProposal {
  action: string
  args: Record<string, string | number | boolean>
  summary: string
  ts: number
  sig: string
}

export interface ChatReply {
  ok: boolean
  reply: string
  proposals: ChatProposal[]
  rejected: string[]
  meta?: { turns?: number; secs?: number }
}

export interface ChatConfirmResult {
  ok: boolean
  result: string
}

export interface LifeChatInfo {
  enabled: boolean
  allowed: boolean
  scope: string
  generated_at: string
}
