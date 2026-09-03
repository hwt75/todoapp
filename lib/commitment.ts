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
  /**
   * `HH:MM`, a wall-clock time of day in Asia/Ho_Chi_Minh — never an instant (AD-6). Null on
   * an untimed commitment, which behaves exactly as every commitment did before Story 6.1.
   */
  dueTime: string | null;
  /** Minutes after `dueTime` during which the commitment still counts as met. */
  lateWindowMinutes: number | null;
  /**
   * Whether the author keeps a photo against this commitment (Story 6.8).
   *
   * Deliberately gated by neither `autoChecksPossible()` nor `canBeTimed()`. Both of those
   * exclude an abstention and an hours quota — one because no sensor exists, the other because
   * no moment exists — and neither reason reaches this. A photo that decides nothing is
   * meaningless for no kind and no cadence, which is why an abstention, the one kind that could
   * never carry a time, can carry this.
   *
   * Settlement never reads it. Nothing about a verdict, a penalty, a chain or a grace allowance
   * changes when it is on, and a day with no photo settles exactly as it would with it off.
   */
  requiresPhoto: boolean;
}

/** The window's bounds, mirroring `commitment_late_window_range`. */
export const LATE_WINDOW_MIN_MINUTES = 5;
export const LATE_WINDOW_MAX_MINUTES = 240;

/** What a window is set to when a time is first switched on. */
export const LATE_WINDOW_DEFAULT_MINUTES = 30;

/** Mirrors `commitment_window_within_the_day`. Half-open: a window ending here is inside the day. */
export const MINUTES_IN_A_DAY = 1440;

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
  dueTime: null,
  lateWindowMinutes: null,
  // Off, like `carriesPenalty` and for a milder version of the same reason: keeping a record is
  // a thing the author chooses to do, never something the product starts asking him for.
  requiresPhoto: false,
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
 *
 * An Hours-per-day commitment is excluded the same way, for a different reason (Epic 4
 * retrospective, finding A7): it is judged by banked Focus-Session minutes, never by a
 * Declaration (`commitments_owing()` excludes `daily_hours_quota` entirely,
 * `20260820140000_weekly_quota_is_not_judged_daily.sql`), so `resolve_auto_checks()`'s
 * settlement-gating guard (`auto_check_pending()`, AD-13) never runs for one — an attached
 * check would have no path that could ever enforce it. `cadence` defaults to `'daily'` so
 * every existing single-argument call site (kind-only checks) keeps its prior meaning.
 */
export function autoChecksPossible(
  kind: CommitmentKind,
  cadence: CommitmentCadence = 'daily',
): boolean {
  return kind !== 'abstain' && cadence !== 'daily_hours_quota';
}

/**
 * Whether this commitment has a moment that could be named.
 *
 * **This is deliberately not `autoChecksPossible()`, and must not be merged with it.** The two
 * exclude the same two cases today and the reasons are unrelated. `autoChecksPossible()` is
 * about whether a *sensor* exists: nothing observes a thing not done, and an hours quota is
 * measured in banked minutes rather than reported on. This is about whether a *moment* exists:
 * an abstention has no instant of doing to photograph, and an hours quota is never settled by a
 * declaration at all, so a due time would name a moment nothing would ever read.
 *
 * The match is a coincidence. Sharing one function would make two unrelated rules move
 * together, and the next change to either would break the other in silence.
 *
 * Mirrors `commitment_time_needs_a_moment`; the constraint is what actually decides.
 */
export function canBeTimed(kind: CommitmentKind, cadence: CommitmentCadence): boolean {
  return kind !== 'abstain' && cadence !== 'daily_hours_quota';
}

/** `HH:MM`, 24-hour, whole minutes — the shape `<input type="time">` produces and the database accepts. */
const TIME_OF_DAY = /^([01]\d|2[0-3]):([0-5]\d)$/;

/**
 * Minutes from midnight, or null if this is not a time of day.
 *
 * Whole minutes on purpose, matching `commitment_due_time_whole_minute`: with seconds allowed,
 * 23:55:30 with a five-minute window compares as exactly 1440 and passes, while the window it
 * describes ends half a minute into the next day.
 */
export function minutesIntoDay(dueTime: string): number | null {
  const match = TIME_OF_DAY.exec(dueTime);
  if (!match) return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

/**
 * Turn a time on or off, carrying the window with it.
 *
 * Switching a time on brings the default window rather than leaving it null, because the two
 * are refused separately by `commitment_time_and_window_together` and a form that asked for
 * them one at a time would show a problem the author had not yet had a chance to cause.
 */
export function withDueTime(draft: CommitmentDraft, dueTime: string | null): CommitmentDraft {
  if (dueTime === null) {
    return { ...draft, dueTime: null, lateWindowMinutes: null };
  }
  return {
    ...draft,
    dueTime,
    lateWindowMinutes: draft.lateWindowMinutes ?? LATE_WINDOW_DEFAULT_MINUTES,
  };
}

/**
 * What the author is told before a time is saved, verbatim.
 *
 * Kept here for the reason `lib/appeal.ts`'s `APPEAL_COPY` gives: this is a copy rule, testable
 * without a component, and the source `components/commitment-form.tsx` reads from rather than
 * one it invents inline. It is load-bearing rather than decoration — a timed commitment trades
 * the three-day declaration window for a deadline at midnight, and this sentence is the only
 * place the author learns that before it costs him.
 */
export const TIMED_COMMITMENT_COPY = {
  warning:
    'A timed commitment is settled by a photo, not by the morning question. No photo before ' +
    'midnight is a failed day — and you have only two Grace Days a month to undo one.',
} as const;

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

  // A time and its window are refused separately by the database
  // (`commitment_time_and_window_together`), so they are checked together here.
  if ((draft.dueTime === null) !== (draft.lateWindowMinutes === null)) {
    problems.push(
      draft.dueTime === null
        ? 'A late window needs a time to be late against.'
        : 'A time needs a late window.',
    );
  }

  if (draft.dueTime !== null) {
    // Mirrors `canBeTimed()` and `commitment_time_needs_a_moment`. Kept as its own message
    // rather than folded into the Auto-check one: the two rules exclude the same kinds for
    // unrelated reasons, and a shared sentence would imply a shared cause.
    if (draft.kind === 'abstain') {
      problems.push('An Avoid-it commitment has no moment to put a time on.');
    } else if (draft.cadence === 'daily_hours_quota') {
      problems.push(
        'An Hours-per-day commitment is judged by the time you bank, not by a time of day.',
      );
    }

    const startsAt = minutesIntoDay(draft.dueTime);
    if (startsAt === null) {
      problems.push('A time of day looks like 20:00.');
    } else if (draft.lateWindowMinutes !== null) {
      if (
        !Number.isInteger(draft.lateWindowMinutes) ||
        draft.lateWindowMinutes < LATE_WINDOW_MIN_MINUTES ||
        draft.lateWindowMinutes > LATE_WINDOW_MAX_MINUTES
      ) {
        problems.push(
          `The late window must be a whole number of minutes from ${LATE_WINDOW_MIN_MINUTES} to ${LATE_WINDOW_MAX_MINUTES}.`,
        );
      } else if (startsAt + draft.lateWindowMinutes > MINUTES_IN_A_DAY) {
        // Not arithmetic on a time value, on purpose. `time + interval` wraps in Postgres and
        // in most date libraries, so 23:30 plus an hour reads as 00:30 and the check passes on
        // exactly the case it exists to refuse.
        problems.push('The late window has to end before midnight.');
      }
    }
  }

  if (draft.autoCheckEnabled) {
    // Mirrors `autoChecksPossible()`: there is no sensor for a thing not done, so an
    // Auto-check can never attach to an abstention — refused here and by the database's
    // own `commitment_auto_check_not_on_abstain` check. An Hours-per-day cadence is refused
    // the same way, by `commitment_auto_check_not_on_hours_quota`.
    if (draft.kind === 'abstain') {
      problems.push('Nothing can check an Avoid-it commitment automatically.');
    } else if (draft.cadence === 'daily_hours_quota') {
      problems.push('Nothing can check an Hours-per-day commitment automatically.');
    }
    if (draft.autoCheckAccountRef.trim() === '') {
      problems.push('Account elsewhere needs an account identifier to check.');
    }

    // Mirrors `commitment_time_not_with_auto_check` (Story 6.4). A sensor and a photo are two
    // answers to one question, and a timed commitment is settled by the photo: an Auto-check
    // filing `held` the next morning would hold a day no photo ever proved, and one filing
    // `slipped` would answer for a day already decided at midnight. Reported from this block
    // rather than the time block above because it is the Auto-check that has to come off — the
    // time is the thing the author just chose.
    if (draft.dueTime !== null) {
      problems.push('A timed commitment is proved by its photo, so nothing can check it for you.');
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
  const checksPossible = autoChecksPossible(kind, draft.cadence);
  const timeable = canBeTimed(kind, draft.cadence);
  return {
    ...draft,
    kind,
    autoCheckEnabled: checksPossible ? draft.autoCheckEnabled : false,
    autoCheckAccountRef: checksPossible ? draft.autoCheckAccountRef : '',
    // Cleared for the same reason a stale target is: a time left on a kind that cannot carry
    // one is refused by a constraint about a field no longer on screen.
    dueTime: timeable ? draft.dueTime : null,
    lateWindowMinutes: timeable ? draft.lateWindowMinutes : null,
    // `requiresPhoto` is carried by the spread above and cleared by neither this nor
    // `withCadence`, on purpose. A time is cleared because a constraint would refuse it on a
    // kind that cannot carry one; there is no such constraint here, and every kind can keep a
    // photo. Switching an Avoid-it commitment to a Do-it one and back must not quietly lose it.
  };
}

/** Clears whatever the previous cadence needed, so switching cadence cannot leave a stale target. */
export function withCadence(draft: CommitmentDraft, cadence: CommitmentCadence): CommitmentDraft {
  const required = requiredTargets(cadence);
  const checksPossible = autoChecksPossible(draft.kind, cadence);
  const timeable = canBeTimed(draft.kind, cadence);
  return {
    ...draft,
    cadence,
    dueTime: timeable ? draft.dueTime : null,
    lateWindowMinutes: timeable ? draft.lateWindowMinutes : null,
    weeklyTarget: required.includes('weeklyTarget') ? draft.weeklyTarget : null,
    weekStartDay: required.includes('weekStartDay') ? draft.weekStartDay : null,
    dailyMinutesTarget: required.includes('dailyMinutesTarget') ? draft.dailyMinutesTarget : null,
    autoCheckEnabled: checksPossible ? draft.autoCheckEnabled : false,
    autoCheckAccountRef: checksPossible ? draft.autoCheckAccountRef : '',
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
    // `HH:MM` reaches a `time` column as written; no client ever derives a date or an instant
    // from it (AD-6).
    due_time: draft.dueTime,
    late_window_minutes: draft.lateWindowMinutes,
    // Story 6.8. Configuration, like every other column here — no settlement function reads it,
    // so it has no as-of change log and needs none (see the migration's own comment).
    requires_photo: draft.requiresPhoto,
    auto_check_kind: draft.autoCheckEnabled ? 'account_elsewhere' : null,
    auto_check_account_ref: draft.autoCheckEnabled ? draft.autoCheckAccountRef.trim() : null,
    // Untouched (stripped before the request) while still enabled — it is a value the
    // resolution pass owns, never the client. Explicitly cleared to null on unlink, along
    // with the other two columns, so a stale read cannot survive it.
    auto_check_last_checked_at: draft.autoCheckEnabled ? undefined : null,
  };
}
