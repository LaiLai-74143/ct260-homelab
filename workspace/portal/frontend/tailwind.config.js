/** @type {import('tailwindcss').Config} */
// tokens 依《入口大廳設計報告-3》§6:全站僅六色 + 語義三色,不得自行加色
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // 0.17.0 夜間模式:五個受 html.night 影響的 token 改走 CSS 變數
        // (RGB 三元組形式保住 bg-bg/95、border-amber/60 這類 alpha 修飾);
        // 實值(日/夜兩套)只在 index.css :root 與 html.night 維護
        bg: 'rgb(var(--bg-rgb) / <alpha-value>)',
        panel: 'rgb(var(--panel-rgb) / <alpha-value>)',
        line: 'rgb(var(--line-rgb) / <alpha-value>)',
        text: 'rgb(var(--text-rgb) / <alpha-value>)',
        amber: 'rgb(var(--amber-rgb) / <alpha-value>)',
        muted: '#8A94A3',
        ok: '#4CC38A',
        warn: '#D9A03F',
        crit: '#E5534B',
        unk: '#57606C',
      },
      fontFamily: {
        sans: ['"Noto Sans TC"', 'sans-serif'],
        serif: ['"Noto Serif TC"', 'serif'],
        // CJK 後備必須排在 monospace 前:JetBrains Mono 無中文字形,數字/IP 取 mono、中文取 Noto
        mono: ['"JetBrains Mono"', '"Noto Sans TC"', 'monospace'],
      },
      borderRadius: {
        card: '6px',
        btn: '3px',
      },
    },
  },
  plugins: [],
}
