'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import type { CommitmentOutcome } from '@/lib/chain';
import {
  OBJECTION_REASON_MAX,
  REFEREE_DAY_COPY,
  objectionIsOffered,
  type RefereeDayRow,
} from '@/lib/referee';

type View = { kind: 'loading' } | { kind: 'ready' } | { kind: 'failed'; reason: string };

/** What the last lookup produced. `idle` is not "nothing found" — it is "he has not asked yet",
 *  and the two must render differently or an untouched screen reads as an empty queue. */
type Found =
  | { kind: 'idle' }
  | { kind: 'looking' }
  | { kind: 'found'; day: string; rows: RefereeDayRow[] }
  | { kind: 'failed'; reason: string };

/** One commitment's own objection status, keyed by `settlementId-commitmentId` — a refusal on one
 *  row must not bleed into another's, the same shape `referee-home.tsx`'s own Mark Collected
 *  statuses use. The settlement id is part of the key even though `object_to_day()` and
 *  `referee_day_lookup()` are both scoped to the one account the referee is paired to, so at most
 *  one settled day ever comes back for a date: a key that depended on that staying true would
 *  silently merge two accounts' rows the day it stopped. */
/** One row's key. See the ObjectState comment for why the settlement id is part of it. */
function rowKey(row: { settlementId: string; commitmentId: string }): string {
  return `${row.settlementId}-${row.commitmentId}`;
}

type ObjectState =
  | { kind: 'idle' }
  | { kind: 'objecting' }
  | { kind: 'objected' }
  | { kind: 'failed'; reason: string };

/**
 * The referee looks up one day (Story 6.7, the pull half).
 *
 * **This screen exists so that no list has to.** He reaches a day by typing its date — because he
 * was there, or because the author told him — and the app never shows him a page of the author's
 * days to work through. A browsable list of proven days is a queue in everything but name, and the
 * property the whole arrangement rests on is that he is never sent one: with no action from him at
 * all, every proven day settles held. So there is no count here, no badge, no "days awaiting you",
 * and no empty state that reads as a queue drained.
 *
 * **The server is the sole judge (AD-1).** `object_to_day()` checks the role first, then the
 * account he is paired to, then a day corrected since he read it, then the window, then an outcome
 * that is not held, and then the landing guard — an objection is refused wherever it would leave
 * the author a broken chain with no Grace Day able to reach it: an expired day, a commitment
 * carrying no penalty, a Weekly Quota, or a penalty in any state but `owed`. Each in its own words.
 * This screen mirrors only the three facts `referee_day_lookup()` hands back
 * (`objectionIsOffered`), and only to decide whether the control renders at all; every refusal it
 * cannot see comes back from the function and is shown verbatim.
 *
 * **An objection is final.** There is no undo, no ruling step after it and no reply from the
 * author, so the control says so before he presses it and the screen stops offering it afterwards.
 * The author's recourse is the Grace Day he already has.
 *
 * **Zero notification permissions, no focus trap (NFR3, NFR15).** Nothing here touches the
 * `Notification` API, and every control is a plain field or button in document order.
 */
export function RefereeDayLookup() {
  const router = useRouter();
  const [view, setView] = useState<View>({ kind: 'loading' });
  const [day, setDay] = useState('');
  const [found, setFound] = useState<Found>({ kind: 'idle' });
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [objectState, setObjectState] = useState<Record<string, ObjectState>>({});
  // Which settled days have been objected to during this visit, keyed by settlement id.
  // `objection_once_per_day` is `(subject, for_day)`, not per commitment, so the moment one
  // commitment on a day is objected to every other row on that day can only ever be refused --
  // and a control that can only be refused is worse than no control.
  const [dayObjected, setDayObjected] = useState<Record<string, boolean>>({});

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const supabase = createClient();
      const { data: userData, error: userError } = await supabase.auth.getUser();
      if (cancelled) return;

      if (userError || !userData.user) {
        router.replace('/referee/login');
        return;
      }

      const { data: profile, error: profileError } = await supabase
        .from('profile')
        .select('role')
        .maybeSingle();
      if (cancelled) return;

      if (profileError) {
        setView({ kind: 'failed', reason: profileError.message });
        return;
      }

      // Not this screen's business to enforce (AD-7) — object_to_day() and referee_day_lookup()
      // both check the role themselves. This only avoids showing a doer a shell he can never
      // populate.
      if ((profile as { role?: string } | null)?.role !== 'referee') {
        router.replace('/');
        return;
      }

      setView({ kind: 'ready' });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [router]);

  /**
   * One named date, looked up. Two reads: the day's own settlement (which `settlement: referee
   * reads day and week` already grants him, so naming a day costs no new access), then
   * `referee_day_lookup()` for the commitment names and frozen outcomes behind it — a `security
   * definer` function rather than an RLS policy on `settlement_commitment`, which is also
   * `chain_current`'s base table and would silently reopen a doer-facing surface.
   *
   * `settlement_current`, never `settlement`: an objection has to supersede the end of the chain,
   * so a day already corrected by a Grace Day or an appeal is looked up at its correction. Passing
   * a superseded id would simply be refused by the function.
   */
  async function look() {
    setFound({ kind: 'looking' });
    setObjectState({});
    setDayObjected({});
    setReasons({});

    const supabase = createClient();

    const { data: settlements, error } = await supabase
      .from('settlement_current')
      .select('id')
      .eq('kind', 'day')
      .eq('period', day);

    if (error) {
      setFound({ kind: 'failed', reason: error.message });
      return;
    }

    const rows: RefereeDayRow[] = [];

    for (const settlement of settlements ?? []) {
      const settlementId = settlement.id as string;
      const { data: commitments, error: lookupError } = await supabase.rpc('referee_day_lookup', {
        p_settlement_id: settlementId,
      });

      if (lookupError) {
        setFound({ kind: 'failed', reason: lookupError.message });
        return;
      }

      for (const row of commitments ?? []) {
        rows.push({
          settlementId,
          commitmentId: row.commitment_id as string,
          commitmentName: (row.commitment_name as string | null) ?? 'A commitment',
          outcome: row.outcome as CommitmentOutcome,
          objectionDeadline: row.objection_deadline as string,
          alreadyObjected: Boolean(row.already_objected),
        });
      }
    }

    setFound({ kind: 'found', day, rows });
  }

  /**
   * The objection itself. One RPC, and whatever it decides is what the screen says — a closed
   * window, a day corrected since he read it, or a penalty already collected all come back as the
   * function's own refusal rather than being guessed at here.
   *
   * A refusal never reloads the lookup away: the row would simply lose its control with no
   * explanation, which is the same failure `referee-home.tsx`'s own Mark Collected was fixed for.
   * A success marks this row objected and leaves it on screen saying so, rather than clearing the
   * date field — he should be able to see what he just did.
   */
  async function object(row: RefereeDayRow) {
    const key = rowKey(row);
    setObjectState((s) => ({ ...s, [key]: { kind: 'objecting' } }));

    const { error } = await createClient().rpc('object_to_day', {
      p_settlement_id: row.settlementId,
      p_commitment_id: row.commitmentId,
      p_reason: reasons[key] ?? '',
    });

    if (error) {
      setObjectState((s) => ({ ...s, [key]: { kind: 'failed', reason: error.message } }));
      return;
    }

    setObjectState((s) => ({ ...s, [key]: { kind: 'objected' } }));
    // The whole day is spoken for now, not only this row: `objection_once_per_day` is
    // (subject, for_day). Every other commitment on this day stops offering a control that
    // could only ever come back "already objected to".
    setDayObjected((d) => ({ ...d, [row.settlementId]: true }));
  }

  return (
    <main>
      <section className="screen">
        <header className="screen-head">
          <button type="button" className="quiet back" onClick={() => router.push('/referee')}>
            {REFEREE_DAY_COPY.back}
          </button>
          <h1>{REFEREE_DAY_COPY.title}</h1>
        </header>

        {view.kind === 'loading' && <p>{REFEREE_DAY_COPY.looking}</p>}

        {view.kind === 'failed' && (
          <p role="status">
            <strong>{REFEREE_DAY_COPY.failed}</strong> {view.reason}
          </p>
        )}

        {view.kind === 'ready' && (
          <>
            <p>{REFEREE_DAY_COPY.intro}</p>

            <label htmlFor="objection-day">{REFEREE_DAY_COPY.dateLabel}</label>
            <input
              id="objection-day"
              type="date"
              value={day}
              onChange={(event) => setDay(event.target.value)}
            />
            <div className="actions">
              <button
                type="button"
                disabled={day === '' || found.kind === 'looking'}
                aria-busy={found.kind === 'looking'}
                onClick={() => void look()}
              >
                {found.kind === 'looking' ? REFEREE_DAY_COPY.looking : REFEREE_DAY_COPY.look}
              </button>
            </div>

            {found.kind === 'failed' && (
              <p role="status">
                <strong>{REFEREE_DAY_COPY.failed}</strong> {found.reason}
              </p>
            )}

            {found.kind === 'found' && found.rows.length === 0 && (
              <p role="status">{REFEREE_DAY_COPY.nothing}</p>
            )}

            {/* `role="status"` for the same reason the "nothing settled" branch above carries it:
                these rows arrive after he pressed Look up, and the one case where something
                actually came back must not be the silent one. */}
            {found.kind === 'found' && found.rows.length > 0 && (
              <div className="card" role="status">
                {found.rows.map((row) => {
                  const key = rowKey(row);
                  const state: ObjectState = objectState[key] ?? { kind: 'idle' };
                  // Evaluated once per render, against the clock as it was when this render ran.
                  // Nothing re-renders this screen on a timer, so a window that closes while he
                  // reads the page leaves the control on screen until something else redraws it —
                  // and `object_to_day()` refuses it in its own words, which is where a closed
                  // window is decided in any case (AD-1). A ticking clock here would be a second
                  // authority on a question the server already answers.
                  const open = objectionIsOffered(row, new Date());
                  const spoken = row.alreadyObjected || Boolean(dayObjected[row.settlementId]);
                  const offered = open && !spoken && state.kind !== 'objected';

                  return (
                    <div className="row" key={key}>
                      <div className="row-main">
                        <div className="row-name">{row.commitmentName}</div>
                        <div className="row-muted">
                          {REFEREE_DAY_COPY.outcome(row.outcome)} · {found.day}
                        </div>

                        {row.outcome !== 'held' && <p>{REFEREE_DAY_COPY.notHeld}</p>}

                        {/* Said once per row, and only where it is the reason the control is
                            missing. The day-level flag covers every other commitment on a day one
                            objection has already spoken for — `objection_once_per_day` is
                            (subject, for_day), so those rows could only ever be refused. */}
                        {row.outcome === 'held' && spoken && state.kind !== 'objected' && (
                          <p>{REFEREE_DAY_COPY.alreadyObjected}</p>
                        )}

                        {row.outcome === 'held' && !spoken && !open && (
                          <p>{REFEREE_DAY_COPY.windowClosed}</p>
                        )}

                        {offered && (
                          <>
                            <p>{REFEREE_DAY_COPY.window(row.objectionDeadline)}</p>
                            <label htmlFor={`objection-reason-${key}`}>
                              {REFEREE_DAY_COPY.reasonLabel}
                            </label>
                            <textarea
                              id={`objection-reason-${key}`}
                              rows={3}
                              // The bound `objection_reason_is_said` enforces. Without it the one
                              // refusal path this screen exists to keep human comes back as a raw
                              // 23514 rendered verbatim; object_to_day() words that refusal too,
                              // but the kinder answer is not to let him write past the limit.
                              maxLength={OBJECTION_REASON_MAX}
                              placeholder={REFEREE_DAY_COPY.reasonPlaceholder}
                              value={reasons[key] ?? ''}
                              onChange={(event) =>
                                setReasons((r) => ({ ...r, [key]: event.target.value }))
                              }
                            />
                            <p>{REFEREE_DAY_COPY.finalWarning}</p>
                            <div className="actions">
                              <button
                                type="button"
                                className="action"
                                // The reason is required server-side (`objection_reason_is_said`
                                // and object_to_day()'s own refusal); disabling here only spares
                                // him a round trip to be told what he can already see.
                                disabled={
                                  (reasons[key] ?? '').trim() === '' || state.kind === 'objecting'
                                }
                                aria-busy={state.kind === 'objecting'}
                                aria-label={`Object to ${row.commitmentName}, ${found.day}`}
                                onClick={() => void object(row)}
                              >
                                {state.kind === 'objecting'
                                  ? REFEREE_DAY_COPY.objecting
                                  : REFEREE_DAY_COPY.object}
                              </button>
                            </div>
                          </>
                        )}

                        {state.kind === 'objected' && <p>{REFEREE_DAY_COPY.objected}</p>}

                        {state.kind === 'failed' && (
                          <p>
                            <strong>{REFEREE_DAY_COPY.failed}</strong> {state.reason}
                          </p>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </>
        )}
      </section>
    </main>
  );
}
