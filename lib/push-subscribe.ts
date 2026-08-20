/**
 * Getting a push subscription, and refusing before the prompt is spent.
 *
 * Extracted from `components/push-probe.tsx` when Settings became the second place that asks for
 * notification permission (spec 3.0, D3). Two callers and one copy: the probe is Story 1.2's
 * diagnostic and Settings is the product's way in, and they must not drift about *when* it is safe
 * to prompt.
 *
 * **The order of the checks is the substance.** `Notification.requestPermission()` prompts exactly
 * once on iOS; every later call returns the standing answer. So anything that would make a
 * subscription useless has to be caught **before** prompting, or the single prompt is spent on a
 * build that could never have worked:
 *
 *   1. Not launched from the home screen — iOS delivers push only to an installed app, and a
 *      subscription made in a tab silently receives nothing. Diagnosing that from the symptoms
 *      costs hours; refusing up front costs a sentence.
 *   2. No VAPID public key in the build — the browser's own error for this is cryptic, and the key
 *      is inlined at build time, so an unset deploy variable is the likeliest way to meet it.
 *
 * Every refusal names itself. In Story 1.2 each retry cost the author a reboot or an idle hour,
 * and that is still the price of a dead end that says nothing.
 */

import type { InstallState } from './install-state';

/** How long to wait for the service worker before calling it a failure rather than hanging. */
export const SERVICE_WORKER_TIMEOUT_MS = 10_000;

export type SubscribeResult =
  | { kind: 'subscribed'; json: PushSubscriptionJSON; savedToDatabase: boolean }
  | { kind: 'refused'; reason: string };

export interface SaveSubscription {
  (json: PushSubscriptionJSON): Promise<{ error: { message: string } | null }>;
}

/**
 * Rejects rather than waiting forever for a service worker that is never coming.
 *
 * `navigator.serviceWorker.ready` never settles when no worker registers — which is exactly what
 * happens on a non-production build, where Serwist is disabled. A button stuck on "Working…" says
 * nothing.
 */
export async function serviceWorkerReady(): Promise<ServiceWorkerRegistration> {
  return Promise.race([
    navigator.serviceWorker.ready,
    new Promise<never>((_, reject) =>
      setTimeout(
        () =>
          reject(
            new Error(
              'No service worker registered after 10s. It is built only in a production build — check that this is the deployed app and not a dev server.',
            ),
          ),
        SERVICE_WORKER_TIMEOUT_MS,
      ),
    ),
  ]);
}

/**
 * Why this device cannot usefully subscribe, or null when it can.
 *
 * Separate from the subscribing itself so both callers can ask the question without prompting —
 * Settings uses it to decide whether offering the control would be honest.
 */
export function refusalBeforePrompting(
  installState: InstallState,
  vapidPublicKey: string | undefined,
): string | null {
  if (installState !== 'installed') {
    return 'Not launched from the home screen. iOS delivers push only to an installed app, so a subscription made here would never receive anything.';
  }

  if (!vapidPublicKey) {
    return 'NEXT_PUBLIC_VAPID_PUBLIC_KEY is not set in this build. Set it in the deploy environment and redeploy — it is inlined at build time, so setting it alone changes nothing.';
  }

  return null;
}

/**
 * Asks for permission if it has not been asked, subscribes, and hands the result to `save`.
 *
 * `save` is passed in rather than imported so this module never decides *where* a subscription
 * belongs: the probe shows it for the CLI, Settings writes it to `push_subscription`. Omit it and
 * the subscription is produced and returned without being stored, which is the signed-out case.
 */
export async function subscribeThisDevice(
  installState: InstallState,
  vapidPublicKey: string | undefined,
  save?: SaveSubscription,
): Promise<SubscribeResult> {
  const refusal = refusalBeforePrompting(installState, vapidPublicKey);
  if (refusal) return { kind: 'refused', reason: refusal };

  try {
    const permission = await Notification.requestPermission();
    if (permission !== 'granted') {
      // Which answer, not merely that it failed. `denied` and `default` need different things
      // done about them, and only one of them can still be changed from inside the app.
      return { kind: 'refused', reason: `Notification permission: ${permission}` };
    }

    const registration = await serviceWorkerReady();
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: vapidPublicKey,
    });

    const json = subscription.toJSON();

    if (save) {
      const { error } = await save(json);
      if (error) {
        // The two halves fail independently, and the author needs to know which one did: a
        // subscription that exists but was not stored is invisible to the worker.
        return { kind: 'refused', reason: `Subscribed, but not saved: ${error.message}` };
      }
    }

    return { kind: 'subscribed', json, savedToDatabase: Boolean(save) };
  } catch (error) {
    // Verbatim, never a friendly summary: the exact failure is the finding.
    return { kind: 'refused', reason: String(error) };
  }
}
