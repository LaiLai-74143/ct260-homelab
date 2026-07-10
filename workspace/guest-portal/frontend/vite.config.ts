import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// /api 一律走 BFF(dev 時指向本機 uvicorn :8399)
export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/api': 'http://localhost:8300' } },
  preview: { proxy: { '/api': 'http://localhost:8300' } },
})
