'use client';

import { useEffect, useRef, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { buildLedger, ledgerPillFamily, ledgerPillLabel, type LedgerRow } from '@/lib/ledger';
import { formatDong } from '@/lib/money';
import {
  GRACE_DAY_COPY,
  classifyGraceDaySpend,
  formatGraceAllowance,
  toGraceDayRow,
} from '@/lib/grace';

type View =
  | { kind: 'loading' }
  // `graceRemaining` is a plain `number`, never `number | null` — a failed or missing
  // `grace_allowance_remaining` read fails the whole view below (the same treatment every
  // other parallel read here already gets), so by the time this variant is reached the
  // count is always a real one. Never coerced from "unknown" to "0 remaining" by a `?? 0`
  // at the render site, which would read as a real, confident answer it is not.
  | { kind: 'ready'; rows: LedgerRow[]; graceRemaining: number }
  | { kind: 'failed'; reason: string };

/** One row's own Grace Day control, keyed by `for_day` — a client-local status alongside the
 *  server's own (there is no polling surface for whether `apply_grace_days()` has folded a
 *  spend in yet; that is up to an hour away by design, this story's own Design Notes). */
type GraceRowState =
  { kind: 'idle' } | { kind: 'spending' } | { kind: 'spent' } | { kind: 'failed'; reason: string };

export interface AppealTarget {
  commitmentId: string;
  commitmentName: string;
  forDay: string;
  amountDong: number;
}

/**
 * Every day that has been judged, newest first.
 *
 * **No row is tinted, on any day.** This screen is structurally a list of failures and is
 * reached in one tap from Today on exactly the worst day — so it is the one most likely to
 * become a wall of red, and a wall of red is the artifact this product exists to avoid.
 * The author's documented failure is retreating from the sight of his own record. Colour
 * lives in the pill and nowhere else.
 */
export function Ledger({
  ownerId,
  onClose,
  onOpenAppeal,
}: {
  ownerId: string;
  onClose: () => void;
  /** Story 4.4. Reachable the same way Chains detail and Focus Session are: a callback this
   *  component invokes itself, never a route the caller renders beside it. Optional so every
   *  caller that has not wired the Appeal screen yet keeps compiling — the Contest control
   *  simply does not render without it. */
  onOpenAppeal?: (target: AppealTarget) => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });
  // Story 5.1. Keyed by `for_day` rather than one shared status — a Failed Day can carry its
  // own control independent of every other row's, the same reasoning `ledger.tsx`'s own
  // per-commitment Contest buttons already rest on.
  const [graceState, setGraceState] = useState<Record<string, GraceRowState>>({});
  // Guards `spendGraceDay`'s own state updates after the insert's await resolves — mirrors
  // `components/settings.tsx`'s identical `mounted` ref, needed for the same reason: a spend
  // fired from a click can still be in flight when navigating away (`onClose`) unmounts this
  // screen.
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
      const supabase = createClient();

      const [
        { data: settlements, error },
        { data: penalties, error: penaltiesError },
        { data: misses, error: missesError },
        { data: weekSettlements, error: weekSettlementsError },
        { data: weekPenalties, error: weekPenaltiesError },
        { data: grace, error: graceError },
      ] = await Promise.all([
        supabase.from('settlement_current').select('period,verdict,missed_count').eq('kind', 'day'),
        supabase.from('penalty_current').select('amount_dong,state,period').eq('kind', 'day'),
        supabase
          .from('declaration')
          .select('for_day,commitment_id,filed_by,commitment:commitment_id(name,carries_penalty)')
          .eq('answer', 'slipped'),
        supabase
          .from('settlement_current')
          .select('period,verdict,missed_count')
          .eq('kind', 'week'),
        supabase.from('penalty_current').select('amount_dong,state,period').eq('kind', 'week'),
        // Story 5.1: the one source for how many Grace Days remain this calendar month
        // (AD-8) — never a client-side tally of raw grace_day rows.
        supabase.from('grace_allowance_remaining').select('remaining').maybeSingle(),
      ]);

      if (cancelled) return;

      // Every parallel read is checked, not only the first — a failed penalties/misses/week
      // read used to render silently as an incomplete or wrong ledger rather than a failure.
      const failed =
        error ??
        penaltiesError ??
        missesError ??
        weekSettlementsError ??
        weekPenaltiesError ??
        graceError;
      if (failed) {
        setView({ kind: 'failed', reason: failed.message });
        return;
      }

      // A real doer session always has exactly one row here (`grace_allowance_remaining`'s
      // own `where role = 'doer'`) — no row without an error is itself a failure to
      // surface, never a silent "treat it as 0 remaining" (Story 5.1 review finding).
      if (!grace) {
        setView({ kind: 'failed', reason: 'No Grace Days allowance found for this account.' });
        return;
      }

      const toPenaltyRecord = (p: { amount_dong: unknown; state: unknown; period: unknown }) => ({
        period: p.period as string,
        amount_dong: p.amount_dong as number,
        state: p.state as 'owed' | 'held' | 'dropped',
      });

      setView({
        kind: 'ready',
        graceRemaining: grace.remaining as number,
        rows: buildLedger(
          settlements ?? [],
          (penalties ?? []).map(toPenaltyRecord),
          (misses ?? [])
            .filter(
              (m) => (m.commitment as unknown as { carries_penalty: boolean })?.carries_penalty,
            )
            .map((m) => ({
              for_day: m.for_day as string,
              commitment_id: m.commitment_id as string,
              commitment_name: (m.commitment as unknown as { name: string }).name,
              filed_by: m.filed_by as 'doer' | 'auto_check',
            })),
          weekSettlements ?? [],
          (weekPenalties ?? []).map(toPenaltyRecord),
        ),
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  /**
   * Spends a Grace Day against one Failed, owed day (Story 5.1). One insert, and every
   * eligibility rule it can run into lives entirely in `grace_day_validate()`'s own trigger
   * (AD-1) — this never pre-checks anything itself, the same discipline `appeal-form.tsx`
   * follows for Contest.
   *
   * **The row does not flip to Waived here.** The insert only records the event; the actual
   * correction is folded in by the next hourly settlement pass, up to an hour later (this
   * story's own Design Notes) — so a successful spend disables this row's own control and
   * says so, rather than optimistically rendering a state the server has not produced yet.
   */
  async function spendGraceDay(forDay: string) {
    setGraceState((s) => ({ ...s, [forDay]: { kind: 'spending' } }));

    const { error } = await createClient()
      .from('grace_day')
      .insert(toGraceDayRow({ forDay }, ownerId));

    if (!mounted.current) return;

    const outcome = classifyGraceDaySpend(error);

    if (outcome.kind === 'refused') {
      setGraceState((s) => ({ ...s, [forDay]: { kind: 'failed', reason: outcome.reason } }));
      return;
    }

    // Either outcome disables this row's own control from here — a grace_day row now exists
    // for this day either way (lib/grace.ts's own comment on why 'spent' and 'already-spent'
    // need no further disambiguation for this particular table). Only 'spent' is a *new* row,
    // though: 'already-spent' (23505) means nothing was written this time — the count the
    // last read returned already accounts for that day's own earlier spend, and decrementing
    // it again here would undercount what actually remains.
    setGraceState((s) => ({ ...s, [forDay]: { kind: 'spent' } }));
    if (outcome.kind === 'spent') {
      setView((v) =>
        v.kind === 'ready' ? { ...v, graceRemaining: Math.max(0, v.graceRemaining - 1) } : v,
      );
    }
  }

  return (
    <section>
      <h1>Ledger</h1>
      <button type="button" onClick={onClose}>
        Back to today
      </button>

      {view.kind === 'loading' && <p>Working…</p>}

      {view.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && view.rows.length === 0 && (
        <p className="row-muted">No day has been judged yet.</p>
      )}

      {view.kind === 'ready' &&
        view.rows.map((row) => {
          // A stable local reference, not a repeated `graceState[row.day]` lookup — TypeScript
          // narrows a discriminated union through a `const` it can track, never through the
          // same computed index re-evaluated at each use.
          const rowGrace: GraceRowState = graceState[row.day] ?? { kind: 'idle' };

          return (
            <div
              className={row.kind === 'week' ? 'row row-week' : 'row'}
              key={`${row.kind}-${row.day}`}
              role="group"
              aria-label={
                row.kind === 'week'
                  ? row.verdict === 'clean'
                    ? `Week of ${row.day}, clean`
                    : `Week of ${row.day}, owed ${formatDong(row.amountDong ?? 0)}`
                  : row.state === 'waived'
                    ? `${row.day}, waived`
                    : row.verdict === 'clean'
                      ? `${row.day}, clean`
                      : row.verdict === 'expired'
                        ? `${row.day}, expired unanswered, owed ${formatDong(row.amountDong ?? 0)}`
                        : row.state === 'held'
                          ? `${row.day}, ${formatDong(row.amountDong ?? 0)} on hold pending appeal, for ${row.missed.join(' and ')}`
                          : row.state === 'dropped'
                            ? `${row.day}, dropped, for ${row.missed.join(' and ')}`
                            : `${row.day}, owed ${formatDong(row.amountDong ?? 0)}, for ${row.missed.join(' and ')}`
              }
            >
              <div className="row-main">
                <div className="row-name">
                  {row.kind === 'week' ? `Week of ${row.day}` : row.day}
                </div>
                <div className="row-muted" aria-hidden="true">
                  {row.kind === 'week'
                    ? row.verdict === 'clean'
                      ? 'Everything held'
                      : `Fell short${row.amountDong ? ` · ${formatDong(row.amountDong)}` : ''}`
                    : row.verdict === 'expired'
                      ? `Went unanswered${row.amountDong ? ` · ${formatDong(row.amountDong)}` : ''}`
                      : row.verdict === 'clean'
                        ? 'Everything held'
                        : `${row.missed.join(' · ')}${row.amountDong ? ` · ${formatDong(row.amountDong)}` : ''}`}
                </div>

                {/* Contest: only on an eligible owed failed-day row (a machine-filed miss whose
                  Penalty has not already moved to held/dropped/anything else). One control
                  per contestable commitment — a Failed Day can carry more than one. */}
                {row.kind === 'day' &&
                  onOpenAppeal &&
                  row.appealable.map((miss) => (
                    <button
                      key={miss.commitmentId}
                      type="button"
                      onClick={() =>
                        onOpenAppeal({
                          commitmentId: miss.commitmentId,
                          commitmentName: miss.commitmentName,
                          forDay: row.day,
                          amountDong: row.amountDong ?? 0,
                        })
                      }
                    >
                      Contest {miss.commitmentName}
                    </button>
                  ))}

                {/* Grace Day (Story 5.1): offered on every Failed, still-owed day — never only
                  inside a future Silence intervention (this story's own Never boundary) —
                  always stating how many remain. Once spent, the row states so and offers no
                  further control for it; it does not read Waived until the next hourly
                  settlement pass folds the correction in. */}
                {row.kind === 'day' && row.graceable && (
                  <div className="row-grace">
                    {rowGrace.kind === 'spent' ? (
                      <p role="status">{GRACE_DAY_COPY.spent}</p>
                    ) : (
                      <>
                        <button
                          type="button"
                          // Distinguishes one row's control from every other's for a
                          // screen-reader user — every row otherwise shares the identical
                          // accessible name "Spend a Grace Day", the same gap
                          // `referee-home.tsx`'s own "Open"/"Copy"/"Mark collected" controls
                          // were already fixed for.
                          aria-label={`Spend a Grace Day for ${row.day}`}
                          onClick={() => void spendGraceDay(row.day)}
                          disabled={rowGrace.kind === 'spending' || view.graceRemaining <= 0}
                        >
                          {rowGrace.kind === 'spending'
                            ? GRACE_DAY_COPY.spending
                            : GRACE_DAY_COPY.spend}
                        </button>
                        <span className="row-muted">
                          {formatGraceAllowance(view.graceRemaining)}
                        </span>
                      </>
                    )}
                    {rowGrace.kind === 'failed' && (
                      <p role="status">
                        <strong>{GRACE_DAY_COPY.failed}</strong> {rowGrace.reason}
                      </p>
                    )}
                  </div>
                )}
              </div>
              {/* The pill carries the colour. The row never does. */}
              <span className={`pill pill-${ledgerPillFamily(row)}`} aria-hidden="true">
                {ledgerPillLabel(row)}
              </span>
            </div>
          );
        })}
    </section>
  );
}
