/**
 * When a question stops waiting.
 *
 * A declaration for day `D` is requested at the morning hour on `D+1` and expires at that
 * same hour on `D+3` — 48 hours, wall-clock, in the product's fixed zone (AD-6). It is not
 * extended for being unreachable: the remedy for a genuinely impossible two days is a Grace
 * Day applied afterwards, which is a recorded act with a count, rather than a clock that
 * stretches for whoever asks.
 *
 * **This is the untimed rule, and since Story 6.4 it is no longer the only one.** A commitment
 * carrying a `due_time` is decided at midnight of its own day instead — it cannot be claimed
 * outside its window and cannot be proved after the day ends, so there is no 48 hours to wait
 * through. `public.commitment_deadline` is where the two live together; everything below
 * describes only the branch it falls back to.
 *
 * **Not production code, and nothing holds it to the rule it copies.** The deadline that
 * decides anything is `public.declaration_deadline`
 * (`supabase/migrations/20260819241000_expiry_and_supersession.sql`). Nothing in `app/` or
 * `components/` imports this file; `expiry.test.ts` exercises the TypeScript and never runs
 * the SQL, so the earlier claim here — that the tests hold the two together — was false. It
 * is kept as a readable statement of the rule. If the two ever disagree, the function is
 * right and this file is a bug.
 */

import { ZONE, previousDay } from './declaration';

/** Days from the day in question to the moment its answer stops being accepted. */
export const EXPIRY_DAYS = 3;

/** The instant a day's declarations expire. */
export function deadlineFor(day: string, morningHour: number): Date {
  const [y, m, d] = day.split('-').map(Number);
  // Build the local wall-clock moment, then find the instant that matches it in the fixed
  // zone. Ho Chi Minh City has no daylight saving, so the offset is constant and this is
  // exact rather than approximate.
  const asIfUtc = Date.UTC(y, m - 1, d + EXPIRY_DAYS, morningHour, 0, 0);
  return new Date(asIfUtc - zoneOffsetMs(new Date(asIfUtc)));
}

/** The zone's offset from UTC, in milliseconds, at a given instant. */
function zoneOffsetMs(at: Date): number {
  const local = new Date(at.toLocaleString('en-US', { timeZone: ZONE }));
  const utc = new Date(at.toLocaleString('en-US', { timeZone: 'UTC' }));
  return local.getTime() - utc.getTime();
}

/** Whether a day's answers are no longer accepted as of `now`. */
export function hasExpired(day: string, morningHour: number, now: Date): boolean {
  return now.getTime() >= deadlineFor(day, morningHour).getTime();
}

/**
 * Whether an answer was given in time, whenever it happened to arrive.
 *
 * This is the distinction the whole supersession rule turns on. AD-5 ignores *late-arriving
 * events*; an answer tapped at 07:31 on day two and delivered on day four is a timely event
 * delivered late, and `answered_at` is what tells them apart.
 *
 * **It is currently true for every declaration the schema can produce**, and that is worth
 * knowing rather than discovering later. The `for_day` trigger derives the day as
 * `answered_at - 1 day`, so a tap always lands on `D+1` while the deadline is on `D+3` —
 * at least a full day of margin. A day older than yesterday cannot be answered at all,
 * which means it can only expire.
 *
 * The check stays because it is the rule, not the current arithmetic. If a catch-up surface
 * ever lets him answer an older day, this is what stops a late answer erasing an expiry.
 */
export function answeredInTime(answeredAt: Date, day: string, morningHour: number): boolean {
  return answeredAt.getTime() < deadlineFor(day, morningHour).getTime();
}

/** The day whose answer expires next, given today. Only ever yesterday, by FR-9. */
export function dayAtRisk(today: string): string {
  return previousDay(today);
}
