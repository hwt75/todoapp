'use client';

import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { CommitmentForm } from '@/components/commitment-form';
import {
  CADENCE_LABELS,
  KIND_LABELS,
  type CommitmentCadence,
  type CommitmentDraft,
  type CommitmentKind,
  toRow,
} from '@/lib/commitment';

interface CommitmentRow {
  id: string;
  name: string;
  kind: CommitmentKind;
  cadence: CommitmentCadence;
  carries_penalty: boolean;
  weekly_target: number | null;
  week_start_day: number | null;
  daily_minutes_target: number | null;
}

type View =
  | { kind: 'loading' }
  | { kind: 'list' }
  | { kind: 'new' }
  | { kind: 'edit'; row: CommitmentRow }
  | { kind: 'failed'; reason: string };

const SELECT =
  'id,name,kind,cadence,carries_penalty,weekly_target,week_start_day,daily_minutes_target';

/** The one query both the first load and every refresh use, so they cannot drift apart. */
function fetchCommitments() {
  return createClient()
    .from('commitment')
    .select(SELECT)
    .is('archived_at', null)
    .order('created_at');
}

function toDraft(row: CommitmentRow): CommitmentDraft {
  return {
    name: row.name,
    kind: row.kind,
    cadence: row.cadence,
    carriesPenalty: row.carries_penalty,
    weeklyTarget: row.weekly_target,
    weekStartDay: row.week_start_day,
    dailyMinutesTarget: row.daily_minutes_target,
  };
}

/** How a commitment reads in one line, without its own row having to carry any colour. */
function describe(row: CommitmentRow): string {
  const parts = [KIND_LABELS[row.kind], CADENCE_LABELS[row.cadence]];
  if (row.weekly_target !== null) parts.push(`${row.weekly_target}×`);
  if (row.daily_minutes_target !== null) parts.push(`${row.daily_minutes_target / 60}h`);
  return parts.join(' · ');
}

/**
 * The author's commitments, and the surface for changing them.
 *
 * Reads and writes go through RLS: a row that is not this account's is invisible rather
 * than refused, and a write for another owner is rejected by policy. Nothing here filters
 * by owner — doing so would put an access decision in the client, which AD-7 forbids.
 */
export function CommitmentList({ ownerId }: { ownerId: string }) {
  const [view, setView] = useState<View>({ kind: 'loading' });
  const [rows, setRows] = useState<CommitmentRow[]>([]);
  const [busy, setBusy] = useState(false);

  // Plain function, not a useCallback the effect depends on: the React Compiler rejects
  // an effect whose dependency sets state, and it is right — the effect should own its
  // first load and nothing else should re-trigger it.
  async function reload() {
    const { data, error } = await fetchCommitments();
    if (error) {
      setView({ kind: 'failed', reason: error.message });
      return;
    }
    setRows((data ?? []) as CommitmentRow[]);
    setView({ kind: 'list' });
  }

  useEffect(() => {
    let cancelled = false;

    async function first() {
      const { data, error } = await fetchCommitments();
      if (cancelled) return;

      if (error) {
        setView({ kind: 'failed', reason: error.message });
        return;
      }
      setRows((data ?? []) as CommitmentRow[]);
      setView({ kind: 'list' });
    }

    void first();
    return () => {
      cancelled = true;
    };
  }, []);

  async function save(draft: CommitmentDraft, existing?: CommitmentRow) {
    setBusy(true);
    const supabase = createClient();

    // AD-4: the key is generated here, at the moment of the action, so a retry of this
    // same save reuses it and cannot produce a second commitment.
    const idempotencyKey = crypto.randomUUID();
    const row = toRow(draft, ownerId, idempotencyKey);

    const { error } = existing
      ? await supabase
          .from('commitment')
          .update({ ...row, idempotency_key: undefined, owner_id: undefined })
          .eq('id', existing.id)
      : // Upsert that ignores a duplicate rather than insert that raises one. AD-4 wants a
        // retry to land once; a unique-violation error would land once and then tell the
        // author his save failed when it had already succeeded, which is the worse of the
        // two lies on a screen about commitments he is held to.
        await supabase
          .from('commitment')
          .upsert(row, { onConflict: 'idempotency_key', ignoreDuplicates: true });

    setBusy(false);
    if (error) {
      setView({ kind: 'failed', reason: error.message });
      return;
    }
    await reload();
  }

  async function archive(row: CommitmentRow) {
    setBusy(true);
    // Archive, not delete. Every declaration, failed day and penalty that touched this
    // commitment still points at it, and a ledger that cannot name what was missed has
    // stopped explaining itself.
    const { error } = await createClient()
      .from('commitment')
      .update({ archived_at: new Date().toISOString() })
      .eq('id', row.id);

    setBusy(false);
    if (error) {
      setView({ kind: 'failed', reason: error.message });
      return;
    }
    await reload();
  }

  if (view.kind === 'loading') {
    return (
      <section>
        <h2>Commitments</h2>
        <p>Working…</p>
      </section>
    );
  }

  if (view.kind === 'new') {
    return (
      <CommitmentForm
        busy={busy}
        onSave={(draft) => void save(draft)}
        onCancel={() => setView({ kind: 'list' })}
      />
    );
  }

  if (view.kind === 'edit') {
    return (
      <CommitmentForm
        initial={toDraft(view.row)}
        busy={busy}
        onSave={(draft) => void save(draft, view.row)}
        onCancel={() => setView({ kind: 'list' })}
        onDelete={() => void archive(view.row)}
      />
    );
  }

  return (
    <section>
      <h2>Commitments</h2>

      {view.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {view.reason}
        </p>
      )}

      {rows.length === 0 && <p className="row-muted">Nothing yet.</p>}

      {rows.map((row) => (
        <div className="row" key={row.id}>
          <div>
            <strong>{row.name}</strong>{' '}
            {/* The pill carries whatever colour there is; the row itself stays neutral. */}
            {row.carries_penalty && <span className="pill pill-neutral">costs money</span>}
          </div>
          <div className="row-muted">{describe(row)}</div>
          <button type="button" onClick={() => setView({ kind: 'edit', row })}>
            Edit
          </button>
        </div>
      ))}

      <button type="button" className="action" onClick={() => setView({ kind: 'new' })}>
        New commitment
      </button>
    </section>
  );
}
