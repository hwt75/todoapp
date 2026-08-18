// The service worker. Everything else in this story exists to get a push to this file.
//
// This is the piece that runs when the app is closed and the phone is locked, so it
// is the only place that can turn a push into something visible on a lock screen.
// The caching half is Serwist's default; the push half below is the story.

import { defaultCache } from '@serwist/next/worker';
import { Serwist, type PrecacheEntry, type SerwistGlobalConfig } from 'serwist';
import { resolvePushContent } from '@/lib/push-payload';

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

/**
 * Turns a push into a visible notification, always.
 *
 * What to show is decided by `resolvePushContent`, which is a pure function so
 * it can be tested without a device — see `lib/push-payload.ts`. This function
 * is only the plumbing around it, and that split is deliberate: a rule that can
 * only be checked by rebooting a phone is a rule nobody checks.
 */
async function showPush(data: PushMessageData | null): Promise<void> {
  const { title, body } = resolvePushContent(data?.text());

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
