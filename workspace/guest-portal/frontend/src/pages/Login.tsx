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

  const err = login.error as (Error & { status?: number; hint?: string }) | null
  // 顯示伺服器實際訊息(查無此帳號 / 密碼錯誤 / 此帳號已停用 / 嘗試過於頻繁)+ 提示
  const errMsg = err ? (err.message || '登入失敗') : ''
  const errHint = err?.hint || ''

  return (
    <div className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <h1 className="text-xl font-serif text-text">行程共享</h1>
          <p className="text-muted text-sm mt-1">登入以查看行程與往來明細</p>
        </div>
        <form onSubmit={submit} className="bg-panel border border-line rounded-card p-5 space-y-4">
          <label className="block">
            <span className="text-sm text-muted">帳號<span className="ml-1.5 text-unk">(身分證字號)</span></span>
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
            <span className="text-sm text-muted">密碼<span className="ml-1.5 text-unk">(管制標籤號)</span></span>
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
            <div role="alert">
              <div className="text-crit text-sm">{errMsg}</div>
              {errHint && <div className="text-muted text-xs mt-0.5">{errHint}</div>}
            </div>
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
      </div>
    </div>
  )
}
