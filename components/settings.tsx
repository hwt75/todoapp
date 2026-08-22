'use client';

import { useEffect, useRef, useState } from 'react';
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
  // Shared by `setHour` and `turnOnNotifications`, not only `load()`'s own effect: both fire a
  // request from a click and can still be in flight when `onClose` unmounts this screen.
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

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

      // No second fallback constant here — `lib/use-gate.ts` has the only one, and a signed-in
      // account always has a profile row (it is created by the sign-up trigger), so a missing
      // row is a real failure to surface rather than a case to paper over with a guessed hour.
      if (!data) {
        setView({ kind: 'failed', reason: 'No profile found for this account.' });
        return;
      }

      setView({ kind: 'ready', hour: data.morning_hour as number });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  async function setHour(hour: number) {
    if (!isSendableHour(hour)) return;

    setSaving({ kind: 'saving' });
    setView({ kind: 'ready', hour });

    const { error } = await createClient()
      .from('profile')
      .update({ morning_hour: hour })
      .eq('id', ownerId);

    if (!mounted.current) return;

    if (error) {
      // Nothing was written, so "Not saved." must say so — but the field keeps the hour he
      // typed rather than reverting it, because showing anything else would be a second lie on
      // top of the first: this is what he chose, and the message beside it says it did not
      // stick. The message is the database's own.
      setSaving({ kind: 'failed', reason: error.message });
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

    if (!mounted.current) return;

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
  // The install row leads: a subscription made outside the installed app silently receives
  // nothing, so the control is never offered there, whatever `permission` itself reads.
  const permissionActionable = permissionRow.actionable && installState === 'installed';

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
        {permissionActionable ? (
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
