// The service worker. Everything else in this story exists to get a push to this file.
//
// This is the piece that runs when the app is closed and the phone is locked, so it
// is the only place that can turn a push into something visible on a lock screen.
// The caching half is Serwist's default; the push half below is the story.

import { defaultCache } from '@serwist/next/worker';
import { Serwist, type PrecacheEntry, type SerwistGlobalConfig } from 'serwist';

declare global {
  interface WorkerGlobalScope extends SerwistGlobalConfig {
    __SW_MANIFEST: (PrecacheEntry | string)[] | undefined;
  }
}

// A module-scoped shadow of the global `self`, which the DOM lib types as a Window.
declare const self: ServiceWorkerGlobalScope;

const serwist = new Serwist({
  precacheEntries: self.__SW_MANIFEST,
  // Claim immediately so a freshly installed worker handles the very next push
  // rather than waiting for every tab to close — on a phone that could be days.
  skipWaiting: true,
  clientsClaim: true,
  navigationPreload: true,
  runtimeCaching: defaultCache,
});

serwist.addEventListeners();

interface PushPayload {
  title?: unknown;
  body?: unknown;
}

/**
 * Turns a push into a visible notification, always.
 *
 * The subscription is made with `userVisibleOnly`, which is a promise to show
 * something for every push received. A push that shows nothing is a broken
 * promise the browser may answer by dropping the subscription — and that would
 * look exactly like the delivery failure this story exists to detect. So a
 * malformed payload still shows a notification, saying so in the body.
 */
async function showPush(data: PushMessageData | null): Promise<void> {
  let title = 'todoapp';
  let body = 'A push arrived, but its payload could not be read as JSON.';

  try {
    const payload = data?.json() as PushPayload | null;
    if (typeof payload?.title === 'string' && payload.title) title = payload.title;
    if (typeof payload?.body === 'string' && payload.body) body = payload.body;
  } catch {
    // Deliberately swallowed. The fallback text above is the finding: the push
    // arrived — which is the question this story asks — and the payload is the
    // separate, lesser problem.
  }

  await self.registration.showNotification(title, {
    body,
    // No `tag`: a tag makes each notification replace the last, which would make
    // a second send indistinguishable from a first that never cleared.
    icon: '/icons/icon-192.png',
    badge: '/icons/icon-192.png',
  });
}

self.addEventListener('push', (event) => {
  event.waitUntil(showPush(event.data));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(openApp());
});

/**
 * Focuses the app if it is already open, otherwise opens it. Without this a tap
 * on the notification dismisses it and does nothing, which reads as a dead push.
 */
async function openApp(): Promise<void> {
  const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const existing = windows[0];
  if (existing) {
    await existing.focus();
    return;
  }
  await self.clients.openWindow('/');
}
