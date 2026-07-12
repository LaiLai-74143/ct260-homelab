// 0.19.x mock 走查:邸報(剪藏/邸報切換、六部分區+組內分排、AI 導讀、批閱准駁、L0 sub)+0.18 回歸
// 用法:node e2e-0190-mock.mjs(需 mock BFF 於 :8188,PORTAL_STATIC=dist;每輪重啟 BFF 取乾淨態)
import { chromium } from 'playwright'
import { mkdirSync } from 'fs'

const BASE = 'http://127.0.0.1:8188'
const SHOT = '/tmp/portal-0190-shots'
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

// ---- 1. 大廳 L0:拾遺卡 sub 帶邸報今日 ----
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.waitForTimeout(600)
const archCard = p.locator('a[href="/m/archive"].card-hover')
check('L0 拾遺卡 sub 帶「邸報今日」', ((await archCard.textContent()) ?? '').includes('邸報今日'), (await archCard.textContent()) ?? '')

// ---- 2. 列表頁:預設剪藏(6 篇/六部分組),切邸報(4 篇/按分排) ----
await p.goto(`${BASE}/m/archive`)
await p.waitForSelector('h2:has-text("拾遺歸檔")')
await p.waitForSelector('text=吏·名籍')
check('剪藏視圖:六部分組+總數 6', ((await p.locator('h2:has-text("拾遺歸檔")').locator('..').textContent()) ?? '').includes('6 篇'))
check('剪藏視圖:有收藏輸入列', await p.locator('input[placeholder^="貼上網址"]').count() === 1)
await p.locator('button', { hasText: '邸報' }).click()
await p.waitForSelector('text=GhostLock', { timeout: 5000 })
check('邸報視圖:總數 4', ((await p.locator('h2:has-text("拾遺歸檔")').locator('..').textContent()) ?? '').includes('4 篇'))
// 0.19.1:邸報也六部分區(固定順序戶→禮→刑→工,空部隱藏),組內按分
const rssHeads = await p.locator('section > div.font-serif').allTextContents()
check('邸報六部分區(戶/禮/刑/工)', rssHeads.length === 4
  && ['戶·府庫', '禮·典章', '刑·稽核', '工·營造'].every((t, i) => (rssHeads[i] ?? '').includes(t)), rssHeads.join('|'))
check('GhostLock 在刑·稽核區塊', ((await p.locator('section', { hasText: '刑·稽核' }).textContent()) ?? '').includes('GhostLock'))
const scores = await p.locator('a[href^="/archive/"] span.text-amber').allTextContents()
check('分區後組內按分(6,5,9,8)', scores.join(',') === '6,5,9,8', scores.join(','))
check('邸報視圖:收藏輸入列隱藏', await p.locator('input[placeholder^="貼上網址"]').count() === 0)
check('URL 帶 tab=rss', p.url().includes('tab=rss'))
await p.screenshot({ path: `${SHOT}/01-dibao-list.png` })

// ---- 3. 邸報閱讀器:批閱列+meta ----
await p.locator('a[href^="/archive/"]', { hasText: 'GhostLock' }).click()
await p.waitForSelector('article h1')
check('閱讀器 meta 帶邸報籤(來源+分數)', ((await p.locator('article').textContent()) ?? '').includes('邸報 · Hacker News · 9 分'))
check('閱讀器正文帶【AI 導讀】(0.19.1)', ((await p.locator('article').textContent()) ?? '').includes('【AI 導讀】'))
check('批閱列在(准/駁)', await p.locator('button', { hasText: '准 · 收編入庫' }).count() === 1
  && await p.locator('button', { hasText: '駁 · 撤下' }).count() === 1)
check('返回鏈=回邸報', ((await p.locator('text=← 回邸報').count())) === 1)
await p.screenshot({ path: `${SHOT}/02-dibao-reader.png` })

// ---- 4. 准:收編入庫 → 剪藏 7 篇、邸報 3 篇 ----
await p.locator('button', { hasText: '准 · 收編入庫' }).click()
await p.waitForSelector('text=准——已收編入六部剪藏庫', { timeout: 8000 })
check('准 → toast', true)
await p.waitForTimeout(500)
check('准後批閱列消失(已成剪藏件)', await p.locator('button', { hasText: '准 · 收編入庫' }).count() === 0)
await p.goto(`${BASE}/m/archive`)
await p.waitForSelector('h2:has-text("拾遺歸檔")')
await p.waitForTimeout(400)
check('准後剪藏 7 篇', ((await p.locator('h2:has-text("拾遺歸檔")').locator('..').textContent()) ?? '').includes('7 篇'))
check('GhostLock 進了刑·稽核組', ((await p.locator('section', { hasText: '刑·稽核' }).textContent()) ?? '').includes('GhostLock'))

// ---- 5. 駁:確認框 → 回邸報列表 ----
await p.goto(`${BASE}/m/archive?tab=rss`)
await p.waitForSelector('text=GPT-Live')
await p.locator('a[href^="/archive/"]', { hasText: 'GPT-Live' }).click()
await p.waitForSelector('button:has-text("駁 · 撤下")')
await p.locator('button', { hasText: '駁 · 撤下' }).click()
await p.waitForSelector('text=確認執行')
check('駁出確認框(文案=駁下)', ((await p.locator('[role="dialog"]').textContent()) ?? '').includes('駁下'))
await p.locator('button', { hasText: '確認執行' }).click()
await p.waitForURL('**/m/archive?tab=rss')
await p.waitForTimeout(400)
check('駁後回邸報列表且剩 2 篇', ((await p.locator('h2:has-text("拾遺歸檔")').locator('..').textContent()) ?? '').includes('2 篇'))

// ---- 6. ⌘K:剪藏可搜、邸報流水不進面板 ----
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.keyboard.press('Control+k')
await p.waitForSelector('[aria-label="命令面板"]')
await p.keyboard.type('SQLite')
await p.waitForTimeout(250)
check('⌘K 搜到剪藏(SQLite WAL)', ((await p.locator('[aria-label="命令面板"] [data-sel]').textContent()) ?? '').includes('SQLite WAL'))
await p.keyboard.press('Escape')
await p.keyboard.press('Control+k')
await p.keyboard.type('記憶體短缺')
await p.waitForTimeout(250)
check('⌘K 搜不到邸報件(記憶體短缺)', await p.locator('[aria-label="命令面板"]').locator('text=沒有符合的結果').count() === 1)
await p.keyboard.press('Escape')

// ---- 7. 0.18 回歸:剪藏收藏+閱讀器+g r ----
await p.goto(`${BASE}/m/archive`)
await p.waitForSelector('input[placeholder^="貼上網址"]')
await p.locator('input[placeholder^="貼上網址"]').fill('家用 UPS 更換電池計畫與注意事項')
await p.locator('button', { hasText: '收藏' }).click()
await p.waitForSelector('text=已歸入 兵·行令', { timeout: 8000 })
check('回歸:收藏 → toast 已歸入', true)
await p.locator('a[href^="/archive/"]', { hasText: 'LXC 裡跑 Docker' }).click()
await p.waitForSelector('article h1')
check('回歸:剪藏閱讀器開起、無批閱列', await p.locator('button', { hasText: '准 · 收編入庫' }).count() === 0)
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.keyboard.press('g')
await p.keyboard.press('r')
await p.waitForURL('**/m/archive')
check('回歸:g r 跳拾遺', true)

// ---- 8. 手機 390:邸報視圖 ----
const ctxM = await browser.newContext({ viewport: { width: 390, height: 780 } })
const pm = await ctxM.newPage()
pm.on('pageerror', (e) => errors.push(String(e)))
await pm.goto(`${BASE}/m/archive?tab=rss`)
await pm.waitForSelector('h2:has-text("拾遺歸檔")')
check('手機:邸報列表渲染(分數可見)', await pm.locator('a[href^="/archive/"] span.text-amber').first().isVisible())
await pm.screenshot({ path: `${SHOT}/03-dibao-mobile.png` })

check('無 page error', errors.length === 0, errors.join(' | '))
await browser.close()

const fails = results.filter((r) => !r.ok).length
console.log(`\n${results.length - fails}/${results.length} PASS`)
process.exit(fails ? 1 : 0)
