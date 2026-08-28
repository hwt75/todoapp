import { describe, expect, it } from 'vitest';
import {
  COMMITMENT_CADENCES,
  COMMITMENT_KINDS,
  EMPTY_DRAFT,
  LATE_WINDOW_DEFAULT_MINUTES,
  MINUTES_IN_A_DAY,
  TIMED_COMMITMENT_COPY,
  type CommitmentDraft,
  autoChecksPossible,
  canBeTimed,
  draftProblems,
  minutesIntoDay,
  requiredTargets,
  toRow,
  withCadence,
  withDueTime,
  withKind,
} from './commitment';

function draft(overrides: Partial<CommitmentDraft> = {}): CommitmentDraft {
  return { ...EMPTY_DRAFT, name: 'Gym', ...overrides };
}

describe('a blank commitment', () => {
  it('does not carry money', () => {
    // The one default worth a test of its own. Money is never opt-out.
    expect(EMPTY_DRAFT.carriesPenalty).toBe(false);
  });

  it('starts with no targets set', () => {
    expect(EMPTY_DRAFT.weeklyTarget).toBeNull();
    expect(EMPTY_DRAFT.weekStartDay).toBeNull();
    expect(EMPTY_DRAFT.dailyMinutesTarget).toBeNull();
  });

  it('starts with no Auto-check attached', () => {
    expect(EMPTY_DRAFT.autoCheckEnabled).toBe(false);
    expect(EMPTY_DRAFT.autoCheckAccountRef).toBe('');
  });
});

describe('which targets a cadence needs', () => {
  it.each([
    ['daily', []],
    ['weekly_quota', ['weeklyTarget', 'weekStartDay']],
    ['daily_hours_quota', ['dailyMinutesTarget']],
  ] as const)('%s', (cadence, expected) => {
    expect(requiredTargets(cadence)).toEqual(expected);
  });

  it('covers every cadence, so a new one cannot be added without deciding', () => {
    for (const cadence of COMMITMENT_CADENCES) {
      expect(() => requiredTargets(cadence)).not.toThrow();
    }
  });
});

describe('auto-checks', () => {
  it('are impossible for an abstention', () => {
    // There is no sensor for a thing not done. The screen has to say so, not just grey
    // the controls out.
    expect(autoChecksPossible('abstain')).toBe(false);
  });

  it.each([['do'], ['open_ended']] as const)('are possible in principle for %s', (kind) => {
    expect(autoChecksPossible(kind)).toBe(true);
  });

  it('has an answer for every kind', () => {
    for (const kind of COMMITMENT_KINDS) {
      expect(typeof autoChecksPossible(kind)).toBe('boolean');
    }
  });

  it('are impossible for an Hours-per-day commitment (Epic 4 retro, finding A7)', () => {
    // commitments_owing() excludes daily_hours_quota entirely, so no settlement path ever
    // consults an Auto-check attached to one — mirrors the abstain exclusion above.
    expect(autoChecksPossible('do', 'daily_hours_quota')).toBe(false);
  });

  it('defaults the cadence argument to one that always allows a check', () => {
    // Every pre-existing single-argument call site keeps its prior meaning.
    expect(autoChecksPossible('do')).toBe(true);
  });
});

describe('an Account-elsewhere Auto-check draft', () => {
  it('is valid once enabled with a ref, on a kind that allows it', () => {
    expect(
      draftProblems(draft({ autoCheckEnabled: true, autoCheckAccountRef: 'my-handle' })),
    ).toEqual([]);
  });

  it('is refused enabled with a blank ref', () => {
    expect(
      draftProblems(draft({ autoCheckEnabled: true, autoCheckAccountRef: '   ' })).length,
    ).toBeGreaterThan(0);
  });

  it('is refused enabled with no ref at all', () => {
    expect(draftProblems(draft({ autoCheckEnabled: true })).length).toBeGreaterThan(0);
  });

  it('is refused on an abstention, even with a ref typed', () => {
    // Mirrors autoChecksPossible(): there is no sensor for a thing not done.
    expect(
      draftProblems(
        draft({ kind: 'abstain', autoCheckEnabled: true, autoCheckAccountRef: 'my-handle' }),
      ).length,
    ).toBeGreaterThan(0);
  });

  it('is refused on an Hours-per-day commitment, even with a ref typed (Epic 4 retro, A7)', () => {
    expect(
      draftProblems(
        draft({
          cadence: 'daily_hours_quota',
          dailyMinutesTarget: 180,
          autoCheckEnabled: true,
          autoCheckAccountRef: 'my-handle',
        }),
      ).length,
    ).toBeGreaterThan(0);
  });

  it('raises no problem while disabled, whatever the ref field holds', () => {
    expect(draftProblems(draft({ autoCheckEnabled: false, autoCheckAccountRef: '' }))).toEqual([]);
  });
});

describe('switching kind', () => {
  it('clears a linked Auto-check when the new kind cannot carry one', () => {
    // Otherwise the checkbox would render checked and disabled at once — checked because
    // the draft still says so, disabled because abstain has no sensor — with no control
    // left for the author to uncheck it from.
    const linked = draft({ kind: 'do', autoCheckEnabled: true, autoCheckAccountRef: 'my-handle' });
    const next = withKind(linked, 'abstain');
    expect(next.autoCheckEnabled).toBe(false);
    expect(next.autoCheckAccountRef).toBe('');
  });

  it('leaves a linked Auto-check alone when the new kind still allows one', () => {
    const linked = draft({ kind: 'do', autoCheckEnabled: true, autoCheckAccountRef: 'my-handle' });
    const next = withKind(linked, 'open_ended');
    expect(next.autoCheckEnabled).toBe(true);
    expect(next.autoCheckAccountRef).toBe('my-handle');
  });

  it('is a no-op on Auto-check fields when nothing was linked', () => {
    expect(withKind(draft({ kind: 'do' }), 'abstain').autoCheckEnabled).toBe(false);
  });
});

describe('a draft the database would accept', () => {
  it('daily, named', () => {
    expect(draftProblems(draft())).toEqual([]);
  });

  it('weekly quota with both targets', () => {
    expect(
      draftProblems(draft({ cadence: 'weekly_quota', weeklyTarget: 3, weekStartDay: 1 })),
    ).toEqual([]);
  });

  it('daily hours quota with minutes', () => {
    expect(draftProblems(draft({ cadence: 'daily_hours_quota', dailyMinutesTarget: 180 }))).toEqual(
      [],
    );
  });
});

describe('a draft the database would refuse', () => {
  it.each([
    ['a blank name', draft({ name: '   ' })],
    ['weekly quota with no target', draft({ cadence: 'weekly_quota', weekStartDay: 1 })],
    ['weekly quota with no week start', draft({ cadence: 'weekly_quota', weeklyTarget: 3 })],
    ['weekly target of zero', draft({ cadence: 'weekly_quota', weeklyTarget: 0, weekStartDay: 1 })],
    [
      'weekly target of eight',
      draft({ cadence: 'weekly_quota', weeklyTarget: 8, weekStartDay: 1 }),
    ],
    [
      'a fractional weekly target',
      draft({ cadence: 'weekly_quota', weeklyTarget: 2.5, weekStartDay: 1 }),
    ],
    ['a week start of zero', draft({ cadence: 'weekly_quota', weeklyTarget: 3, weekStartDay: 0 })],
    ['a week start of eight', draft({ cadence: 'weekly_quota', weeklyTarget: 3, weekStartDay: 8 })],
    ['hours quota with no minutes', draft({ cadence: 'daily_hours_quota' })],
    ['zero minutes', draft({ cadence: 'daily_hours_quota', dailyMinutesTarget: 0 })],
    ['negative minutes', draft({ cadence: 'daily_hours_quota', dailyMinutesTarget: -30 })],
  ])('%s', (_label, bad) => {
    expect(draftProblems(bad).length).toBeGreaterThan(0);
  });

  it('a target left over from another cadence', () => {
    // The likeliest way to produce one: pick weekly, type a target, switch to daily.
    const stale = draft({ cadence: 'daily', weeklyTarget: 3, weekStartDay: 1 });
    expect(draftProblems(stale).length).toBeGreaterThan(0);
  });
});

describe('switching cadence', () => {
  it('clears the targets the previous cadence needed', () => {
    const weekly = draft({ cadence: 'weekly_quota', weeklyTarget: 3, weekStartDay: 1 });
    const daily = withCadence(weekly, 'daily');

    expect(daily.weeklyTarget).toBeNull();
    expect(daily.weekStartDay).toBeNull();
    expect(draftProblems(daily)).toEqual([]);
  });

  it('keeps a target the new cadence still needs', () => {
    const hours = draft({ cadence: 'daily_hours_quota', dailyMinutesTarget: 180 });
    expect(withCadence(hours, 'daily_hours_quota').dailyMinutesTarget).toBe(180);
  });

  it('leaves the name and the money flag alone', () => {
    const original = draft({ name: 'Company work', carriesPenalty: true });
    const switched = withCadence(original, 'daily_hours_quota');
    expect(switched.name).toBe('Company work');
    expect(switched.carriesPenalty).toBe(true);
  });

  it('clears a linked Auto-check when switching to Hours-per-day (Epic 4 retro, A7)', () => {
    const linked = draft({
      cadence: 'daily',
      autoCheckEnabled: true,
      autoCheckAccountRef: 'handle',
    });
    const switched = withCadence(linked, 'daily_hours_quota');
    expect(switched.autoCheckEnabled).toBe(false);
    expect(switched.autoCheckAccountRef).toBe('');
  });

  it('leaves a linked Auto-check alone when switching between cadences that both allow one', () => {
    const linked = draft({
      cadence: 'daily',
      autoCheckEnabled: true,
      autoCheckAccountRef: 'handle',
    });
    const switched = withCadence(linked, 'weekly_quota');
    expect(switched.autoCheckEnabled).toBe(true);
    expect(switched.autoCheckAccountRef).toBe('handle');
  });
});

describe('the row that reaches the database', () => {
  it('trims the name', () => {
    const row = toRow(draft({ name: '  Gym  ' }), 'owner-1', 'key-1');
    expect(row.name).toBe('Gym');
  });

  it('carries the owner and the idempotency key', () => {
    const row = toRow(draft(), 'owner-1', 'key-1');
    expect(row.owner_id).toBe('owner-1');
    expect(row.idempotency_key).toBe('key-1');
  });

  it('uses the column names the migration declares', () => {
    const row = toRow(
      draft({ cadence: 'weekly_quota', weeklyTarget: 3, weekStartDay: 1 }),
      'o',
      'k',
    );
    expect(Object.keys(row).sort()).toEqual(
      [
        'auto_check_account_ref',
        'auto_check_kind',
        'auto_check_last_checked_at',
        'carries_penalty',
        'cadence',
        'daily_minutes_target',
        'due_time',
        'idempotency_key',
        'kind',
        'late_window_minutes',
        'name',
        'owner_id',
        'week_start_day',
        'weekly_target',
      ].sort(),
    );
  });

  it('writes the auto-check columns when linked', () => {
    const row = toRow(
      draft({ autoCheckEnabled: true, autoCheckAccountRef: '  my-handle  ' }),
      'o',
      'k',
    );
    expect(row.auto_check_kind).toBe('account_elsewhere');
    expect(row.auto_check_account_ref).toBe('my-handle');
    // Left untouched — the resolution pass owns this column, never the client. Supabase
    // strips an `undefined` value from the request, so an update leaves the existing
    // database value alone rather than sending a null.
    expect(row.auto_check_last_checked_at).toBeUndefined();
  });

  it('clears all three auto-check columns when unlinked', () => {
    const row = toRow(draft({ autoCheckEnabled: false, autoCheckAccountRef: 'stale' }), 'o', 'k');
    expect(row.auto_check_kind).toBeNull();
    expect(row.auto_check_account_ref).toBeNull();
    expect(row.auto_check_last_checked_at).toBeNull();
  });
});

describe('the five starting commitments from the PRD', () => {
  // If the shape cannot express the set the product ships with, the shape is wrong.
  it.each([
    ['No fap', draft({ name: 'No fap', kind: 'abstain', cadence: 'daily', carriesPenalty: true })],
    [
      'Gym',
      draft({
        name: 'Gym',
        kind: 'do',
        cadence: 'weekly_quota',
        weeklyTarget: 3,
        weekStartDay: 1,
        carriesPenalty: true,
      }),
    ],
    ['TryHackMe', draft({ name: 'TryHackMe', kind: 'do', cadence: 'daily', carriesPenalty: true })],
    ['Morning exercise', draft({ name: 'Morning exercise', kind: 'do', cadence: 'daily' })],
    [
      'Company work',
      draft({
        name: 'Company work',
        kind: 'open_ended',
        cadence: 'daily_hours_quota',
        dailyMinutesTarget: 180,
      }),
    ],
  ])('%s is expressible and valid', (_name, commitment) => {
    expect(draftProblems(commitment)).toEqual([]);
  });

  it('records three hours as 180 minutes, not 3', () => {
    const work = draft({ cadence: 'daily_hours_quota', dailyMinutesTarget: 180 });
    expect(toRow(work, 'o', 'k').daily_minutes_target).toBe(180);
  });
});

/**
 * Story 6.1 — a time of day, and the window after it.
 *
 * Every rule here is mirrored by a check constraint in
 * `20260828130000_a_commitment_can_carry_a_time.sql`, and the constraint is what actually
 * decides. These exist so the form can refuse a bad draft without a round trip, and so the
 * midnight arithmetic is exercised at both of its boundaries — which is where it is wrong if
 * anyone ever rewrites it as time-plus-interval.
 */
describe('a blank commitment, on time', () => {
  it('has no time and no window', () => {
    expect(EMPTY_DRAFT.dueTime).toBeNull();
    expect(EMPTY_DRAFT.lateWindowMinutes).toBeNull();
  });
});

describe('which commitments can name a moment', () => {
  it('an abstention cannot: there is no instant of not doing a thing', () => {
    expect(canBeTimed('abstain', 'daily')).toBe(false);
  });

  it('an Hours-per-day commitment cannot: it is judged by banked minutes, not by a moment', () => {
    expect(canBeTimed('do', 'daily_hours_quota')).toBe(false);
  });

  it.each([
    ['do', 'daily'],
    ['do', 'weekly_quota'],
    ['open_ended', 'daily'],
    ['open_ended', 'weekly_quota'],
  ] as const)('%s / %s can', (kind, cadence) => {
    expect(canBeTimed(kind, cadence)).toBe(true);
  });

  it('has an answer for every kind and cadence', () => {
    for (const kind of COMMITMENT_KINDS) {
      for (const cadence of COMMITMENT_CADENCES) {
        expect(typeof canBeTimed(kind, cadence)).toBe('boolean');
      }
    }
  });
});

describe('reading a time of day', () => {
  it.each([
    ['00:00', 0],
    ['08:30', 510],
    ['20:00', 1200],
    ['23:59', 1439],
  ])('%s is %i minutes into the day', (time, minutes) => {
    expect(minutesIntoDay(time as string)).toBe(minutes);
  });

  it.each([['24:00'], ['8:30'], ['20:60'], ['20:00:00'], ['evening'], ['']])(
    '"%s" is not a time of day',
    (bad) => {
      expect(minutesIntoDay(bad)).toBeNull();
    },
  );
});

describe('a timed draft the database would accept', () => {
  it('a time with its window', () => {
    expect(draftProblems(draft({ dueTime: '20:00', lateWindowMinutes: 30 }))).toEqual([]);
  });

  it('a window ending at exactly midnight — the half-open boundary', () => {
    // 23:30 + 30 = 1440. The last instant inside it is 23:59:59.999, so it is still this day.
    expect(minutesIntoDay('23:30')! + 30).toBe(MINUTES_IN_A_DAY);
    expect(draftProblems(draft({ dueTime: '23:30', lateWindowMinutes: 30 }))).toEqual([]);
  });

  it('the shortest and longest windows allowed', () => {
    expect(draftProblems(draft({ dueTime: '06:00', lateWindowMinutes: 5 }))).toEqual([]);
    expect(draftProblems(draft({ dueTime: '06:00', lateWindowMinutes: 240 }))).toEqual([]);
  });

  it('no time at all, which is every commitment that existed before this story', () => {
    expect(draftProblems(draft())).toEqual([]);
  });
});

describe('a timed draft the database would refuse', () => {
  it('a window that crosses midnight, by an hour or by one minute', () => {
    // Written as a time plus an interval, 23:30 + 60 minutes reads as 00:30 and passes —
    // which is the whole reason this rule is arithmetic on minutes from midnight.
    expect(draftProblems(draft({ dueTime: '23:30', lateWindowMinutes: 60 }))).toContain(
      'The late window has to end before midnight.',
    );
    expect(draftProblems(draft({ dueTime: '23:30', lateWindowMinutes: 31 }))).toContain(
      'The late window has to end before midnight.',
    );
  });

  it('a time with no window', () => {
    expect(draftProblems(draft({ dueTime: '20:00' }))).toContain('A time needs a late window.');
  });

  it('a window with no time', () => {
    expect(draftProblems(draft({ lateWindowMinutes: 30 }))).toContain(
      'A late window needs a time to be late against.',
    );
  });

  it.each([[0], [4], [241], [1000], [30.5]])('a window of %s minutes', (minutes) => {
    expect(draftProblems(draft({ dueTime: '06:00', lateWindowMinutes: minutes }))).toContain(
      'The late window must be a whole number of minutes from 5 to 240.',
    );
  });

  it('a time that is not a time', () => {
    expect(draftProblems(draft({ dueTime: '25:00', lateWindowMinutes: 30 }))).toContain(
      'A time of day looks like 20:00.',
    );
  });

  it('a time on an abstention', () => {
    expect(
      draftProblems(draft({ kind: 'abstain', dueTime: '20:00', lateWindowMinutes: 30 })),
    ).toContain('An Avoid-it commitment has no moment to put a time on.');
  });

  it('a time on an Hours-per-day commitment', () => {
    expect(
      draftProblems(
        draft({
          cadence: 'daily_hours_quota',
          dailyMinutesTarget: 180,
          dueTime: '20:00',
          lateWindowMinutes: 30,
        }),
      ),
    ).toContain(
      'An Hours-per-day commitment is judged by the time you bank, not by a time of day.',
    );
  });
});

describe('switching a time on and off', () => {
  it('brings the default window with it', () => {
    const timed = withDueTime(draft(), '20:00');
    expect(timed.lateWindowMinutes).toBe(LATE_WINDOW_DEFAULT_MINUTES);
    expect(draftProblems(timed)).toEqual([]);
  });

  it('keeps a window the author already chose', () => {
    const timed = withDueTime(draft({ dueTime: '20:00', lateWindowMinutes: 90 }), '21:00');
    expect(timed.lateWindowMinutes).toBe(90);
  });

  it('takes the window away with it', () => {
    const untimed = withDueTime(draft({ dueTime: '20:00', lateWindowMinutes: 30 }), null);
    expect(untimed.dueTime).toBeNull();
    expect(untimed.lateWindowMinutes).toBeNull();
  });
});

describe('a time that cannot survive a switch', () => {
  it('is cleared when the kind becomes one with no moment', () => {
    const cleared = withKind(draft({ dueTime: '20:00', lateWindowMinutes: 30 }), 'abstain');
    expect(cleared.dueTime).toBeNull();
    expect(cleared.lateWindowMinutes).toBeNull();
  });

  it('is cleared when the cadence becomes one judged by banked minutes', () => {
    const cleared = withCadence(
      draft({ dueTime: '20:00', lateWindowMinutes: 30 }),
      'daily_hours_quota',
    );
    expect(cleared.dueTime).toBeNull();
    expect(cleared.lateWindowMinutes).toBeNull();
  });

  it('survives a switch between cadences that both have moments', () => {
    const kept = withCadence(draft({ dueTime: '20:00', lateWindowMinutes: 30 }), 'weekly_quota');
    expect(kept.dueTime).toBe('20:00');
    expect(kept.lateWindowMinutes).toBe(30);
  });
});

describe('the timed row that reaches the database', () => {
  it('sends the time as written and the window in minutes', () => {
    const row = toRow(draft({ dueTime: '20:00', lateWindowMinutes: 30 }), 'o', 'k');
    expect(row.due_time).toBe('20:00');
    expect(row.late_window_minutes).toBe(30);
  });

  it('sends nulls for an untimed commitment, so saving one changes nothing', () => {
    const row = toRow(draft(), 'o', 'k');
    expect(row.due_time).toBeNull();
    expect(row.late_window_minutes).toBeNull();
  });
});

describe('what the author is told before a time is saved', () => {
  it('names all three things a time costs him', () => {
    // Not a link to a document and not a paraphrase. Each clause is the only place the author
    // learns that part of the trade before it costs him.
    expect(TIMED_COMMITMENT_COPY.warning).toContain('settled by a photo');
    expect(TIMED_COMMITMENT_COPY.warning).toContain('not by the morning question');
    expect(TIMED_COMMITMENT_COPY.warning).toContain('No photo before midnight is a failed day');
    expect(TIMED_COMMITMENT_COPY.warning).toContain('two Grace Days a month');
  });
});
