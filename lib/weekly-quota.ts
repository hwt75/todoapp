/**
 * How a Weekly Quota commitment's live position reads, on the pill and to a screen reader.
 *
 * `weekly_quota_progress` (Story 3.3's own migration) is the one source of the numbers here —
 * held, target, days remaining — the same discipline `focus_day_minutes` established for the
 * other quota (AD-8). This file does no arithmetic of its own on those three numbers; it only
 * decides how they are written and spoken, mirroring `lib/focus-session.ts`'s split between
 * formatting and the surface that reads it.
 *
 * **D2: always `urgent` while open, `held` the moment the target is met.** The story's own
 * acceptance example — 0 of 3 on a Tuesday, five days still open — is called `urgent` even
 * though nothing is tight yet: `EXPERIENCE.md`'s "fewer days left than sessions owed" is one
 * illustration of the family, not its gate. A met quota sitting in urgent orange for the rest
 * of the week would tell the author to keep worrying about something already finished, so
 * `held ≥ target` flips the family immediately and drops the days count — there is nothing
 * left to count down (Design Notes: `≥` rather than `=`, so a stray correction can never leave
 * a quota that has actually been won stuck reading urgent).
 *
 * **The pill's text is exactly what `DESIGN.md` already specifies** (`1/3 · 3 days`) — no new
 * copy for the visible label. The spoken form *is* new copy: `StatusPill`'s label is
 * `aria-hidden`, so `rowLabel`'s `spokenOverride` is the only sentence a screen reader gets for
 * this row, and it has to state the same position in words rather than falling back to
 * "not yet done today" beside a pill that disagrees with it.
 */

import type { StateFamily } from './commitment-state';

/** The three numbers `weekly_quota_progress` returns for one commitment. */
export interface WeeklyQuotaPosition {
  /** Qualifying days held this week, so far. */
  held: number;
  /** How many qualifying days the week asks for. */
  target: number;
  /** Days from tomorrow through the end of this week (D1). Meaningless once met. */
  daysRemaining: number;
}

/** `held ≥ target` (Design Notes: a guard against overshoot costs nothing). */
export function weeklyQuotaMet(position: WeeklyQuotaPosition): boolean {
  return position.held >= position.target;
}

/** `day` or `days` — the one place this decision is made, so no caller writes it inline. */
function dayWord(days: number): string {
  return days === 1 ? 'day' : 'days';
}

/**
 * The pill's visible text.
 *
 * Met: `3/3` — the count alone, since the family already carries "this is good" and a days
 * count that no longer means anything would be the first thing to contradict it.
 * Open: `1/3 · 3 days` (`0/3 · 5 days`, `1/3 · 1 day` singular) — `DESIGN.md`'s own ratified
 * format, reproduced exactly rather than re-derived.
 *
 * `met` is passed in rather than recomputed, so a caller juggling several of these derived
 * values for the same position — `weeklyQuotaOverride` below is exactly that caller — decides
 * `weeklyQuotaMet(position)` once rather than once per function.
 */
export function weeklyQuotaLabel(
  position: WeeklyQuotaPosition,
  met = weeklyQuotaMet(position),
): string {
  const { held, target, daysRemaining } = position;
  if (met) return `${held}/${target}`;
  return `${held}/${target} · ${daysRemaining} ${dayWord(daysRemaining)}`;
}

/**
 * How the same position reads aloud, as the row's one accessibility label.
 *
 * Never "not yet done today" — that sentence is honest for a Daily commitment with nothing
 * recorded, but a Weekly Quota commitment mid-week has something to say, and the pill beside it
 * already says it in numbers.
 */
export function weeklyQuotaSpoken(
  position: WeeklyQuotaPosition,
  met = weeklyQuotaMet(position),
): string {
  const { held, target, daysRemaining } = position;
  if (met) return `${held} of ${target} this week, held`;
  const left = daysRemaining === 1 ? '1 day' : `${daysRemaining} days`;
  return `${held} of ${target} this week, ${left} left`;
}

/** The pill family: `held` the instant the target is met, `urgent` for every day it is not. */
export function weeklyQuotaFamily(
  position: WeeklyQuotaPosition,
  met = weeklyQuotaMet(position),
): StateFamily {
  return met ? 'held' : 'urgent';
}

/** The whole `StatusPill` override in one call — label and family together. */
export function weeklyQuotaOverride(position: WeeklyQuotaPosition): {
  family: StateFamily;
  label: string;
} {
  const met = weeklyQuotaMet(position);
  return { family: weeklyQuotaFamily(position, met), label: weeklyQuotaLabel(position, met) };
}
