'use client';

import { useState } from 'react';
import {
  CADENCE_LABELS,
  COMMITMENT_CADENCES,
  COMMITMENT_KINDS,
  EMPTY_DRAFT,
  KIND_LABELS,
  LATE_WINDOW_MAX_MINUTES,
  LATE_WINDOW_MIN_MINUTES,
  TIMED_COMMITMENT_COPY,
  type CommitmentCadence,
  type CommitmentDraft,
  type CommitmentKind,
  autoChecksPossible,
  canBeTimed,
  draftProblems,
  requiredTargets,
  withCadence,
  withDueTime,
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
  const checksPossible = autoChecksPossible(draft.kind, draft.cadence);
  const autoCheckActive = checksPossible && draft.autoCheckEnabled;
  const timeable = canBeTimed(draft.kind, draft.cadence);

  function set<K extends keyof CommitmentDraft>(key: K, value: CommitmentDraft[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
  }

  return (
    <section className="stack">
      <h2>{initial ? 'Edit commitment' : 'New commitment'}</h2>

      {/* What the commitment is. The fields carry their own block spacing, which is the one
          place in this product a flow layout still reads better than a `gap` — a label sits
          tight against its own control and loose from the next one, and that pairing is what
          makes a form scannable. */}
      <div className="card card-pad">
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

        {/* A time is optional and stays optional: leaving it blank is the behaviour every
            commitment had before Story 6.1. It is offered only where there is a moment to
            name — an abstention has none, and an Hours-per-day commitment is judged by banked
            minutes rather than by an instant. */}
        {timeable && (
          <>
            <label htmlFor="commitment-due-time">Time of day</label>
            <input
              id="commitment-due-time"
              type="time"
              value={draft.dueTime ?? ''}
              // Switching a time on brings its window with it. Asking for the two separately
              // would show a problem the author had not yet had a chance to cause.
              onChange={(event) =>
                setDraft((current) =>
                  withDueTime(current, event.target.value === '' ? null : event.target.value),
                )
              }
            />

            {draft.dueTime !== null && (
              <>
                <label htmlFor="commitment-late-window">Late window, in minutes</label>
                <input
                  id="commitment-late-window"
                  type="number"
                  min={LATE_WINDOW_MIN_MINUTES}
                  max={LATE_WINDOW_MAX_MINUTES}
                  value={draft.lateWindowMinutes ?? ''}
                  onChange={(event) =>
                    set(
                      'lateWindowMinutes',
                      event.target.value === '' ? null : Number(event.target.value),
                    )
                  }
                />

                {/* The trade a time makes: three days to answer becomes a deadline at
                    midnight. Said here, once, rather than discovered at the end of a month. */}
                <p className="row-muted">{TIMED_COMMITMENT_COPY.warning}</p>
              </>
            )}
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

        {/* Story 6.8. Offered on every Kind and every Cadence, unlike the time above: a photo
            that decides nothing is meaningless for none of them, and an Avoid-it commitment —
            the one kind that can never carry a time — is exactly the case this exists for.

            It carries no warning sentence, deliberately. `TIMED_COMMITMENT_COPY.warning` exists
            because a missing photo on a timed commitment costs 500,000₫; here nothing is at
            stake, and a warning would be a lie about the stakes. The line below says what is
            true instead.

            Two sentences rather than one, because no single one is true of both cases. With a
            time set, `TIMED_COMMITMENT_COPY.warning` is on screen saying the photo settles the
            day, and a line beside it saying the photo decides nothing would contradict it — and
            Today suppresses this control for a timed row anyway, so the honest thing to say is
            that marking it changes nothing. The untimed sentence deliberately does not name what
            *does* settle the day: the morning answer does for a Do-it daily, but an Hours-per-day
            commitment is judged by banked Focus minutes and never by a declaration at all. */}
        <p>
          <label>
            <input
              type="checkbox"
              checked={draft.requiresPhoto}
              onChange={(event) => set('requiresPhoto', event.target.checked)}
            />{' '}
            Keep a photo against this
          </label>
        </p>
        <p className="row-muted">
          {draft.dueTime === null
            ? 'Your own record, for any day you want one. Nothing reads it: it never decides a day, and a day with no photo ends exactly as it would have ended anyway.'
            : 'This one already keeps a photo — the timed proof above, which does decide its day. Marking it here adds nothing while it has a time.'}
        </p>
      </div>

      {/* Its own frame: what can watch this commitment is a separate question from what the
          commitment is, and on most kinds the answer is "nothing". */}
      <div className="card card-pad">
        <h3>Auto-checks</h3>
        {checksPossible ? (
          <p className="row-muted">
            Location with dwell, Phone movement and Timer don&apos;t run yet — Epic 4 builds them.
            Until then, and unless Account elsewhere is linked below, every commitment is settled by
            your morning answer.
          </p>
        ) : draft.kind === 'abstain' ? (
          <p className="row-muted">
            Nothing can check this one. There is no sensor for a thing not done, so your morning
            answer is the record — and the only record.
          </p>
        ) : (
          <p className="row-muted">
            Nothing can check this one. An Hours-per-day commitment is judged by the time you bank,
            never by a morning answer, so there is nothing an Auto-check could report.
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

          {autoCheckActive && (
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
      </div>

      {draft.carriesPenalty && autoCheckActive && (
        <p className="row-muted">
          Because this costs money and has an Auto-check attached, the Auto-check&apos;s result will
          stand once it reports a miss — you won&apos;t be able to correct it yourself.
        </p>
      )}

      {problems.length > 0 && (
        <ul className="row-muted">
          {problems.map((problem) => (
            <li key={problem}>{problem}</li>
          ))}
        </ul>
      )}

      <div className="actions">
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
      </div>

      {onDelete &&
        (confirmingDelete ? (
          <>
            <p className="row-muted">
              Delete <strong>{draft.name}</strong>? Its history stays in the ledger; it just stops
              appearing here.
            </p>
            <div className="actions">
              <button type="button" className="destructive" disabled={busy} onClick={onDelete}>
                Yes, delete it
              </button>
              <button type="button" disabled={busy} onClick={() => setConfirmingDelete(false)}>
                Keep it
              </button>
            </div>
          </>
        ) : (
          <div className="actions">
            <button type="button" className="destructive" onClick={() => setConfirmingDelete(true)}>
              Delete
            </button>
          </div>
        ))}
    </section>
  );
}
