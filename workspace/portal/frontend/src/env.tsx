import { createContext, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useAlerts } from './api'

/** ?crit=1/0、?night=1/0 強制預覽(走查/驗收用,同 ?clawd= 慣例) */
function forcedFlag(key: string): boolean | null {
  const q = new URLSearchParams(window.location.search).get(key)
  return q === null ? null : q === '1'
}

interface Env {
  crit: boolean
  night: boolean
  /** 夜間預覽切換(命令面板用;重整還原自動判定) */
  toggleNight: () => void
}

const EnvCtx = createContext<Env>({ crit: false, night: false, toggleNight: () => {} })

export function useEnv(): Env {
  return useContext(EnvCtx)
}

/**
 * 環境態(0.17.0):把 crit 戰情(critical firing>0)與 night 夜間
 * (23:00–07:00,與 Clawd 睡覺同一張表)掛到 <html> class——
 * CSS token(html.night 降飽和)與 html.crit 頂部紅呼吸條全站聯動。
 * 掛在 Layout=kiosk(頂層路由)天然不受影響;unmount 摘 class 不殘留。
 */
export function EnvProvider({ children }: { children: ReactNode }) {
  const al = useAlerts()
  const [hour, setHour] = useState(() => new Date().getHours())
  const [nightOverride, setNightOverride] = useState<boolean | null>(() => forcedFlag('night'))

  // 夜間判定對表(每分鐘;同 Mascot 睡覺時鐘)
  useEffect(() => {
    const iv = window.setInterval(() => setHour(new Date().getHours()), 60_000)
    return () => clearInterval(iv)
  }, [])

  const crit = forcedFlag('crit') ?? (al.data?.firing ?? []).some((a) => a.severity === 'critical')
  const night = nightOverride ?? (hour >= 23 || hour < 7)

  useEffect(() => {
    document.documentElement.classList.toggle('crit', crit)
    document.documentElement.classList.toggle('night', night)
  }, [crit, night])
  useEffect(() => () => document.documentElement.classList.remove('crit', 'night'), [])

  const value = useMemo<Env>(
    () => ({ crit, night, toggleNight: () => setNightOverride((o) => !(o ?? night)) }),
    [crit, night],
  )
  return <EnvCtx.Provider value={value}>{children}</EnvCtx.Provider>
}
