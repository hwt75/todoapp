'use client';

import { useEffect, useState } from 'react';
import { CommitmentRow, type RowCommitment } from '@/components/commitment-row';
import { stateToday } from '@/lib/commitment-state';
import { createClient } from '@/lib/supabase/client';
import { DebtBlock } from '@/components/debt-block';
import { totalOwed } from '@/lib/money';
import type { WeeklyQuotaPosition } from '@/lib/weekly-quota';

type View =
  | { kind: 'loading' }
  | {
      kind: 'ready';
      rows: RowCommitment[];
      owedDong: number;
      chains: Record<string, number>;
      quotas: Record<string, WeeklyQuotaPosition>;
    }
  | { kind: 'failed'; reason: string };

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
  onOpenLedger,
  onOpenChain,
  onOpenFocus,
}: {
  onOpenLedger: () => void;
  onOpenChain: (commitment: RowCommitment) => void;
  /** Where a *Put hours in* row goes instead. See the fork below. */
  onOpenFocus: (commitment: RowCommitment) => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const supabase = createClient();
      const [{ data, error }, { data: penalties }, { data: chains }, { data: quotas }] =
        await Promise.all([
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
        ]);

      if (cancelled) return;
      if (error) {
        setView({ kind: 'failed', reason: error.message });
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
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    /* The debt block is drawn first and read last, and that is not a styling accident.
       EXPERIENCE.md requires the commitment rows to be announced before it: a sighted
       reader can look past the figure, a VoiceOver user cannot skip what is read to them,
       and being told your own debt first thing every morning is a cost this product does
       not need to add. So the DOM order is rows-then-figure and CSS `order` puts the
       figure on top. */
    <section className="today">
      <h1>Today</h1>

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
        </>
      )}
    </section>
  );
}
