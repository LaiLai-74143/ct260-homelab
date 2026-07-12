import React from 'react'
import ReactDOM from 'react-dom/client'
import { createBrowserRouter, RouterProvider } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// 字體自托管(@fontsource,LAN 不依賴外網 CDN):三役 = Serif 刊頭 / Sans 內文 / Mono 數據
import '@fontsource/noto-serif-tc/700.css'
import '@fontsource/noto-serif-tc/900.css'
import '@fontsource/noto-sans-tc/400.css'
import '@fontsource/noto-sans-tc/500.css'
import '@fontsource/noto-sans-tc/700.css'
import '@fontsource/jetbrains-mono/400.css'
import '@fontsource/jetbrains-mono/600.css'
import './index.css'

import Layout from './components/Layout'
import { ToastProvider } from './components/Toast'
import Home from './pages/Home'
import Devices from './pages/Devices'
import Alerts from './pages/Alerts'
import Services from './pages/Services'
import Security from './pages/Security'
import Power from './pages/Power'
import Game from './pages/Game'
import Life from './pages/Life'
import Archive from './pages/Archive'
import ArchiveDoc from './pages/ArchiveDoc'
import More from './pages/More'
import Host from './pages/Host'
import Kiosk from './pages/Kiosk'

const router = createBrowserRouter([
  {
    path: '/',
    element: <Layout />,
    children: [
      { index: true, element: <Home /> },
      { path: 'm/devices', element: <Devices /> },
      { path: 'm/alerts', element: <Alerts /> },
      { path: 'm/services', element: <Services /> },
      { path: 'm/security', element: <Security /> },
      { path: 'm/power', element: <Power /> },
      { path: 'm/game', element: <Game /> },
      { path: 'm/life', element: <Life /> },
      { path: 'm/archive', element: <Archive /> },
      { path: 'archive/:id', element: <ArchiveDoc /> },
      { path: 'more', element: <More /> },
      { path: 'host/:name', element: <Host /> },
      { path: '*', element: <Home /> },
    ],
  },
  // kiosk 頂層路由繞過 Layout:側欄/tabbar/全域快捷鍵天然不存在(M4)
  { path: '/kiosk', element: <Kiosk /> },
])

const qc = new QueryClient({
  defaultOptions: {
    queries: { retry: 1, refetchOnWindowFocus: true },
  },
})

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={qc}>
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </QueryClientProvider>
  </React.StrictMode>,
)
