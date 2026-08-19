'use client';

import { useEffect, useState } from 'react';
import { CommitmentRow, type RowCommitment } from '@/components/commitment-row';
import { stateToday } from '@/lib/commitment-state';
import { createClient } from '@/lib/supabase/client';

type View =
  | { kind: 'loading' }
  | { kind: 'ready'; rows: RowCommitment[] }
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
export function Today() {
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const { data, error } = await createClient()
        .from('commitment')
        .select(SELECT)
        .is('archived_at', null)
        .order('created_at');

      if (cancelled) return;
      if (error) {
        setView({ kind: 'failed', reason: error.message });
        return;
      }
      setView({ kind: 'ready', rows: (data ?? []) as RowCommitment[] });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <section>
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

      {view.kind === 'ready' &&
        view.rows.map((row) => (
          <CommitmentRow key={row.id} commitment={row} state={stateToday(row)} />
        ))}
    </section>
  );
}
