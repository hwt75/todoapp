/**
 * What a commitment is, as rules rather than as a form.
 *
 * The database enforces all of this with check constraints and is the actual authority.
 * This module exists so the same rules can be tested without a database, and so the form
 * can refuse a bad draft before spending a round trip on it — never so the form becomes
 * the enforcement point. A rule that lives only in a component is a rule only a browser
 * can exercise, which is how it stops being exercised.
 */

export type CommitmentKind = 'do' | 'abstain' | 'open_ended';
export type CommitmentCadence = 'daily' | 'weekly_quota' | 'daily_hours_quota';

export const COMMITMENT_KINDS: readonly CommitmentKind[] = ['do', 'abstain', 'open_ended'];
export const COMMITMENT_CADENCES: readonly CommitmentCadence[] = [
  'daily',
  'weekly_quota',
  'daily_hours_quota',
];

/** What the author sees. `Do it / Avoid it / Put hours in`, per the story's own wording. */
export const KIND_LABELS: Record<CommitmentKind, string> = {
  do: 'Do it',
  abstain: 'Avoid it',
  open_ended: 'Put hours in',
};

export const CADENCE_LABELS: Record<CommitmentCadence, string> = {
  daily: 'Every day',
  weekly_quota: 'Times a week',
  daily_hours_quota: 'Hours per day',
};

/** The one Auto-check kind wired up so far (Story 4.1). Location/Phone/Timer stay placeholders. */
export type AutoCheckKind = 'account_elsewhere';

export interface CommitmentDraft {
  name: string;
  kind: CommitmentKind;
  cadence: CommitmentCadence;
  carriesPenalty: boolean;
  weeklyTarget: number | null;
  /** ISO-8601 day numbering, 1 = Monday. */
  weekStartDay: number | null;
  /** Minutes, never hours — one unit at rest, so no rounding decision is made twice. */
  dailyMinutesTarget: number | null;
  /** Whether the Account-elsewhere Auto-check is attached to this commitment. */
  autoCheckEnabled: boolean;
  /** What the author typed to identify the account elsewhere. Saved as-is, no validation. */
  autoCheckAccountRef: string;
}

/**
 * A blank commitment. `carriesPenalty` is false and that is the point: money is never a
 * default, and turning it on has to be a deliberate act.
 */
export const EMPTY_DRAFT: CommitmentDraft = {
  name: '',
  kind: 'do',
  cadence: 'daily',
  carriesPenalty: false,
  weeklyTarget: null,
  weekStartDay: null,
  dailyMinutesTarget: null,
  autoCheckEnabled: false,
  autoCheckAccountRef: '',
};

export type TargetField = 'weeklyTarget' | 'weekStartDay' | 'dailyMinutesTarget';

/** Which targets a cadence needs. Everything else must be left null. */
export function requiredTargets(cadence: CommitmentCadence): TargetField[] {
  switch (cadence) {
    case 'weekly_quota':
      return ['weeklyTarget', 'weekStartDay'];
    case 'daily_hours_quota':
      return ['dailyMinutesTarget'];
    case 'daily':
      return [];
  }
}

/**
 * Whether any Auto-check could ever apply.
 *
 * Nothing can observe an abstention — there is no sensor for a thing not done, and no
 * account elsewhere that records it. Those commitments are settled by the author's
 * morning answer and nothing else, which the setup screen has to say out loud rather
 * than leaving the controls merely greyed.
 */
export function autoChecksPossible(kind: CommitmentKind): boolean {
  return kind !== 'abstain';
}

/**
 * Every reason a draft cannot be saved, in the order a reader would meet them.
 *
 * Returns messages rather than a boolean so the form can show which field is wrong. An
 * empty array means the database would accept it — the constraints here mirror the ones
 * in `20260819150000_commitment.sql`, and the migration is what actually decides.
 */
export function draftProblems(draft: CommitmentDraft): string[] {
  const problems: string[] = [];

  if (draft.name.trim() === '') {
    problems.push('A commitment needs a name.');
  }

  const required = requiredTargets(draft.cadence);

  if (required.includes('weeklyTarget')) {
    if (draft.weeklyTarget === null) {
      problems.push('How many times a week?');
    } else if (
      !Number.isInteger(draft.weeklyTarget) ||
      draft.weeklyTarget < 1 ||
      draft.weeklyTarget > 7
    ) {
      problems.push('Times a week must be a whole number from 1 to 7.');
    }
  }

  if (required.includes('weekStartDay')) {
    if (draft.weekStartDay === null) {
      problems.push('Which day does the week start?');
    } else if (
      !Number.isInteger(draft.weekStartDay) ||
      draft.weekStartDay < 1 ||
      draft.weekStartDay > 7
    ) {
      problems.push('Week start must be a day from Monday (1) to Sunday (7).');
    }
  }

  if (required.includes('dailyMinutesTarget')) {
    if (draft.dailyMinutesTarget === null) {
      problems.push('How many hours a day?');
    } else if (!Number.isInteger(draft.dailyMinutesTarget) || draft.dailyMinutesTarget <= 0) {
      problems.push('Hours per day must be more than zero.');
    }
  }

  // A target left over from a cadence the author switched away from would be refused by
  // the database, and the message it gives names a constraint rather than a field.
  const ALL_TARGETS: TargetField[] = ['weeklyTarget', 'weekStartDay', 'dailyMinutesTarget'];
  for (const field of ALL_TARGETS) {
    if (!required.includes(field) && draft[field] !== null) {
      problems.push(`${field} does not belong to a ${CADENCE_LABELS[draft.cadence]} commitment.`);
    }
  }

  if (draft.autoCheckEnabled) {
    // Mirrors `autoChecksPossible()`: there is no sensor for a thing not done, so an
    // Auto-check can never attach to an abstention — refused here and by the database's
    // own `commitment_auto_check_not_on_abstain` check.
    if (!autoChecksPossible(draft.kind)) {
      problems.push('Nothing can check an Avoid-it commitment automatically.');
    }
    if (draft.autoCheckAccountRef.trim() === '') {
      problems.push('Account elsewhere needs an account identifier to check.');
    }
  }

  return problems;
}

/**
 * Clears the Auto-check when switching to a kind that can't carry one, so a checked-but-
 * disabled box can never be left with no way to uncheck it (`autoChecksPossible()` would
 * refuse the save anyway — this is what keeps the control itself from becoming a dead end).
 */
export function withKind(draft: CommitmentDraft, kind: CommitmentKind): CommitmentDraft {
  const checksPossible = autoChecksPossible(kind);
  return {
    ...draft,
    kind,
    autoCheckEnabled: checksPossible ? draft.autoCheckEnabled : false,
    autoCheckAccountRef: checksPossible ? draft.autoCheckAccountRef : '',
  };
}

/** Clears whatever the previous cadence needed, so switching cadence cannot leave a stale target. */
export function withCadence(draft: CommitmentDraft, cadence: CommitmentCadence): CommitmentDraft {
  const required = requiredTargets(cadence);
  return {
    ...draft,
    cadence,
    weeklyTarget: required.includes('weeklyTarget') ? draft.weeklyTarget : null,
    weekStartDay: required.includes('weekStartDay') ? draft.weekStartDay : null,
    dailyMinutesTarget: required.includes('dailyMinutesTarget') ? draft.dailyMinutesTarget : null,
  };
}

/** The column names the database uses. Kept here so no component spells them. */
export function toRow(draft: CommitmentDraft, ownerId: string, idempotencyKey: string) {
  return {
    owner_id: ownerId,
    idempotency_key: idempotencyKey,
    name: draft.name.trim(),
    kind: draft.kind,
    cadence: draft.cadence,
    carries_penalty: draft.carriesPenalty,
    weekly_target: draft.weeklyTarget,
    week_start_day: draft.weekStartDay,
    daily_minutes_target: draft.dailyMinutesTarget,
    auto_check_kind: draft.autoCheckEnabled ? 'account_elsewhere' : null,
    auto_check_account_ref: draft.autoCheckEnabled ? draft.autoCheckAccountRef.trim() : null,
    // Untouched (stripped before the request) while still enabled — it is a value the
    // resolution pass owns, never the client. Explicitly cleared to null on unlink, along
    // with the other two columns, so a stale read cannot survive it.
    auto_check_last_checked_at: draft.autoCheckEnabled ? undefined : null,
  };
}
