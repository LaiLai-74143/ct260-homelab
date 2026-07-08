// 常用網站板塊走查(0.5.1):大廳 SITES 段 5 組 14 站、target=_blank、手機斷點換行
import { chromium } from 'playwright'
const BASE = 'http://localhost:18099'
const results = []
function check(name, ok, extra = '') { results.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? ` — ${extra}` : ''}`) }
const browser = await chromium.launch()

// 桌面 1280
const p = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage()
await p.goto(`${BASE}/`)
await p.waitForSelector('text=SITES · 常用網站')
const card = p.locator('div:below(:text("SITES · 常用網站"))').first()
const links = p.locator('a[target="_blank"][href^="https://"]')
const n = await links.count()
check('外連站點 14 顆', n === 14, `count=${n}`)
const hrefs = await links.evaluateAll(els => els.map(e => e.href))
check('含 ChatGPT/Tailscale/U2', ['https://chatgpt.com/', 'https://login.tailscale.com/admin/machines', 'https://u2.dmhy.org/'].every(h => hrefs.includes(h)))
check('rel=noreferrer 全數', await links.evaluateAll(els => els.every(e => e.rel.includes('noreferrer'))))
const groups = await p.locator('span.font-mono.text-\\[10px\\].tracking-wide').allTextContents()
check('5 組標籤', JSON.stringify(groups) === JSON.stringify(['AI','Social','Video','Private Tracker','Network']), groups.join(','))
check('模塊卡仍在(回歸)', await p.locator('text=MODULES').count() === 1)
await p.screenshot({ path: '/tmp/sites-desktop.png', fullPage: true })

// 手機 390
const m = await (await browser.newContext({ viewport: { width: 390, height: 844 } })).newPage()
await m.goto(`${BASE}/`)
await m.waitForSelector('text=SITES · 常用網站')
check('手機斷點 14 顆', await m.locator('a[target="_blank"][href^="https://"]').count() === 14)
await m.screenshot({ path: '/tmp/sites-mobile.png', fullPage: true })

await browser.close()
console.log(results.every(Boolean) ? `ALL PASS ${results.length}/${results.length}` : 'HAS FAIL')
process.exit(results.every(Boolean) ? 0 : 1)
