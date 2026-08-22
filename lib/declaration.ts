/**
 * Who owes an answer, for which day, and from what hour.
 *
 * Every boundary here is `Asia/Ho_Chi_Minh` (AD-6). No client ever derives a date for
 * storage — the server does that from the instant it is sent — but the client does have to
 * decide *what to ask*, and that decision has to agree with the server's. So the rule lives
 * here as a pure function, tested against both sides of every boundary, rather than inside
 * a component where only a real clock could exercise it.
 */

import type { CommitmentCadence } from './commitment';

export const ZONE = 'Asia/Ho_Chi_Minh';

export interface CalendarMoment {
  /** `YYYY-MM-DD` in the product's fixed zone. */
  day: string;
  /** 0–23 in the product's fixed zone. */
  hour: number;
}

const PARTS = new Intl.DateTimeFormat('en-CA', {
  timeZone: ZONE,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

/** The wall-clock day and hour in Ho Chi Minh City, whatever the device believes. */
export function calendarMoment(at: Date): CalendarMoment {
  const parts = Object.fromEntries(PARTS.formatToParts(at).map((p) => [p.type, p.value]));
  return {
    day: `${parts.year}-${parts.month}-${parts.day}`,
    // Intl renders midnight as 24 in some engines under hour12: false.
    hour: Number(parts.hour) % 24,
  };
}

/** The day before a `YYYY-MM-DD`, without touching timezones again. */
export function previousDay(day: string): string {
  const [y, m, d] = day.split('-').map(Number);
  const at = new Date(Date.UTC(y, m - 1, d));
  at.setUTCDate(at.getUTCDate() - 1);
  return at.toISOString().slice(0, 10);
}

/**
 * The day the morning question is about: the one before today, locally.
 *
 * Deliberately independent of `morningHour`. Answering at 06:00 and at 08:00 both refer to
 * yesterday, so moving the hour never silently re-points an answer at a different day —
 * and this agrees with the database trigger, which derives the same thing from the instant.
 */
export function dayInQuestion(now: Date): string {
  return previousDay(calendarMoment(now).day);
}

/** Whether the author has reached the hour at which he agreed to be asked. */
export function isAskingTime(now: Date, morningHour: number): boolean {
  return calendarMoment(now).hour >= morningHour;
}

/**
 * Whether a commitment of this cadence is settled by the author's word at all.
 *
 * FR-2 judges each cadence at its own point. A daily commitment is judged at Day Close, so
 * his word is what settles it. A weekly quota is judged at Week Close, but the *sessions*
 * that feed it happen on days — so it is still asked daily, and 2.5 decides what the
 * answers add up to.
 *
 * A daily hours quota is different in kind: FR-2 judges it "against accumulated Focus
 * Session minutes", which is a measurement rather than a statement. Asking him to declare
 * it would invite a second, softer answer to a question the timer already answers exactly.
 *
 * That leaves a real gap until Epic 3 builds the timer: an hours-quota commitment is asked
 * nothing and measured by nothing. The gap belongs to the sequencing, not to this rule, and
 * papering over it with a daily yes/no would hide it.
 */
export function isDeclared(cadence: CommitmentCadence): boolean {
  return cadence !== 'daily_hours_quota';
}

export interface OwedCommitment {
  id: string;
  name: string;
  cadence: CommitmentCadence;
}

/**
 * Which commitments still owe an answer for the day in question.
 *
 * A commitment archived *after* the day it is being asked about is still asked: the day it
 * belongs to predates the archive, and a ledger with a hole in it is worse than one extra
 * question.
 */
export function commitmentsOwing(
  commitments: readonly (OwedCommitment & { archived_at?: string | null })[],
  alreadyAnsweredCommitmentIds: readonly string[],
  now: Date,
  morningHour: number,
): OwedCommitment[] {
  if (!isAskingTime(now, morningHour)) return [];

  const answered = new Set(alreadyAnsweredCommitmentIds);
  const day = dayInQuestion(now);

  return commitments
    .filter((c) => isDeclared(c.cadence))
    .filter((c) => !answered.has(c.id))
    .filter((c) => !archivedBefore(c.archived_at ?? null, day))
    .map(({ id, name, cadence }) => ({ id, name, cadence }));
}

/** True when the commitment was already archived before the day being asked about. */
function archivedBefore(archivedAt: string | null, day: string): boolean {
  if (!archivedAt) return false;
  return calendarMoment(new Date(archivedAt)).day <= day;
}

/**
 * The question, phrased for the cadence.
 *
 * A daily commitment either held or it did not. A weekly one is asking whether a session
 * happened, and calling that "held" would imply the week is already decided when FR-2 says
 * it is not judged until Week Close.
 */
export function questionFor(commitment: OwedCommitment, day: string): string {
  return commitment.cadence === 'weekly_quota'
    ? `Did you do ${commitment.name} on ${day}?`
    : `Did ${commitment.name} hold on ${day}?`;
}
