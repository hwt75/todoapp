import { describe, expect, it } from 'vitest';
import {
  type MissRecord,
  type PenaltyRecord,
  type SettlementRecord,
  buildLedger,
  ledgerPillFamily,
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

describe('a week row folds in alongside day rows (3.4)', () => {
  const failedWeek: SettlementRecord = { period: '2026-08-17', verdict: 'failed', missed_count: 1 };
  const cleanWeek: SettlementRecord = { period: '2026-08-10', verdict: 'clean', missed_count: 0 };
  const weekPenalty: PenaltyRecord = {
    period: '2026-08-17',
    amount_dong: PENALTY_DONG,
    state: 'owed',
  };

  it('is tagged kind: week, distinct from a day row', () => {
    const rows = buildLedger([], [], [], [failedWeek], [weekPenalty]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ kind: 'week', day: '2026-08-17', amountDong: PENALTY_DONG });
  });

  it('names nothing — Week Close freezes no per-commitment outcome', () => {
    const rows = buildLedger([], [], [], [failedWeek], [weekPenalty]);
    expect(rows[0].missed).toEqual([]);
  });

  it('leaves existing day-row behavior unchanged when no week rows are given', () => {
    const rows = buildLedger([failedDay], [penalty], misses);
    expect(rows).toEqual(buildLedger([failedDay], [penalty], misses, [], []));
  });

  it('sorts alongside day rows, newest first, by period', () => {
    const rows = buildLedger([failedDay, cleanDay], [penalty], misses, [failedWeek, cleanWeek]);
    // failedDay (08-18) newest, then the 08-17 pair (cleanDay and failedWeek — same date,
    // both assert '2026-08-17' regardless of which comes first), then cleanWeek (08-10).
    expect(rows.map((r) => r.day)).toEqual([
      '2026-08-18',
      '2026-08-17',
      '2026-08-17',
      '2026-08-10',
    ]);
  });

  it('breaks a same-date tie week-before-day, rather than leaving it to insertion order', () => {
    const rows = buildLedger([cleanDay], [], [], [failedWeek]);
    expect(rows.map((r) => r.kind)).toEqual(['week', 'day']);
  });

  it("does not let a week's penalty answer a same-dated day's lookup, or vice versa", () => {
    // A week's period is an ordinary calendar date, so it can coincide with an actual
    // day's own settlement period. Each must resolve strictly against its own kind.
    const dayOnThatDate: SettlementRecord = {
      period: '2026-08-17',
      verdict: 'clean',
      missed_count: 0,
    };
    const rows = buildLedger([dayOnThatDate], [], [], [failedWeek], [weekPenalty]);

    const dayRow = rows.find((r) => r.kind === 'day')!;
    const weekRow = rows.find((r) => r.kind === 'week')!;

    expect(dayRow.amountDong).toBeNull();
    expect(weekRow.amountDong).toBe(PENALTY_DONG);
  });

  it('a clean week has no penalty, not a penalty of zero', () => {
    const rows = buildLedger([], [], [], [cleanWeek], []);
    expect(rows[0].amountDong).toBeNull();
    expect(rows[0].state).toBeNull();
  });

  it('counts toward the outstanding total the same as a day penalty', () => {
    const rows = buildLedger([], [], [], [failedWeek], [weekPenalty]);
    expect(outstandingTotal(rows)).toBe(PENALTY_DONG);
  });

  it('carries a pill label the same way a day row does', () => {
    const rows = buildLedger([], [], [], [failedWeek], [weekPenalty]);
    expect(ledgerPillLabel(rows[0])).toBe('Owed');
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

  it('says Expired for a day that closed on the clock, never Owed', () => {
    // What he did and what he failed to say are different facts. A record that calls
    // silence an admission is telling him he said something he never said.
    const expiredDay = { period: '2026-08-14', verdict: 'expired' as const, missed_count: 1 };
    const itsPenalty = { period: '2026-08-14', amount_dong: PENALTY_DONG, state: 'owed' as const };
    const row = buildLedger([expiredDay], [itsPenalty], [])[0];

    expect(ledgerPillLabel(row)).toBe('Expired');
    expect(ledgerPillLabel(row)).not.toBe('Owed');
  });

  it('charges an expired day exactly what an admitted one costs', () => {
    // Cheaper would make silence cheaper than honesty, which is the failure the story is
    // named after. Dearer would punish being unreachable.
    const expiredDay = { period: '2026-08-14', verdict: 'expired' as const, missed_count: 1 };
    const rows = buildLedger(
      [expiredDay, failedDay],
      [{ period: '2026-08-14', amount_dong: PENALTY_DONG, state: 'owed' }, penalty],
      misses,
    );
    expect(rows.map((r) => r.amountDong)).toEqual([PENALTY_DONG, PENALTY_DONG]);
  });
});

describe('a Penalty on hold, and one dropped by timeout (Story 4.4)', () => {
  const heldPenalty: PenaltyRecord = {
    period: '2026-08-18',
    amount_dong: PENALTY_DONG,
    state: 'held',
  };
  const droppedPenalty: PenaltyRecord = {
    period: '2026-08-18',
    amount_dong: PENALTY_DONG,
    state: 'dropped',
  };

  it('says Held, never Owed and never Failed', () => {
    const row = buildLedger([failedDay], [heldPenalty], misses)[0];
    expect(ledgerPillLabel(row)).toBe('Held');
  });

  it('says Dropped, never Owed', () => {
    const row = buildLedger([failedDay], [droppedPenalty], misses)[0];
    expect(ledgerPillLabel(row)).toBe('Dropped');
  });

  it('colours Held urgent — never the failed family and never the held colour family', () => {
    // epic-4-context.md's own note: "held" the colour token means good/complete elsewhere
    // in this design system, so a Held Penalty (not yet decided) has to use a third family
    // rather than either of the two a reader would otherwise assume.
    const row = buildLedger([failedDay], [heldPenalty], misses)[0];
    expect(ledgerPillFamily(row)).toBe('urgent');
    expect(ledgerPillFamily(row)).not.toBe('failed');
  });

  it('colours Dropped the held (good/resolved) family, like a clean day', () => {
    // The timeout resolved in his favour — the same family a chain that held or a grace
    // day gets, not the failed family a row that still costs him money gets.
    const row = buildLedger([failedDay], [droppedPenalty], misses)[0];
    expect(ledgerPillFamily(row)).toBe('held');
  });

  it('excludes a Held Penalty from the outstanding total — it is not owed', () => {
    const rows = buildLedger([failedDay], [heldPenalty], misses);
    expect(outstandingTotal(rows)).toBe(0);
  });

  it('excludes a Dropped Penalty from the outstanding total', () => {
    const rows = buildLedger([failedDay], [droppedPenalty], misses);
    expect(outstandingTotal(rows)).toBe(0);
  });

  it('an owed day still colours failed, unaffected by held/dropped existing as states', () => {
    const row = buildLedger([failedDay], [penalty], misses)[0];
    expect(ledgerPillFamily(row)).toBe('failed');
  });

  it('a clean day still colours held, unaffected by held/dropped existing as states', () => {
    const row = buildLedger([cleanDay], [], [])[0];
    expect(ledgerPillFamily(row)).toBe('held');
  });
});

describe('a Penalty a won appeal voided (Story 4.6)', () => {
  // Unreachable through a real penalty_current read in production — a voided penalty's own
  // settlement is superseded by the ruling's own corrective row, so it drops out of
  // penalty_current entirely (20260825090000). Exercised here anyway: PenaltyState is a
  // shared union type, and both functions below are written as exhaustive checks over it.
  const voidedPenalty: PenaltyRecord = {
    period: '2026-08-18',
    amount_dong: PENALTY_DONG,
    state: 'voided',
  };

  it('says Voided, distinct from Dropped', () => {
    const row = buildLedger([failedDay], [voidedPenalty], misses)[0];
    expect(ledgerPillLabel(row)).toBe('Voided');
    expect(ledgerPillLabel(row)).not.toBe('Dropped');
  });

  it('colours the held (good/resolved) family, the same as Dropped and a clean day', () => {
    const row = buildLedger([failedDay], [voidedPenalty], misses)[0];
    expect(ledgerPillFamily(row)).toBe('held');
  });

  it('excludes a voided Penalty from the outstanding total', () => {
    const rows = buildLedger([failedDay], [voidedPenalty], misses);
    expect(outstandingTotal(rows)).toBe(0);
  });
});

describe('a Penalty the referee marked Collected (Story 4.7)', () => {
  const collectedPenalty: PenaltyRecord = {
    period: '2026-08-18',
    amount_dong: PENALTY_DONG,
    state: 'collected',
  };

  it('says Collected, distinct from Owed', () => {
    const row = buildLedger([failedDay], [collectedPenalty], misses)[0];
    expect(ledgerPillLabel(row)).toBe('Collected');
    expect(ledgerPillLabel(row)).not.toBe('Owed');
  });

  it('colours the held (good/resolved) family, the same as Dropped and Voided', () => {
    const row = buildLedger([failedDay], [collectedPenalty], misses)[0];
    expect(ledgerPillFamily(row)).toBe('held');
    expect(ledgerPillFamily(row)).not.toBe('failed');
  });

  it('excludes a collected Penalty from the outstanding total — the debt has been paid', () => {
    const rows = buildLedger([failedDay], [collectedPenalty], misses);
    expect(outstandingTotal(rows)).toBe(0);
  });
});

describe('a resolved Penalty on a day that closed expired (Epic 4 retro, 2026-08-27, finding A6)', () => {
  // A day can close `expired` (silence from some *other* commitment) while still freezing
  // one commitment's own machine-filed `missed` and its Penalty — that Penalty can still
  // resolve to held/dropped/voided/collected. Before this fix, `ledgerPillLabel` checked
  // `verdict === 'expired'` before any of these states, so a paid or resolved debt kept
  // reading "Expired" forever, hiding what actually happened to the money.
  const expiredDay: SettlementRecord = { period: '2026-08-18', verdict: 'expired', missed_count: 1 };

  it.each([
    ['held', 'Held'],
    ['dropped', 'Dropped'],
    ['voided', 'Voided'],
    ['collected', 'Collected'],
  ] as const)('says %s, never Expired, on a day that otherwise closed expired', (state, label) => {
    const penaltyRecord: PenaltyRecord = { period: '2026-08-18', amount_dong: PENALTY_DONG, state };
    const row = buildLedger([expiredDay], [penaltyRecord], misses)[0];
    expect(ledgerPillLabel(row)).toBe(label);
    expect(ledgerPillLabel(row)).not.toBe('Expired');
  });

  it('still says Expired when nothing else resolved the Penalty (owed, unaffected by this fix)', () => {
    const row = buildLedger([expiredDay], [penalty], misses)[0];
    expect(ledgerPillLabel(row)).toBe('Expired');
  });
});

describe('a Penalty a Grace Day waived (Story 5.1)', () => {
  // apply_grace_days() gives the corrective settlement its own fresh penalty row, already
  // waived (20260825110000) — so unlike `voided`, this state genuinely reaches
  // penalty_current, and its own settlement genuinely reads verdict `clean` (the day is
  // forgiven whole). buildLedger has to read the two together correctly. A settlement of its
  // own, sharing the waived penalty's own period — `cleanDay` above is a different day and
  // would not fold together with it.
  const correctedDay: SettlementRecord = {
    period: '2026-08-18',
    verdict: 'clean',
    missed_count: 0,
  };
  const waivedPenalty: PenaltyRecord = {
    period: '2026-08-18',
    amount_dong: PENALTY_DONG,
    state: 'waived',
  };

  it('says Waived, not Clean, even though the corrective settlement reads verdict clean', () => {
    const row = buildLedger([correctedDay], [waivedPenalty], [])[0];
    expect(ledgerPillLabel(row)).toBe('Waived');
    expect(ledgerPillLabel(row)).not.toBe('Clean');
  });

  it('colours the held (good/resolved) family, the same as a clean day, Dropped, Voided and Collected', () => {
    const row = buildLedger([correctedDay], [waivedPenalty], [])[0];
    expect(ledgerPillFamily(row)).toBe('held');
  });

  it('excludes a waived Penalty from the outstanding total — it is not owed', () => {
    const rows = buildLedger([correctedDay], [waivedPenalty], []);
    expect(outstandingTotal(rows)).toBe(0);
  });
});

describe('which day rows offer a Grace Day control (Story 5.1)', () => {
  it('offers it on a Failed, owed day — the same two conditions grace_day_validate() checks', () => {
    const row = buildLedger([failedDay], [penalty], misses)[0];
    expect(row.graceable).toBe(true);
  });

  it('never offers it on a clean day — nothing to forgive', () => {
    const row = buildLedger([cleanDay], [], [])[0];
    expect(row.graceable).toBe(false);
  });

  it('never offers it on a day that closed expired — silence, not an admitted or machine-filed miss', () => {
    const expiredDay: SettlementRecord = {
      period: '2026-08-14',
      verdict: 'expired',
      missed_count: 1,
    };
    const itsPenalty: PenaltyRecord = {
      period: '2026-08-14',
      amount_dong: PENALTY_DONG,
      state: 'owed',
    };
    const row = buildLedger([expiredDay], [itsPenalty], [])[0];
    expect(row.graceable).toBe(false);
  });

  it('stops offering it once the Penalty has moved off owed', () => {
    for (const state of ['held', 'dropped', 'voided', 'collected', 'waived'] as const) {
      const p: PenaltyRecord = { period: '2026-08-18', amount_dong: PENALTY_DONG, state };
      const row = buildLedger([failedDay], [p], misses)[0];
      expect(row.graceable).toBe(false);
    }
  });

  it('never appears on a week row — Grace Days are day-scoped only (Story 4.4’s own day-only restriction)', () => {
    const failedWeek: SettlementRecord = {
      period: '2026-08-18',
      verdict: 'failed',
      missed_count: 1,
    };
    const weekPenalty: PenaltyRecord = {
      period: '2026-08-18',
      amount_dong: PENALTY_DONG,
      state: 'owed',
    };
    const rows = buildLedger([], [], [], [failedWeek], [weekPenalty]);
    expect(rows[0].graceable).toBe(false);
  });
});

describe('which misses can still be contested (Story 4.4)', () => {
  const machineFiled: MissRecord = {
    for_day: '2026-08-18',
    commitment_id: 'commitment-tryhackme',
    commitment_name: 'TryHackMe',
    filed_by: 'auto_check',
  };
  const selfDeclared: MissRecord = {
    for_day: '2026-08-18',
    commitment_id: 'commitment-gym',
    commitment_name: 'Gym',
    filed_by: 'doer',
  };

  it('offers a machine-filed miss on an owed Penalty', () => {
    const row = buildLedger([failedDay], [penalty], [machineFiled])[0];
    expect(row.appealable).toEqual([
      { commitmentId: 'commitment-tryhackme', commitmentName: 'TryHackMe' },
    ]);
  });

  it('never offers a miss on a day that closed `expired`, even with an owed, machine-filed Penalty', () => {
    // A day can close `expired` on a different commitment's silence while still freezing
    // one commitment's own machine-filed `missed` and creating an owed Penalty from it
    // (`settle_day`'s "an expired day costs exactly what an admitted one costs"). Appeal
    // exists to contest what the machine *said* on a day that closed on someone's word
    // (`failed`) — never a day that closed on someone else's silence — matching the same
    // `verdict = 'failed'` requirement `appeal_hold_penalty()` enforces server-side
    // (`20260824150000_an_appeal_reads_the_day_that_stands.sql`). Offering Contest here
    // would render a button the server is guaranteed to refuse.
    const expiredDay: SettlementRecord = {
      period: '2026-08-18',
      verdict: 'expired',
      missed_count: 1,
    };
    const row = buildLedger([expiredDay], [penalty], [machineFiled])[0];
    expect(row.appealable).toEqual([]);
  });

  it('never offers the author’s own honest slip — nothing to contest', () => {
    const row = buildLedger([failedDay], [penalty], [selfDeclared])[0];
    expect(row.appealable).toEqual([]);
  });

  it('offers only the machine-filed one when both kinds missed the same day', () => {
    const row = buildLedger([failedDay], [penalty], [machineFiled, selfDeclared])[0];
    expect(row.appealable.map((a) => a.commitmentName)).toEqual(['TryHackMe']);
  });

  it('stops offering it once the Penalty has moved off owed', () => {
    const held: PenaltyRecord = { period: '2026-08-18', amount_dong: PENALTY_DONG, state: 'held' };
    const row = buildLedger([failedDay], [held], [machineFiled])[0];
    expect(row.appealable).toEqual([]);
  });

  it('never appears on a week row — Weekly Quota carries no appeal', () => {
    const failedWeek: SettlementRecord = {
      period: '2026-08-18',
      verdict: 'failed',
      missed_count: 1,
    };
    const weekPenalty: PenaltyRecord = {
      period: '2026-08-18',
      amount_dong: PENALTY_DONG,
      state: 'owed',
    };
    const rows = buildLedger([], [], [], [failedWeek], [weekPenalty]);
    expect(rows[0].appealable).toEqual([]);
  });

  it('a pre-4.4 caller that never selected commitment_id/filed_by still compiles and offers nothing', () => {
    const row = buildLedger([failedDay], [penalty], misses)[0];
    expect(row.appealable).toEqual([]);
  });
});
