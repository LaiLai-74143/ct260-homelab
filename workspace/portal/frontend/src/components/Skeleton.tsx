/** 首屏骨架(絲滑包 D2):首載入佔位,取代空白/假數據首繪;
    形狀近似實頁即可,不追像素;reduced-motion 退化為靜態灰塊(index.css)。 */

export function SkeletonBlock({ className }: { className?: string }) {
  return <div className={`skeleton ${className ?? ''}`} aria-hidden="true" />
}

function SkeletonCard() {
  return (
    <div className="rounded-card border border-line bg-panel p-[13px] md:px-[18px] md:py-4">
      <SkeletonBlock className="mb-3 h-4 w-1/2" />
      <SkeletonBlock className="mb-2 h-7 w-16" />
      <SkeletonBlock className="h-3 w-3/4" />
    </div>
  )
}

function SkeletonRow() {
  return (
    <div className="mb-2.5 flex items-start gap-3 rounded-card border border-line bg-panel px-4 py-3.5">
      <SkeletonBlock className="mt-1.5 h-2 w-2 rounded-full" />
      <div className="min-w-0 flex-1">
        <SkeletonBlock className="mb-2 h-4 w-1/3" />
        <SkeletonBlock className="h-3 w-2/3" />
      </div>
    </div>
  )
}

/** 模塊頁通用首屏骨架:banner(選配)+卡片牆(tiles)+全寬列(rows) */
export default function PageSkeleton({ tiles = 0, rows = 0, banner = false }: {
  tiles?: number
  rows?: number
  banner?: boolean
}) {
  return (
    <div aria-hidden="true">
      {banner && <SkeletonBlock className="mb-[22px] h-[52px] w-full rounded-card" />}
      {tiles > 0 && (
        <div className="mb-3.5 grid grid-cols-2 gap-2.5 md:gap-3.5 xl:grid-cols-3">
          {Array.from({ length: tiles }, (_, i) => <SkeletonCard key={i} />)}
        </div>
      )}
      {Array.from({ length: rows }, (_, i) => <SkeletonRow key={i} />)}
    </div>
  )
}
