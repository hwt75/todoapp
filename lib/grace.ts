/**
 * Grace Day: a countable, honest way out of a Failed Day (Story 5.1, FR-17).
 *
 * The server is the sole judge (AD-1). Every eligibility rule — that the day's current
 * settlement reads `failed`, that its Penalty still reads `owed`, that fewer than
 * `grace_days_per_month()` have already been spent this calendar month — lives entirely in
 * `grace_day_validate()`'s trigger (`20260825110000_a_countable_way_to_be_forgiven.sql`).
 * This module carries only what the client actually owns: the shape of what it sends
 * (`lib/appeal.ts`'s own style — a plain function mapping a draft to a row, database columns
 * spelled in exactly one place), the copy, and how to read back what the server decided.
 *
 * **Why a spend is never re-validated client-side.** `lib/appeal.ts`'s own comment gives the
 * reason and it holds here unchanged: a client-side re-derivation of the same rule is exactly
 * the second copy that drifts. This module sends one insert and classifies whatever the
 * database sends back.
 *
 * **The correction is never immediate.** A successful insert means the *event* was accepted
 * — the day's Penalty does not actually move to `waived` until the next hourly settlement
 * pass folds it in (`apply_grace_days()`, called from `settle_due_days()`). The copy below
 * says so rather than implying the Ledger will update on the spot.
 */

import { classifyWriteError } from './declaration-submit';

/** What `grace_day` needs from a spend: the already-settled day being forgiven, read off a
 *  Day summary or a Ledger row — client-supplied the same way `appeal.for_day` is (naming an
 *  already-settled day rather than describing something that just happened). */
export interface GraceDayDraft {
  /** `YYYY-MM-DD`. */
  forDay: string;
}

/** The column names `grace_day` uses. Kept here so no component spells them — unlike
 *  `appeal`, there is no idempotency key: `grace_day_once_per_day` (the unique constraint on
 *  `(owner_id, for_day)`) is itself what makes a retry safe, since there is exactly one
 *  possible owner for any given `for_day` a client could ever send. */
export function toGraceDayRow(draft: GraceDayDraft, ownerId: string) {
  return { owner_id: ownerId, for_day: draft.forDay };
}

/**
 * What one `grace_day` insert came back as.
 *
 * `'already-spent'` covers both a genuine retry of this exact attempt and a second,
 * independent attempt racing it for the same day — `classifyWriteError`'s own `'duplicate'`
 * cannot tell those apart (Postgres's error carries the violated constraint, not the winning
 * row's key), but unlike `lib/appeal.ts`'s equivalent disambiguation, none is needed here:
 * `grace_day` has exactly one possible owner for a given `for_day` (RLS requires
 * `auth.uid() = owner_id`), so either reading means the same thing — a Grace Day is recorded
 * for this day, whichever attempt actually won.
 */
export type SpendGraceDayOutcome =
  { kind: 'spent' } | { kind: 'already-spent' } | { kind: 'refused'; reason: string };

/**
 * Classifies what a `grace_day` insert's own `error` means, without a second round trip.
 *
 * `'rejected'` carries `grace_day_validate()`'s own raised message verbatim (e.g. "This
 * day's Penalty is not eligible for a Grace Day…", "Both Grace Days for this month have
 * already been spent…") — always more specific than anything this module could say on its
 * own, so it is passed straight through. `'unreachable'` carries none of the server's own
 * words, so the generic sentence stands in for it.
 */
export function classifyGraceDaySpend(
  error: { code?: string; message?: string } | null,
): SpendGraceDayOutcome {
  const outcome = classifyWriteError(error);

  if (outcome === 'sent') return { kind: 'spent' };
  if (outcome === 'duplicate') return { kind: 'already-spent' };

  return {
    kind: 'refused',
    reason:
      outcome === 'rejected'
        ? (error?.message ?? GRACE_DAY_COPY.failed)
        : GRACE_DAY_COPY.unreachable,
  };
}

/**
 * Every string this surface says.
 *
 * Kept here for the reason `lib/appeal.ts`'s own `APPEAL_COPY` gives: copy rules, testable
 * independent of a component.
 */
export const GRACE_DAY_COPY = {
  spend: 'Spend a Grace Day',
  spending: 'Spending…',
  /** Never "Waived" — the correction is folded in by the next settlement pass, up to an
   *  hour later (this story's own Design Notes), and claiming it happened immediately would
   *  be a small lie the Ledger then has to contradict. */
  spent: 'Grace Day spent. This day clears within the hour.',
  alreadySpent: 'A Grace Day is already recorded for this day.',
  failed: 'Not spent.',
  unreachable: 'The server could not be reached.',
} as const;

/**
 * The remaining-count sentence, shown beside every Grace Day control (Day summary, Ledger
 * row, Settings) so the same number is always in view wherever it can be spent — never only
 * inside a future Silence intervention (FR-17's own Never boundary).
 */
export function formatGraceAllowance(remaining: number): string {
  if (remaining <= 0) return 'No Grace Days remaining this month.';
  return `${remaining} Grace Day${remaining === 1 ? '' : 's'} remaining this month.`;
}
