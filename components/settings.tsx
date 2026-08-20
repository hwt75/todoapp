'use client';

import { useEffect, useState } from 'react';
import type { InstallState } from '@/lib/install-state';
import { subscribeThisDevice } from '@/lib/push-subscribe';
import {
  INSTALL_ROWS,
  PERMISSION_ROWS,
  hourLabel,
  isSendableHour,
  type PermissionState,
} from '@/lib/settings';
import { createClient } from '@/lib/supabase/client';

const VAPID_PUBLIC_KEY = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;

type View =
  { kind: 'loading' } | { kind: 'ready'; hour: number } | { kind: 'failed'; reason: string };

type Saving = { kind: 'idle' } | { kind: 'saving' } | { kind: 'failed'; reason: string };

const HOURS = Array.from({ length: 24 }, (_, hour) => hour);

/**
 * The hour the question arrives, and what is currently switched off.
 *
 * Three rows, and only the first is something this app owns. Notification permission is granted or
 * refused by iOS; home-screen installation is done by adding or deleting an icon. Both are
 * **stated with what breaks while they are off** rather than offered as toggles — a toggle implies
 * the app can turn the thing off, and a control that appears to do something it cannot is the
 * failure this product can least afford. The symptom of a dead delivery channel is silence, and
 * silence looks exactly like the product working while being ignored (spec 3.0, D2).
 *
 * Referee pairing and grace days are **absent rather than disabled**. There is no referee yet and
 * no grace day can be produced; a greyed-out row would be a promise with a date the author cannot
 * see, and this epic's own lesson is that an unbuildable control shown anyway is how a screen
 * starts lying quietly (D4).
 */
export function Settings({
  ownerId,
  installState,
  onClose,
}: {
  ownerId: string;
  installState: InstallState;
  onClose: () => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });
  const [saving, setSaving] = useState<Saving>({ kind: 'idle' });
  const [permission, setPermission] = useState<PermissionState>('default');
  const [subscribing, setSubscribing] = useState(false);
  const [subscribeError, setSubscribeError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      // Read from the browser rather than from a stored copy: permission changes outside this
      // app, in iOS Settings, and a stored copy would be a stale copy.
      if (typeof Notification !== 'undefined') {
        setPermission(Notification.permission as PermissionState);
      }

      const { data, error } = await createClient()
        .from('profile')
        .select('morning_hour')
        .maybeSingle();

      if (cancelled) return;
      if (error) {
        setView({ kind: 'failed', reason: error.message });
        return;
      }

      // The same fallback `lib/use-gate.ts` uses, and deliberately the only other place it
      // appears — two constants that can disagree about when he is asked would be worse than
      // one that is wrong.
      setView({ kind: 'ready', hour: (data?.morning_hour as number | undefined) ?? 7 });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  async function setHour(hour: number) {
    if (!isSendableHour(hour)) return;

    const previous = view;
    setSaving({ kind: 'saving' });
    setView({ kind: 'ready', hour });

    const { error } = await createClient()
      .from('profile')
      .update({ morning_hour: hour })
      .eq('id', ownerId);

    if (error) {
      // Nothing was written, so the screen must not go on showing the new hour as though it
      // were saved. The message is the database's own.
      setSaving({ kind: 'failed', reason: error.message });
      setView(previous);
      return;
    }

    setSaving({ kind: 'idle' });
  }

  async function turnOnNotifications() {
    setSubscribing(true);
    setSubscribeError(null);

    const result = await subscribeThisDevice(installState, VAPID_PUBLIC_KEY, async (json) =>
      createClient().from('push_subscription').upsert(
        {
          owner_id: ownerId,
          endpoint: json.endpoint,
          p256dh: json.keys?.p256dh,
          auth: json.keys?.auth,
          dead_at: null,
          dead_reason: null,
        },
        { onConflict: 'endpoint' },
      ),
    );

    setSubscribing(false);

    if (result.kind === 'refused') {
      setSubscribeError(result.reason);
    }

    // Re-read rather than assume: the author may have dismissed the prompt, and the browser is
    // the only thing that knows what it now holds.
    if (typeof Notification !== 'undefined') {
      setPermission(Notification.permission as PermissionState);
    }
  }

  const permissionRow = PERMISSION_ROWS[permission];
  const installRow = INSTALL_ROWS[installState];

  return (
    <section>
      <h1>Settings</h1>
      <button type="button" onClick={onClose}>
        Back to today
      </button>

      {view.kind === 'loading' && <p>Working…</p>}

      {view.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && (
        <div className="row" role="group" aria-label={`Morning hour, ${hourLabel(view.hour)}`}>
          <div className="row-main">
            <label className="row-name" htmlFor="morning-hour">
              Morning hour
            </label>
            <div className="row-muted">
              When yesterday is asked about. The reminders and the 48-hour deadline follow it.
            </div>
          </div>
          <select
            id="morning-hour"
            value={view.hour}
            disabled={saving.kind === 'saving'}
            onChange={(event) => void setHour(Number(event.target.value))}
          >
            {HOURS.map((hour) => (
              <option key={hour} value={hour}>
                {hourLabel(hour)}
              </option>
            ))}
          </select>
        </div>
      )}

      {saving.kind === 'failed' && (
        <p>
          <strong>Not saved.</strong> {saving.reason}
        </p>
      )}

      {/* Install state leads the two read-only rows. Without home-screen installation there is no
          push at all, and without push there is no product. */}
      <div className="row" role="group" aria-label={`Home screen, ${installRow.state}`}>
        <div className="row-main">
          <div className="row-name">Home screen</div>
          <div className="row-muted">{installRow.consequence}</div>
        </div>
        <span className="row-muted">{installRow.state}</span>
      </div>

      <div className="row" role="group" aria-label={`Notifications, ${permissionRow.state}`}>
        <div className="row-main">
          <div className="row-name">Notifications</div>
          <div className="row-muted">{permissionRow.consequence}</div>
        </div>
        {permissionRow.actionable ? (
          <button type="button" onClick={() => void turnOnNotifications()} disabled={subscribing}>
            {subscribing ? 'Working…' : 'Turn on notifications'}
          </button>
        ) : (
          <span className="row-muted">{permissionRow.state}</span>
        )}
      </div>

      {subscribeError && (
        <p>
          <strong>Refused.</strong> {subscribeError}
        </p>
      )}
    </section>
  );
}
