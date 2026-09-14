'use client';

import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { CommitmentForm } from '@/components/commitment-form';
import { calendarMoment } from '@/lib/declaration';
import { readRefereeReach } from '@/lib/evidence';
import {
  CADENCE_LABELS,
  KIND_LABELS,
  type AutoCheckKind,
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
  auto_check_kind: AutoCheckKind | null;
  auto_check_account_ref: string | null;
  auto_check_last_checked_at: string | null;
  /** `HH:MM:SS` — Postgres renders a `time` with its seconds, which are always zero here. */
  due_time: string | null;
  late_window_minutes: number | null;
  /** Story 6.8: whether the author keeps a photo against this one. Never read by settlement. */
  requires_photo: boolean;
  /** Story 8.1: whether this one asks the paired referee to sign its day off. */
  requires_referee_approval: boolean;
}

type View =
  | { kind: 'loading' }
  | { kind: 'list' }
  | { kind: 'new' }
  | { kind: 'edit'; row: CommitmentRow }
  | { kind: 'failed'; reason: string };

const SELECT =
  'id,name,kind,cadence,carries_penalty,weekly_target,week_start_day,daily_minutes_target,auto_check_kind,auto_check_account_ref,auto_check_last_checked_at,due_time,late_window_minutes,requires_photo,requires_referee_approval';

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
    autoCheckEnabled: row.auto_check_kind !== null,
    autoCheckAccountRef: row.auto_check_account_ref ?? '',
    // `20:00:00` back to `20:00`. The draft carries what `<input type="time">` both renders
    // and produces, so an edit that never touches the field sends back exactly what it read.
    dueTime: row.due_time === null ? null : row.due_time.slice(0, 5),
    lateWindowMinutes: row.late_window_minutes,
    // Read back so an edit that never touches the checkbox cannot silently turn it off — the
    // column is `not null default false`, so a row written before Story 6.8 reads as false.
    requiresPhoto: row.requires_photo,
    // Read back for the same reason, and with more at stake: this one appends to an
    // append-only log on every change, so a flag lost on a round trip would be recorded as a
    // decision the author never made.
    requiresRefereeApproval: row.requires_referee_approval,
  };
}

/** How a commitment reads in one line, without its own row having to carry any colour. */
function describe(row: CommitmentRow): string {
  const parts = [KIND_LABELS[row.kind], CADENCE_LABELS[row.cadence]];
  if (row.weekly_target !== null) parts.push(`${row.weekly_target}×`);
  if (row.daily_minutes_target !== null) parts.push(`${row.daily_minutes_target / 60}h`);
  if (row.due_time !== null) {
    parts.push(`${row.due_time.slice(0, 5)} +${row.late_window_minutes}m`);
  }
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
  // `save()` writes to `commitment` directly, so there is no server hop where the pairing could
  // be read in passing. The form cannot read it either — `profile.referee_of` is on the
  // referee's own row and `profile: read own` hides it — so this is asked for explicitly and
  // passed down.
  //
  // Three states, not two, and the third is the point. `undefined` means nobody has asked yet or
  // the asking failed, and it is not the same as `false`. Collapsing them makes the form stricter
  // than the rule it mirrors: `commitment_sign_off_needs_a_referee()` refuses only a write that
  // turns the flag on, so a commitment already flagged stays editable whatever the pairing says —
  // and a form told `false` on a failed request would disable both the save and the control,
  // locking the author out of his own row.
  const [hasReferee, setHasReferee] = useState<boolean | undefined>(undefined);
  /** The pairing read's own failure, said out loud rather than collapsed into "no referee". */
  const [pairingFailed, setPairingFailed] = useState<string | null>(null);
  /**
   * Story 8.3: whether the commitment being edited asked for the referee's signature **as of
   * today**, which is not the same as `row.requires_referee_approval` for the rest of any day the
   * author moves the flag. `undefined` until asked, and on a failure — `hasReferee`'s own three
   * states, for the same reason: an unknown must not be read as a `false` that would make the
   * form say the photograph decides nothing.
   */
  const [signOffRead, setSignOffRead] = useState<{
    id: string;
    signedOff: boolean | undefined;
  } | null>(null);

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

    // Its own request, and its failure is not the list's failure: a commitments screen that
    // refuses to draw because one boolean could not be read is the larger loss. But the failure
    // is not swallowed either — it leaves `hasReferee` undefined, which is what stops the form
    // refusing a save it has no business refusing, and says so on screen.
    async function pairing() {
      const { data, error } = await createClient().rpc('has_paired_referee');
      if (cancelled) return;

      if (error) {
        setPairingFailed(error.message);
        return;
      }
      setHasReferee(data === true);
    }

    void first();
    void pairing();
    return () => {
      cancelled = true;
    };
  }, []);

  /**
   * Story 8.3 — the flag as of today for the commitment being edited.
   *
   * Its own effect and its own request, keyed on which row is open: the pairing read above
   * answers about the account and is asked once, this answers about one commitment and one day
   * and has to be asked again every time a different row is opened.
   *
   * Reset to `undefined` before each read for the reason `components/today.tsx`'s own reach
   * effect gives — the previous row's answer left in place would describe this row, and on the
   * flagged→unflagged pair that is the exact wrong sentence. A failure leaves it `undefined`
   * too, which falls back to the draft flag: the reading this form made before Story 8.3, wrong
   * only in the window the story is about, rather than a screen that cannot describe itself.
   */
  const editingId = view.kind === 'edit' ? view.row.id : null;

  useEffect(() => {
    let cancelled = false;

    if (editingId === null) return;

    async function read() {
      const id = editingId as string;
      const answer = await readRefereeReach([id], calendarMoment(new Date()).day, {
        cancelled: () => cancelled,
      });
      if (cancelled) return;
      setSignOffRead({ id, signedOff: answer.reach.get(id) });
    }

    void read();
    return () => {
      cancelled = true;
    };
  }, [editingId]);

  /**
   * The as-of answer, but only if it is about the row now open.
   *
   * **Stamped with its commitment id and discarded by mismatch, rather than cleared when a new
   * read goes out** — `components/today.tsx`'s reach read is keyed by its day for the same
   * reason. Opening a flagged row and then an unflagged one would otherwise describe the second
   * with the first's answer for a whole round trip, which is precisely the wrong sentence. It
   * also keeps the effect free of a synchronous `setState`, which `react-hooks/set-state-in-effect`
   * refuses and which would cost a render on every open that had nothing to clear.
   *
   * `undefined` for a row nobody has answered for yet, for a read that failed, and for a
   * commitment being created — the form falls back to the draft flag in all three, which is the
   * reading it made before Story 8.3.
   */
  const signedOffToday = signOffRead?.id === editingId ? signOffRead.signedOff : undefined;

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
        hasReferee={hasReferee}
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
        autoCheckLastCheckedAt={view.row.auto_check_last_checked_at}
        hasReferee={hasReferee}
        signedOffToday={signedOffToday}
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

      {/* Said rather than swallowed. The list itself is fine — this only means the sign-off
          control cannot be greyed on a known answer, so the database will be the one to refuse
          a flag with nobody to ask. */}
      {pairingFailed !== null && (
        <p className="row-muted">Could not check whether a referee is paired. {pairingFailed}</p>
      )}

      {rows.length === 0 && <p className="row-muted">Nothing yet.</p>}

      {rows.length > 0 && (
        <div className="card">
          {rows.map((row) => (
            <div className="row" key={row.id}>
              <div>
                <strong>{row.name}</strong>{' '}
                {/* Plain text, not a pill. A pill carries *state* — a chain count, a quota
                position, a ledger outcome — and "costs money" is configuration. Spending
                the pill vocabulary on a setting would blunt it where it has to be read at
                a glance. */}
                {row.carries_penalty && <span className="row-muted"> · costs money</span>}
              </div>
              <div className="row-muted">{describe(row)}</div>
              <button type="button" onClick={() => setView({ kind: 'edit', row })}>
                Edit
              </button>
            </div>
          ))}
        </div>
      )}

      <div className="actions">
        <button type="button" className="action" onClick={() => setView({ kind: 'new' })}>
          New commitment
        </button>
      </div>
    </section>
  );
}
