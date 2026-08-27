import { describe, expect, it } from 'vitest';
import {
  type AppealOutcomeRow,
  type ChainRow,
  type CommitmentAnswerRateRow,
  appealRejectShare,
  countSilenceEpisodes,
  daysBetween,
  foldAppealOutcomes,
  foldChains,
  foldCommitmentCompletion,
  foldDeclarationAnswerRate,
  foldPenaltyFigure,
  formatDays,
  formatMonthLabel,
  formatRate,
  isRefereeStillActive,
  lookaheadEndDay,
  median,
  medianDaysToAcknowledge,
  medianDaysToReturn,
  monthDayBounds,
  monthInstantBounds,
  mostRecentCompletedMonth,
  originalPenaltyRows,
  type OriginalPenaltyRow,
} from './monthly-report';

describe('the report always names the most recently completed month (no picker)', () => {
  it('reads one month back, in Asia/Ho_Chi_Minh, from the middle of a month', () => {
    expect(mostRecentCompletedMonth(new Date('2026-08-26T10:00:00+07:00'))).toEqual({
      year: 2026,
      month: 7,
    });
  });

  it('rolls the year back across a January boundary', () => {
    expect(mostRecentCompletedMonth(new Date('2026-01-15T10:00:00+07:00'))).toEqual({
      year: 2025,
      month: 12,
    });
  });

  it('reads the zone, not the reader device — 01:00 UTC on the 1st is already the 8th, HCM', () => {
    // 2026-08-01T01:00:00Z is 2026-08-01T08:00:00+07:00 — already August in HCM, so the most
    // recently completed month is July, not June.
    expect(mostRecentCompletedMonth(new Date('2026-08-01T01:00:00Z'))).toEqual({
      year: 2026,
      month: 7,
    });
  });
});

describe('month boundaries', () => {
  it('monthDayBounds gives a plain [gte, lt) calendar range', () => {
    expect(monthDayBounds(2026, 7)).toEqual({ gte: '2026-07-01', lt: '2026-08-01' });
  });

  it('monthDayBounds rolls the year at December', () => {
    expect(monthDayBounds(2026, 12)).toEqual({ gte: '2026-12-01', lt: '2027-01-01' });
  });

  it('monthInstantBounds carries the fixed Asia/Ho_Chi_Minh +07:00 offset — never a naive UTC range', () => {
    expect(monthInstantBounds(2026, 7)).toEqual({
      gte: '2026-07-01T00:00:00+07:00',
      lt: '2026-08-01T00:00:00+07:00',
    });
  });

  it('lookaheadEndDay extends 14 days past the month by default', () => {
    // 2026-08-01 + 14 days = 2026-08-15.
    expect(lookaheadEndDay(2026, 7)).toBe('2026-08-15');
  });

  it('lookaheadEndDay honors a caller-supplied window', () => {
    expect(lookaheadEndDay(2026, 7, 1)).toBe('2026-08-02');
  });

  it('formatMonthLabel names the month and year, independent of the reader’s own timezone', () => {
    expect(formatMonthLabel(2026, 7)).toBe('July 2026');
  });
});

describe('day-gap arithmetic (the daysSinceQuiet idiom, without its +1)', () => {
  it('one calendar day apart is a 1-day gap, not a 2-day streak', () => {
    expect(daysBetween('2026-07-10', '2026-07-11')).toBe(1);
  });

  it('the same day is a zero gap', () => {
    expect(daysBetween('2026-07-10', '2026-07-10')).toBe(0);
  });

  it('spans a month boundary correctly', () => {
    expect(daysBetween('2026-07-30', '2026-08-02')).toBe(3);
  });
});

describe('median', () => {
  it('is null for an empty list — "no data", never zero', () => {
    expect(median([])).toBeNull();
  });

  it('is the middle value for an odd-length list', () => {
    expect(median([5, 1, 3])).toBe(3);
  });

  it('averages the two middle values for an even-length list', () => {
    expect(median([1, 2, 3, 4])).toBe(2.5);
  });
});

describe('SM-2: median days to return after a Failed Day', () => {
  it('is null when there were no Failed days this month', () => {
    expect(medianDaysToReturn([], ['2026-07-05'])).toBeNull();
  });

  it('pairs each Failed day with the earliest later clean day', () => {
    // Failed on the 1st, clean on the 2nd -> 1. Failed on the 10th, clean on the 15th -> 5.
    const gap = medianDaysToReturn(['2026-07-01', '2026-07-10'], ['2026-07-02', '2026-07-15']);
    expect(gap).toBe(3);
  });

  it('excludes a Failed day whose only later clean day falls outside the lookahead window', () => {
    const gap = medianDaysToReturn(['2026-07-01'], ['2026-08-01'], 14);
    expect(gap).toBeNull();
  });

  it('never picks a clean day at or before the Failed day itself', () => {
    const gap = medianDaysToReturn(['2026-07-10'], ['2026-07-09', '2026-07-10', '2026-07-12']);
    expect(gap).toBe(2);
  });
});

describe('SM-C2: median days to acknowledge — the same gap logic against declaration answers', () => {
  it('converts an answered_at instant to its own Asia/Ho_Chi_Minh calendar day first', () => {
    // Failed 2026-07-10. A declaration answered at 2026-07-11T23:30:00Z is
    // 2026-07-12T06:30:00+07:00 in HCM — day 12, a 2-day gap, not a 1-day one a naive UTC
    // read of the instant's own date would produce.
    const gap = medianDaysToAcknowledge(['2026-07-10'], ['2026-07-11T23:30:00Z']);
    expect(gap).toBe(2);
  });

  it('is null when nothing was ever answered inside the window', () => {
    expect(medianDaysToAcknowledge(['2026-07-10'], [])).toBeNull();
  });
});

describe('SM-1: Chains — a plain fold, never recomputed', () => {
  it('attaches the commitment name and sorts alphabetically', () => {
    const rows: ChainRow[] = [
      { commitment_id: 'b', current_days: 3, longest_days: 5 },
      { commitment_id: 'a', current_days: 1, longest_days: 1 },
    ];
    const names = new Map([
      ['a', 'Gym'],
      ['b', 'No fap'],
    ]);
    expect(foldChains(rows, names)).toEqual([
      { commitmentId: 'a', commitmentName: 'Gym', currentDays: 1, longestDays: 1 },
      { commitmentId: 'b', commitmentName: 'No fap', currentDays: 3, longestDays: 5 },
    ]);
  });

  it('falls back to a generic name when the map has nothing for it', () => {
    const rows: ChainRow[] = [{ commitment_id: 'x', current_days: 0, longest_days: 0 }];
    expect(foldChains(rows, new Map())[0].commitmentName).toBe('A commitment');
  });
});

describe('SM-3 / SM-6: commitment_answer_rate_for_month, folded two ways', () => {
  const rows: CommitmentAnswerRateRow[] = [
    { commitment_id: 'gym', asked: 30, answered: 28 },
    { commitment_id: 'nofap', asked: 30, answered: 30 },
  ];
  const names = new Map([
    ['gym', 'Gym'],
    ['nofap', 'No fap'],
  ]);

  it('SM-3: per-commitment, generic — never hardcoded to a specific commitment', () => {
    const completion = foldCommitmentCompletion(rows, names);
    expect(completion).toEqual([
      { commitmentId: 'gym', commitmentName: 'Gym', asked: 30, answered: 28, rate: 28 / 30 },
      { commitmentId: 'nofap', commitmentName: 'No fap', asked: 30, answered: 30, rate: 1 },
    ]);
  });

  it('a commitment never asked reads no rate rather than dividing by zero', () => {
    const completion = foldCommitmentCompletion(
      [{ commitment_id: 'x', asked: 0, answered: 0 }],
      new Map(),
    );
    expect(completion[0].rate).toBeNull();
  });

  it('SM-6: summed across every commitment, never "answered within the morning window"', () => {
    expect(foldDeclarationAnswerRate(rows)).toEqual({ asked: 60, answered: 58, rate: 58 / 60 });
  });

  it('SM-6 reads no data, not a crash, when nothing was ever asked', () => {
    expect(foldDeclarationAnswerRate([]).rate).toBeNull();
  });
});

describe('SM-4: Silence episodes — a plain count of already-scoped rows', () => {
  it('counts whatever rows the query already scoped by month', () => {
    expect(
      countSilenceEpisodes([{ started_day: '2026-07-03' }, { started_day: '2026-07-20' }]),
    ).toBe(2);
  });

  it('reads zero, never undefined, for no episodes', () => {
    expect(countSilenceEpisodes([])).toBe(0);
  });
});

describe('SM-5: Referee still active', () => {
  it('reads true when either signal is non-empty', () => {
    expect(isRefereeStillActive(1, 0)).toBe(true);
    expect(isRefereeStillActive(0, 1)).toBe(true);
  });

  it('reads false only when the Referee neither ruled nor collected anything', () => {
    expect(isRefereeStillActive(0, 0)).toBe(false);
  });
});

describe('SM-C1: Penalties incurred / collected — two figures, never merged', () => {
  it('counts and sums independently', () => {
    expect(foldPenaltyFigure([{ amount_dong: 500_000 }, { amount_dong: 500_000 }])).toEqual({
      count: 2,
      totalDong: 1_000_000,
    });
  });

  it('reads zero for an empty set, never a crash', () => {
    expect(foldPenaltyFigure([])).toEqual({ count: 0, totalDong: 0 });
  });
});

describe('originalPenaltyRows (Epic 5 retro, 2026-08-27, finding A3)', () => {
  const original: OriginalPenaltyRow = {
    amount_dong: 500_000,
    settlement: { supersedes: null },
  };
  const corrective: OriginalPenaltyRow = {
    amount_dong: 500_000,
    settlement: { supersedes: 'settlement-original-id' },
  };

  it('keeps a penalty whose own settlement was never superseded', () => {
    expect(originalPenaltyRows([original])).toEqual([{ amount_dong: 500_000 }]);
  });

  it('excludes a corrective penalty — its settlement carries a non-null supersedes', () => {
    expect(originalPenaltyRows([corrective])).toEqual([]);
  });

  it('excludes the corrective row and keeps the original when both are present', () => {
    // Never double-counted alongside the original it corrects, and the original's own
    // figure is never lost just because a later correction also exists.
    expect(originalPenaltyRows([original, corrective])).toEqual([{ amount_dong: 500_000 }]);
  });

  it('excludes a row whose settlement could not be read at all', () => {
    expect(originalPenaltyRows([{ amount_dong: 500_000, settlement: null }])).toEqual([]);
  });

  it('reads empty for an empty set, never a crash', () => {
    expect(originalPenaltyRows([])).toEqual([]);
  });
});

describe('SM-C3: Appeals rejected as a share filed', () => {
  it('maps penalty.state the way referee-appeal-detail.tsx already infers an outcome', () => {
    const rows: AppealOutcomeRow[] = [
      { penalty_state: 'voided' }, // approved
      { penalty_state: 'owed' }, // rejected
      { penalty_state: 'waived' }, // rejected, later forgiven — still counts as rejected
      { penalty_state: 'collected' }, // rejected, later collected — still counts as rejected
      { penalty_state: 'dropped' }, // dropped (timed out)
      { penalty_state: 'held' }, // pending — excluded
    ];
    expect(foldAppealOutcomes(rows)).toEqual({ rejected: 3, approved: 1, dropped: 1 });
  });

  it('excludes a row whose joined penalty could not be read', () => {
    expect(foldAppealOutcomes([{ penalty_state: null }])).toEqual({
      rejected: 0,
      approved: 0,
      dropped: 0,
    });
  });

  it('reads no data, not a divide-by-zero, when no appeal has a resolved outcome', () => {
    expect(appealRejectShare({ rejected: 0, approved: 0, dropped: 0 })).toBeNull();
    expect(appealRejectShare(foldAppealOutcomes([{ penalty_state: 'held' }]))).toBeNull();
  });

  it('is rejected divided by every resolved outcome', () => {
    const totals = foldAppealOutcomes([
      { penalty_state: 'owed' },
      { penalty_state: 'owed' },
      { penalty_state: 'voided' },
    ]);
    expect(appealRejectShare(totals)).toBe(2 / 3);
  });
});

describe('presentation', () => {
  it('formatRate reads "No data" for null, a rounded percent otherwise', () => {
    expect(formatRate(null)).toBe('No data');
    expect(formatRate(0.9333)).toBe('93%');
  });

  it('formatDays reads "No data" for null, singular for one, plural otherwise', () => {
    expect(formatDays(null)).toBe('No data');
    expect(formatDays(1)).toBe('1 day');
    expect(formatDays(5)).toBe('5 days');
  });
});
