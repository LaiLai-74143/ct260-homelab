import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useArchiveDeleteMutation, useArchiveItem, useArchiveUpdateMutation } from '../api'
import ConfirmDialog from '../components/ConfirmDialog'
import PageHead from '../components/PageHead'
import Reveal from '../components/Reveal'
import PageSkeleton from '../components/Skeleton'
import { useToast } from '../components/Toast'
import { ARCHIVE_TOPICS, topicLabel } from './Archive'

/** 拾遺閱讀器(L2):Serif 大題+琥珀批註摘要+正文;改歸六部/刪除在文末 */
export default function ArchiveDoc() {
  const { id } = useParams()
  const nav = useNavigate()
  const it = useArchiveItem(id)
  const upd = useArchiveUpdateMutation()
  const del = useArchiveDeleteMutation()
  const toast = useToast()
  const [confirmDel, setConfirmDel] = useState(false)
  const d = it.data?.item

  return (
    <>
      <PageHead
        title="拾遺歸檔"
        right={
          <Link to={d?.origin === 'rss' ? '/m/archive?tab=rss' : '/m/archive'} viewTransition className="hover:text-amber">
            {d?.origin === 'rss' ? '← 回邸報' : '← 回六部'}
          </Link>
        }
      />

      {it.isError && !d && (
        <div className="rounded-card border border-dashed border-line p-6 text-center text-[13.5px] text-muted">
          讀不到這篇收藏——可能已被刪除。<Link to="/m/archive" viewTransition className="text-amber">回列表</Link>。
        </div>
      )}
      {!d && !it.isError && <PageSkeleton rows={3} />}

      {d && (
        <>
          <Reveal>
            <article className="rounded-card border border-line bg-panel px-5 py-5 md:px-7 md:py-6">
              <h1 className="font-serif text-[22px] font-black leading-snug">{d.title}</h1>
              <div className="mt-2.5 flex flex-wrap items-center gap-x-3 gap-y-1.5 font-mono text-[11px] text-muted">
                <span className="rounded-btn border border-amber/60 px-2 py-0.5 text-amber">{topicLabel(d.topic_id)}</span>
                {d.origin === 'rss' && (
                  <span className="rounded-btn border border-line px-2 py-0.5">邸報 · {d.feed ?? '?'} · {d.score ?? '—'} 分</span>
                )}
                <span>{d.created_at.slice(0, 10)}</span>
                <span>{d.origin === 'rss' ? '自動呈報' : d.content_type === 'web' ? '網頁剪藏' : '純文字'}</span>
                {d.model && d.model !== 'mock' && <span>{d.model}</span>}
                {d.source_url && (
                  <a href={d.source_url} target="_blank" rel="noreferrer" className="hover:text-amber">原文 ↗</a>
                )}
              </div>
              {/* 批註式摘要(AI 歸納;Serif 呼應奏折硃批,色走既有 amber token) */}
              <div className="mt-4 border-l-2 border-amber/70 pl-3.5 font-serif text-[14.5px] leading-relaxed">
                {d.summary}
              </div>
              {d.truncated && (
                <div className="mt-2 text-[11.5px] text-muted">(原文過長,抓取時已截斷至 12000 字)</div>
              )}
              <div className="mt-5 whitespace-pre-wrap break-words text-[14px] leading-[1.9]">
                {d.full_text}
              </div>
            </article>
          </Reveal>

          {/* 邸報批閱:准=收編入剪藏庫(origin→manual);駁=刪除(共用下方確認框) */}
          {d.origin === 'rss' && (
            <section className="mt-3.5 flex flex-wrap items-center gap-2 rounded-card border border-amber/40 bg-panel px-4 py-3">
              <span className="font-serif text-[13px] font-bold text-amber">批閱:</span>
              <button
                disabled={upd.isPending}
                onClick={() => upd.mutate({ id: d.id, origin: 'manual' }, {
                  onSuccess: () => { toast('ok', '准——已收編入六部剪藏庫') },
                  onError: (e) => { toast('err', `收編失敗:${e.error}${e.hint ? ` — ${e.hint}` : ''}`) },
                })}
                className="btn-press rounded-btn border border-amber px-3 py-1 text-[12.5px] text-amber transition-colors duration-150 hover:bg-amber/10 disabled:opacity-45"
              >
                准 · 收編入庫
              </button>
              <button
                onClick={() => setConfirmDel(true)}
                disabled={del.isPending}
                className="btn-press rounded-btn border border-line px-3 py-1 text-[12.5px] text-muted transition-colors duration-150 hover:border-crit hover:text-crit disabled:opacity-45"
              >
                駁 · 撤下
              </button>
              <span className="ml-auto font-mono text-[10.5px] text-muted">不批也行:14 天後自動清</span>
            </section>
          )}

          {/* 改歸六部+刪除:非破壞性動作即點即改;刪除走既有確認框 */}
          <section className="mt-3.5 flex flex-wrap items-center gap-2 rounded-card border border-line bg-panel px-4 py-3">
            <span className="font-mono text-[11px] text-muted">改歸:</span>
            {ARCHIVE_TOPICS.map((t) => (
              <button
                key={t.id}
                disabled={upd.isPending || t.id === d.topic_id}
                onClick={() => upd.mutate({ id: d.id, topic_id: t.id }, {
                  onSuccess: () => { toast('ok', `已改歸 ${t.label}`) },
                  onError: (e) => { toast('err', `改歸失敗:${e.error}${e.hint ? ` — ${e.hint}` : ''}`) },
                })}
                className={`btn-press rounded-btn border px-2.5 py-1 text-[12px] transition-colors duration-150 ${
                  t.id === d.topic_id
                    ? 'border-amber text-amber'
                    : 'border-line text-muted hover:border-amber hover:text-amber'
                } disabled:cursor-default`}
              >
                {t.label}
              </button>
            ))}
            <button
              onClick={() => setConfirmDel(true)}
              disabled={del.isPending}
              className="btn-press ml-auto rounded-btn border border-line px-2.5 py-1 text-[12px] text-muted transition-colors duration-150 hover:border-crit hover:text-crit disabled:opacity-45"
            >
              {del.isPending ? '刪除中…' : '刪除'}
            </button>
          </section>

          <ConfirmDialog
            open={confirmDel}
            text={d.origin === 'rss' ? `駁下「${d.title}」` : `刪除「${d.title}」`}
            danger="刪除後不可復原(SQLite 內這筆直接消失)"
            onConfirm={() => {
              setConfirmDel(false)
              const backTo = d.origin === 'rss' ? '/m/archive?tab=rss' : '/m/archive'
              del.mutate({ id: d.id }, {
                onSuccess: () => { toast('ok', d.origin === 'rss' ? '已駁下' : '已刪除'); nav(backTo, { viewTransition: true }) },
                onError: (e) => { toast('err', `刪除失敗:${e.error}${e.hint ? ` — ${e.hint}` : ''}`) },
              })
            }}
            onCancel={() => setConfirmDel(false)}
          />
        </>
      )}
    </>
  )
}
