// 模塊註冊表:導航(側欄/tabbar/更多頁)與 L0 卡片共用
export interface ModuleDef {
  key: string
  route: string
  label: string
  shortLabel: string
  icon: string
}

export const MODULES: ModuleDef[] = [
  { key: 'home', route: '/', label: '大廳', shortLabel: '大廳', icon: '◈' },
  { key: 'devices', route: '/m/devices', label: '設備總覽', shortLabel: '設備', icon: '▣' },
  { key: 'alerts', route: '/m/alerts', label: '告警中心', shortLabel: '告警', icon: '▲' },
  { key: 'services', route: '/m/services', label: '服務目錄', shortLabel: '服務', icon: '≡' },
  { key: 'security', route: '/m/security', label: '安全面板', shortLabel: '安全', icon: '◉' },
  { key: 'power', route: '/m/power', label: '電力', shortLabel: '電力', icon: '⚡' },
  { key: 'game', route: '/m/game', label: '遊戲', shortLabel: '遊戲', icon: '▶' },
  { key: 'life', route: '/m/life', label: '生活', shortLabel: '生活', icon: '✦' },
  { key: 'storage', route: '/m/storage', label: '檔案站', shortLabel: '檔案站', icon: '▦' },
  { key: 'archive', route: '/m/archive', label: '拾遺歸檔', shortLabel: '拾遺', icon: '▤' },
]

const byKey = (k: string) => MODULES.find((m) => m.key === k)!

// 手機底部 tab:大廳/設備/檔案站/更多(0.19.4 告警讓位檔案站,告警入口移「更多」)
export const TABBAR = [
  byKey('home'),
  byKey('devices'),
  byKey('storage'),
  { key: 'more', route: '/more', label: '更多', shortLabel: '更多', icon: '⋯' },
]
