// 0.17.0 mock 走查:⌘K 面板/g 跳頁/sparkline/氛圍層/夜間/crit 戰情/晨報條列/光暈/回歸
// 用法:node e2e-0170-mock.mjs(需 mock BFF 於 :8188,PORTAL_ACTION_AUTH=open)
import { chromium } from 'playwright'
import { mkdirSync } from 'fs'

const BASE = 'http://127.0.0.1:8188'
const SHOT = '/tmp/portal-0170-shots'
mkdirSync(SHOT, { recursive: true })

const results = []
function check(name, ok, extra = '') {
  results.push({ name, ok })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? ` — ${extra}` : ''}`)
}

const browser = await chromium.launch()
const errors = []
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
const p = await ctx.newPage()
p.on('pageerror', (e) => errors.push(String(e)))

// ---- 1. 大廳:sparkline + 氛圍層 + ⌘K 鈕 ----
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.waitForTimeout(800)
const sparkN = await p.locator('svg.spark').count()
check('大廳卡片 sparkline(devices/alerts/security/power=4 條)', sparkN === 4, `實際 ${sparkN}`)
check('氛圍層 canvas 存在', await p.locator('canvas[aria-hidden]').count() === 1)
check('banner 有「⌘K 搜尋」鈕', await p.locator('button', { hasText: '⌘K 搜尋' }).count() === 1)
await p.screenshot({ path: `${SHOT}/01-home.png` })

// ---- 2. 晨報「今日訊息」條列 ----
const news = p.locator('section', { hasText: '今日訊息' })
// 刊頭 mast 也是 flex items-baseline,要用新聞列獨有的 gap-2.5 區分
const rows = await news.locator('div.flex.items-baseline.gap-2\\.5').count()
check('今日訊息拆條列(6 條)', rows === 6, `實際 ${rows}`)
const srcs = await news.locator('span.font-mono.text-\\[10\\.5px\\]').allTextContents()
check('來源右欄抽出(Hacker News/Ars Technica)', srcs.filter((s) => /Hacker News|Ars Technica/.test(s)).length === 6, JSON.stringify(srcs))

// ---- 3. ⌘K 面板:鍵盤開合、模糊搜尋、Enter 導航 ----
await p.keyboard.press('Control+k')
await p.waitForSelector('[aria-label="命令面板"]')
check('Ctrl+K 開面板', true)
await p.keyboard.type('設備')
await p.waitForTimeout(150)
const firstItem = await p.locator('[aria-label="命令面板"] [data-sel]').textContent()
check('模糊搜尋「設備」選中設備總覽', (firstItem ?? '').includes('設備總覽'), firstItem ?? '')
await p.keyboard.press('Enter')
await p.waitForURL('**/m/devices')
check('Enter 導航到 /m/devices', true)
check('面板已關閉', await p.locator('[aria-label="命令面板"]').count() === 0)

// ---- 4. / 開面板、Esc 關、g h 跳大廳 ----
await p.keyboard.press('/')
await p.waitForSelector('[aria-label="命令面板"]')
check('/ 開面板', true)
await p.keyboard.press('Escape')
await p.waitForTimeout(120)
check('Esc 關面板', await p.locator('[aria-label="命令面板"]').count() === 0)
await p.keyboard.press('g')
await p.keyboard.press('h')
await p.waitForURL(`${BASE}/`)
check('g h 跳大廳', true)
await p.keyboard.press('g')
await p.keyboard.press('a')
await p.waitForURL('**/m/alerts')
check('g a 跳告警', true)

// ---- 5. 面板靜音動作:確認框 → POST /api/action payload → toast ----
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
let actionBody = null
p.on('request', (r) => {
  if (r.url().endsWith('/api/action') && r.method() === 'POST') actionBody = r.postDataJSON()
})
await p.keyboard.press('Control+k')
await p.waitForSelector('[aria-label="命令面板"]')
await p.keyboard.type('靜音')
await p.waitForTimeout(150)
const muteItem = await p.locator('[aria-label="命令面板"] [data-sel]').textContent()
check('搜「靜音」出現告警靜音項', (muteItem ?? '').includes('靜音') && (muteItem ?? '').includes('1 小時'), muteItem ?? '')
await p.keyboard.press('Enter')
await p.waitForSelector('text=確認執行')
check('靜音先出確認框', true)
await p.screenshot({ path: `${SHOT}/02-confirm.png` })
await p.locator('button', { hasText: '確認執行' }).click()
await p.waitForSelector('text=已靜音', { timeout: 8000 })
check('toast「已靜音 … 1 小時」', true)
check('POST payload 鍵集合 {action,param} 且 action=silence-1h',
  actionBody !== null && actionBody.action === 'silence-1h' && typeof actionBody.param === 'string'
  && Object.keys(actionBody).sort().join() === 'action,param', JSON.stringify(actionBody))

// ---- 6. 面板戳 Clawd ----
await p.keyboard.press('Control+k')
await p.waitForSelector('[aria-label="命令面板"]')
await p.keyboard.type('clawd')
await p.waitForTimeout(150)
await p.keyboard.press('Enter')
await p.waitForTimeout(300)
const bubble = await p.locator('[role="status"]').filter({ hasText: /Clawd|值班|防火牆|Prometheus|綠燈|施工|blame|crit/ }).count()
check('面板「戳一下 Clawd」出台詞泡泡', bubble >= 1)

// ---- 7. 夜間模式:?night=1 → html.night + token 變化 + 月相 ----
await p.goto(`${BASE}/?night=1`)
await p.waitForSelector('text=MODULES')
check('?night=1 掛 html.night', await p.evaluate(() => document.documentElement.classList.contains('night')))
const amber = await p.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--amber').trim())
check('夜間琥珀降飽和 #C9913F', amber.toUpperCase() === '#C9913F', amber)
const bodyBg = await p.evaluate(() => getComputedStyle(document.body).backgroundColor)
check('夜間 body 背景換深階(tailwind var 管道通)', bodyBg === 'rgb(10, 13, 18)', bodyBg)
check('刊頭出月相 ☾', (await p.locator('text=☾').count()) >= 1)
await p.screenshot({ path: `${SHOT}/03-night.png` })

// ---- 8. crit 戰情:?crit=1 → html.crit + INCIDENT + 紅條 ----
await p.goto(`${BASE}/?crit=1`)
await p.waitForSelector('text=MODULES')
check('?crit=1 掛 html.crit', await p.evaluate(() => document.documentElement.classList.contains('crit')))
check('刊頭 INCIDENT 徽章', await p.locator('text=INCIDENT').count() === 1)
const beforeBar = await p.evaluate(() => {
  const s = getComputedStyle(document.body, '::before')
  return { h: s.height, pos: s.position }
})
check('頂部紅呼吸條(body::before fixed 2px)', beforeBar.h === '2px' && beforeBar.pos === 'fixed', JSON.stringify(beforeBar))
await p.screenshot({ path: `${SHOT}/04-crit.png` })

// ---- 9. 光暈:pointermove 寫入 --mx/--my ----
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.waitForTimeout(600)
const card = p.locator('a.card-hover').first()
const box = await card.boundingBox()
await p.mouse.move(box.x + 40, box.y + 20)
await p.waitForTimeout(100)
const mx = await card.evaluate((el) => el.style.getPropertyValue('--mx'))
check('卡片光暈 --mx 寫入', /px$/.test(mx), mx)

// ---- 10. 回歸:右鍵 Clawd 問答殼、服務頁、reduced-motion ----
const mascotBtn = p.locator('button[aria-label="戳一下 Clawd"]')
await mascotBtn.click({ button: 'right' })
await p.waitForSelector('text=CLAWD · SONNET 5 · 唯讀')
check('右鍵 Clawd 問答框仍開得起來', true)
await p.keyboard.press('Escape')

const ctxR = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 1440, height: 900 } })
const pr = await ctxR.newPage()
pr.on('pageerror', (e) => errors.push(String(e)))
await pr.goto(`${BASE}/`)
await pr.waitForSelector('text=MODULES')
await pr.waitForTimeout(400)
check('reduced-motion 下內容可見(卡片非隱藏)', await pr.locator('a.card-hover').first().isVisible())
check('reduced-motion 氛圍層仍在(靜態網格)', await pr.locator('canvas[aria-hidden]').count() === 1)

// ---- 11. 手機寬度:tabbar 上開面板(banner 鈕) ----
const ctxM = await browser.newContext({ viewport: { width: 390, height: 780 } })
const pm = await ctxM.newPage()
pm.on('pageerror', (e) => errors.push(String(e)))
await pm.goto(`${BASE}/`)
await pm.waitForSelector('text=MODULES')
await pm.locator('button', { hasText: '⌘K 搜尋' }).click()
check('手機:banner 鈕開面板', await pm.locator('[aria-label="命令面板"]').count() === 1)
await pm.screenshot({ path: `${SHOT}/05-mobile-cmdk.png` })

check('無 page error', errors.length === 0, errors.join(' | '))
await browser.close()

const fails = results.filter((r) => !r.ok).length
console.log(`\n${results.length - fails}/${results.length} PASS`)
process.exit(fails ? 1 : 0)
