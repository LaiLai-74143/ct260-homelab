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
]

// 手機底部 tab:大廳/設備/告警/更多(報告 §3)
export const TABBAR = [
  MODULES[0],
  MODULES[1],
  MODULES[2],
  { key: 'more', route: '/more', label: '更多', shortLabel: '更多', icon: '⋯' },
]
