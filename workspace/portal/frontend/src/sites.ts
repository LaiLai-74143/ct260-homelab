// 常用網站(待辦49 Homepage 退役前置,2026-07-08 使用者點名搬遷)
// SoT=原 Homepage bookmarks.yaml(ansible/backups/ct201/opt/homepage/config/bookmarks.yaml)
// 5 組 14 站,名稱/縮寫/分組沿用使用者原命名;新增站點直接改本檔。
export interface Site {
  name: string
  abbr: string
  href: string
}
export interface SiteGroup {
  label: string
  sites: Site[]
}

export const SITE_GROUPS: SiteGroup[] = [
  {
    label: 'AI',
    sites: [
      { name: 'ChatGPT', abbr: 'GPT', href: 'https://chatgpt.com/' },
      { name: 'Claude', abbr: 'CL', href: 'https://claude.ai/' },
      { name: 'DeepSeek', abbr: 'DS', href: 'https://chat.deepseek.com/' },
      { name: 'Google Gemini', abbr: 'GM', href: 'https://gemini.google.com/' },
      { name: 'Grok', abbr: 'GK', href: 'https://grok.com/' },
    ],
  },
  {
    label: 'Social',
    sites: [
      { name: 'Facebook', abbr: 'FB', href: 'https://www.facebook.com/' },
      { name: 'Messenger', abbr: 'MS', href: 'https://www.messenger.com/' },
      { name: 'Gmail', abbr: 'GL', href: 'https://mail.google.com/' },
      { name: '雲端硬碟', abbr: 'GD', href: 'https://drive.google.com/' },
    ],
  },
  {
    label: 'Video',
    sites: [
      { name: 'YouTube', abbr: 'YT', href: 'https://www.youtube.com/' },
      { name: 'BiliBili', abbr: 'BB', href: 'https://www.bilibili.com/' },
    ],
  },
  {
    label: 'Private Tracker',
    sites: [
      { name: 'M-Team', abbr: 'MT', href: 'https://kp.m-team.cc/' },
      { name: 'U2分享園', abbr: 'U2', href: 'https://u2.dmhy.org/' },
    ],
  },
  {
    label: 'Network',
    sites: [
      { name: 'Tailscale', abbr: 'TS', href: 'https://login.tailscale.com/admin/machines' },
    ],
  },
]
