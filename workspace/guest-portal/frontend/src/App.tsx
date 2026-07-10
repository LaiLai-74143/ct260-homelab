import { useMe } from './api'
import Login from './pages/Login'
import Dashboard from './pages/Dashboard'

export default function App() {
  const me = useMe()

  if (me.isLoading) {
    return <div className="flex min-h-screen items-center justify-center text-muted">載入中…</div>
  }
  // 401 → useMe 落 error;已登入 → success
  return me.isSuccess ? <Dashboard /> : <Login />
}
