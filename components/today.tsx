'use client';

import { useEffect, useRef, useState } from 'react';
import { CommitmentRow, type RowCommitment } from '@/components/commitment-row';
import { stateToday } from '@/lib/commitment-state';
import { createClient } from '@/lib/supabase/client';
import { DebtBlock } from '@/components/debt-block';
import { totalOwed } from '@/lib/money';
import type { WeeklyQuotaPosition } from '@/lib/weekly-quota';
import { buildLedger, type LedgerRow } from '@/lib/ledger';
import {
  GRACE_DAY_COPY,
  classifyGraceDaySpend,
  formatGraceAllowance,
  toGraceDayRow,
} from '@/lib/grace';

type View =
  | { kind: 'loading' }
  | {
      kind: 'ready';
      rows: RowCommitment[];
      owedDong: number;
      chains: Record<string, number>;
      quotas: Record<string, WeeklyQuotaPosition>;
      /** Story 5.1: every Failed, still-owed day a Grace Day could void — "the Day summary"
       *  entry point FR-17's own AC names, alongside a Ledger row. Empty far more often than
       *  not (most days are clean), which is why this screen otherwise says nothing about
       *  money at all until there is something to say. */
      graceRows: LedgerRow[];
      // Never `number | null` — a failed or missing `grace_allowance_remaining` read fails
      // the whole view below, the same treatment every other parallel read here already
      // gets, so a real doer session always has a real number by the time this variant is
      // reached (Story 5.1 review finding: never coerce "unknown" to "0 remaining").
      graceRemaining: number;
    }
  | { kind: 'failed'; reason: string };

/** Mirrors `components/ledger.tsx`'s own per-row Grace Day status — see that file's comment
 *  for why this needs to be its own client-local state rather than something read back from
 *  the server: there is no polling surface for whether `apply_grace_days()` has folded a
 *  spend in yet. */
type GraceRowState =
  { kind: 'idle' } | { kind: 'spending' } | { kind: 'spent' } | { kind: 'failed'; reason: string };

const SELECT = 'id,name,cadence,carries_penalty,weekly_target,daily_minutes_target';

/**
 * The screen the author opens, and the only one he opens under reluctance.
 *
 * His stated failure mode is opening the app, feeling nothing worth staying for, and not
 * coming back for days. So this answers "where do I stand" before anything is read, and
 * it says nothing it cannot support: until settlement exists, every commitment is
 * honestly `not yet` and no row claims otherwise.
 */
export function Today({
  ownerId,
  onOpenLedger,
  onOpenChain,
  onOpenFocus,
  onOpenSettings,
}: {
  ownerId: string;
  onOpenLedger: () => void;
  onOpenChain: (commitment: RowCommitment) => void;
  /** Where a *Put hours in* row goes instead. See the fork below. */
  onOpenFocus: (commitment: RowCommitment) => void;
  onOpenSettings: () => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });
  // Story 5.1, keyed by `for_day` — mirrors `components/ledger.tsx`'s own identical state.
  const [graceState, setGraceState] = useState<Record<string, GraceRowState>>({});
  // Guards `spendGraceDay`'s own state updates after the insert's await resolves — mirrors
  // `components/settings.tsx`'s identical `mounted` ref, needed for the same reason: a spend
  // fired from a click can still be in flight when this screen unmounts (opening the Ledger,
  // Settings, a Chain, or a Focus Session all swap it out in `app/page.tsx`).
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
        { data, error },
        { data: penalties, error: penaltiesError },
        { data: chains, error: chainsError },
        { data: quotas, error: quotasError },
        { data: graceSettlements, error: graceSettlementsError },
        { data: gracePenalties, error: gracePenaltiesError },
        { data: grace, error: graceError },
      ] = await Promise.all([
        supabase.from('commitment').select(SELECT).is('archived_at', null).order('created_at'),
        // `penalty_current`, not `penalty`. A penalty attached to a superseded verdict is
        // history rather than debt — it stays in the table so the trace survives and stops
        // counting (AD-9). Reading the base table would charge him for a day he took back.
        supabase.from('penalty_current').select('amount_dong').eq('state', 'owed'),
        // Derived in one place — `chain_current` — rather than counted here. A second
        // implementation of the chain rule would drift, and this one would drift silently
        // because a wrong chain still looks like a number.
        supabase.from('chain_current').select('commitment_id,current_days'),
        // Same pattern, for the other live position this screen shows: `weekly_quota_progress`
        // (spec 3-3) is the one source the pill reads, never a client-side tally of raw
        // `declaration` rows (AD-8).
        supabase.from('weekly_quota_progress').select('commitment_id,held,target,days_remaining'),
        // Story 5.1: two separate reads (never reusing the unfiltered `penalty_current` read
        // above, which deliberately mixes day- and week-kind rows for the aggregate figure) —
        // day-kind only, folded through `buildLedger` the same way `components/ledger.tsx`
        // derives `graceable`, so the two surfaces cannot drift into disagreeing about which
        // day qualifies. Filtered to `verdict = 'failed'` server-side too — unlike the
        // Ledger, which genuinely needs every day ever judged to render its own history,
        // this screen only ever wants the handful that could still be graced, so there is no
        // reason to pull the account's entire settled-day history just to filter it back
        // down client-side.
        supabase
          .from('settlement_current')
          .select('period,verdict,missed_count')
          .eq('kind', 'day')
          .eq('verdict', 'failed'),
        supabase
          .from('penalty_current')
          .select('amount_dong,state,period')
          .eq('kind', 'day')
          .eq('state', 'owed'),
        supabase.from('grace_allowance_remaining').select('remaining').maybeSingle(),
      ]);

      if (cancelled) return;

      // Every parallel read is checked, not only the first — a failed penalties/chains/quotas
      // read used to render silently as if nothing were owed or held, which is a wrong answer
      // dressed as a clean one, not an absence of data.
      const failed =
        error ??
        penaltiesError ??
        chainsError ??
        quotasError ??
        graceSettlementsError ??
        gracePenaltiesError ??
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

      setView({
        kind: 'ready',
        rows: (data ?? []) as RowCommitment[],
        owedDong: totalOwed((penalties ?? []).map((p) => p.amount_dong as number)),
        chains: Object.fromEntries(
          (chains ?? []).map((c) => [c.commitment_id as string, c.current_days as number]),
        ),
        quotas: Object.fromEntries(
          (quotas ?? []).map((q) => [
            q.commitment_id as string,
            {
              held: q.held as number,
              target: q.target as number,
              daysRemaining: q.days_remaining as number,
            },
          ]),
        ),
        graceRows: buildLedger(graceSettlements ?? [], gracePenalties ?? [], []).filter(
          (r) => r.graceable,
        ),
        graceRemaining: grace.remaining as number,
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  /** Spends a Grace Day against one Failed, owed day. See `components/ledger.tsx`'s own
   *  identical function for the full reasoning — this is the same control, offered from the
   *  Day summary rather than a Ledger row (FR-17's own two current entry points). */
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

    // Only 'spent' is a *new* row — 'already-spent' (23505) means nothing was written this
    // time, and the count the last read returned already accounts for that day's own
    // earlier spend. See `components/ledger.tsx`'s identical function for the full reasoning.
    setGraceState((s) => ({ ...s, [forDay]: { kind: 'spent' } }));
    if (outcome.kind === 'spent') {
      setView((v) =>
        v.kind === 'ready' ? { ...v, graceRemaining: Math.max(0, v.graceRemaining - 1) } : v,
      );
    }
  }

  return (
    /* The debt block is drawn first and read last, and that is not a styling accident.
       EXPERIENCE.md requires the commitment rows to be announced before it: a sighted
       reader can look past the figure, a VoiceOver user cannot skip what is read to them,
       and being told your own debt first thing every morning is a cost this product does
       not need to add. So the DOM order is rows-then-figure and CSS `order` puts the
       figure on top. */
    <section className="today">
      <h1>Today</h1>
      {/* Reachable the same way the Ledger and Chains detail are: a callback this component
          invokes itself, never a route the caller renders beside it (spec 3.0, Boundaries &
          Constraints). Rendered unconditionally, ahead of the load state, so Settings stays
          reachable even on a failed read — the one place that could turn the morning hour back
          down to something sendable. */}
      <button type="button" onClick={onOpenSettings}>
        Settings
      </button>

      {view.kind === 'loading' && <p>Working…</p>}

      {view.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && view.rows.length === 0 && (
        <p className="row-muted">
          Nothing set up yet. Add a commitment below and it will appear here tomorrow morning.
        </p>
      )}

      {view.kind === 'ready' && (
        <>
          <div className="today-rows">
            {view.rows.map((row) => (
              <CommitmentRow
                key={row.id}
                commitment={row}
                state={stateToday(row)}
                chainDays={view.chains[row.id] ?? 0}
                quotaPosition={view.quotas[row.id]}
                /* An hours-quota row opens the Focus Session, and every other row opens the
                   Chains detail as before. Not a preference: `commitments_owing()` excludes
                   that cadence, so it never reaches `settlement_commitment`, so `chain_current`
                   has nothing for it — its Chains detail is empty by construction. The fork
                   lives here because this component already selects `cadence`, which keeps
                   `commitment-row.tsx` a component that opens a thing rather than one that
                   knows which thing. */
                onOpen={row.cadence === 'daily_hours_quota' ? onOpenFocus : onOpenChain}
              />
            ))}
          </div>

          <DebtBlock totalDong={view.owedDong} onOpen={onOpenLedger} />

          {/* Grace Day (Story 5.1): "the Day summary" entry point FR-17's own AC names,
              alongside a Ledger row — never only inside a future Silence intervention. Says
              nothing at all when nothing is graceable, the same "nothing it cannot support"
              rule the rest of this screen already keeps. */}
          {view.graceRows.map((row) => {
            const rowGrace: GraceRowState = graceState[row.day] ?? { kind: 'idle' };

            return (
              <div
                className="row row-grace"
                key={row.day}
                role="group"
                aria-label={`Grace Day, ${row.day}`}
              >
                <div className="row-main">
                  <div className="row-name">{row.day}</div>
                  {rowGrace.kind === 'spent' ? (
                    <p role="status">{GRACE_DAY_COPY.spent}</p>
                  ) : (
                    <>
                      <button
                        type="button"
                        // Distinguishes one row's control from every other's for a
                        // screen-reader user, the same fix `components/ledger.tsx`'s
                        // identical control needed.
                        aria-label={`Spend a Grace Day for ${row.day}`}
                        onClick={() => void spendGraceDay(row.day)}
                        disabled={rowGrace.kind === 'spending' || view.graceRemaining <= 0}
                      >
                        {rowGrace.kind === 'spending'
                          ? GRACE_DAY_COPY.spending
                          : GRACE_DAY_COPY.spend}
                      </button>
                      <span className="row-muted">{formatGraceAllowance(view.graceRemaining)}</span>
                    </>
                  )}
                  {rowGrace.kind === 'failed' && (
                    <p role="status">
                      <strong>{GRACE_DAY_COPY.failed}</strong> {rowGrace.reason}
                    </p>
                  )}
                </div>
              </div>
            );
          })}
        </>
      )}
    </section>
  );
}
