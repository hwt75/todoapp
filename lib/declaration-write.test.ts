import { beforeEach, describe, expect, it, vi } from 'vitest';
import { submitDeclaration } from './declaration-write';
import { readQueue } from './offline-queue';

/**
 * The shared write path, and specifically the one thing Story 6.2 added to it.
 *
 * The behaviour this file inherited from `components/morning-gate.tsx` is still covered
 * through that component — retries, refusals, the queue, the conflict message. What is new,
 * and what only a test at this level can see, is **which day the duplicate-versus-conflict
 * read looks on**. A morning answer's row is filed for yesterday and a claim's row for today;
 * looking on the wrong one finds nothing, `classifyConflict` sees a null, and the author's own
 * retry is reported to him as somebody else having already answered his day.
 */

const insert = vi.fn();
const maybeSingle = vi.fn();
const eq = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: () => ({
      insert,
      select: () => ({
        eq: (column: string, value: string) => {
          eq(column, value);
          return { eq: (c: string, v: string) => (eq(c, v), { maybeSingle }) };
        },
      }),
    }),
  }),
}));

/** A Storage that behaves like the browser's without needing one — the same helper
 *  `lib/offline-queue.test.ts` uses, for the same reason: these rules are exercised in node. */
function fakeStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    clear: () => map.clear(),
    getItem: (k) => map.get(k) ?? null,
    key: (i) => [...map.keys()][i] ?? null,
    removeItem: (k) => void map.delete(k),
    setItem: (k, v) => void map.set(k, v),
  };
}

let storage: Storage;

const tappedAt = new Date('2026-08-19T20:14:00+07:00');

function claim(overrides: Record<string, unknown> = {}) {
  return {
    idempotencyKey: 'key-1',
    ownerId: 'u1',
    commitmentId: 'c1',
    answer: 'held' as const,
    answeredAt: tappedAt.toISOString(),
    ...overrides,
  };
}

beforeEach(() => {
  insert.mockReset();
  insert.mockResolvedValue({ error: null });
  maybeSingle.mockReset();
  maybeSingle.mockResolvedValue({ data: null, error: null });
  eq.mockReset();
  storage = fakeStorage();
});

describe('one declaration on its way to the server', () => {
  it('sends the instant of the tap and never a day', async () => {
    await submitDeclaration(storage, claim({ timed: true }));

    // AD-6: the row carries when he tapped. Which day that belongs to is the server's call,
    // so nothing resembling a date may appear in what is sent.
    expect(insert).toHaveBeenCalledOnce();
    const sent = insert.mock.calls[0][0];
    expect(sent.answered_at).toBe(tappedAt.toISOString());
    expect(sent).not.toHaveProperty('for_day');
    expect(sent).not.toHaveProperty('timed');
  });

  it('reports a clean write as sent and leaves nothing queued', async () => {
    const outcome = await submitDeclaration(storage, claim());

    expect(outcome).toEqual({ kind: 'sent' });
    expect(readQueue(storage)).toHaveLength(0);
  });

  it('keeps an unreachable write in the queue, dated when it was tapped', async () => {
    insert.mockResolvedValue({ error: { message: 'network down' } });

    const outcome = await submitDeclaration(storage, claim());

    expect(outcome).toEqual({ kind: 'queued' });
    expect(readQueue(storage)[0]).toMatchObject({
      idempotencyKey: 'key-1',
      answeredAt: tappedAt.toISOString(),
    });
  });

  it('passes a refusal through in the server’s own words, and stops retrying it', async () => {
    // Story 6.2's new refusal: a claim tapped after its window shut. The sentence names the
    // window, which is more than this layer could say on its own.
    insert.mockResolvedValue({
      error: {
        code: 'P0001',
        message: 'This commitment could be claimed from 20:00 for 30 minutes.',
      },
    });

    const outcome = await submitDeclaration(storage, claim({ timed: true }));

    expect(outcome).toEqual({
      kind: 'refused',
      reason: 'This commitment could be claimed from 20:00 for 30 minutes.',
    });
    // Kept in the queue it would retry forever against a rule that will never accept it,
    // while the author is told it is safely saved.
    expect(readQueue(storage)).toHaveLength(0);
  });
});

describe('which day the duplicate read looks on', () => {
  it('looks at the day of the tap for a timed claim', async () => {
    insert.mockResolvedValue({ error: { code: '23505' } });
    maybeSingle.mockResolvedValue({ data: { idempotency_key: 'key-1' }, error: null });

    const outcome = await submitDeclaration(storage, claim({ timed: true }));

    expect(eq).toHaveBeenCalledWith('for_day', '2026-08-19');
    // Its own key won the race: this is the author's own answer arriving out of order.
    expect(outcome).toEqual({ kind: 'sent' });
  });

  it('looks at the day before for a morning answer', async () => {
    insert.mockResolvedValue({ error: { code: '23505' } });
    maybeSingle.mockResolvedValue({ data: { idempotency_key: 'key-1' }, error: null });

    await submitDeclaration(storage, claim({ timed: false }));

    expect(eq).toHaveBeenCalledWith('for_day', '2026-08-18');
  });

  it('treats an item queued before Story 6.2, which carries no flag, as a morning answer', async () => {
    insert.mockResolvedValue({ error: { code: '23505' } });
    maybeSingle.mockResolvedValue({ data: { idempotency_key: 'key-1' }, error: null });

    // Every item queued before this story was an untimed morning answer, so the falsy
    // default is also the correct one — a stale queue must not start reading the wrong day.
    await submitDeclaration(storage, claim());

    expect(eq).toHaveBeenCalledWith('for_day', '2026-08-18');
  });

  it('reports another row on the claim’s own day as a conflict, not as a save', async () => {
    insert.mockResolvedValue({ error: { code: '23505' } });
    maybeSingle.mockResolvedValue({ data: { idempotency_key: 'somebody-else' }, error: null });

    const outcome = await submitDeclaration(storage, claim({ timed: true }));

    expect(outcome.kind).toBe('refused');
    expect(readQueue(storage)).toHaveLength(0);
  });

  it('stays queued when the read that would tell them apart fails', async () => {
    insert.mockResolvedValue({ error: { code: '23505' } });
    maybeSingle.mockResolvedValue({ data: null, error: { message: 'read failed' } });

    // Never a conflict on a read that did not complete: the same flaky connection that
    // produced the retry can produce this, and reporting it would be a permanent verdict
    // drawn from a transient failure.
    const outcome = await submitDeclaration(storage, claim({ timed: true }));

    expect(outcome).toEqual({ kind: 'queued' });
    expect(readQueue(storage)).toHaveLength(1);
  });
});
