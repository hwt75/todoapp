/**
 * The ledger: one row per day, and one row per week, that has been judged.
 *
 * A day row is a **day**, not a commitment. The acceptance criteria say a row shows "the
 * commitment involved", which reads as one row per miss — but FR-13 gives a Failed Day
 * exactly one Penalty regardless of how many were missed, so a row per miss would either
 * double the visible debt or show half-penalties that do not exist. The same reasoning
 * gives a Failed Week exactly one row (3.4), never one per Weekly Quota commitment that
 * fell short that week.
 *
 * So a row carries its verdict, its penalty if it has one, and — for a day row — the names
 * of the commitments that caused it. A week row names nothing (3.4 never freezes a
 * per-commitment week outcome); its own notification already said what fell short.
 */

import { PENALTY_DONG, totalOwed } from './money';

export type DayVerdict = 'clean' | 'failed' | 'expired';
export type PenaltyState = 'owed';
export type LedgerKind = 'day' | 'week';

/** The rows as they come back from the database, before folding. Shared shape for a day's
 *  and a week's settlement/penalty reads — `kind` distinguishes which list each belongs to,
 *  carried alongside rather than on the record itself, since the two reads are already
 *  separated by the `kind = 'day'` / `kind = 'week'` filter at the query (AD-8's own point:
 *  settlement_current/penalty_current agreeing on `kind` is what settlement itself wrote). */
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
  kind: LedgerKind;
  verdict: DayVerdict;
  /** Null on a clean day/week. A clean period has no penalty, not a penalty of zero. */
  amountDong: number | null;
  state: PenaltyState | null;
  /** Names of the penalty-carrying commitments that were missed. Always empty on a week
   *  row — Week Close freezes no per-commitment outcome (3.4's own "Never"). */
  missed: string[];
}

/**
 * Folds a day's settlement, its penalty and its misses into one row, and — when given —
 * a week's settlement and penalty into another, sorted alongside the day rows rather than
 * in a list of their own.
 *
 * Newest first: the ledger is opened to find out about something recent, and on the worst
 * day it is reached in one tap from Today. Making him scroll past a year of history to
 * reach today would be a small cruelty on exactly the day it lands hardest. A day row and a
 * week row can share the same `period` value (a week's period is the date it starts on,
 * which is an ordinary calendar date like any day's), so ties break week-before-day rather
 * than leaving the order to insertion sequence.
 */
export function buildLedger(
  settlements: readonly SettlementRecord[],
  penalties: readonly PenaltyRecord[],
  misses: readonly MissRecord[],
  weekSettlements: readonly SettlementRecord[] = [],
  weekPenalties: readonly PenaltyRecord[] = [],
): LedgerRow[] {
  // Keyed by kind as well as period: a week's period and a day's period both come from the
  // same date domain and commonly coincide (a week starts on some ordinary calendar day),
  // so period alone would let a week's penalty answer a day's lookup or vice versa.
  const penaltyByKey = new Map<string, PenaltyRecord>();
  for (const p of penalties) penaltyByKey.set(`day:${p.period}`, p);
  for (const p of weekPenalties) penaltyByKey.set(`week:${p.period}`, p);

  const missedByDay = new Map<string, string[]>();
  for (const miss of misses) {
    missedByDay.set(miss.for_day, [...(missedByDay.get(miss.for_day) ?? []), miss.commitment_name]);
  }

  const toRow = (kind: LedgerKind, settlement: SettlementRecord): LedgerRow => {
    const penalty = penaltyByKey.get(`${kind}:${settlement.period}`) ?? null;
    return {
      day: settlement.period,
      kind,
      verdict: settlement.verdict,
      amountDong: penalty?.amount_dong ?? null,
      state: penalty?.state ?? null,
      missed: kind === 'day' ? (missedByDay.get(settlement.period) ?? []).slice().sort() : [],
    };
  };

  const rows = [
    ...settlements.map((s) => toRow('day', s)),
    ...weekSettlements.map((s) => toRow('week', s)),
  ];

  return rows.sort((a, b) => {
    if (a.day !== b.day) return a.day < b.day ? 1 : -1;
    if (a.kind === b.kind) return 0;
    return a.kind === 'week' ? -1 : 1;
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
  // `Expired` is distinguishable from `Owed` on purpose. What he did and what he failed to
  // say are different facts about him, and a record that merges them tells him he admitted
  // something he never said.
  if (row.verdict === 'expired') return 'Expired';
  if (row.verdict === 'clean') return 'Clean';
  return row.state === 'owed' ? 'Owed' : 'Failed';
}

/** Whether a row's colour should come from the failed family. Expired costs the same. */
export function isFailedFamily(row: LedgerRow): boolean {
  return row.verdict !== 'clean';
}

/** How much one failed day costs, for anywhere that needs to say it before it has happened. */
export const ONE_FAILED_DAY = PENALTY_DONG;
