/**
 * 近 24h 告警時間軸:48 根半小時柱,高度∝firing 數;
 * 0=線色細柱(平安),>0 warn 色——只用語義色,不加新色(§6)。
 */
export default function Timeline({ data }: { data: [number, number][] }) {
  if (data.length === 0) {
    return <div className="py-4 text-center font-mono text-[11px] text-muted">時間軸無數據</div>
  }
  const max = Math.max(1, ...data.map((d) => d[1]))
  const fmt = (ts: number) =>
    new Date(ts * 1000).toLocaleTimeString('zh-TW', { hour12: false, hour: '2-digit', minute: '2-digit' })
  return (
    <div>
      <div className="flex h-[56px] items-end gap-[2px]" role="img"
           aria-label={`近 24 小時告警數,最大 ${max}`}>
        {data.map(([ts, n]) => (
          <span
            key={ts}
            title={`${fmt(ts)} · firing ${n}`}
            className={`flex-1 rounded-[1px] ${n > 0 ? 'bg-warn/70' : 'bg-line'}`}
            style={{ height: n > 0 ? `${Math.max(12, (n / max) * 100)}%` : '4px' }}
          />
        ))}
      </div>
      <div className="mt-1 flex justify-between font-mono text-[10px] text-muted">
        <span>-24h</span><span>-12h</span><span>現在</span>
      </div>
    </div>
  )
}
