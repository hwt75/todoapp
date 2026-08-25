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
import {
  REFEREE_PAIRING_COPY,
  isPairableEmail,
  isPairedReferee,
  refereeFunctionErrorMessage,
} from '@/lib/referee';
import { formatGraceAllowance } from '@/lib/grace';
import { createClient } from '@/lib/supabase/client';

const VAPID_PUBLIC_KEY = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;

type View =
  { kind: 'loading' } | { kind: 'ready'; hour: number } | { kind: 'failed'; reason: string };

type Saving = { kind: 'idle' } | { kind: 'saving' } | { kind: 'failed'; reason: string };

type Pairing =
  | { kind: 'idle' }
  | { kind: 'pairing' }
  | { kind: 'paired'; email: string; password: string }
  | { kind: 'failed'; reason: string };

/** Story 5.1. `'loading'` renders as "Working…"; `'failed'` surfaces the read's own reason
 *  (mirroring `View`/`Saving`/`Pairing` above) rather than leaving the row stuck silently on
 *  "Working…" forever — a real read failure used to be indistinguishable from "still
 *  loading" here, since the read's own `error` went unchecked entirely. Never a bare
 *  `number | null`: that conflated "still loading", "failed to load" and "no row at all"
 *  into one value with no way to tell them apart, which is exactly what let the error go
 *  unchecked in the first place. */
type GraceView =
  { kind: 'loading' } | { kind: 'ready'; remaining: number } | { kind: 'failed'; reason: string };

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
 * Referee pairing (Story 4.5) fills the row this comment used to mark absent — the Edge
 * Function it calls, the account it creates, and the RLS it depends on all now exist. Grace
 * Days (Story 5.1) fills the other one: a read-only count, mirroring `grace_allowance_
 * remaining`'s own one-source rule (AD-8) rather than a client-side tally — spending one
 * happens from the Day summary or a Ledger row, never from here, so this row states the
 * number and nothing else.
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
  const [refereeEmail, setRefereeEmail] = useState('');
  const [pairing, setPairing] = useState<Pairing>({ kind: 'idle' });
  const [grace, setGrace] = useState<GraceView>({ kind: 'loading' });
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

  // A separate read from the morning-hour one above, and deliberately never blocks it: this
  // row is one independent fact among several on this screen (the install/notification rows
  // already tolerate their own failure without taking the rest of the page down with them),
  // not a precondition for changing the hour. Its own failure is still surfaced, though,
  // rather than left indistinguishable from "still loading" — the fix below makes: both a
  // resolved `{ error }` and a genuine thrown rejection are handled, where an earlier
  // version destructured only `data` from a bare `.then()` and had no `try`/`catch` at all.
  useEffect(() => {
    let cancelled = false;

    async function loadGrace() {
      try {
        const { data, error } = await createClient()
          .from('grace_allowance_remaining')
          .select('remaining')
          .maybeSingle();

        if (cancelled) return;

        if (error) {
          setGrace({ kind: 'failed', reason: error.message });
          return;
        }

        // A real doer session always has exactly one row here
        // (`grace_allowance_remaining`'s own `where role = 'doer'`) — no row without an
        // error is itself a failure to surface, never a silent "treat it as 0 remaining".
        if (!data) {
          setGrace({ kind: 'failed', reason: 'No Grace Days allowance found for this account.' });
          return;
        }

        setGrace({ kind: 'ready', remaining: data.remaining as number });
      } catch (err) {
        if (!cancelled) setGrace({ kind: 'failed', reason: String(err) });
      }
    }

    void loadGrace();
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

  /**
   * Pairing (Story 4.5). One call to the `pair-referee` Edge Function — the one place in
   * this codebase a service-role client may live — and nothing decided here: eligibility
   * (live doer, no existing referee) is entirely the function's own call. This screen only
   * sends the address and shows back whatever the server decided, verbatim on refusal, and
   * the one-time password exactly once on success (Never boundary — it is never emailed,
   * never stored, and this render is the only place it is ever shown).
   */
  async function pairReferee() {
    if (!isPairableEmail(refereeEmail)) return;

    setPairing({ kind: 'pairing' });

    const { data, error } = await createClient().functions.invoke('pair-referee', {
      body: { email: refereeEmail },
    });

    if (!mounted.current) return;

    if (error) {
      setPairing({ kind: 'failed', reason: await refereeFunctionErrorMessage(error) });
      return;
    }

    if (!isPairedReferee(data)) {
      setPairing({ kind: 'failed', reason: REFEREE_PAIRING_COPY.noPassword });
      return;
    }

    setPairing({ kind: 'paired', email: data.email, password: data.password });
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

      {/* Read-only (Story 5.1): spending one happens from the Day summary or a Ledger row,
          never from here — this row only states the count, the same one source
          (grace_allowance_remaining) every other surface that shows it reads (AD-8). */}
      <div className="row" role="group" aria-label="Grace Days">
        <div className="row-main">
          <div className="row-name">Grace Days</div>
          <div className="row-muted">
            A limited, non-carrying monthly allowance that voids a Failed Day&rsquo;s Penalty.
          </div>
          {grace.kind === 'failed' && (
            <p role="status">
              <strong>Failed.</strong> {grace.reason}
            </p>
          )}
        </div>
        {grace.kind !== 'failed' && (
          <span className="row-muted">
            {grace.kind === 'loading' ? 'Working…' : formatGraceAllowance(grace.remaining)}
          </span>
        )}
      </div>

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

      <div className="row" role="group" aria-label={REFEREE_PAIRING_COPY.rowName}>
        <div className="row-main">
          <div className="row-name">{REFEREE_PAIRING_COPY.rowName}</div>
          <div className="row-muted">{REFEREE_PAIRING_COPY.consequence}</div>

          {pairing.kind !== 'paired' && (
            <>
              <input
                type="email"
                inputMode="email"
                autoComplete="off"
                placeholder={REFEREE_PAIRING_COPY.emailPlaceholder}
                value={refereeEmail}
                disabled={pairing.kind === 'pairing'}
                onChange={(event) => setRefereeEmail(event.target.value.trim())}
              />
              <button
                type="button"
                onClick={() => void pairReferee()}
                disabled={pairing.kind === 'pairing' || !isPairableEmail(refereeEmail)}
              >
                {pairing.kind === 'pairing'
                  ? REFEREE_PAIRING_COPY.pairing
                  : REFEREE_PAIRING_COPY.pair}
              </button>
            </>
          )}

          {pairing.kind === 'failed' && (
            <p role="status">
              <strong>{REFEREE_PAIRING_COPY.failed}</strong> {pairing.reason}
            </p>
          )}

          {pairing.kind === 'paired' && (
            <div role="status">
              <p>{REFEREE_PAIRING_COPY.paired(pairing.email)}</p>
              <p>
                <strong>{REFEREE_PAIRING_COPY.passwordLabel}</strong> {pairing.password}
              </p>
              <p className="row-muted">{REFEREE_PAIRING_COPY.shownOnce}</p>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
