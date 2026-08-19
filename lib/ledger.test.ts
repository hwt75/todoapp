import { describe, expect, it } from 'vitest';
import {
  type MissRecord,
  type PenaltyRecord,
  type SettlementRecord,
  buildLedger,
  ledgerPillLabel,
  outstandingTotal,
} from './ledger';
import { PENALTY_DONG } from './money';

const failedDay: SettlementRecord = { period: '2026-08-18', verdict: 'failed', missed_count: 2 };
const cleanDay: SettlementRecord = { period: '2026-08-17', verdict: 'clean', missed_count: 0 };

const penalty: PenaltyRecord = {
  period: '2026-08-18',
  amount_dong: PENALTY_DONG,
  state: 'owed',
};

const misses: MissRecord[] = [
  { for_day: '2026-08-18', commitment_name: 'TryHackMe' },
  { for_day: '2026-08-18', commitment_name: 'Gym' },
];

describe('a ledger row is a day, not a miss', () => {
  it('two commitments missed on one day make one row', () => {
    // FR-13: a Failed Day generates one Penalty regardless of how many were missed. Two
    // rows would double the visible debt or show two half-penalties that do not exist.
    const rows = buildLedger([failedDay], [penalty], misses);
    expect(rows).toHaveLength(1);
    expect(rows[0].amountDong).toBe(PENALTY_DONG);
  });

  it('names every commitment that caused it, so the row answers "why"', () => {
    const rows = buildLedger([failedDay], [penalty], misses);
    expect(rows[0].missed).toEqual(['Gym', 'TryHackMe']);
  });

  it('a clean day has no penalty, not a penalty of zero', () => {
    // Zero is a number he would have to interpret. Absence is not.
    const rows = buildLedger([cleanDay], [], []);
    expect(rows[0].amountDong).toBeNull();
    expect(rows[0].state).toBeNull();
  });

  it('a clean day still appears — the ledger is the record, not the bad news', () => {
    const rows = buildLedger([failedDay, cleanDay], [penalty], misses);
    expect(rows.map((r) => r.day)).toEqual(['2026-08-18', '2026-08-17']);
  });
});

describe('order', () => {
  it('is newest first', () => {
    // It is opened to find out about something recent, and on the worst day it is one tap
    // from Today. Scrolling past a year of history to reach today would land hardest
    // exactly when it hurts most.
    const rows = buildLedger(
      [
        { period: '2026-08-10', verdict: 'clean', missed_count: 0 },
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-14', verdict: 'clean', missed_count: 0 },
      ],
      [],
      [],
    );
    expect(rows.map((r) => r.day)).toEqual(['2026-08-18', '2026-08-14', '2026-08-10']);
  });

  it('does not mutate what it was given', () => {
    const settlements = [cleanDay, failedDay];
    buildLedger(settlements, [], []);
    expect(settlements[0].period).toBe('2026-08-17');
  });
});

describe('the total owed', () => {
  it('is zero with no penalties', () => {
    expect(outstandingTotal(buildLedger([cleanDay], [], []))).toBe(0);
  });

  it('sums the owed rows only', () => {
    const rows = buildLedger([failedDay, cleanDay], [penalty], misses);
    expect(outstandingTotal(rows)).toBe(PENALTY_DONG);
  });

  it('accumulates across days and is never reset by a boundary', () => {
    // A debt that resets each month is a debt the product has quietly forgiven, and
    // forgiveness here has exactly two forms and both are recorded acts.
    const days = ['2026-06-30', '2026-07-01', '2026-08-18'];
    const rows = buildLedger(
      days.map((period) => ({ period, verdict: 'failed' as const, missed_count: 1 })),
      days.map((period) => ({ period, amount_dong: PENALTY_DONG, state: 'owed' as const })),
      [],
    );
    expect(outstandingTotal(rows)).toBe(PENALTY_DONG * 3);
  });

  it('stays exact over a long run', () => {
    const days = Array.from({ length: 500 }, (_, i) => `2026-01-${String((i % 28) + 1)}-${i}`);
    const rows = buildLedger(
      days.map((period) => ({ period, verdict: 'failed' as const, missed_count: 1 })),
      days.map((period) => ({ period, amount_dong: PENALTY_DONG, state: 'owed' as const })),
      [],
    );
    expect(outstandingTotal(rows)).toBe(250_000_000);
  });
});

describe('what a pill says', () => {
  it('never says nothing', () => {
    // Colour is never the sole carrier of state, and a blank row reads as missing data
    // rather than as a good day.
    const rows = buildLedger([failedDay, cleanDay], [penalty], misses);
    for (const row of rows) {
      expect(ledgerPillLabel(row).trim()).not.toBe('');
    }
  });

  it('says Owed for a failed day with a penalty', () => {
    expect(ledgerPillLabel(buildLedger([failedDay], [penalty], misses)[0])).toBe('Owed');
  });

  it('says Clean for a day that held', () => {
    expect(ledgerPillLabel(buildLedger([cleanDay], [], [])[0])).toBe('Clean');
  });
});
