// 0.18.0 mock 走查:拾遺歸檔板塊(L0 卡/列表/收藏/閱讀器/改歸/刪除/⌘K/g r/三斷點)+回歸
// 用法:node e2e-0180-mock.mjs(需 mock BFF 於 :8188,PORTAL_STATIC=dist)
import { chromium } from 'playwright'
import { mkdirSync } from 'fs'

const BASE = 'http://127.0.0.1:8188'
const SHOT = '/tmp/portal-0180-shots'
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

// ---- 1. 大廳:拾遺 L0 卡(fixture 真值)+ 側欄入口 ----
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.waitForTimeout(600)
const archCard = p.locator('a[href="/m/archive"].card-hover')
check('大廳有拾遺卡', await archCard.count() === 1)
check('拾遺卡顯 fixture 真值(6 篇)', ((await archCard.textContent()) ?? '').includes('6'), (await archCard.textContent()) ?? '')
check('側欄有拾遺歸檔', await p.locator('nav a[href="/m/archive"]').count() >= 1)
await p.screenshot({ path: `${SHOT}/01-home.png` })

// ---- 2. 列表頁:六部分組 + 搜尋 ----
await p.goto(`${BASE}/m/archive`)
await p.waitForSelector('h2:has-text("拾遺歸檔")')
await p.waitForSelector('text=吏·名籍')
const groupsN = await p.locator('section:has(a[href^="/archive/"])').count()
check('六部分組渲染(mock 6 部各 1 篇)', groupsN === 6, `實際 ${groupsN}`)
check('總數 6 篇', ((await p.locator('h2:has-text("拾遺歸檔")').locator('..').textContent()) ?? '').includes('6 篇'))
await p.screenshot({ path: `${SHOT}/02-archive-desktop.png` })
await p.locator('input[placeholder="搜尋標題/摘要…"]').fill('Docker')
await p.waitForTimeout(200)
const afterFilter = await p.locator('a[href^="/archive/"]').count()
check('搜尋「Docker」過濾到 1 篇', afterFilter === 1, `實際 ${afterFilter}`)
await p.locator('input[placeholder="搜尋標題/摘要…"]').fill('')

// ---- 3. 收藏(mock 假分類:含「計畫」→ 兵·行令)----
await p.locator('input[placeholder^="貼上網址"]').fill('家用 UPS 更換電池計畫與注意事項')
await p.locator('button', { hasText: '收藏' }).click()
await p.waitForSelector('text=已歸入 兵·行令', { timeout: 8000 })
check('收藏 → toast 已歸入 兵·行令', true)
await p.waitForTimeout(400)
check('列表刷新後 7 篇', ((await p.locator('h2:has-text("拾遺歸檔")').locator('..').textContent()) ?? '').includes('7 篇'))

// ---- 4. 閱讀器:標題/批註摘要/正文/來源 ----
await p.locator('a[href^="/archive/"]', { hasText: 'LXC 裡跑 Docker' }).click()
await p.waitForSelector('h1:has-text("LXC 裡跑 Docker 的 keyctl 坑")')
check('閱讀器開起(Serif 大題)', true)
check('六部籤(工·營造)', await p.locator('article span', { hasText: '工·營造' }).count() === 1)
check('批註摘要在(border-amber)', await p.locator('article div.border-l-2').count() === 1)
check('原文 ↗ 外鏈在', await p.locator('article a', { hasText: '原文' }).count() === 1)
check('正文渲染', ((await p.locator('article').textContent()) ?? '').includes('mock 正文'))
await p.screenshot({ path: `${SHOT}/03-reader.png` })

// ---- 5. 改歸六部:點「禮·典章」→ toast + 籤更新 ----
await p.locator('section button', { hasText: '禮·典章' }).click()
await p.waitForSelector('text=已改歸 禮·典章', { timeout: 8000 })
check('改歸 → toast', true)
await p.waitForTimeout(500)
check('條目籤已變 禮·典章', await p.locator('article span', { hasText: '禮·典章' }).count() === 1)

// ---- 6. 刪除:確認框 → 回列表 → 6 篇 ----
await p.locator('button', { hasText: '刪除' }).first().click()
await p.waitForSelector('text=確認執行')
check('刪除先出確認框(danger 行)', await p.locator('text=刪除後不可復原').count() === 1)
await p.locator('button', { hasText: '確認執行' }).click()
await p.waitForURL('**/m/archive')
await p.waitForTimeout(400)
check('刪除後回列表且剩 6 篇', ((await p.locator('h2:has-text("拾遺歸檔")').locator('..').textContent()) ?? '').includes('6 篇'))

// ---- 7. ⌘K:搜收藏標題 → 拾遺分組 → Enter 開閱讀器;g r 跳列表 ----
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.keyboard.press('Control+k')
await p.waitForSelector('[aria-label="命令面板"]')
await p.keyboard.type('SQLite WAL')
await p.waitForTimeout(200)
const cmdkItem = await p.locator('[aria-label="命令面板"] [data-sel]').textContent()
check('⌘K 搜到拾遺收藏', (cmdkItem ?? '').includes('SQLite WAL'), cmdkItem ?? '')
await p.keyboard.press('Enter')
await p.waitForURL('**/archive/**')
check('Enter 直開閱讀器', true)
await p.goto(`${BASE}/`)
await p.waitForSelector('text=MODULES')
await p.keyboard.press('g')
await p.keyboard.press('r')
await p.waitForURL('**/m/archive')
check('g r 跳拾遺列表', true)

// ---- 8. 回歸:⌘K 模糊搜尋模塊仍中、服務頁正常 ----
await p.keyboard.press('Control+k')
await p.waitForSelector('[aria-label="命令面板"]')
await p.keyboard.type('設備')
await p.waitForTimeout(150)
check('回歸:⌘K 搜「設備」仍中', ((await p.locator('[aria-label="命令面板"] [data-sel]').textContent()) ?? '').includes('設備總覽'))
await p.keyboard.press('Escape')
await p.goto(`${BASE}/m/services`)
await p.waitForSelector('h2:has-text("服務目錄")')
check('回歸:服務頁開得起來', await p.locator('a', { hasText: '開啟' }).count() > 0)

// ---- 9. 平板 820:列表頁 ----
const ctxT = await browser.newContext({ viewport: { width: 820, height: 1180 } })
const pt = await ctxT.newPage()
pt.on('pageerror', (e) => errors.push(String(e)))
await pt.goto(`${BASE}/m/archive`)
await pt.waitForSelector('h2:has-text("拾遺歸檔")')
await pt.waitForTimeout(500)
check('平板 820:列表可見', await pt.locator('a[href^="/archive/"]').first().isVisible())
await pt.screenshot({ path: `${SHOT}/04-archive-tablet.png` })

// ---- 10. 手機 390:更多頁入口 + 列表 + 閱讀器 ----
const ctxM = await browser.newContext({ viewport: { width: 390, height: 780 } })
const pm = await ctxM.newPage()
pm.on('pageerror', (e) => errors.push(String(e)))
await pm.goto(`${BASE}/more`)
await pm.waitForSelector('text=更多')
check('手機:更多頁有拾遺入口', await pm.locator('a[href="/m/archive"]:visible').count() >= 1)
await pm.locator('a[href="/m/archive"]:visible').first().click()
await pm.waitForSelector('h2:has-text("拾遺歸檔")')
check('手機:列表渲染', await pm.locator('a[href^="/archive/"]').first().isVisible())
await pm.screenshot({ path: `${SHOT}/05-archive-mobile.png` })
await pm.locator('a[href^="/archive/"]').first().click()
await pm.waitForSelector('article h1')
check('手機:閱讀器渲染', true)
await pm.screenshot({ path: `${SHOT}/06-reader-mobile.png` })

check('無 page error', errors.length === 0, errors.join(' | '))
await browser.close()

const fails = results.filter((r) => !r.ok).length
console.log(`\n${results.length - fails}/${results.length} PASS`)
process.exit(fails ? 1 : 0)
