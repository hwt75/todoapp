/**
 * The Monthly report (Story 5.4, FR-24): whether the whole arrangement — including the
 * Referee's own participation — is still alive, at the only altitude a single day can never
 * show it. Author-only, read-only, spine-only fidelity: the most recently completed calendar
 * month, computed live, no stored report row and no month picker.
 *
 * Every PRD §8 measure is either a direct read of an existing table/view (Chains, Penalties,
 * Silence episodes, Appeal outcomes, Referee activity) or a fold over rows the component
 * fetches — this module owns the folding, mirroring `lib/ledger.ts`'s own row-folding style
 * (`buildLedger`) rather than recomputing anything a server view or function already decided.
 * The one exception is SM-6/SM-3 (declaration answer rate, per-commitment completion), which
 * both need `commitment_answer_rate_for_month()`'s own server-side aggregation — the client
 * cannot reach `commitments_owing()` directly (it is revoked from `authenticated`).
 *
 * **The month boundary, replicated client-side.** `grace_day_validate()`'s own idiom —
 * `date_trunc('month', <col> at time zone 'Asia/Ho_Chi_Minh')` — cannot be spelled in
 * PostgREST query params directly, so this module reproduces its exact effect for a range
 * filter instead: Asia/Ho_Chi_Minh carries no DST, a fixed UTC+7 offset year-round, so
 * `[month-start, next-month-start)` expressed as instants at that fixed offset is the precise
 * equivalent of the SQL idiom, not an approximation of it. `monthDayBounds` is the plainer
 * sibling for the `date`-typed columns (`settlement.period`, `silence_episode.started_day`)
 * that are already anchored to an Asia/Ho_Chi_Minh calendar day by construction and need no
 * zone conversion at all.
 */

import { calendarMoment } from './declaration';
import type { PenaltyState } from './ledger';
import { formatDong } from './money';

export interface MonthlyReportMonth {
  year: number;
  /** 1–12. */
  month: number;
}

/** The 14-day lookahead window SM-2/SM-C2 both use (Design Notes): a deliberate, stated
 *  boundary, not a discovered constant. A Failed day in the last days of the month may not
 *  have "returned" or been "acknowledged" yet by the time the report is viewed, and an
 *  unbounded search would let one very-late return dominate a small month's median. */
export const RETURN_LOOKAHEAD_DAYS = 14;

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

/**
 * The most recently completed calendar month, in Asia/Ho_Chi_Minh, as of `now` — this story's
 * own "no month picker" boundary: the report always names this month and no other.
 */
export function mostRecentCompletedMonth(now: Date): MonthlyReportMonth {
  const [year, month] = calendarMoment(now).day.split('-').map(Number);
  return month === 1 ? { year: year - 1, month: 12 } : { year, month: month - 1 };
}

/** `[gte, lt)` as `YYYY-MM-DD` strings for a `date`-typed column already anchored to an
 *  Asia/Ho_Chi_Minh calendar day (`settlement.period`, `silence_episode.started_day`) — no
 *  zone conversion needed, only the calendar arithmetic. */
export function monthDayBounds(year: number, month: number): { gte: string; lt: string } {
  const nextMonth = month === 12 ? 1 : month + 1;
  const nextYear = month === 12 ? year + 1 : year;
  return { gte: `${year}-${pad2(month)}-01`, lt: `${nextYear}-${pad2(nextMonth)}-01` };
}

/** `[gte, lt)` as instant strings for a `timestamptz`-typed column (`penalty.created_at`,
 *  `penalty.collected_at`, `appeal.created_at`, `appeal.ruled_at`) — the fixed `+07:00`
 *  offset is what makes this the exact equivalent of `date_trunc('month', col at time zone
 *  'Asia/Ho_Chi_Minh')` rather than a naive UTC-midnight range that would be off by 7 hours
 *  at both ends of the month. */
export function monthInstantBounds(year: number, month: number): { gte: string; lt: string } {
  const { gte, lt } = monthDayBounds(year, month);
  return { gte: `${gte}T00:00:00+07:00`, lt: `${lt}T00:00:00+07:00` };
}

/** The last `YYYY-MM-DD` a query needs to reach to cover the lookahead window past a report
 *  month — the widened upper bound `medianDaysToReturn`/`medianDaysToAcknowledge`'s own
 *  candidate rows have to be fetched through, so a return/acknowledgement landing just past
 *  the month boundary is not silently excluded from the search. */
export function lookaheadEndDay(
  year: number,
  month: number,
  lookaheadDays: number = RETURN_LOOKAHEAD_DAYS,
): string {
  const { lt } = monthDayBounds(year, month);
  const [y, m, d] = lt.split('-').map(Number);
  const at = new Date(Date.UTC(y, m - 1, d));
  at.setUTCDate(at.getUTCDate() + lookaheadDays);
  return at.toISOString().slice(0, 10);
}

const MONTH_LABEL = new Intl.DateTimeFormat('en-US', {
  month: 'long',
  year: 'numeric',
  timeZone: 'UTC',
});

/** "July 2026" — `timeZone: 'UTC'` against a UTC-midnight instant so no reader's own
 *  timezone can shift which month is named; the month itself was already decided in
 *  Asia/Ho_Chi_Minh by `mostRecentCompletedMonth`. */
export function formatMonthLabel(year: number, month: number): string {
  return MONTH_LABEL.format(new Date(Date.UTC(year, month - 1, 1)));
}

// ---------------------------------------------------------------------------------
// SM-1: Chains. `chain_current` read directly, never recomputed — this only attaches a name.
// ---------------------------------------------------------------------------------

export interface ChainRow {
  commitment_id: string;
  current_days: number;
  longest_days: number;
}

export interface ChainSummary {
  commitmentId: string;
  commitmentName: string;
  currentDays: number;
  longestDays: number;
}

export function foldChains(
  rows: readonly ChainRow[],
  names: ReadonlyMap<string, string>,
): ChainSummary[] {
  return rows
    .map((r) => ({
      commitmentId: r.commitment_id,
      commitmentName: names.get(r.commitment_id) ?? 'A commitment',
      currentDays: r.current_days,
      longestDays: r.longest_days,
    }))
    .sort((a, b) => a.commitmentName.localeCompare(b.commitmentName));
}

// ---------------------------------------------------------------------------------
// Shared: the UTC date-string-arithmetic idiom `lib/referee.ts`'s own `daysSinceQuiet`
// establishes, replicated for every day-count computation below — `Date.UTC` against the
// parsed `YYYY-MM-DD` parts, never a raw millisecond diff of two `Date` objects (which would
// be sensitive to whatever timezone the parts were constructed in). Unlike `daysSinceQuiet`
// (an inclusive streak length, `+1`), this is a *gap* between two distinct calendar days —
// "Failed on the 10th, returned on the 11th" is a 1-day gap, not a 2-day streak — so there is
// deliberately no `+1` here.
// ---------------------------------------------------------------------------------

export function daysBetween(fromDay: string, toDay: string): number {
  const [fy, fm, fd] = fromDay.split('-').map(Number);
  const [ty, tm, td] = toDay.split('-').map(Number);
  return Math.round((Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86_400_000);
}

/** The median of a list of gaps, or `null` for an empty list — "no data", never zero or a
 *  crash (I/O Matrix: "No Failed days this month"). */
export function median(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

/** For each `fromDay`, the gap in days to the earliest `targetDay` strictly after it that
 *  still falls inside `lookaheadDays` — a `fromDay` with no qualifying target inside the
 *  window contributes nothing to the list (excluded from the median, never counted as zero).
 *  Shared by SM-2 (`medianDaysToReturn`) and SM-C2 (`medianDaysToAcknowledge`): both are "the
 *  gap from a Failed day to the next qualifying later event", differing only in what counts
 *  as the target day. */
function gapsToNextTarget(
  fromDays: readonly string[],
  targetDays: readonly string[],
  lookaheadDays: number,
): number[] {
  const sortedTargets = [...targetDays].sort();
  const gaps: number[] = [];

  for (const from of fromDays) {
    const next = sortedTargets.find((target) => daysBetween(from, target) > 0);
    if (next === undefined) continue;

    const gap = daysBetween(from, next);
    if (gap <= lookaheadDays) gaps.push(gap);
  }

  return gaps;
}

// ---------------------------------------------------------------------------------
// SM-2: median days to return after a Failed Day. `failedDayPeriods` are this report month's
// own Failed day-settlement periods; `cleanDayPeriods` are every `clean` day-settlement
// period the component fetched through the lookahead window (the report month is not enough
// on its own — a late-month Failed day can return in the following month).
// ---------------------------------------------------------------------------------

export function medianDaysToReturn(
  failedDayPeriods: readonly string[],
  cleanDayPeriods: readonly string[],
  lookaheadDays: number = RETURN_LOOKAHEAD_DAYS,
): number | null {
  return median(gapsToNextTarget(failedDayPeriods, cleanDayPeriods, lookaheadDays));
}

// ---------------------------------------------------------------------------------
// SM-C2: median days to acknowledge the first Failed day. Reuses `declaration_satisfies_
// silence()`'s own established framing (Story 5.2): any Declaration, for any commitment,
// counts as acknowledgement, not only one naming the Failed day itself.
// `answeredAtInstants` are every `declaration.answered_at` the component fetched through the
// lookahead window, converted here to their own Asia/Ho_Chi_Minh calendar day before the
// same gap search SM-2 uses.
// ---------------------------------------------------------------------------------

export function medianDaysToAcknowledge(
  failedDayPeriods: readonly string[],
  answeredAtInstants: readonly string[],
  lookaheadDays: number = RETURN_LOOKAHEAD_DAYS,
): number | null {
  const answeredDays = answeredAtInstants.map((iso) => calendarMoment(new Date(iso)).day);
  return median(gapsToNextTarget(failedDayPeriods, answeredDays, lookaheadDays));
}

// ---------------------------------------------------------------------------------
// SM-3 / SM-6: `commitment_answer_rate_for_month()`'s own rows, folded two ways — per
// commitment (SM-3, generic, never hardcoded to a specific commitment's identity) and summed
// across every commitment (SM-6).
// ---------------------------------------------------------------------------------

export interface CommitmentAnswerRateRow {
  commitment_id: string;
  asked: number;
  answered: number;
}

export interface CommitmentCompletion {
  commitmentId: string;
  commitmentName: string;
  asked: number;
  answered: number;
  /** `answered / asked`, or `null` when nothing was ever asked this month. */
  rate: number | null;
}

export function foldCommitmentCompletion(
  rows: readonly CommitmentAnswerRateRow[],
  names: ReadonlyMap<string, string>,
): CommitmentCompletion[] {
  return rows
    .map((r) => ({
      commitmentId: r.commitment_id,
      commitmentName: names.get(r.commitment_id) ?? 'A commitment',
      asked: r.asked,
      answered: r.answered,
      rate: r.asked > 0 ? r.answered / r.asked : null,
    }))
    .sort((a, b) => a.commitmentName.localeCompare(b.commitmentName));
}

export interface AnswerRateTotal {
  asked: number;
  answered: number;
  rate: number | null;
}

/** SM-6: the sum of asked/answered across every row — never "answered within the morning
 *  window" (no such signal exists in this schema; the story's own scope decision). */
export function foldDeclarationAnswerRate(
  rows: readonly CommitmentAnswerRateRow[],
): AnswerRateTotal {
  const asked = rows.reduce((sum, r) => sum + r.asked, 0);
  const answered = rows.reduce((sum, r) => sum + r.answered, 0);
  return { asked, answered, rate: asked > 0 ? answered / asked : null };
}

// ---------------------------------------------------------------------------------
// SM-4: Silence episodes. `count(*)` from `silence_episode` rows whose `started_day` falls
// in-month — every row already represents ≥2 consecutive quiet days by construction (Story
// 5.2's own opening threshold), so this is nothing but a count of the rows the component
// already scoped by month with `monthDayBounds`.
// ---------------------------------------------------------------------------------

export function countSilenceEpisodes(rows: readonly { started_day: string }[]): number {
  return rows.length;
}

// ---------------------------------------------------------------------------------
// SM-5: Referee still active. `true` when any `appeal.ruled_at` or `penalty.collected_at`
// falls in-month — the component fetches both sets already scoped by `monthInstantBounds`
// and `not null`, so this is just "did either read come back non-empty".
// ---------------------------------------------------------------------------------

export function isRefereeStillActive(
  ruledInMonthCount: number,
  collectedInMonthCount: number,
): boolean {
  return ruledInMonthCount > 0 || collectedInMonthCount > 0;
}

// ---------------------------------------------------------------------------------
// SM-C1: Penalties incurred / collected. Two figures, never merged (UX-DR19) — the same
// `foldPenaltyFigure` folds whichever set the component already scoped by month (`created_at`
// for incurred, `collected_at` for collected), split by `kind` at the call site.
// ---------------------------------------------------------------------------------

export interface PenaltyFigure {
  count: number;
  totalDong: number;
}

export function foldPenaltyFigure(rows: readonly { amount_dong: number }[]): PenaltyFigure {
  return {
    count: rows.length,
    totalDong: rows.reduce((sum, r) => sum + r.amount_dong, 0),
  };
}

/**
 * SM-C1 Incurred, corrected (Epic 5 retrospective, 2026-08-27, finding A3): `apply_grace_days()`
 * and `rule_appeal()`'s own approval path both fold a Failed Day's original penalty into a
 * *corrective* settlement, stamped with a fresh `created_at` at fold-in time — not the
 * original Failed Day's own timestamp — and the original penalty drops out of `penalty_current`
 * entirely once its own settlement is superseded. Read against `penalty_current`, "Incurred"
 * would silently lose the original month's own figure the moment either lands, however late,
 * and could gain a spurious one in whatever month the fold-in itself happened in.
 *
 * The fix: read the base `penalty` table (every row, corrective or not) with each row's own
 * settlement embedded, and keep only the ones whose settlement was never superseded — the
 * original incurring event, on its own original timestamp, regardless of what happened to it
 * later. A corrective row's own settlement always carries a non-null `supersedes`, so it is
 * excluded here rather than double-counted alongside the original it corrects.
 */
export interface OriginalPenaltyRow {
  amount_dong: number;
  settlement: { supersedes: string | null } | null;
}

export function originalPenaltyRows(
  rows: readonly OriginalPenaltyRow[],
): { amount_dong: number }[] {
  return rows
    .filter((r) => r.settlement !== null && r.settlement.supersedes === null)
    .map((r) => ({ amount_dong: r.amount_dong }));
}

// ---------------------------------------------------------------------------------
// SM-C3: Appeals rejected as a share of appeals filed. `appeal` rows this report month,
// joined to `penalty.state` the same way `referee-appeal-detail.tsx` already infers an
// appeal's outcome from that same column:
//   'voided'                        -> approved (rule_appeal(true) sets this unconditionally)
//   'owed' | 'waived' | 'collected' -> rejected (all three are only ever reachable through a
//                                      rejection's own held -> owed transition; `waived` and
//                                      `collected` are later, unrelated events on top of that
//                                      same rejection, never a second ruling)
//   'dropped'                       -> dropped (timed out; nobody ruled)
//   'held' | null                   -> excluded — still pending, or the joined penalty could
//                                      not be read; either way not a resolved outcome yet
// ---------------------------------------------------------------------------------

export interface AppealOutcomeRow {
  penalty_state: PenaltyState | null;
}

export interface AppealOutcomeTotals {
  rejected: number;
  approved: number;
  dropped: number;
}

export function foldAppealOutcomes(rows: readonly AppealOutcomeRow[]): AppealOutcomeTotals {
  let rejected = 0;
  let approved = 0;
  let dropped = 0;

  for (const row of rows) {
    switch (row.penalty_state) {
      case 'voided':
        approved++;
        break;
      case 'owed':
      case 'waived':
      case 'collected':
        rejected++;
        break;
      case 'dropped':
        dropped++;
        break;
      case 'held':
      case null:
        break;
      default: {
        const exhaustive: never = row.penalty_state;
        throw new Error(`foldAppealOutcomes: unhandled penalty state ${String(exhaustive)}`);
      }
    }
  }

  return { rejected, approved, dropped };
}

/** `rejected / (rejected + approved + dropped)`, or `null` when no appeal this month has
 *  reached a resolved outcome yet (I/O Matrix: "No appeals filed this month" reports "no
 *  data", never a divide-by-zero). */
export function appealRejectShare(totals: AppealOutcomeTotals): number | null {
  const denominator = totals.rejected + totals.approved + totals.dropped;
  return denominator > 0 ? totals.rejected / denominator : null;
}

// ---------------------------------------------------------------------------------
// Presentation. Kept here for the reason every other `*_COPY` object in this codebase gives:
// copy rules, testable independent of a component.
// ---------------------------------------------------------------------------------

export function formatRate(rate: number | null): string {
  return rate === null ? 'No data' : `${Math.round(rate * 100)}%`;
}

export function formatDays(days: number | null): string {
  if (days === null) return 'No data';
  return days === 1 ? '1 day' : `${days} days`;
}

export const MONTHLY_REPORT_COPY = {
  title: 'Monthly report',
  loading: 'Working…',
  failed: 'Failed.',
  subtitle: (monthLabel: string) => `${monthLabel}, the most recently completed month.`,

  chainsHeading: 'Chains',
  noChains: 'No commitments to show.',
  chainLine: (currentDays: number, longestDays: number): string =>
    `Day ${currentDays} · best ${longestDays}`,

  returnHeading: 'Median days to return after a Failed Day',

  completionHeading: 'Commitment completion',
  noCompletionData: 'No data this month.',
  completionLine: (answered: number, asked: number): string => `${answered} of ${asked}`,

  silenceHeading: 'Silence episodes',
  silenceCount: (count: number): string => (count === 1 ? '1 episode' : `${count} episodes`),

  refereeHeading: 'Referee activity',
  refereeActive: 'The referee ruled on an appeal or collected a Penalty this month.',
  refereeInactive: 'The referee neither ruled on an appeal nor collected a Penalty this month.',

  answerRateHeading: 'Declaration answer rate',
  noAnswerRateData: 'No data this month.',

  penaltiesHeading: 'Penalties',
  incurredLabel: 'Incurred',
  collectedLabel: 'Collected',
  penaltyLine: (count: number, totalDong: number): string => `${count} · ${formatDong(totalDong)}`,
  noPenalties: 'None.',

  acknowledgeHeading: 'Median days to acknowledge the first Failed Day',

  appealsHeading: 'Appeals rejected as a share filed',
  noAppealsData: 'No data — no appeals filed this month.',
  appealShareLine: (totals: AppealOutcomeTotals): string =>
    `${totals.rejected} of ${totals.rejected + totals.approved + totals.dropped} rejected`,
} as const;
