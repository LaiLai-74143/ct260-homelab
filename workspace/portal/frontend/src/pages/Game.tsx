import { useGame } from '../api'
import Bar from '../components/Bar'
import Dot from '../components/Dot'
import PageHead from '../components/PageHead'

export default function Game() {
  const gm = useGame()
  const d = gm.data

  return (
    <>
      <PageHead title="遊戲" right="mc.lailai74143.com" />
      {gm.isError && !d && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到遊戲數據——檢查 BFF /api/game。
        </div>
      )}
      {d && (
        <>
          <div className="mb-3.5 grid grid-cols-2 gap-2.5">
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 flex items-center gap-2 text-[12px] text-muted">
                <Dot state={d.server_up ? 'ok' : d.instance_state === 'stopped' ? 'unk' : 'crit'} />
                Minecraft 伺服器
              </div>
              <div className="font-mono text-2xl font-semibold">
                {d.server_up ? '運行中' : d.instance_state === 'stopped' ? '已停機' : '異常'}
              </div>
              <div className="mt-1 font-mono text-[11px] text-muted">CT100 {d.instance_state}</div>
            </div>
            <div className="rounded-card border border-line bg-panel px-4 py-3.5">
              <div className="mb-1 text-[12px] text-muted">在線玩家</div>
              <div className="font-mono text-2xl font-semibold">
                {d.players_online ?? '—'}
              </div>
              {d.players_online === null && (
                <div className="mt-1 text-[11.5px] text-muted">{d.note}</div>
              )}
              {(d.player_names ?? []).length > 0 && (
                <div className="mt-1 font-mono text-[11.5px] text-muted">{d.player_names!.join(' · ')}</div>
              )}
            </div>
          </div>

          <div className="grid grid-cols-1 gap-2.5 md:grid-cols-2">
            {d.hosts.map((h) => (
              <div key={h.name} className={`rounded-card border border-line bg-panel px-3.5 py-[13px] ${h.up ? '' : 'opacity-55'}`}>
                <div className="mb-2 flex items-center gap-2">
                  <Dot state={h.up ? 'ok' : 'unk'} />
                  <span className="font-mono text-[13.5px] font-semibold">{h.name}</span>
                </div>
                <Bar k="cpu" v={h.cpu} />
                <Bar k="mem" v={h.mem} />
              </div>
            ))}
          </div>
        </>
      )}
    </>
  )
}
