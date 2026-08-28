import { describe, expect, it } from 'vitest';
import {
  COMMITMENT_CADENCES,
  COMMITMENT_KINDS,
  EMPTY_DRAFT,
  type CommitmentDraft,
  autoChecksPossible,
  draftProblems,
  requiredTargets,
  toRow,
  withCadence,
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
        'idempotency_key',
        'kind',
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
