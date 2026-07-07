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
import Home from './pages/Home'
import Devices from './pages/Devices'
import Alerts from './pages/Alerts'
import More from './pages/More'
import Host from './pages/Host'
import Stub from './pages/Stub'

const router = createBrowserRouter([
  {
    path: '/',
    element: <Layout />,
    children: [
      { index: true, element: <Home /> },
      { path: 'm/devices', element: <Devices /> },
      { path: 'm/alerts', element: <Alerts /> },
      { path: 'm/services', element: <Stub title="服務目錄" api="GET /api/services" /> },
      { path: 'm/security', element: <Stub title="安全面板" api="GET /api/security" /> },
      { path: 'm/power', element: <Stub title="電力" api="GET /api/power" /> },
      { path: 'm/game', element: <Stub title="遊戲" api="GET /api/game" /> },
      { path: 'm/life', element: <Stub title="生活" api="GET /api/life" /> },
      { path: 'more', element: <More /> },
      { path: 'host/:name', element: <Host /> },
      { path: 'kiosk', element: <Stub title="Kiosk 輪播" api="M4(待辦44 牆面平板)" /> },
      { path: '*', element: <Home /> },
    ],
  },
])

const qc = new QueryClient({
  defaultOptions: {
    queries: { retry: 1, refetchOnWindowFocus: true },
  },
})

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={qc}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </React.StrictMode>,
)
