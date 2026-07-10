/** 主機卡三迷你條(cpu/mem/disk);≥80% 轉 warn 色 */
export default function Bar({ k, v }: { k: string; v: number | null }) {
  if (v == null) return null
  return (
    <div className="mb-[5px] flex items-center gap-2">
      <span className="w-7 font-mono text-[10px] text-muted">{k}</span>
      <span className="h-1 flex-1 overflow-hidden rounded-[2px] bg-line">
        <span
          className={`block h-full rounded-[2px] transition-[width] duration-500 ease-out ${v >= 80 ? 'bg-warn' : 'bg-muted'}`}
          style={{ width: `${Math.min(100, Math.max(0, v))}%` }}
        />
      </span>
      <span className="w-8 text-right font-mono text-[10px] text-muted">{v}%</span>
    </div>
  )
}
