import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WAITING_ON_REFEREE_COPY, readWaitingOnReferee } from './referee-waiting';

let answer: unknown = { data: [], error: null };
let throws = false;

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    rpc: async () => {
      if (throws) throw new Error('offline');
      return answer;
    },
  }),
}));

beforeEach(() => {
  answer = { data: [], error: null };
  throws = false;
});

describe('readWaitingOnReferee (Story 8.6)', () => {
  it('returns the ids the server named, stamped with the day the server answered for', async () => {
    answer = {
      data: [
        { commitment_id: 'c1', for_day: '2026-09-30' },
        { commitment_id: 'c2', for_day: '2026-09-30' },
      ],
      error: null,
    };
    const read = await readWaitingOnReferee('2026-09-29');
    expect(read?.day).toBe('2026-09-30');
    expect([...(read?.ids ?? [])]).toEqual(['c1', 'c2']);
  });

  it('takes the day asked for when there is nothing to stamp it with', async () => {
    const read = await readWaitingOnReferee('2026-09-29');
    expect(read).toEqual({ day: '2026-09-29', ids: new Set() });
  });

  it('keeps the well-formed rows of a mixed answer rather than refusing all of it', async () => {
    answer = {
      data: [{ commitment_id: 'c1', for_day: '2026-09-29' }, 3, null, { commitment_id: 7 }],
      error: null,
    };
    expect([...((await readWaitingOnReferee('2026-09-29'))?.ids ?? [])]).toEqual(['c1']);
  });

  // The line is information and its absence costs nothing -- so a read that does not come back is
  // `null`, never an error for Today to show, and Today keeps what it had.
  it.each([
    ['an error', () => (answer = { data: null, error: { message: 'nope' } })],
    ['a thrown fetch', () => (throws = true)],
    ['a malformed answer', () => (answer = { data: { not: 'a list' }, error: null })],
  ])('answers null on %s', async (_label, arrange) => {
    arrange();
    expect(await readWaitingOnReferee('2026-09-29')).toBeNull();
  });
});

/**
 * CAP-8's copy constraint, asserted in both directions: what it must say, and what it must never
 * say. The absences are the half that catch a well-meant edit.
 */
describe('WAITING_ON_REFEREE_COPY (Story 8.6)', () => {
  const line = WAITING_ON_REFEREE_COPY.line;

  it('says his referee has not looked — a fact about the friend', () => {
    expect(line).toMatch(/your referee hasn’t looked/i);
  });

  it('carries that the day holds without a decision', () => {
    expect(line).toMatch(/if he never does, it holds/i);
  });

  it('never says waiting, and never asks him to do anything about it', () => {
    expect(line).not.toMatch(/waiting|pending/i);
    expect(line).not.toMatch(/remind|ask him|message him|tell him|nudge|chase|contact/i);
  });

  it('never raises a refusal, a count, or a deadline to beat', () => {
    expect(line).not.toMatch(/refus|fail|penalt|₫/i);
    expect(line).not.toMatch(/\d/);
    expect(line).not.toMatch(/before it|hurry|time left|only until/i);
  });
});
