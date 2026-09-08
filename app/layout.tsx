import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import { Caprasimo, Figtree, Lora } from 'next/font/google';
import { METADATA_COLORS } from '@/lib/design-tokens';
import './globals.css';

/**
 * The three faces, self-hosted at build time by `next/font` rather than fetched from
 * Google at runtime. Two reasons, and neither is preference: a font that arrives late
 * reflows a screen the user is already reluctant to open, and this is a PWA whose whole
 * point is working on a phone that may have no connection at the moment it is opened.
 *
 * Each declares the CSS variable `app/tokens.css` names, so the stylesheet keeps owning
 * which face does which job and this file only supplies them.
 *
 * `display: 'swap'` with a real fallback stack in the token: the fallback renders
 * immediately and the web font replaces it, which is the trade this product wants — a
 * screen that is readable at once beats a screen that is correct a moment later.
 */
const figtree = Figtree({
  subsets: ['latin', 'latin-ext'],
  weight: ['400', '500', '600'],
  display: 'swap',
  variable: '--font-figtree',
});

/** The display voice. Rationed to the debt total and the running focus timer. */
const caprasimo = Caprasimo({
  subsets: ['latin'],
  weight: '400',
  display: 'swap',
  variable: '--font-caprasimo',
});

/** Italic only, and reserved to one string: the referee's collection message. */
const lora = Lora({
  subsets: ['latin', 'latin-ext'],
  weight: '400',
  style: 'italic',
  display: 'swap',
  variable: '--font-lora',
});

export const metadata: Metadata = {
  title: 'todoapp',
  description: 'Commitments with real stakes and a real person holding you to them.',
  appleWebApp: {
    capable: true,
    title: 'todoapp',
    statusBarStyle: 'default',
  },
  // Manifest icons are honoured only by newer iOS. The apple-prefixed link is the
  // fallback that decides whether the home-screen icon is the real icon or a
  // screenshot of the page — which would read as a broken install.
  icons: {
    apple: [{ url: '/icons/icon-180.png', sizes: '180x180', type: 'image/png' }],
  },
};

export const viewport: Viewport = {
  // Two entries, not one. A single light theme-colour leaves the iOS status bar a bright
  // band above a dark app — the dark-mode gap recorded in deferred-work.md, which was
  // assigned to this token layer rather than hand-patched onto the shell.
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: METADATA_COLORS.surfaceBase },
    { media: '(prefers-color-scheme: dark)', color: METADATA_COLORS.surfaceBaseDark },
  ],
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
};

/**
 * Not styling — mechanism. The install hint is server-rendered so it survives a
 * JavaScript failure, and this hides it on an installed launch before hydration,
 * so an installed user never sees it flash. The design token layer is a later story.
 */
const INSTALL_HINT_VISIBILITY = `
@media (display-mode: standalone), (display-mode: fullscreen), (display-mode: minimal-ui) {
  [data-install-hint] { display: none; }
}
`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${figtree.variable} ${caprasimo.variable} ${lora.variable}`}>
      <head>
        <style>{INSTALL_HINT_VISIBILITY}</style>
      </head>
      <body>{children}</body>
    </html>
  );
}
