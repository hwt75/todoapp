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
/** `held` and `dropped` arrive with Story 4.4 (Appeal): a machine-filed miss under appeal
 *  moves its Penalty to `held`, and one whose deadline passed with no ruling to `dropped`
 *  — never back to `owed` on its own. `voided` arrives with Story 4.6: the referee's own
 *  "He did it" ruling on a Held Penalty — distinct from `dropped` (nobody ruled; the clock
 *  did) because a decided reversal and an unresolved timeout are different facts, even
 *  though both cost nothing. A `voided` penalty belongs to a superseded settlement (the
 *  ruling's own corrective row takes its place — `20260825090000`), so it structurally
 *  never reaches `penalty_current`/the Ledger the way `held`/`dropped` do —
 *  `components/referee-appeal-detail.tsx` infers it by comparing settlement ids rather than
 *  reading it off any row (this codebase's one-door-per-table rule, `lib/chain.test.ts`,
 *  forbids reading the base `penalty` table directly). The case exists here only so this
 *  shared union type and every exhaustive switch over it — `summarizeReferee`,
 *  `ledgerPillLabel`/`ledgerPillFamily` below — compile rather than silently misclassify a
 *  state that now exists. `collected` (4.7) and `waived` (5.1) are still ahead. */
export type PenaltyState = 'owed' | 'held' | 'dropped' | 'voided';
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
  /** Story 4.4: which commitment this is, and who filed the day's `slipped` declaration for
   *  it — the exact two facts `appeal_hold_penalty()`'s own trigger checks server-side.
   *  Both optional so every pre-4.4 caller (and fixture) that never selected these columns
   *  keeps compiling and simply never offers Contest. */
  commitment_id?: string;
  filed_by?: 'doer' | 'auto_check';
}

export interface AppealableMiss {
  commitmentId: string;
  commitmentName: string;
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
  /** Which of this day's misses can still be contested: machine-filed (`filed_by ===
   *  'auto_check'`) and the day's Penalty is still `owed` — the same two conditions
   *  `appeal_hold_penalty()` enforces server-side, mirrored here only to decide whether the
   *  Contest affordance renders at all. Always empty on a week row (no appeal exists for
   *  Weekly Quota) and once the Penalty has moved off `owed`. */
  appealable: AppealableMiss[];
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
  const appealableByDay = new Map<string, AppealableMiss[]>();
  for (const miss of misses) {
    missedByDay.set(miss.for_day, [...(missedByDay.get(miss.for_day) ?? []), miss.commitment_name]);
    if (miss.filed_by === 'auto_check' && miss.commitment_id) {
      appealableByDay.set(miss.for_day, [
        ...(appealableByDay.get(miss.for_day) ?? []),
        { commitmentId: miss.commitment_id, commitmentName: miss.commitment_name },
      ]);
    }
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
      // Only an `owed` Penalty on a `failed` day is still contestable — `appeal_hold_penalty()`
      // requires the same `verdict = 'failed'` server-side (a day that closed on the clock,
      // not on his word, is a different fact from an admitted slip and is never appealable,
      // even when one of its frozen outcomes happens to read `missed`); one already `held`,
      // `dropped` or otherwise resolved has nothing left for Contest to do; and a week row
      // never carries an appeal at all (Weekly Quota is out of Story 4.4's scope).
      appealable:
        kind === 'day' && settlement.verdict === 'failed' && penalty?.state === 'owed'
          ? (appealableByDay.get(settlement.period) ?? [])
              .slice()
              .sort((a, b) => a.commitmentName.localeCompare(b.commitmentName))
          : [],
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
  // Held and Dropped both name a real, distinct fact — a Held Penalty is not yet decided
  // (still Owed in every sense that matters until it is), and Dropped is not the same fact
  // as Owed either: money that was never actually collected must never read the same as
  // money that stands.
  if (row.state === 'held') return 'Held';
  if (row.state === 'dropped') return 'Dropped';
  // Unreachable through penalty_current in practice (see the PenaltyState comment above) —
  // kept distinct from `Dropped` per Story 4.6's own boundary: a decided reversal is not
  // the same fact as an unresolved timeout, even where neither ever renders today.
  if (row.state === 'voided') return 'Voided';
  return row.state === 'owed' ? 'Owed' : 'Failed';
}

/**
 * Which pill family a row's colour comes from.
 *
 * `held` (a Penalty on hold pending appeal) is deliberately the **urgent** family, never
 * `failed` and never the `held` *colour* family either — that name means good/complete
 * elsewhere in this design system (a chain that held, a grace day that waived a miss), and
 * a Held Penalty is "sort this out", not "you lost this" (epic-4-context.md's own note).
 * `dropped` — the timeout resolved in his favour — takes the `held` colour family instead,
 * alongside `waived`: both are a bad day that ended up costing nothing.
 */
export function ledgerPillFamily(row: LedgerRow): 'held' | 'urgent' | 'failed' {
  if (row.verdict === 'clean') return 'held';
  if (row.state === 'held') return 'urgent';
  if (row.state === 'dropped') return 'held';
  // A won appeal, same good/resolved family as `dropped` and a clean day — money that in
  // the end cost nothing, never the failed family a row that still owes gets.
  if (row.state === 'voided') return 'held';
  return 'failed';
}

/** How much one failed day costs, for anywhere that needs to say it before it has happened. */
export const ONE_FAILED_DAY = PENALTY_DONG;
