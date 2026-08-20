import { describe, expect, it } from 'vitest';
import {
  type WeeklyQuotaPosition,
  weeklyQuotaFamily,
  weeklyQuotaLabel,
  weeklyQuotaMet,
  weeklyQuotaOverride,
  weeklyQuotaSpoken,
} from './weekly-quota';

/**
 * The I/O matrix from spec-3-3, checked directly. Every row here is one the spec's own table
 * names, so a change to the pill's text or family shows up as a failing example rather than a
 * drifted assumption.
 */

function position(held: number, target: number, daysRemaining: number): WeeklyQuotaPosition {
  return { held, target, daysRemaining };
}

describe('whether the week is won', () => {
  it('is not met while held is below target', () => {
    expect(weeklyQuotaMet(position(2, 3, 1))).toBe(false);
  });

  it('is met the instant held equals target', () => {
    expect(weeklyQuotaMet(position(3, 3, 0))).toBe(true);
  });

  it('stays met past the target rather than reverting — a guard against overshoot, not an equality check', () => {
    // Design Notes: `held >= target`, not `held = target`. A stray correction that pushes held
    // one past target must never leave the pill stuck reading urgent.
    expect(weeklyQuotaMet(position(4, 3, 2))).toBe(true);
  });
});

describe('the pill text, matching the spec matrix exactly', () => {
  it('0 of 3, Tuesday, 5 days remain', () => {
    expect(weeklyQuotaLabel(position(0, 3, 5))).toBe('0/3 · 5 days');
  });

  it('1 of 3, Thursday — KF-6’s own number', () => {
    expect(weeklyQuotaLabel(position(1, 3, 3))).toBe('1/3 · 3 days');
  });

  it('1 of 3, Saturday — singular "day", not "days"', () => {
    expect(weeklyQuotaLabel(position(1, 3, 1))).toBe('1/3 · 1 day');
  });

  it('3 of 3 met mid-week: the count alone, no days count', () => {
    expect(weeklyQuotaLabel(position(3, 3, 4))).toBe('3/3');
  });

  it('2 of 3, the week’s last day, still open: "0 days" is a real state, not treated as met', () => {
    // The most consequential day the feature has: the target has not been reached and there
    // is nothing left after today. `daysRemaining = 0` must still read as the open, urgent
    // form — only `held >= target` may ever collapse the days count away.
    expect(weeklyQuotaLabel(position(2, 3, 0))).toBe('2/3 · 0 days');
  });

  it('never mentions days once the target is met, however many were left when it was', () => {
    expect(weeklyQuotaLabel(position(3, 3, 0))).not.toMatch(/day/);
  });
});

describe('the family — urgent while open, held once met, never a sixth state', () => {
  it('is urgent at 0 of 3 on a Tuesday, even with five days of slack', () => {
    // The AC calls this urgent even though nothing is remotely tight yet — the family is not
    // gated on how close the margin is.
    expect(weeklyQuotaFamily(position(0, 3, 5))).toBe('urgent');
  });

  it('is urgent right up to the day before the target is met', () => {
    expect(weeklyQuotaFamily(position(2, 3, 1))).toBe('urgent');
  });

  it('is still urgent on the week’s last day, unmet, with zero days remaining', () => {
    expect(weeklyQuotaFamily(position(2, 3, 0))).toBe('urgent');
  });

  it('flips to held the moment the target is met', () => {
    expect(weeklyQuotaFamily(position(3, 3, 4))).toBe('held');
  });
});

describe('the spoken form states the same position the pill shows', () => {
  it('reads the fraction and the days left while open', () => {
    expect(weeklyQuotaSpoken(position(1, 3, 3))).toBe('1 of 3 this week, 3 days left');
  });

  it('reads "1 day left", singular', () => {
    expect(weeklyQuotaSpoken(position(1, 3, 1))).toBe('1 of 3 this week, 1 day left');
  });

  it('reads "held" once met, rather than a stale days count', () => {
    expect(weeklyQuotaSpoken(position(3, 3, 4))).toBe('3 of 3 this week, held');
  });

  it('reads "0 days left" on the week’s last day, unmet — never "held" early', () => {
    expect(weeklyQuotaSpoken(position(2, 3, 0))).toBe('2 of 3 this week, 0 days left');
  });
});

describe('the StatusPill override, assembled in one call', () => {
  it('carries the open label and the urgent family together', () => {
    expect(weeklyQuotaOverride(position(0, 3, 5))).toEqual({
      family: 'urgent',
      label: '0/3 · 5 days',
    });
  });

  it('carries the met label and the held family together', () => {
    expect(weeklyQuotaOverride(position(3, 3, 0))).toEqual({ family: 'held', label: '3/3' });
  });
});
