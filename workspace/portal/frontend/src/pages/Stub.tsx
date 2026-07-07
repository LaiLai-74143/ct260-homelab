import PageHead from '../components/PageHead'

export default function Stub({ title, api }: { title: string; api: string }) {
  return (
    <>
      <PageHead title={title} />
      <div className="rounded-card border border-dashed border-line px-5 py-10 text-center text-[13.5px] text-muted">
        此模塊屬 M2 實作範圍——目前僅示意導航與骨架
        <span className="mt-1.5 block font-mono text-[11px]">{api}</span>
      </div>
    </>
  )
}
