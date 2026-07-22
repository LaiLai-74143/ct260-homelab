import PageHead from '../components/PageHead'

/** 檔案站(0.19.4):與電力/遊戲/生活同級的獨立頁,iframe 內嵌完整網頁檔案站。
 *  後端=CT260:8790(與 LaiBoard 鍵盤同一個 rime-cloud-dict server),portal 不代理——
 *  portal.hl 是 https,嵌 LAN http 會踩混合內容,一律走公網 https(CF Tunnel),LAN 亦可達。
 *  通行碼存 iframe 同源(storage.lailai74143.com)localStorage,首次使用輸一次即記住。 */
const STORAGE_URL = 'https://storage.lailai74143.com/'

export default function Storage() {
  return (
    <>
      <PageHead
        title="檔案站"
        right={
          <a href={STORAGE_URL} target="_blank" rel="noreferrer" className="hover:text-amber">
            新分頁開啟 ↗
          </a>
        }
      />
      <iframe
        src={STORAGE_URL}
        title="檔案站"
        className="h-[calc(100dvh-200px)] min-h-[420px] w-full rounded-card border border-line bg-panel md:h-[calc(100dvh-160px)]"
      />
    </>
  )
}
