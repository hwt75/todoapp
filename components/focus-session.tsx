'use client';

import { useEffect, useRef, useState } from 'react';
import { calendarMoment } from '@/lib/declaration';
import { classifyWriteError, shouldRetry } from '@/lib/declaration-submit';
import {
  FOCUS_COPY,
  FOCUS_QUEUE_KEY,
  type QueuedFocusSession,
  type RunningSession,
  bankedAgainstTarget,
  bankedPercent,
  clearRunning,
  elapsedLabel,
  elapsedSeconds,
  formatElapsed,
  queuedSeconds,
  readRunning,
  readStoppedSessions,
  shownMinutes,
  startSession,
} from '@/lib/focus-session';
import { enqueue, flush, removeFromQueue } from '@/lib/offline-queue';
import { createClient } from '@/lib/supabase/client';

type View =
  | { kind: 'loading' }
  | { kind: 'ready'; bankedSeconds: number; targetMinutes: number }
  /** The total could not be read. The clock still works, and that is the point. */
  | { kind: 'unreadable'; reason: string }
  /** This row cannot carry sessions at all. There is nothing here to run. */
  | { kind: 'refused'; reason: string };

type Sending =
  { kind: 'idle' } | { kind: 'sending' } | { kind: 'queued' } | { kind: 'failed'; reason: string };

interface Rejection {
  key: string;
  message: string;
}

interface Delivery {
  /** Keys still waiting: the network is gone, not the rule. */
  kept: string[];
  /**
   * Every permanent refusal this pass produced, each carrying the key of the item it belongs
   * to — never just the message. A rejection is only *this* session's business if its key says
   * so; a stale, unrelated item the server will never accept must not be mistaken for the one
   * just stopped (`components/morning-gate.tsx`'s own flush already gets this right, and this
   * mirrors it).
   */
  rejections: Rejection[];
}

/**
 * Sends every stopped session waiting on this device.
 *
 * Module-level rather than a closure over props, because three things call it: stopping, opening
 * the screen, and the network coming back. A session stopped in a tunnel used to reach the server
 * only if the author later stopped *another* session on this same screen, which is a queue that
 * drains by coincidence.
 *
 * Every permanent refusal is collected, not just the one that was tapped. An older item the server
 * will never accept is dropped from the queue either way; dropping it without saying so is the
 * queue quietly losing work while the screen looks fine.
 */
async function deliverSessions(): Promise<Delivery> {
  const rejections: Rejection[] = [];

  const outcome = await flush<QueuedFocusSession>(
    window.localStorage,
    async (pending) => {
      const { error } = await createClient().from('focus_session').insert({
        owner_id: pending.ownerId,
        commitment_id: pending.commitmentId,
        idempotency_key: pending.idempotencyKey,
        started_at: pending.startedAt,
        stopped_at: pending.stoppedAt,
      });

      const result = classifyWriteError(error);

      // A refusal is permanent — the wrong cadence, another account's commitment, a clock that
      // ran backwards. Keeping it queued would retry forever against a rule that will never
      // accept it, while the screen shows the minutes as banked.
      if (result === 'rejected') {
        rejections.push({
          key: pending.idempotencyKey,
          message: error?.message ?? FOCUS_COPY.serverRefused,
        });
        removeFromQueue(window.localStorage, pending.idempotencyKey, FOCUS_QUEUE_KEY);
      }

      return shouldRetry(result) ? 'failed' : 'sent';
    },
    FOCUS_QUEUE_KEY,
  );

  return { kept: outcome.kept, rejections };
}

/**
 * The one screen in this product that exists to make *starting* easy.
 *
 * The author's failure with company work is not finishing it, it is beginning it: laptop open at
 * nine, Facebook twice, still nothing at ten. So there is one control when nothing is running, it
 * says what it does, and the sentence beside it removes the only reason he would hesitate — that
 * pressing start invites something to watch him.
 *
 * **Nothing runs.** Start writes a record to this device and the figure is `now − startedAt`,
 * recomputed once a second because text has to change, not because time is being counted
 * anywhere. That is why a locked phone, a backgrounded app and a killed process are the same
 * event here, and why nothing can pause, flag or invalidate a session. There is no
 * `visibilitychange` handler, no wake lock and no heartbeat, deliberately.
 *
 * **The clock outranks the screen.** Every control the author needs to bank his work renders
 * whether or not the day's total could be read. A failed read costs him a number; a hidden Stop
 * control would cost him the session, which is the thing the story is about.
 *
 * **Stop is the only filled button on the screen**, because stopping is the only thing here that
 * deposits anything. Start is an outline control like every other neutral one.
 */
export function FocusSession({
  ownerId,
  commitmentId,
  name,
  onClose,
}: {
  ownerId: string;
  commitmentId: string;
  name: string;
  onClose: () => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });
  const [running, setRunning] = useState<RunningSession | null>(null);
  const [queued, setQueued] = useState<QueuedFocusSession[]>([]);
  const [sending, setSending] = useState<Sending>({ kind: 'idle' });
  const [now, setNow] = useState(() => new Date());
  const [reloads, setReloads] = useState(0);
  // Checked by `stop()`, which — unlike `load()` and `drain()` — has no effect of its own to
  // hang a `cancelled` flag on; it runs from a click and can still be in flight when `onClose`
  // unmounts this screen.
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  // The day the screen *reports on*, derived from the same instant the figure is drawn from, so
  // a session running across local midnight moves the screen onto the new day rather than going
  // on reporting yesterday's total. The day a session is *filed* under is the database's, derived
  // from the start instant it is sent (AD-6) — the client never sends a date.
  const day = calendarMoment(now).day;

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setRunning(readRunning(window.localStorage));
      setQueued(readStoppedSessions(window.localStorage));

      const supabase = createClient();
      const [{ data: commitment, error }, { data: banked, error: bankedError }] = await Promise.all(
        [
          supabase
            .from('commitment')
            .select('daily_minutes_target')
            .eq('id', commitmentId)
            .maybeSingle(),
          // Seconds rather than minutes, so a session still sitting in the queue can be added to
          // this and the sum floored exactly once — the way the view itself floors it.
          supabase
            .from('focus_day_minutes')
            .select('seconds')
            .eq('commitment_id', commitmentId)
            .eq('for_day', day)
            .maybeSingle(),
        ],
      );

      if (cancelled) return;

      if (error || bankedError) {
        // Stated, and then got past: the clock and its Stop control render regardless, because
        // the read that failed is the one that produces a number and not the one that banks work.
        setView({ kind: 'unreadable', reason: (error ?? bankedError)!.message });
        return;
      }

      const targetMinutes = commitment?.daily_minutes_target as number | null | undefined;

      // Never a quieter rendering. `commitment_daily_hours_target` makes the target present on
      // exactly the cadence this screen serves, so a missing one means the row is not what this
      // surface is for — and a screen that shrugged would offer a clock whose every stop the
      // database is going to refuse.
      if (targetMinutes === null || targetMinutes === undefined) {
        setView({ kind: 'refused', reason: FOCUS_COPY.notAnHoursQuota });
        return;
      }

      setView({
        kind: 'ready',
        // Nothing banked today is a real state and reads as zero, not as an error.
        bankedSeconds: Number((banked?.seconds as number | string | undefined) ?? 0),
        targetMinutes,
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [commitmentId, day, reloads]);

  // Opening the screen, and the network coming back, both drain whatever is waiting. Neither is
  // a heartbeat and neither watches the author: `online` is a fact about the radio.
  useEffect(() => {
    let cancelled = false;

    async function drain() {
      if (readStoppedSessions(window.localStorage).length === 0) return;

      const { rejections } = await deliverSessions();
      if (cancelled) return;

      setQueued(readStoppedSessions(window.localStorage));
      setReloads((n) => n + 1);
      if (rejections.length > 0) {
        setSending({ kind: 'failed', reason: rejections.map((r) => r.message).join(' ') });
      }
    }

    const onOnline = () => void drain();
    void drain();
    window.addEventListener('online', onOnline);

    return () => {
      cancelled = true;
      window.removeEventListener('online', onOnline);
    };
  }, []);

  // A session belonging to another commitment is not this screen's to show or to stop.
  const mine = running && running.commitmentId === commitmentId ? running : null;

  useEffect(() => {
    if (!mine) return;
    const tick = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(tick);
  }, [mine]);

  function start() {
    try {
      setSending({ kind: 'idle' });
      setNow(new Date());

      const outcome = startSession(window.localStorage, {
        idempotencyKey: crypto.randomUUID(),
        commitmentId,
        startedAt: new Date().toISOString(),
      });

      if (outcome.kind === 'running-elsewhere') {
        // Nothing was written and nothing is this screen's to show, so the tap has to say so.
        // Silently keeping a foreign record would leave a control that does nothing at all.
        setSending({ kind: 'failed', reason: FOCUS_COPY.alreadyElsewhere });
        return;
      }

      setRunning(outcome.session);
    } catch {
      // Blocked storage, or no crypto outside a secure context. The raw exception is not shown:
      // a stack trace on this screen is noise, and the sentence says what to do instead.
      setSending({ kind: 'failed', reason: FOCUS_COPY.deviceRefused });
    }
  }

  async function stop(session: RunningSession) {
    setSending({ kind: 'sending' });

    try {
      const stopped: QueuedFocusSession = {
        // Minted at the start tap, reused here and by every retry (AD-4), so a replayed flush is
        // refused by the unique constraint rather than banking the same time twice.
        idempotencyKey: session.idempotencyKey,
        ownerId,
        commitmentId: session.commitmentId,
        startedAt: session.startedAt,
        stoppedAt: new Date().toISOString(),
      };

      // Queued before it is sent, and the running record cleared either way. The session is over
      // the moment he taps; whether it has reached the server yet is a separate question, and it
      // must not be answered by leaving a clock apparently still running.
      enqueue(window.localStorage, stopped, FOCUS_QUEUE_KEY);
      clearRunning(window.localStorage);
      setRunning(null);

      const { kept, rejections } = await deliverSessions();

      if (!mounted.current) return;

      setQueued(readStoppedSessions(window.localStorage));
      setReloads((n) => n + 1);

      // Scoped to *this* session's own key, not to the pass as a whole — a different, stale
      // item the same flush happened to refuse is not evidence that this one was. Reporting
      // "Not banked" for a session the server actually accepted is the false negative the rest
      // of this product goes out of its way never to produce.
      const ownRejection = rejections.find((r) => r.key === stopped.idempotencyKey);
      if (ownRejection) {
        // Nothing refused was written and nothing refused is waiting to be. The total must not
        // move, and the screen must not say it banked anything.
        setSending({ kind: 'failed', reason: ownRejection.message });
        return;
      }

      setSending(kept.includes(stopped.idempotencyKey) ? { kind: 'queued' } : { kind: 'idle' });
    } catch {
      if (mounted.current) setSending({ kind: 'failed', reason: FOCUS_COPY.deviceRefused });
    }
  }

  // What is still waiting, and only for the day on screen: a session banks to the day it
  // *started*, so one stopped after midnight belongs to yesterday's total rather than to this
  // one. This is the single place the client adds minutes of its own, and the number is only
  // ever displayed — it is never sent anywhere (AD-1).
  const waitingSeconds = queued
    .filter((s) => s.commitmentId === commitmentId)
    .filter((s) => calendarMoment(new Date(s.startedAt)).day === day)
    .reduce((total, s) => total + queuedSeconds(s), 0);

  const total =
    view.kind === 'ready'
      ? bankedAgainstTarget(shownMinutes(view.bankedSeconds, waitingSeconds), view.targetMinutes)
      : null;

  // Same numbers the text above derives from — AD-8's discipline in one screen: the bar and
  // the total never compute their own, separate arithmetic.
  const percent =
    view.kind === 'ready'
      ? bankedPercent(shownMinutes(view.bankedSeconds, waitingSeconds), view.targetMinutes)
      : null;

  // The clock is offered unless this row provably cannot carry one. A failed read is not proof.
  const clockAvailable = view.kind === 'ready' || view.kind === 'unreadable';

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>{name}</h1>
        <button type="button" className="quiet back" onClick={onClose}>
          Back to today
        </button>
      </header>

      {view.kind === 'loading' && <p>Working…</p>}

      {(view.kind === 'unreadable' || view.kind === 'refused') && (
        <p role="status">
          <strong>{FOCUS_COPY.failed}</strong> {view.reason}
        </p>
      )}

      {view.kind === 'unreadable' && <p className="row-muted">{FOCUS_COPY.stillRuns}</p>}

      {clockAvailable && (
        <>
          <div className="card card-pad stack">
            {/* The sentence stands whether or not anything is running: it is the reason he presses
                start, so it must be readable before he does. */}
            <p className="row-muted">{FOCUS_COPY.unwatched}</p>

            {mine ? (
              <>
                {/* The second and last claimant of the `figure` role in the whole product. The debt
                    total spent the first and has been holding this one open since 2.6 — and, like
                    it, the element carries the sentence and hides the bare digits, so a reader is
                    told what the number is rather than handed one. */}
                <p
                  className="focus-figure"
                  role="timer"
                  aria-label={elapsedLabel(elapsedSeconds(mine, now))}
                >
                  <span aria-hidden="true">{formatElapsed(elapsedSeconds(mine, now))}</span>
                </p>

                {/* The only filled button on this screen. Stopping is the only thing here that
                    deposits anything, and the word says so. */}
                <div className="actions">
                  <button
                    type="button"
                    className="action"
                    disabled={sending.kind === 'sending'}
                    aria-busy={sending.kind === 'sending'}
                    onClick={() => void stop(mine)}
                  >
                    {sending.kind === 'sending' ? FOCUS_COPY.stopping : FOCUS_COPY.stop}
                  </button>
                </div>
              </>
            ) : (
              <div className="actions">
                <button type="button" onClick={start}>
                  {FOCUS_COPY.start}
                </button>
              </div>
            )}
          </div>

          {total !== null && percent !== null && (
            <div className="card">
              <div className="row" role="group" aria-label={`${FOCUS_COPY.banked}, ${total}`}>
                <div className="row-main">
                  <div className="row-name">{FOCUS_COPY.banked}</div>
                  {/* aria-hidden: the row's own aria-label above already states this fraction as
                      text. A bar that spoke too would be a second announcement of the same
                      number, not a second piece of information. */}
                  <div className="quota-bar" aria-hidden="true">
                    <div className="quota-bar-fill" style={{ width: `${percent}%` }} />
                  </div>
                </div>
                <span className="row-muted" aria-hidden="true">
                  {total}
                </span>
              </div>
            </div>
          )}
        </>
      )}

      {sending.kind === 'queued' && (
        <p className="row-muted" role="status">
          {FOCUS_COPY.queuedOffline}
        </p>
      )}

      {sending.kind === 'failed' && (
        <p role="status">
          <strong>{FOCUS_COPY.notBanked}</strong> {sending.reason}
        </p>
      )}
    </section>
  );
}
