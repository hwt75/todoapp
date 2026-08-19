'use client';

import { useEffect, useState } from 'react';
import { CommitmentRow, type RowCommitment } from '@/components/commitment-row';
import { stateToday } from '@/lib/commitment-state';
import { createClient } from '@/lib/supabase/client';
import { DebtBlock } from '@/components/debt-block';
import { totalOwed } from '@/lib/money';

type View =
  | { kind: 'loading' }
  | { kind: 'ready'; rows: RowCommitment[]; owedDong: number }
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
export function Today({ onOpenLedger }: { onOpenLedger: () => void }) {
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const supabase = createClient();
      const [{ data, error }, { data: penalties }] = await Promise.all([
        supabase.from('commitment').select(SELECT).is('archived_at', null).order('created_at'),
        supabase.from('penalty').select('amount_dong').eq('state', 'owed'),
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
              <CommitmentRow key={row.id} commitment={row} state={stateToday(row)} />
            ))}
          </div>

          <DebtBlock totalDong={view.owedDong} onOpen={onOpenLedger} />
        </>
      )}
    </section>
  );
}
