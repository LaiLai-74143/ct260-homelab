// RWD 三斷點截圖自查(報告 §12):против http://localhost:8088(BFF 供產物,貼近正式部署)
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const OUT = process.env.SHOT_DIR || 'shots'
const BASE = process.env.SHOT_BASE || 'http://localhost:8088'
mkdirSync(OUT, { recursive: true })

const BREAKPOINTS = [
  { tag: 'mobile-390', width: 390, height: 844 },
  { tag: 'tablet-1024', width: 1024, height: 800 },
  { tag: 'pc-1440', width: 1440, height: 900 },
]
const PAGES = [
  { tag: 'home', path: '/' },
  { tag: 'devices', path: '/m/devices' },
  { tag: 'alerts', path: '/m/alerts' },
  { tag: 'services', path: '/m/services' },
  { tag: 'security', path: '/m/security' },
  { tag: 'power', path: '/m/power' },
  { tag: 'game', path: '/m/game' },
  { tag: 'life', path: '/m/life' },
  { tag: 'host', path: '/host/ct201' },
]

const browser = await chromium.launch()
for (const bp of BREAKPOINTS) {
  const ctx = await browser.newContext({ viewport: { width: bp.width, height: bp.height } })
  const page = await ctx.newPage()
  for (const p of PAGES) {
    // SSE 常駐連線使 networkidle 永不成立 → 等 load + 面板元素出現
    await page.goto(`${BASE}${p.path}`, { waitUntil: 'load' })
    await page.waitForSelector('main .rounded-card', { timeout: 10_000 })
    await page.waitForTimeout(600) // 字體/淡入落定
    await page.screenshot({ path: `${OUT}/${p.tag}-${bp.tag}.png`, fullPage: true })
    console.log(`${p.tag}-${bp.tag}.png`)
  }
  await ctx.close()
}
await browser.close()
