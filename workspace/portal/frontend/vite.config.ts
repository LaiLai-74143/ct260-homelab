import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// /api 一律走 BFF(dev 時指向本機 uvicorn :8088)——前端永遠只跟 BFF 說話
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: { '/api': 'http://localhost:8088' },
  },
  preview: {
    proxy: { '/api': 'http://localhost:8088' },
  },
})
