// M3 mock 走查(段A 驗收):動作按鈕顯隱、確認框、toast、Remote-User 兩態、RWD 三斷點
// 用法:node e2e-m3-mock.mjs(需 BFF mock 於 :18099 服務已建置 SPA)
import { chromium } from 'playwright'

const BASE = 'http://localhost:18099'
const SHOT = '/tmp/m3-shots'
import { mkdirSync } from 'fs'
mkdirSync(SHOT, { recursive: true })

const results = []
function check(name, ok, extra = '') {
  results.push({ name, ok, extra })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? ` — ${extra}` : ''}`)
}

const browser = await chromium.launch()

// ---- 場景 1:portal.hl(帶 Remote-User)----
const ctxAuth = await browser.newContext({ extraHTTPHeaders: { 'Remote-User': 'lai' }, viewport: { width: 1440, height: 900 } })
const p = await ctxAuth.newPage()
await p.goto(`${BASE}/m/alerts`)
await p.waitForSelector('text=SquidProxyDown')

// 1a. mapped 告警有處置鍵 + 靜音兩鍵
const squidRow = p.locator('div.rounded-card', { hasText: 'SquidProxyDown' }).first()
check('SquidProxyDown 列有〔重啟 CT202 squid〕處置鍵', await squidRow.locator('button', { hasText: '重啟 CT202 squid' }).count() === 1)
check('SquidProxyDown 列有靜音兩鍵', await squidRow.locator('button', { hasText: '靜音 1h' }).count() === 1 && await squidRow.locator('button', { hasText: '靜音 24h' }).count() === 1)

// 1b. 未對映告警只有靜音鍵
const vmRow = p.locator('div.rounded-card', { hasText: 'VM300HoneypotDown' }).first()
check('VM300HoneypotDown 只有靜音鍵(無處置鍵)', await vmRow.locator('button').count() === 2)

await p.screenshot({ path: `${SHOT}/alerts-desktop.png`, fullPage: true })

// 1c. 確認框:寫明將執行什麼;Esc 取消
await vmRow.locator('button', { hasText: '靜音 1h' }).click()
const dlg = p.locator('[role="dialog"]')
check('確認框寫明將執行什麼', (await dlg.textContent()).includes('將執行:靜音 VM300HoneypotDown 1 小時'))
await p.screenshot({ path: `${SHOT}/confirm.png` })
await p.keyboard.press('Escape')
check('Esc 取消確認框', await dlg.count() === 0)

// 1d. 確認 → toast「已靜音 X 1 小時」+ optimistic 標記
await vmRow.locator('button', { hasText: '靜音 1h' }).click()
await dlg.locator('button', { hasText: '確認執行' }).click()
await p.waitForSelector('text=已靜音 VM300HoneypotDown 1 小時', { timeout: 5000 })
check('成功 toast 命名一致(已+按鈕文案)', true)
check('optimistic 已送出靜音標記', await vmRow.locator('text=已送出靜音').count() === 1)
check('該列按鈕送出後 disabled', await vmRow.locator('button[disabled]').count() === 2)
await p.screenshot({ path: `${SHOT}/toast.png` })

// 1e. danger 警告行(重啟 CT203 會清通行證——mock fixture 無 CtdmzGateDown,改驗處置鍵確認框)
await squidRow.locator('button', { hasText: '重啟 CT202 squid' }).click()
check('處置鍵確認框文案', (await dlg.textContent()).includes('將執行:重啟 CT202 squid'))
await dlg.locator('button', { hasText: '取消' }).click()

// ---- 場景 2:直達 :8088(無 Remote-User)----
const ctxDirect = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const q = await ctxDirect.newPage()
await q.goto(`${BASE}/m/alerts`)
await q.waitForSelector('text=SquidProxyDown')
check('直達無任何動作按鈕', await q.locator('div.rounded-card button', { hasText: '靜音' }).count() === 0)
check('直達顯示唯讀提示', await q.locator('text=操作按鈕僅在 portal.hl 登入後提供').count() === 1)
await q.screenshot({ path: `${SHOT}/direct-readonly.png`, fullPage: true })

// ---- 場景 3:RWD 平板/手機(帶 header)----
for (const [name, w, h] of [['tablet', 1024, 768], ['phone', 390, 844]]) {
  const c = await ctxAuth.newPage()
  await c.setViewportSize({ width: w, height: h })
  await c.goto(`${BASE}/m/alerts`)
  await c.waitForSelector('text=SquidProxyDown')
  check(`${name} 按鈕排可見`, await c.locator('button', { hasText: '靜音 1h' }).first().isVisible())
  await c.screenshot({ path: `${SHOT}/alerts-${name}.png`, fullPage: true })
  await c.close()
}

await browser.close()
const fails = results.filter(r => !r.ok)
console.log(`\n== ${results.length - fails.length}/${results.length} PASS ==`)
process.exit(fails.length ? 1 : 0)
