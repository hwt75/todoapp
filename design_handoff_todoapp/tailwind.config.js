// tailwind.config.js — todoapp
// Dark mode is a DECLARED palette. Use class strategy and swap the CSS variables
// (tokens.css) rather than duplicating every colour here.
module.exports = {
  darkMode: ['class', '[data-theme="dark"]'],
  theme: {
    extend: {
      colors: {
        page: 'var(--pg)',
        card: 'var(--cd)',
        sunken: 'var(--sk)',
        hairline: 'var(--hl)',
        strong: 'var(--st)',
        ink: { DEFAULT: 'var(--ink)', 2: 'var(--ink2)', 3: 'var(--ink3)' },
        held: { tint: 'var(--held-tint)', ink: 'var(--held-ink)' },
        urgent: { tint: 'var(--urg-tint)', ink: 'var(--urg-ink)' },
        failed: { tint: 'var(--fail-tint)', ink: 'var(--fail-ink)' },
        neutralState: { tint: 'var(--neu-tint)', ink: 'var(--neu-ink)' },
        action: { fill: 'var(--act-fill)', ink: 'var(--act-ink)' },
        lock: 'var(--lock)',
      },
      fontFamily: {
        display: ['Caprasimo', 'serif'],
        sans: ['Figtree', 'system-ui', 'sans-serif'],
        quote: ['Lora', 'Georgia', 'serif'],
      },
      fontSize: {
        caption: ['11px', '1.45'],
        label: ['13px', '1.4'],
        body: ['16px', '1.55'],
        title: ['21px', '1.2'],
        figure: ['44px', '1.05'],
      },
      borderRadius: {
        control: '16px', card: '16px', frame: '28px', urgent: '6px',
      },
      boxShadow: { layer: '0 3px 10px rgba(46,43,37,0.10)' },
      maxWidth: { column: '544px' },
      spacing: { row: '11px', card: '18px' },
    },
  },
};
