/**
 * The day-two Silence intervention (Story 5.2, FR-16): copy and the small pure helper that
 * fills in its one variable.
 *
 * `lib/grace.ts`'s own comment gives the reason this lives here rather than inside
 * `components/silence-intervention.tsx`: copy rules, testable independent of a component, and
 * the one place these strings can be checked against `EXPERIENCE.md` (Voice and Tone, "Day two
 * of silence" / "Day two, unanswered days pending", UX-DR21) rather than typed twice.
 *
 * The two variants differ only in their closing clause — verbatim otherwise. The "Declarations
 * pending" variant names the specific outstanding days rather than repeating EXPERIENCE.md's
 * own worked example ("Wednesday and Thursday") literally, since the real days vary by
 * episode: they are always `silence_episode.started_day` and the asked-day right after it —
 * the exact pair `enqueue_gate_reminders()` itself checked to open the episode (Story 5.2
 * Design Notes).
 */

const WEEKDAY = new Intl.DateTimeFormat('en-US', {
  weekday: 'long',
  timeZone: 'Asia/Ho_Chi_Minh',
});

/** The weekday name for a `YYYY-MM-DD` calendar date, independent of the reader's own
 *  timezone. Anchored at UTC noon rather than UTC midnight so no timezone on earth could shift
 *  the formatted weekday to the day before or after. */
function weekdayName(day: string): string {
  const [y, m, d] = day.split('-').map(Number);
  return WEEKDAY.format(new Date(Date.UTC(y, m - 1, d, 12)));
}

/** The day after a `YYYY-MM-DD`, without touching timezones again — mirrors
 *  `lib/declaration.ts`'s own `previousDay`. */
function nextDay(day: string): string {
  const [y, m, d] = day.split('-').map(Number);
  const at = new Date(Date.UTC(y, m - 1, d));
  at.setUTCDate(at.getUTCDate() + 1);
  return at.toISOString().slice(0, 10);
}

/** "Wednesday and Thursday" for a `started_day` of the earlier one — the two quiet asked-days
 *  that opened the episode. */
export function silenceDayNames(startedDay: string): string {
  return `${weekdayName(startedDay)} and ${weekdayName(nextDay(startedDay))}`;
}

/**
 * Every string this surface says (EXPERIENCE.md, verbatim, UX-DR21). No debt figure, no
 * itemized miss list, no red — Story 5.2's own Never boundary — so there is nothing here past
 * these two sentences and the Grace Days count (`lib/grace.ts`'s own `formatGraceAllowance`,
 * read verbatim rather than a second computation).
 */
export const SILENCE_COPY = {
  title: 'Two quiet days',
  opening: "Two quiet days. This is the part where it usually ends. It doesn't have to.",
  /** No Declarations outstanding when the episode fires — names one concrete thing to do
   *  instead of a day. */
  noPending: 'Do one thing today — TryHackMe, twenty minutes.',
  /** 1+ Declarations outstanding when it fires — `silenceDayNames` fills in which. */
  pendingSuffix: 'close tonight — answer them, and do one thing today.',
  failed: 'Failed.',
  unreachable: 'The server could not be reached.',
} as const;

/** The full sentence for whichever variant applies, `pending` deciding between them exactly
 *  the way `app/page.tsx`'s own `gate.owing.length > 0` already decides whether MorningGate
 *  has something to ask. */
export function silenceCopy(pending: boolean, startedDay: string): string {
  if (!pending) return `${SILENCE_COPY.opening} ${SILENCE_COPY.noPending}`;
  return `${SILENCE_COPY.opening} ${silenceDayNames(startedDay)} ${SILENCE_COPY.pendingSuffix}`;
}
