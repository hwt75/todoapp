import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import { METADATA_COLORS } from '@/lib/design-tokens';
import './globals.css';

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
    <html lang="en">
      <head>
        <style>{INSTALL_HINT_VISIBILITY}</style>
      </head>
      <body>{children}</body>
    </html>
  );
}
