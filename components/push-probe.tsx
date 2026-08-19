'use client';

import { useState } from 'react';
import type { InstallState } from '@/lib/install-state';
import { createClient } from '@/lib/supabase/client';

type ProbeState =
  | { kind: 'idle' }
  | { kind: 'working' }
  | { kind: 'subscribed'; json: string; savedToDatabase: boolean }
  | { kind: 'refused'; reason: string };

const VAPID_PUBLIC_KEY = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;

/** How long to wait for the service worker before calling it a failure rather than hanging. */
const SERVICE_WORKER_TIMEOUT_MS = 10_000;

/**
 * Rejects rather than waiting forever for a service worker that is never coming.
 *
 * `navigator.serviceWorker.ready` never settles when no worker registers — which
 * is exactly what happens on a non-production build, where Serwist is disabled.
 * A button stuck on "Working…" says nothing; this story needs every dead end to
 * name itself, because each retry costs the author another reboot or idle hour.
 */
async function serviceWorkerReady(): Promise<ServiceWorkerRegistration> {
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
 * Produces a push subscription and shows it for copying into the send CLI.
 *
 * Subscribing is gated on install state because on iOS a subscription created
 * from a browser tab silently fails to receive anything. Diagnosing that from
 * the symptoms costs hours; refusing up front costs a sentence.
 */
export function PushProbe({
  installState,
  ownerId,
}: {
  installState: InstallState;
  ownerId: string | null;
}) {
  const [state, setState] = useState<ProbeState>({ kind: 'idle' });

  async function subscribe() {
    setState({ kind: 'working' });

    if (installState !== 'installed') {
      setState({
        kind: 'refused',
        reason:
          'Not launched from the home screen. iOS delivers push only to an installed app, so a subscription made here would never receive anything.',
      });
      return;
    }

    // Checked before prompting: the browser's own error for a missing key is
    // cryptic, and a public key unset in the deploy environment is the likeliest
    // way to get one. Spending the permission prompt on it would be worse — iOS
    // does not offer it twice.
    if (!VAPID_PUBLIC_KEY) {
      setState({
        kind: 'refused',
        reason:
          'NEXT_PUBLIC_VAPID_PUBLIC_KEY is not set in this build. Set it in the deploy environment and redeploy — it is inlined at build time, so setting it alone changes nothing.',
      });
      return;
    }

    try {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        setState({ kind: 'refused', reason: `Notification permission: ${permission}` });
        return;
      }

      const registration = await serviceWorkerReady();
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: VAPID_PUBLIC_KEY,
      });

      const json = subscription.toJSON();
      const keys = json.keys ?? {};

      // Signed in: the endpoint belongs in the database, where the worker can reach it.
      // Signed out: fall back to showing it for `npm run push`, which is still the only
      // channel that has actually been seen to deliver. The fallback goes when the worker
      // has been watched doing the job, not before.
      if (ownerId) {
        const { error } = await createClient().from('push_subscription').upsert(
          {
            owner_id: ownerId,
            endpoint: json.endpoint,
            p256dh: keys.p256dh,
            auth: keys.auth,
            // Re-subscribing a device that had been marked dead should bring it back.
            dead_at: null,
            dead_reason: null,
          },
          { onConflict: 'endpoint' },
        );

        if (error) {
          setState({ kind: 'refused', reason: `Subscribed, but not saved: ${error.message}` });
          return;
        }
      }

      setState({
        kind: 'subscribed',
        json: JSON.stringify(json, null, 2),
        savedToDatabase: Boolean(ownerId),
      });
    } catch (error) {
      // Verbatim, never a friendly summary: the exact failure is the finding.
      setState({ kind: 'refused', reason: String(error) });
    }
  }

  return (
    <section>
      <h2>Push probe</h2>
      <button
        type="button"
        className="action"
        onClick={subscribe}
        disabled={state.kind === 'working'}
      >
        {state.kind === 'working' ? 'Working…' : 'Subscribe this device'}
      </button>

      {state.kind === 'refused' && (
        <p>
          <strong>Refused.</strong> {state.reason}
        </p>
      )}

      {state.kind === 'subscribed' && (
        <>
          <p>
            Save this to `.push-subscription.json` in the project root, then run the send script.
          </p>
          <textarea readOnly rows={12} cols={60} value={state.json} />
        </>
      )}
    </section>
  );
}
