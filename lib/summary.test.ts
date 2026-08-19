import { describe, expect, it } from 'vitest';
import { PENALTY_DONG } from './money';
import { type DaySummary, countWord, daySummaryBody, summaryProblems, weekdayOf } from './summary';

function summary(overrides: Partial<DaySummary> = {}): DaySummary {
  return {
    day: '2026-08-18',
    total: 5,
    held: 4,
    amountDong: null,
    heldNames: ['Morning exercise', 'No fap', 'TryHackMe', 'Company work'],
    suggestion: 'Gym',
    ...overrides,
  };
}

describe('the register', () => {
  it('reads counts as words, the way a person says them', () => {
    expect(countWord(4)).toBe('Four');
    expect(countWord(1)).toBe('One');
    expect(countWord(0)).toBe('None');
  });

  it('falls back to digits past the point words stay short', () => {
    expect(countWord(17)).toBe('17');
  });

  it('names the weekday without letting a timezone move it', () => {
    // The string already names a local day. Parsing it as an instant and formatting it in
    // another zone is how a Tuesday becomes a Monday.
    expect(weekdayOf('2026-08-18')).toBe('Tuesday');
    expect(weekdayOf('2026-01-01')).toBe('Thursday');
  });
});

describe('a good day', () => {
  it('states the count, names the day, and offers one thing', () => {
    expect(daySummaryBody(summary())).toBe(
      'Four of five on Tuesday. Morning exercise held though. Start with Gym tomorrow.',
    );
  });

  it('names no amount when nothing is owed', () => {
    expect(daySummaryBody(summary())).not.toContain('₫');
  });
});

describe('a bad day', () => {
  const bad = summary({
    held: 1,
    amountDong: PENALTY_DONG,
    heldNames: ['Morning exercise'],
    suggestion: 'Morning exercise',
  });

  it('states the amount once and then moves on', () => {
    const body = daySummaryBody(bad);
    expect(body).toContain(formatted());
    expect(body.split(formatted()).length - 1).toBe(1);
  });

  it('names something that held rather than what did not', () => {
    expect(daySummaryBody(bad)).toContain('Morning exercise held though');
  });

  it('points at the survivor when that is the suggestion', () => {
    expect(daySummaryBody(bad)).toContain('Start there tomorrow');
  });

  it('itemises nothing', () => {
    // The rule this message exists for. A list of failures is what it replaces.
    const missed = ['Gym', 'TryHackMe', 'No fap', 'Company work'];
    expect(summaryProblems(bad, missed)).toEqual([]);
    for (const name of missed) {
      expect(daySummaryBody(bad)).not.toContain(name);
    }
  });

  function formatted() {
    return new Intl.NumberFormat('vi-VN').format(PENALTY_DONG) + '₫';
  }
});

describe('a day where nothing held', () => {
  const nothing = summary({
    held: 0,
    amountDong: PENALTY_DONG,
    heldNames: [],
    suggestion: 'Morning exercise',
  });

  it('offers a starting point without claiming anything survived', () => {
    const body = daySummaryBody(nothing);
    expect(body).toContain('Start with Morning exercise tomorrow');
    expect(body).not.toContain('held though');
  });

  it('still states the count and the amount once', () => {
    expect(daySummaryBody(nothing)).toContain('None of five');
    expect(summaryProblems(nothing, ['Gym'])).toEqual([]);
  });
});

describe('the rules, checked against a body that breaks them', () => {
  it('does not flag the suggestion, even when the suggestion is a miss', () => {
    // "Start with Gym tomorrow" when Gym was missed today is the right sentence. The rule
    // is never to list the misses, not never to name one as a place to begin.
    const bad = summary({ held: 1, amountDong: PENALTY_DONG, heldNames: [], suggestion: 'Gym' });
    expect(summaryProblems(bad, ['Gym'])).toEqual([]);
  });

  it('catches a miss that appears for any other reason', () => {
    const leaky = summary({
      held: 1,
      amountDong: PENALTY_DONG,
      heldNames: [],
      suggestion: 'Morning exercise',
    });
    // 'Morning exercise' is the suggestion and exempt; 'exercise' is not, and a body that
    // named it would be itemising.
    expect(summaryProblems(leaky, ['exercise'])).toContain('The body itemises a miss: "exercise".');
  });

  it('is satisfied by a well-formed body', () => {
    expect(summaryProblems(summary(), ['Gym'])).toEqual([]);
  });
});

describe('every summary', () => {
  const cases: DaySummary[] = [
    summary(),
    summary({ held: 5, heldNames: ['A', 'B', 'C', 'D', 'E'], suggestion: 'A' }),
    summary({ held: 0, amountDong: PENALTY_DONG, heldNames: [], suggestion: 'Gym' }),
    summary({ total: 1, held: 0, amountDong: PENALTY_DONG, heldNames: [], suggestion: 'No fap' }),
  ];

  it.each(cases.map((c, i) => [i, c]))(
    'case %i names exactly one commitment to start with',
    (_i, c) => {
      expect(daySummaryBody(c)).toContain(c.suggestion);
    },
  );

  it.each(cases.map((c, i) => [i, c]))('case %i names the day it is about', (_i, c) => {
    expect(daySummaryBody(c)).toContain(weekdayOf(c.day));
  });

  it.each(cases.map((c, i) => [i, c]))('case %i stays legible on a lock screen', (_i, c) => {
    // iOS shows roughly 110-120 characters before truncating a notification body. NFR1
    // requires it be legible in full without interaction, so this is a real ceiling and not
    // a style preference.
    expect(daySummaryBody(c).length).toBeLessThanOrEqual(120);
  });
});
