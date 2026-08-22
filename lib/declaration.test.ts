import { describe, expect, it } from 'vitest';
import { COMMITMENT_CADENCES } from './commitment';
import {
  calendarMoment,
  commitmentsOwing,
  dayInQuestion,
  isAskingTime,
  isDeclared,
  previousDay,
  questionFor,
} from './declaration';

/** Ho Chi Minh City is UTC+7 all year — no daylight saving to reason about. */
function hcm(day: string, hour: number, minute = 0): Date {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d, hour - 7, minute));
}

describe('the clock the product runs on', () => {
  it('reads the local day and hour, not the device"s', () => {
    const at = hcm('2026-08-19', 7, 30);
    expect(calendarMoment(at)).toEqual({ day: '2026-08-19', hour: 7 });
  });

  it('is still yesterday in UTC when it is already today locally', () => {
    // 00:30 local on the 19th is 17:30 UTC on the 18th. A UTC-derived date would be a
    // whole day out, and under a flat penalty a day is the unit that costs money.
    const at = hcm('2026-08-19', 0, 30);
    expect(at.toISOString().slice(0, 10)).toBe('2026-08-18');
    expect(calendarMoment(at).day).toBe('2026-08-19');
  });

  it('reports midnight as hour 0, never 24', () => {
    expect(calendarMoment(hcm('2026-08-19', 0)).hour).toBe(0);
  });

  it.each([
    ['2026-08-19', '2026-08-18'],
    ['2026-08-01', '2026-07-31'],
    ['2026-01-01', '2025-12-31'],
    ['2028-03-01', '2028-02-29'],
  ])('the day before %s is %s', (day, expected) => {
    expect(previousDay(day)).toBe(expected);
  });
});

describe('the day the question is about', () => {
  it('is yesterday, locally', () => {
    expect(dayInQuestion(hcm('2026-08-19', 7, 30))).toBe('2026-08-18');
  });

  it('does not move when the morning hour moves', () => {
    // Answering at 06:00 and at 08:00 both refer to yesterday. If this were tied to the
    // morning hour, changing the setting would silently re-point an answer at a different
    // day — and the database trigger, which never sees the setting, would disagree.
    expect(dayInQuestion(hcm('2026-08-19', 6))).toBe('2026-08-18');
    expect(dayInQuestion(hcm('2026-08-19', 8))).toBe('2026-08-18');
    expect(dayInQuestion(hcm('2026-08-19', 23, 59))).toBe('2026-08-18');
  });

  it('rolls over at local midnight, not UTC midnight', () => {
    expect(dayInQuestion(hcm('2026-08-19', 23, 59))).toBe('2026-08-18');
    expect(dayInQuestion(hcm('2026-08-20', 0, 1))).toBe('2026-08-19');
  });
});

describe('when he agreed to be asked', () => {
  it.each([
    // A morning hour of 6 means "ask me from 06:00", so 07:00 is past it.
    [6, true],
    [7, true],
    [8, false],
  ])('at 07:00 with a morning hour of %i, asking is %s', (morningHour, expected) => {
    expect(isAskingTime(hcm('2026-08-19', 7), morningHour)).toBe(expected);
  });

  it('is exactly at the hour, not a minute after', () => {
    expect(isAskingTime(hcm('2026-08-19', 7, 0), 7)).toBe(true);
    expect(isAskingTime(hcm('2026-08-19', 6, 59), 7)).toBe(false);
  });
});

describe('which cadences are settled by his word', () => {
  it('daily is', () => {
    expect(isDeclared('daily')).toBe(true);
  });

  it('weekly quota is, because sessions happen on days even though the week is judged later', () => {
    expect(isDeclared('weekly_quota')).toBe(true);
  });

  it('an hours quota is not — FR-2 judges it against measured minutes', () => {
    // Asking for a declaration here would invite a softer second answer to a question the
    // timer answers exactly. The gap until Epic 3 builds the timer is real and belongs to
    // the sequencing, not to this rule.
    expect(isDeclared('daily_hours_quota')).toBe(false);
  });

  it('has an answer for every cadence', () => {
    for (const cadence of COMMITMENT_CADENCES) {
      expect(typeof isDeclared(cadence)).toBe('boolean');
    }
  });
});

describe('who owes an answer', () => {
  const gym = { id: 'gym', name: 'Gym', cadence: 'weekly_quota' as const };
  const nofap = { id: 'nofap', name: 'No fap', cadence: 'daily' as const };
  const work = { id: 'work', name: 'Company work', cadence: 'daily_hours_quota' as const };
  const all = [gym, nofap, work];

  it('nobody, before the morning hour', () => {
    expect(commitmentsOwing(all, [], hcm('2026-08-19', 6, 59), 7)).toEqual([]);
  });

  it('the declared ones, after it', () => {
    const owing = commitmentsOwing(all, [], hcm('2026-08-19', 7), 7).map((c) => c.id);
    expect(owing).toEqual(['gym', 'nofap']);
  });

  it('not one already answered', () => {
    const owing = commitmentsOwing(all, ['nofap'], hcm('2026-08-19', 8), 7).map((c) => c.id);
    expect(owing).toEqual(['gym']);
  });

  it('nobody once every declared commitment has answered', () => {
    expect(commitmentsOwing(all, ['gym', 'nofap'], hcm('2026-08-19', 8), 7)).toEqual([]);
  });

  it('asks in a stable order, so the same one is not asked twice', () => {
    const first = commitmentsOwing(all, [], hcm('2026-08-19', 8), 7).map((c) => c.id);
    const again = commitmentsOwing(all, [], hcm('2026-08-19', 9), 7).map((c) => c.id);
    expect(again).toEqual(first);
  });

  describe('archived commitments', () => {
    it('still owe for a day that predates the archive', () => {
      // Archived this morning, asked about yesterday. The day belongs to the ledger and a
      // hole in it is worse than one extra question.
      const archivedToday = [{ ...nofap, archived_at: hcm('2026-08-19', 9).toISOString() }];
      const owing = commitmentsOwing(archivedToday, [], hcm('2026-08-19', 10), 7);
      expect(owing.map((c) => c.id)).toEqual(['nofap']);
    });

    it('owe nothing for a day after they were archived', () => {
      const archivedLastWeek = [{ ...nofap, archived_at: hcm('2026-08-10', 9).toISOString() }];
      expect(commitmentsOwing(archivedLastWeek, [], hcm('2026-08-19', 10), 7)).toEqual([]);
    });
  });
});

describe('how the question is phrased', () => {
  it('asks a daily commitment whether it held', () => {
    expect(questionFor({ id: 'x', name: 'No fap', cadence: 'daily' }, '2026-08-18')).toContain(
      'hold',
    );
  });

  it('asks a weekly one whether it happened, not whether it held', () => {
    // "Held" would imply the week is already decided. FR-2 says it is not judged until
    // Week Close.
    const q = questionFor({ id: 'x', name: 'Gym', cadence: 'weekly_quota' }, '2026-08-18');
    expect(q).toContain('Did you do');
    expect(q).not.toContain('hold');
  });

  it('names the day, so an answer given late is not about the wrong one', () => {
    expect(questionFor({ id: 'x', name: 'Gym', cadence: 'daily' }, '2026-08-18')).toContain(
      '2026-08-18',
    );
  });
});
