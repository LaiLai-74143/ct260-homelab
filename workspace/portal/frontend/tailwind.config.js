/** @type {import('tailwindcss').Config} */
// tokens 依《入口大廳設計報告-3》§6:全站僅六色 + 語義三色,不得自行加色
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        bg: '#0E1116',
        panel: '#161C24',
        line: '#232B36',
        text: '#DDE3EA',
        muted: '#8A94A3',
        amber: '#E8A33D',
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
