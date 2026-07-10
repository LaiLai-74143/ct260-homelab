import { useState } from 'react'
import { useLogin } from '../api'

export default function Login() {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const login = useLogin()

  function submit(e: React.FormEvent) {
    e.preventDefault()
    if (!username.trim() || !password) return
    login.mutate({ username: username.trim(), password })
  }

  const err = login.error as (Error & { status?: number }) | null
  const errMsg = err
    ? err.status === 429
      ? '嘗試過於頻繁,請 15 分鐘後再試'
      : '帳號或密碼錯誤'
    : ''

  return (
    <div className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <h1 className="text-xl font-serif text-text">行程共享</h1>
          <p className="text-muted text-sm mt-1">登入以查看行程與往來明細</p>
        </div>
        <form onSubmit={submit} className="bg-panel border border-line rounded-card p-5 space-y-4">
          <label className="block">
            <span className="text-sm text-muted">帳號</span>
            <input
              type="text"
              autoComplete="username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="mt-1 w-full bg-bg border border-line rounded-btn px-3 py-2 text-text
                         focus:outline-none focus:border-amber"
              autoFocus
            />
          </label>
          <label className="block">
            <span className="text-sm text-muted">密碼</span>
            <input
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mt-1 w-full bg-bg border border-line rounded-btn px-3 py-2 text-text
                         focus:outline-none focus:border-amber"
            />
          </label>
          {errMsg && (
            <div className="text-crit text-sm" role="alert">{errMsg}</div>
          )}
          <button
            type="submit"
            disabled={login.isPending || !username.trim() || !password}
            className="w-full bg-amber text-bg font-medium rounded-btn py-2
                       disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {login.isPending ? '登入中…' : '登入'}
          </button>
        </form>
        <p className="text-center text-unk text-xs mt-6">
          僅限受邀者存取。所有登入行為均被記錄。
        </p>
      </div>
    </div>
  )
}
