// M4 kiosk mock 走查:無導航/深黑底、輪播、tap 三分區、鍵盤同義、?interval=、reduced-motion 瞬切
// 用法:node e2e-m4-mock.mjs(需 BFF mock 於 :18099 服務已建置 SPA)
import { chromium } from 'playwright'
import { mkdirSync } from 'fs'

const BASE = 'http://localhost:18099'
const SHOT = '/tmp/m4-shots'
mkdirSync(SHOT, { recursive: true })

const results = []
function check(name, ok, extra = '') {
  results.push({ name, ok, extra })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? ` — ${extra}` : ''}`)
}

const browser = await chromium.launch()

// ---- 場景 1:平板 1024×768(§6 kiosk 主斷點),interval=5 供自動換屏驗證 ----
const ctx = await browser.newContext({ viewport: { width: 1024, height: 768 } })
const p = await ctx.newPage()
await p.goto(`${BASE}/kiosk?interval=5`)
await p.waitForSelector('text=MODULES')

// 1a. 無導航(Layout 側欄/底部 tab 不存在)+ 深黑底
check('無側欄/底部 tab', await p.locator('aside').count() === 0 && await p.locator('nav').count() === 0)
const bg = await p.locator('.kiosk-root').evaluate((el) => getComputedStyle(el).backgroundColor)
check('深黑底 #000', bg === 'rgb(0, 0, 0)', bg)
check('三圓點指示、active=1 顆 amber', await p.locator('footer span.rounded-full').count() === 3 && await p.locator('footer span.bg-amber').count() === 1)
await p.screenshot({ path: `${SHOT}/kiosk-home.png` })

// 1b. tap 右 1/3 → 設備屏
await p.mouse.click(1024 * 0.85, 384)
await p.waitForSelector('text=設備總覽')
check('tap 右 1/3 → 設備屏', true)
await p.screenshot({ path: `${SHOT}/kiosk-devices.png` })

// 1c. tap 左 1/3 → 回大廳
await p.mouse.click(1024 * 0.15, 384)
await p.waitForSelector('text=MODULES')
check('tap 左 1/3 → 回大廳', true)

// 1d. tap 中 1/3 → 暫停;暫停時超過 interval 不換屏;再 tap 續播
await p.mouse.click(512, 384)
check('tap 中 → 顯示已暫停', await p.locator('text=已暫停').isVisible())
await p.waitForTimeout(6000)
check('暫停時不自動換屏', await p.locator('text=MODULES').count() > 0)
await p.mouse.click(512, 384)
check('再 tap 中 → 續播(標記消失)', await p.locator('text=已暫停').count() === 0)

// 1e. ?interval=5 自動輪播:等 6s 應轉到設備屏(續播後計時重起)
await p.waitForSelector('text=設備總覽', { timeout: 7000 })
check('?interval=5 自動換屏生效', true)

// 1f. 鍵盤同義:→ 安全屏、← 回設備、空白暫停/續播
await p.keyboard.press('ArrowRight')
await p.waitForSelector('text=安全面板')
check('鍵盤 → 下一屏(安全)', true)
await p.screenshot({ path: `${SHOT}/kiosk-security.png` })
await p.keyboard.press('ArrowLeft')
await p.waitForSelector('text=設備總覽')
check('鍵盤 ← 上一屏', true)
await p.keyboard.press(' ')
check('鍵盤空白 → 暫停', await p.locator('text=已暫停').isVisible())
await p.keyboard.press(' ')

// 1g. 誤觸防護:內容層 pointer-events-none,tap 卡片位置不跳路由(仍在 /kiosk)
await p.mouse.click(1024 * 0.85, 200) // 右上=卡片區,但落在右 1/3 tap 區 → 只換屏
check('tap 卡片位置不離開 /kiosk', new URL(p.url()).pathname === '/kiosk')

// 1h. 輪播循環:安全屏(尾)自動回大廳(頭)
await p.goto(`${BASE}/kiosk?interval=5`)
await p.waitForSelector('text=MODULES')
await p.keyboard.press('ArrowLeft') // 大廳 ← = 循環到安全屏
await p.waitForSelector('text=安全面板')
await p.waitForSelector('text=MODULES', { timeout: 7000 }) // 5s 後自動循環回頭
check('尾屏自動循環回大廳', true)

// 1i. 非法 interval 回預設(不 crash,頁面照常)
await p.goto(`${BASE}/kiosk?interval=abc`)
await p.waitForSelector('text=MODULES')
check('interval=abc 回預設不 crash', true)

// ---- 場景 2:reduced-motion → 去掉 route-fade(瞬切),輪播照轉 ----
const ctxRm = await browser.newContext({ viewport: { width: 1024, height: 768 }, reducedMotion: 'reduce' })
const q = await ctxRm.newPage()
await q.goto(`${BASE}/kiosk?interval=5`)
await q.waitForSelector('text=MODULES')
check('reduced-motion 內容層無 route-fade', await q.locator('.kiosk-root .route-fade').count() === 0)
await q.keyboard.press('ArrowRight')
await q.waitForSelector('text=設備總覽')
check('reduced-motion 換屏(瞬切)照常', true)

// 對照:一般模式內容層有 route-fade
check('一般模式內容層有 route-fade', await p.locator('.kiosk-root .route-fade').count() === 1)

await browser.close()
const fails = results.filter(r => !r.ok)
console.log(`\n== ${results.length - fails.length}/${results.length} PASS ==`)
process.exit(fails.length ? 1 : 0)
