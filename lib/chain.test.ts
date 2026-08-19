import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  OUTCOME_PRESENTATION,
  chainAgainstRecord,
  chainLabel,
  chainSpoken,
  type CommitmentOutcome,
} from './chain';

describe('how a chain is written', () => {
  it('names what the number counts', () => {
    // `12` beside a status pill is a quantity of something unnamed, and the row already
    // carries a target that looks like one.
    expect(chainLabel(12)).toBe('day 12');
    expect(chainLabel(1)).toBe('day 1');
  });

  it('says nothing at all when the chain has just broken', () => {
    // Never `day 0`. A row is not where a reset gets to be visible.
    expect(chainLabel(0)).toBeNull();
  });
});

describe('how a chain is spoken', () => {
  it('is a phrase rather than a written form read out', () => {
    // "Gym, not yet done today, day 12" makes the listener work out what twelve counts.
    expect(chainSpoken(12)).toBe('holding 12 days');
    expect(chainSpoken(1)).toBe('holding one day');
  });

  it('is silent on a broken chain, the same as the written form', () => {
    expect(chainSpoken(0)).toBeNull();
  });
});

describe('a chain read against its record', () => {
  it('never shows the current chain without the longest beside it', () => {
    expect(chainAgainstRecord({ currentDays: 12, longestDays: 30 })).toBe('Day 12 · best 30');
  });

  it('gives a broken chain a record to be read against', () => {
    // The difference between "you have nothing" and "you have done better than this, and
    // you did it yourself".
    const broken = chainAgainstRecord({ currentDays: 0, longestDays: 30 });
    expect(broken).toContain('best 30');
    // "Broken", not "Day 0". Zero is a count of nothing and reads as a scoreline.
    expect(broken).not.toContain('Day 0');
    expect(broken.startsWith('Broken')).toBe(true);
  });

  it('holds even on the first day, when the record is the chain', () => {
    expect(chainAgainstRecord({ currentDays: 1, longestDays: 1 })).toBe('Day 1 · best 1');
  });
});

describe('what a past day says', () => {
  it('keeps silence distinct from a miss', () => {
    // The money treats them the same. The history should not: "I said no" and "I said
    // nothing" are different things to have done.
    expect(OUTCOME_PRESENTATION.missed.label).not.toBe(OUTCOME_PRESENTATION.unanswered.label);
    expect(OUTCOME_PRESENTATION.unanswered.family).toBe('neutral');
  });

  it('never leaves colour as the only carrier of an outcome', () => {
    for (const outcome of Object.values(OUTCOME_PRESENTATION)) {
      expect(outcome.label.trim()).not.toBe('');
      expect(outcome.spoken.trim()).not.toBe('');
    }
  });

  it('covers exactly the outcomes the database can produce', () => {
    // The enum is in SQL and this map is in TypeScript; a value added to one and not the
    // other renders as `undefined` on a screen rather than failing anywhere useful.
    const sql = readFileSync('supabase/migrations/20260819260000_chain.sql', 'utf8');
    const declared = /create type public\.commitment_outcome as enum \(([^)]*)\)/.exec(sql);
    expect(declared).not.toBeNull();

    const values = [...(declared as RegExpExecArray)[1].matchAll(/'([a-z_]+)'/g)]
      .map((m) => m[1])
      .sort();
    expect(Object.keys(OUTCOME_PRESENTATION).sort()).toEqual(values);
  });
});

describe('the chain rule itself', () => {
  it('is written in exactly one place', () => {
    // Story 2.8's lesson, applied rather than repeated. The day-summary copy rules lived in
    // TypeScript and SQL at once and disagreed about a thousands separator within minutes.
    // A second copy of the chain rule would disagree about something worse and later — so
    // this file must never grow one.
    // Structural rather than a keyword blocklist, so it guards something real: computing a
    // chain means walking a sequence of days, and walking anything needs a loop, an array
    // method, or an array type. None of the three may appear in this file.
    const source = readFileSync('lib/chain.ts', 'utf8');
    for (const walking of ['for (', 'while (', '.map(', '.filter(', '.reduce(', '[]']) {
      expect(source).not.toContain(walking);
    }
  });

  it('breaks on silence, and the SQL says why', () => {
    const sql = readFileSync('supabase/migrations/20260819260000_chain.sql', 'utf8');
    // Only `held` extends a chain. If `unanswered` were ever folded in with it, this run
    // would count days elapsed rather than days held.
    expect(sql).toContain("where outcome = 'held'");
    expect(sql).not.toContain("outcome in ('held'");
  });

  it('reads through supersession rather than the base table', () => {
    // A corrected settlement must move the chain with it (AD-9). Reading `settlement`
    // directly would leave a superseded verdict still counting.
    const sql = readFileSync('supabase/migrations/20260819260000_chain.sql', 'utf8');
    const view = sql.slice(sql.indexOf('create view public.chain_current'));
    expect(view).toContain('public.settlement_current');
    expect(view).not.toContain('join public.settlement ');
  });
});

const _outcomes: CommitmentOutcome[] = ['held', 'missed', 'unanswered'];
