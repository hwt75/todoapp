import { describe, expect, it } from 'vitest';
import { EXPIRY_DAYS, answeredInTime, dayAtRisk, deadlineFor, hasExpired } from './expiry';

/** Ho Chi Minh City is UTC+7 all year — no daylight saving to reason about. */
function hcm(day: string, hour: number, minute = 0, second = 0): Date {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d, hour - 7, minute, second));
}

describe('the deadline', () => {
  it('is the morning hour, two days after the question is asked', () => {
    // Asked on the 16th at 07:00 about the 15th; expires on the 18th at 07:00.
    expect(deadlineFor('2026-08-15', 7).getTime()).toBe(hcm('2026-08-18', 7).getTime());
  });

  it('moves with the morning hour', () => {
    expect(deadlineFor('2026-08-15', 6).getTime()).toBe(hcm('2026-08-18', 6).getTime());
    expect(deadlineFor('2026-08-15', 22).getTime()).toBe(hcm('2026-08-18', 22).getTime());
  });

  it('crosses a month boundary', () => {
    expect(deadlineFor('2026-07-30', 7).getTime()).toBe(hcm('2026-08-02', 7).getTime());
  });

  it('crosses a year boundary', () => {
    expect(deadlineFor('2025-12-30', 7).getTime()).toBe(hcm('2026-01-02', 7).getTime());
  });

  it('is three days out, which is 48 hours after the question is asked', () => {
    // The question is asked on D+1; the deadline is on D+3. FR-9 says 48 hours from the
    // request, not from the day.
    expect(EXPIRY_DAYS).toBe(3);
  });
});

describe('whether a day has expired', () => {
  it('is false a minute before', () => {
    expect(hasExpired('2026-08-15', 7, hcm('2026-08-18', 6, 59))).toBe(false);
  });

  it('is true exactly on the hour', () => {
    expect(hasExpired('2026-08-15', 7, hcm('2026-08-18', 7, 0))).toBe(true);
  });

  it('is true long after', () => {
    expect(hasExpired('2026-08-15', 7, hcm('2026-09-01', 12))).toBe(true);
  });

  it('does not expire the day that was only just asked about', () => {
    // Asked this morning about yesterday. Two days of room left.
    expect(hasExpired('2026-08-18', 7, hcm('2026-08-19', 7, 30))).toBe(false);
  });
});

describe('whether an answer was given in time', () => {
  it('is true for one tapped the morning it was asked', () => {
    expect(answeredInTime(hcm('2026-08-16', 7, 31), '2026-08-15', 7)).toBe(true);
  });

  it('is true for one tapped in time but delivered days later', () => {
    // The case the whole supersession rule exists for. What matters is when he tapped, not
    // when the network let it through.
    expect(answeredInTime(hcm('2026-08-16', 7, 31), '2026-08-15', 7)).toBe(true);
  });

  it('is false for one genuinely given after the deadline', () => {
    expect(answeredInTime(hcm('2026-08-19', 9), '2026-08-15', 7)).toBe(false);
  });

  it('is false exactly on the deadline', () => {
    expect(answeredInTime(hcm('2026-08-18', 7, 0), '2026-08-15', 7)).toBe(false);
  });

  describe('is true for every declaration the schema can currently produce', () => {
    // Worth pinning rather than rediscovering. The `for_day` trigger derives the day as
    // `answered_at - 1 day`, so a tap always lands on D+1 while the deadline is on D+3.
    // A day older than yesterday cannot be answered at all — it can only expire.
    it.each([[0], [7], [22], [23]])('with a morning hour of %i', (morningHour) => {
      const day = '2026-08-15';
      const latestPossibleTap = hcm('2026-08-16', 23, 59, 59);
      expect(answeredInTime(latestPossibleTap, day, morningHour)).toBe(true);
    });

    it('by at least a full day, whatever the morning hour', () => {
      const latestPossibleTap = hcm('2026-08-16', 23, 59, 59);
      const earliestDeadline = deadlineFor('2026-08-15', 0);
      const marginHours =
        (earliestDeadline.getTime() - latestPossibleTap.getTime()) / (1000 * 60 * 60);
      expect(marginHours).toBeGreaterThanOrEqual(24);
    });
  });
});

describe('which day is at risk', () => {
  it('is yesterday, and only ever yesterday', () => {
    // FR-9 asks for the previous day. An older one is not asked and therefore not
    // answerable — which is why silence past two days can only end in an expiry.
    expect(dayAtRisk('2026-08-19')).toBe('2026-08-18');
    expect(dayAtRisk('2026-01-01')).toBe('2025-12-31');
  });
});
