import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
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

  it('and so does every screen, which the assertion above could not see', () => {
    // The guard above reads one view's SQL text, and Epic 2's retrospective found what that
    // leaves uncovered: `chains-detail.tsx` selected straight from `settlement_commitment`
    // while this test passed, so the chain followed a correction and the calendar beside it
    // did not (A2). The rule is about the client, so the client is what gets read.
    //
    // Settlement-derived state has exactly one door per table. Reading the base table is
    // reading a superseded day as though it still stood.
    const doors: Record<string, string> = {
      settlement: 'settlement_current',
      settlement_commitment: 'settlement_commitment_current',
      penalty: 'penalty_current',
    };

    // The one legal exception (Story 5.1): `referee-appeal-detail.tsx` reads this appeal's
    // own Penalty by its own fixed `penalty_id` directly off the base table, never off
    // whatever a day's *current* settlement happens to read. A later Grace Day can
    // supersede the same settlement for a reason that has nothing to do with this appeal (a
    // residual, non-appealed miss later forgiven) — `penalty_current`, which only ever
    // answers "what does the *current* settlement owe", cannot tell that apart from this
    // ruling's own correction. This appeal's own row is a single, permanent record of what
    // happened to *it*, immune to anything that happens later to a different row on a
    // different settlement — reading it directly is the fix, not a shortcut around one.
    // Story 4.5's own "penalty: referee reads day and week" RLS policy
    // (`20260824160000_the_referee_has_his_own_way_in.sql`) grants the referee exactly this
    // read on the base table; it is not a door this rule exists to close.
    const exempt: Record<string, string[]> = {
      penalty: ['components/referee-appeal-detail.tsx'],
    };

    for (const file of sourceFiles(['app', 'components', 'lib'])) {
      const normalized = file.replace(/\\/g, '/');
      const source = readFileSync(file, 'utf8');
      for (const [base, view] of Object.entries(doors)) {
        if (exempt[base]?.some((allowed) => normalized.endsWith(allowed))) continue;
        expect(source, `${file} reads ${base} directly; read ${view} instead`).not.toContain(
          `.from('${base}')`,
        );
      }
    }
  });
});

/** Every shipped `.ts`/`.tsx` under these roots — tests excluded, they are allowed to read
    a migration as text and to name a base table while saying so. */
function sourceFiles(roots: string[]): string[] {
  const found: string[] = [];
  for (const root of roots) {
    for (const entry of readdirSync(root, { recursive: true, withFileTypes: true })) {
      if (!entry.isFile()) continue;
      const name = entry.name;
      if (!name.endsWith('.ts') && !name.endsWith('.tsx')) continue;
      if (name.includes('.test.')) continue;
      found.push(join(entry.parentPath ?? root, name));
    }
  }
  return found;
}

const _outcomes: CommitmentOutcome[] = ['held', 'missed', 'unanswered'];
