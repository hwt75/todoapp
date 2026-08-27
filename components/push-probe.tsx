'use client';

import { useState } from 'react';
import type { InstallState } from '@/lib/install-state';
import { subscribeThisDevice } from '@/lib/push-subscribe';
import { createClient } from '@/lib/supabase/client';

type ProbeState =
  | { kind: 'idle' }
  | { kind: 'working' }
  | { kind: 'subscribed'; json: string; savedToDatabase: boolean }
  | { kind: 'refused'; reason: string };

const VAPID_PUBLIC_KEY = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;

/**
 * Produces a push subscription and shows it for copying into the send CLI.
 *
 * Subscribing is gated on install state because on iOS a subscription created from a browser
 * tab silently fails to receive anything. Diagnosing that from the symptoms costs hours;
 * refusing up front costs a sentence.
 *
 * **The gating, the prompt and the save now live in `lib/push-subscribe.ts`**, because Settings
 * asks for permission too (spec 3.0, D3) and the two must not drift about when it is safe to
 * prompt — iOS offers it once. What stays here is this story's own apparatus: the textarea that
 * feeds `npm run push`, which is the only channel that has actually been watched delivering.
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

    const result = await subscribeThisDevice(
      installState,
      VAPID_PUBLIC_KEY,
      // Signed in: the endpoint belongs in the database, where the worker can reach it.
      // Signed out: no save, and the subscription is shown for `npm run push` instead.
      ownerId
        ? async (json) =>
            createClient().from('push_subscription').upsert(
              {
                owner_id: ownerId,
                endpoint: json.endpoint,
                p256dh: json.keys?.p256dh,
                auth: json.keys?.auth,
                // Re-subscribing a device that had been marked dead should bring it back.
                dead_at: null,
                dead_reason: null,
              },
              { onConflict: 'endpoint' },
            )
        : undefined,
    );

    setState(
      result.kind === 'subscribed'
        ? {
            kind: 'subscribed',
            json: JSON.stringify(result.json, null, 2),
            savedToDatabase: result.savedToDatabase,
          }
        : { kind: 'refused', reason: result.reason },
    );
  }

  return (
    <section>
      <h2>Push probe</h2>
      <div className="card card-pad stack">
        <div className="actions">
          <button
            type="button"
            className="action"
            onClick={subscribe}
            disabled={state.kind === 'working'}
          >
            {state.kind === 'working' ? 'Working…' : 'Subscribe this device'}
          </button>
        </div>

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
      </div>
    </section>
  );
}
