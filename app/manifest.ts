import type { MetadataRoute } from 'next';

export default function manifest(): MetadataRoute.Manifest {
  return {
    // `id` pins app identity independently of `start_url`. Without it, changing
    // start_url later registers as a different app: the existing home-screen
    // install is orphaned and its notification subscription goes with it.
    id: '/',
    name: 'todoapp',
    short_name: 'todoapp',
    description: 'Commitments with real stakes and a real person holding you to them.',
    start_url: '/',
    scope: '/',
    display: 'standalone',
    background_color: '#F1EFE8',
    theme_color: '#F1EFE8',
    icons: [
      { src: '/icons/icon-180.png', sizes: '180x180', type: 'image/png' },
      { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png' },
      { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png' },
    ],
  };
}
