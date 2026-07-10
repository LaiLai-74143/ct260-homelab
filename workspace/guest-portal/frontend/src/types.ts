export type CalItem = {
  date: string
  time: string       // "HH:MM" 或 "全天"
  title: string
  all_day: boolean
}

export type DebtDir = 'they_owe' | 'i_owe'

export type OpenTx = {
  id: number
  dir: DebtDir
  amount: number
  item: string | null
  date: string | null
  due: string | null
  notes: string | null
}

export type SettledTx = {
  id: number
  dir: DebtDir
  amount: number
  item: string | null
  date: string | null
  settled_date: string | null
  notes: string | null
}

export type Debts = {
  net: number
  currency: string
  open: OpenTx[]
  settled: SettledTx[]
}

export type GuestData = {
  username: string
  person: string
  generated_at: string | null
  calendar: CalItem[]
  debts: Debts
}

export type Me = {
  username: string
  person: string
}
