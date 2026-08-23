'use client';

import { useState } from 'react';
import {
  CADENCE_LABELS,
  COMMITMENT_CADENCES,
  COMMITMENT_KINDS,
  EMPTY_DRAFT,
  KIND_LABELS,
  type CommitmentCadence,
  type CommitmentDraft,
  type CommitmentKind,
  autoChecksPossible,
  draftProblems,
  requiredTargets,
  withCadence,
  withKind,
} from '@/lib/commitment';

const WEEKDAYS = [
  [1, 'Monday'],
  [2, 'Tuesday'],
  [3, 'Wednesday'],
  [4, 'Thursday'],
  [5, 'Friday'],
  [6, 'Saturday'],
  [7, 'Sunday'],
] as const;

/** The Auto-checks still unbuilt. Location/Phone/Timer stay disabled placeholders (Epic 4). */
const UNBUILT_AUTO_CHECKS = ['Location with dwell', 'Phone movement', 'Timer'];

interface Props {
  initial?: CommitmentDraft;
  busy?: boolean;
  /** When the resolution pass last looked at this commitment, for the "last read" display. */
  autoCheckLastCheckedAt?: string | null;
  onSave: (draft: CommitmentDraft) => void;
  onCancel: () => void;
  onDelete?: () => void;
}

/**
 * Create or edit one commitment.
 *
 * Every rule about what a valid commitment is lives in `lib/commitment.ts` and, actually,
 * in the migration's check constraints. This form asks and shows; it does not decide.
 */
export function CommitmentForm({
  initial,
  busy = false,
  autoCheckLastCheckedAt,
  onSave,
  onCancel,
  onDelete,
}: Props) {
  const [draft, setDraft] = useState<CommitmentDraft>(initial ?? EMPTY_DRAFT);
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  const problems = draftProblems(draft);
  const targets = requiredTargets(draft.cadence);
  const checksPossible = autoChecksPossible(draft.kind);

  function set<K extends keyof CommitmentDraft>(key: K, value: CommitmentDraft[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
  }

  return (
    <section>
      <h2>{initial ? 'Edit commitment' : 'New commitment'}</h2>

      <label htmlFor="commitment-name">Name</label>
      <input
        id="commitment-name"
        type="text"
        value={draft.name}
        placeholder="Gym"
        onChange={(event) => set('name', event.target.value)}
      />

      <label htmlFor="commitment-kind">Kind</label>
      <select
        id="commitment-kind"
        value={draft.kind}
        // Switching to a kind with no sensor for it clears any Auto-check attached, the
        // same way the Cadence select clears a stale target — otherwise a checked box
        // could end up disabled with no way left to uncheck it.
        onChange={(event) =>
          setDraft((current) => withKind(current, event.target.value as CommitmentKind))
        }
      >
        {COMMITMENT_KINDS.map((kind) => (
          <option key={kind} value={kind}>
            {KIND_LABELS[kind]}
          </option>
        ))}
      </select>

      <label htmlFor="commitment-cadence">Cadence</label>
      <select
        id="commitment-cadence"
        value={draft.cadence}
        // Switching clears whatever the previous cadence needed, so a stale target can
        // never survive the change and be refused by a constraint the author never saw.
        onChange={(event) =>
          setDraft((current) => withCadence(current, event.target.value as CommitmentCadence))
        }
      >
        {COMMITMENT_CADENCES.map((cadence) => (
          <option key={cadence} value={cadence}>
            {CADENCE_LABELS[cadence]}
          </option>
        ))}
      </select>

      {targets.includes('weeklyTarget') && (
        <>
          <label htmlFor="commitment-weekly">Times a week</label>
          <input
            id="commitment-weekly"
            type="number"
            min={1}
            max={7}
            value={draft.weeklyTarget ?? ''}
            onChange={(event) =>
              set('weeklyTarget', event.target.value === '' ? null : Number(event.target.value))
            }
          />
        </>
      )}

      {targets.includes('weekStartDay') && (
        <>
          <label htmlFor="commitment-week-start">Week starts on</label>
          <select
            id="commitment-week-start"
            value={draft.weekStartDay ?? ''}
            onChange={(event) =>
              set('weekStartDay', event.target.value === '' ? null : Number(event.target.value))
            }
          >
            <option value="">Choose a day</option>
            {WEEKDAYS.map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </>
      )}

      {targets.includes('dailyMinutesTarget') && (
        <>
          <label htmlFor="commitment-hours">Hours a day</label>
          <input
            id="commitment-hours"
            type="number"
            min={0.5}
            step={0.5}
            // Shown in hours, stored in minutes. One unit at rest means no rounding
            // decision is ever made twice.
            value={draft.dailyMinutesTarget === null ? '' : draft.dailyMinutesTarget / 60}
            onChange={(event) =>
              set(
                'dailyMinutesTarget',
                event.target.value === '' ? null : Math.round(Number(event.target.value) * 60),
              )
            }
          />
        </>
      )}

      <p>
        <label>
          <input
            type="checkbox"
            checked={draft.carriesPenalty}
            onChange={(event) => set('carriesPenalty', event.target.checked)}
          />{' '}
          Missing this costs money
        </label>
      </p>

      <h3>Auto-checks</h3>
      {checksPossible ? (
        <p className="row-muted">
          Location, Phone movement and Timer don&apos;t run yet — Epic 4 builds them. Until then,
          and unless Account elsewhere is linked below, every commitment is settled by your morning
          answer.
        </p>
      ) : (
        <p className="row-muted">
          Nothing can check this one. There is no sensor for a thing not done, so your morning
          answer is the record — and the only record.
        </p>
      )}
      <p>
        <label style={{ display: 'block' }}>
          <input
            type="checkbox"
            disabled={!checksPossible}
            checked={draft.autoCheckEnabled}
            onChange={(event) => set('autoCheckEnabled', event.target.checked)}
          />{' '}
          Account elsewhere
        </label>

        {checksPossible && draft.autoCheckEnabled && (
          <>
            <label htmlFor="commitment-auto-check-ref">Account</label>
            <input
              id="commitment-auto-check-ref"
              type="text"
              value={draft.autoCheckAccountRef}
              placeholder="How you're identified there"
              onChange={(event) => set('autoCheckAccountRef', event.target.value)}
            />
            {autoCheckLastCheckedAt !== undefined && (
              <p className="row-muted">
                {autoCheckLastCheckedAt
                  ? `Last read ${new Date(autoCheckLastCheckedAt).toLocaleString()}`
                  : 'Not read yet.'}
              </p>
            )}
          </>
        )}

        {UNBUILT_AUTO_CHECKS.map((check) => (
          <label key={check} style={{ display: 'block' }}>
            <input type="checkbox" disabled checked={false} readOnly /> {check}
          </label>
        ))}
      </p>

      {problems.length > 0 && (
        <ul className="row-muted">
          {problems.map((problem) => (
            <li key={problem}>{problem}</li>
          ))}
        </ul>
      )}

      <button
        type="button"
        className="action"
        disabled={busy || problems.length > 0}
        onClick={() => onSave(draft)}
      >
        Save
      </button>
      <button type="button" disabled={busy} onClick={onCancel}>
        Cancel
      </button>

      {onDelete &&
        (confirmingDelete ? (
          <>
            <p className="row-muted">
              Delete <strong>{draft.name}</strong>? Its history stays in the ledger; it just stops
              appearing here.
            </p>
            <button type="button" className="destructive" disabled={busy} onClick={onDelete}>
              Yes, delete it
            </button>
            <button type="button" disabled={busy} onClick={() => setConfirmingDelete(false)}>
              Keep it
            </button>
          </>
        ) : (
          <button type="button" className="destructive" onClick={() => setConfirmingDelete(true)}>
            Delete
          </button>
        ))}
    </section>
  );
}
