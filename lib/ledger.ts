/**
 * The ledger: one row per day that has been judged.
 *
 * A row is a **day**, not a commitment. The acceptance criteria say a row shows "the
 * commitment involved", which reads as one row per miss — but FR-13 gives a Failed Day
 * exactly one Penalty regardless of how many were missed, so a row per miss would either
 * double the visible debt or show half-penalties that do not exist.
 *
 * So a row carries the day's verdict, its penalty if it has one, and the names of the
 * commitments that caused it. That is the only shape where the arithmetic stays honest and
 * the row still answers the question it exists for: why do I owe this.
 */

import { PENALTY_DONG, totalOwed } from './money';

export type DayVerdict = 'clean' | 'failed';
export type PenaltyState = 'owed';

/** The rows as they come back from the database, before folding. */
export interface SettlementRecord {
  period: string;
  verdict: DayVerdict;
  missed_count: number;
}

export interface PenaltyRecord {
  period: string;
  amount_dong: number;
  state: PenaltyState;
}

export interface MissRecord {
  for_day: string;
  commitment_name: string;
}

export interface LedgerRow {
  day: string;
  verdict: DayVerdict;
  /** Null on a clean day. A clean day has no penalty, not a penalty of zero. */
  amountDong: number | null;
  state: PenaltyState | null;
  /** Names of the penalty-carrying commitments that were missed. */
  missed: string[];
}

/**
 * Folds a day's settlement, its penalty and its misses into one row.
 *
 * Newest first: the ledger is opened to find out about something recent, and on the worst
 * day it is reached in one tap from Today. Making him scroll past a year of history to
 * reach today would be a small cruelty on exactly the day it lands hardest.
 */
export function buildLedger(
  settlements: readonly SettlementRecord[],
  penalties: readonly PenaltyRecord[],
  misses: readonly MissRecord[],
): LedgerRow[] {
  const penaltyByDay = new Map(penalties.map((p) => [p.period, p]));

  const missedByDay = new Map<string, string[]>();
  for (const miss of misses) {
    missedByDay.set(miss.for_day, [...(missedByDay.get(miss.for_day) ?? []), miss.commitment_name]);
  }

  return [...settlements]
    .sort((a, b) => (a.period < b.period ? 1 : a.period > b.period ? -1 : 0))
    .map((settlement) => {
      const penalty = penaltyByDay.get(settlement.period) ?? null;
      return {
        day: settlement.period,
        verdict: settlement.verdict,
        amountDong: penalty?.amount_dong ?? null,
        state: penalty?.state ?? null,
        missed: (missedByDay.get(settlement.period) ?? []).slice().sort(),
      };
    });
}

/** What the debt block shows. Cumulative since first use, never reset by a period boundary. */
export function outstandingTotal(rows: readonly LedgerRow[]): number {
  return totalOwed(
    rows.filter((r) => r.state === 'owed' && r.amountDong !== null).map((r) => r.amountDong!),
  );
}

/**
 * The words on a ledger row's pill.
 *
 * Every pill carries a word as well as a tint, so a reader who cannot distinguish the
 * families loses nothing. A clean day says so rather than saying nothing — a blank row
 * reads as missing data.
 */
export function ledgerPillLabel(row: LedgerRow): string {
  if (row.verdict === 'clean') return 'Clean';
  return row.state === 'owed' ? 'Owed' : 'Failed';
}

/** How much one failed day costs, for anywhere that needs to say it before it has happened. */
export const ONE_FAILED_DAY = PENALTY_DONG;
