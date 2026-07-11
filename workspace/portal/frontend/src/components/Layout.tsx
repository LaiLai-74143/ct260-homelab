import { useEffect, useRef } from 'react'
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { MODULES, TABBAR } from '../modules'
import { useStream } from '../api'

function isActive(route: string, pathname: string): boolean {
  return route === '/' ? pathname === '/' : pathname.startsWith(route)
}

export default function Layout() {
  const nav = useNavigate()
  const { pathname } = useLocation()
  const pendingG = useRef(false)
  useStream()

  // 鍵盤捷徑(§7):g d 回大廳、g a 告警、/ 服務目錄搜尋
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return
      // 確認框開啟時(焦點在 dialog 內)不吃全域捷徑,避免 g/a 誤導航(M3)
      if (e.target instanceof HTMLElement && e.target.closest('[role="dialog"]')) return
      if (e.key === '/' && !pathname.startsWith('/m/services')) {
        // 進服務目錄;頁內的 / 聚焦由 Services 自己接手
        e.preventDefault()
        pendingG.current = false
        nav('/m/services', { viewTransition: true })
        return
      }
      if (e.key === 'g') { pendingG.current = true; return }
      if (pendingG.current) {
        if (e.key === 'd') nav('/', { viewTransition: true })
        if (e.key === 'a') nav('/m/alerts', { viewTransition: true })
      }
      pendingG.current = false
    }
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [nav, pathname])

  return (
    <div className="flex min-h-screen">
      {/* 側欄:≥1280 全寬 220px;768–1279 圖示欄;<768 隱藏(§6 RWD) */}
      <aside className="sticky top-0 hidden h-screen shrink-0 border-r border-line py-5 md:block md:w-14 xl:w-[220px]">
        <div className="border-b border-line px-0 pb-[18px] text-center xl:px-5 xl:text-left">
          <div className="font-serif text-[19px] font-black tracking-[.06em]">
            <span className="hidden xl:inline">入口大廳</span>
            <span className="xl:hidden">廳</span>
          </div>
          <div className="mt-0.5 hidden font-mono text-[11px] text-muted xl:block">home.arpa · portal v0.12</div>
        </div>
        <nav className="px-1.5 py-3 xl:px-2.5" aria-label="模塊導航">
          {MODULES.map((m) => {
            const on = isActive(m.route, pathname)
            return (
              <NavLink
                key={m.key}
                to={m.route}
                title={m.label}
                viewTransition
                className={`mb-0.5 flex items-center gap-2.5 rounded-card border-l-2 px-2 py-[9px] text-sm transition-colors duration-150 xl:px-3 ${
                  on
                    ? 'border-amber bg-amber/[.07] text-text'
                    : 'border-transparent text-muted hover:text-text'
                }`}
              >
                <span className={`w-[18px] text-center font-mono text-xs ${on ? 'text-amber' : 'text-muted'}`}>{m.icon}</span>
                <span className="hidden xl:inline">{m.label}</span>
              </NavLink>
            )
          })}
        </nav>
      </aside>

      <main className="min-w-0 max-w-[1180px] flex-1 px-3.5 pb-[90px] pt-4 md:px-[26px] md:pt-[22px]">
        {/* 0.10.0:拔 key={pathname} remount(單向淡入會閃)——路由切換交給
            View Transitions crossfade;route-fade 只在首載播一次 */}
        <div className="route-fade">
          <Outlet />
        </div>
      </main>

      {/* 手機底部 tab(<768) */}
      <nav
        className="fixed inset-x-0 bottom-0 z-50 flex border-t border-line bg-bg/95 backdrop-blur-lg md:hidden"
        style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
        aria-label="底部導航"
      >
        {TABBAR.map((m) => {
          const on = isActive(m.route, pathname)
          return (
            <NavLink
              key={m.key}
              to={m.route}
              viewTransition
              className={`flex-1 pb-2 pt-2.5 text-center text-[11px] ${on ? 'text-amber' : 'text-muted'}`}
            >
              <span className="mb-px block font-mono text-[15px]">{m.icon}</span>
              {m.shortLabel}
            </NavLink>
          )
        })}
      </nav>
    </div>
  )
}
