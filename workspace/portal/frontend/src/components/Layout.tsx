import { useEffect } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { MODULES, TABBAR } from '../modules'
import { useStream } from '../api'
import { EnvProvider } from '../env'
import Ambient from './Ambient'
import CommandPalette from './CommandPalette'
import Mascot from './Mascot'

function isActive(route: string, pathname: string): boolean {
  return route === '/' ? pathname === '/' : pathname.startsWith(route)
}

export default function Layout() {
  const { pathname } = useLocation()
  useStream()
  // 鍵盤捷徑(0.17.0 起收攏進 CommandPalette):⌘K//喚起面板、g+字母跳頁

  // 卡片光暈(0.17.0 P1):全站一條 pointermove 委派,把游標位置寫進
  // 最近 .card-hover 的 --mx/--my,::after 的 radial 跟著走
  useEffect(() => {
    const onMove = (e: PointerEvent) => {
      const c = (e.target as Element | null)?.closest?.('.card-hover') as HTMLElement | null
      if (!c) return
      const r = c.getBoundingClientRect()
      c.style.setProperty('--mx', `${e.clientX - r.left}px`)
      c.style.setProperty('--my', `${e.clientY - r.top}px`)
    }
    addEventListener('pointermove', onMove, { passive: true })
    return () => removeEventListener('pointermove', onMove)
  }, [])

  return (
    <EnvProvider>
    <div className="flex min-h-screen">
      {/* 背景氛圍層:z-0;側欄(sticky)與 fixed 元件靠 DOM 序/z 疊其上,
          main 顯式 z-[1](非定位元素會被畫到 canvas 下面) */}
      <Ambient />

      {/* 側欄:≥1280 全寬 220px;768–1279 圖示欄;<768 隱藏(§6 RWD) */}
      <aside className="sticky top-0 hidden h-screen shrink-0 border-r border-line py-5 md:block md:w-14 xl:w-[220px]">
        <div className="border-b border-line px-0 pb-[18px] text-center xl:px-5 xl:text-left">
          <div className="font-serif text-[19px] font-black tracking-[.06em]">
            <span className="hidden xl:inline">入口大廳</span>
            <span className="xl:hidden">廳</span>
          </div>
          <div className="mt-0.5 hidden font-mono text-[11px] text-muted xl:block">home.arpa · portal v0.19.1</div>
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

      <main className="relative z-[1] min-w-0 max-w-[1180px] flex-1 px-3.5 pb-[90px] pt-4 md:px-[26px] md:pt-[22px]">
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

      {/* 吉祥物(0.13.0):fixed 漂浮全頁面;掛在 Layout 根層=無 transform 祖先、
          kiosk(頂層路由不走 Layout)自然豁免 */}
      <Mascot />

      {/* ⌘K 命令面板(0.17.0):全域鍵盤捷徑也由它託管 */}
      <CommandPalette />
    </div>
    </EnvProvider>
  )
}
