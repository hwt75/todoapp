import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  QUEUE_KEY,
  type QueuedDeclaration,
  enqueue,
  flush,
  readQueue,
  removeFromQueue,
} from './offline-queue';

/** A Storage that behaves like the browser's without needing one. */
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

const TAPPED_AT = '2026-08-19T00:31:00.000Z';

function item(overrides: Partial<QueuedDeclaration> = {}): QueuedDeclaration {
  return {
    idempotencyKey: 'key-1',
    ownerId: 'owner-1',
    commitmentId: 'commitment-1',
    answer: 'held',
    answeredAt: TAPPED_AT,
    ...overrides,
  };
}

let storage: Storage;
beforeEach(() => {
  storage = fakeStorage();
});

describe('holding an answer', () => {
  it('starts empty', () => {
    expect(readQueue(storage)).toEqual([]);
  });

  it('keeps the instant he tapped, not the instant it is read back', () => {
    // The whole reason the queue exists. An answer given at 07:31 in a tunnel and flushed
    // at 09:00 is an answer for 07:31, and the day it refers to is derived from that.
    enqueue(storage, item());
    expect(readQueue(storage)[0].answeredAt).toBe(TAPPED_AT);
  });

  it('does not queue the same tap twice', () => {
    enqueue(storage, item());
    enqueue(storage, item());
    expect(readQueue(storage)).toHaveLength(1);
  });

  it('queues two different answers', () => {
    enqueue(storage, item());
    enqueue(storage, item({ idempotencyKey: 'key-2', commitmentId: 'commitment-2' }));
    expect(readQueue(storage)).toHaveLength(2);
  });

  it('survives a corrupt queue rather than throwing into the morning gate', () => {
    storage.setItem(QUEUE_KEY, '{not json');
    expect(() => readQueue(storage)).not.toThrow();
    expect(readQueue(storage)).toEqual([]);
  });

  it('survives a queue that is valid JSON but the wrong shape', () => {
    storage.setItem(QUEUE_KEY, '{"answers":[]}');
    expect(readQueue(storage)).toEqual([]);
  });
});

describe('flushing', () => {
  it('delivers what it can and empties those', async () => {
    enqueue(storage, item());
    const send = vi.fn().mockResolvedValue('sent' as const);

    const outcome = await flush(storage, send);

    expect(outcome.delivered).toEqual(['key-1']);
    expect(outcome.kept).toEqual([]);
    expect(readQueue(storage)).toEqual([]);
  });

  it('keeps what it cannot deliver', async () => {
    enqueue(storage, item());
    const send = vi.fn().mockResolvedValue('failed' as const);

    const outcome = await flush(storage, send);

    expect(outcome.kept).toEqual(['key-1']);
    expect(readQueue(storage)).toHaveLength(1);
  });

  it('sends the tap instant, not the flush instant', async () => {
    enqueue(storage, item());
    const send = vi.fn().mockResolvedValue('sent' as const);

    await flush(storage, send);

    expect(send).toHaveBeenCalledWith(expect.objectContaining({ answeredAt: TAPPED_AT }));
  });

  describe('flushing twice', () => {
    it('produces one answer, because the first flush emptied the queue', async () => {
      enqueue(storage, item());
      const send = vi.fn().mockResolvedValue('sent' as const);

      await flush(storage, send);
      await flush(storage, send);

      expect(send).toHaveBeenCalledTimes(1);
    });

    it('treats a duplicate as delivered rather than retrying it forever', async () => {
      // The case this exists for: a flush got through and the acknowledgement did not, so
      // the row already exists. The answer is recorded — that is success, and keeping it
      // queued would mean retrying something that already worked until the end of time.
      enqueue(storage, item());
      const send = vi.fn().mockResolvedValue('duplicate' as const);

      const outcome = await flush(storage, send);

      expect(outcome.delivered).toEqual(['key-1']);
      expect(readQueue(storage)).toEqual([]);
    });

    it('reuses the same key on a retry, so the server can refuse the second', async () => {
      enqueue(storage, item());
      const send = vi
        .fn()
        .mockResolvedValueOnce('failed' as const)
        .mockResolvedValueOnce('sent' as const);

      await flush(storage, send);
      await flush(storage, send);

      const keys = send.mock.calls.map((c) => (c[0] as QueuedDeclaration).idempotencyKey);
      expect(keys).toEqual(['key-1', 'key-1']);
    });
  });

  it('does not let one failure hold up the rest', async () => {
    enqueue(storage, item());
    enqueue(storage, item({ idempotencyKey: 'key-2', commitmentId: 'commitment-2' }));

    const send = vi
      .fn()
      .mockResolvedValueOnce('failed' as const)
      .mockResolvedValueOnce('sent' as const);

    const outcome = await flush(storage, send);

    expect(outcome.kept).toEqual(['key-1']);
    expect(outcome.delivered).toEqual(['key-2']);
  });
});

describe('removing by key', () => {
  it('removes only the one named', () => {
    enqueue(storage, item());
    enqueue(storage, item({ idempotencyKey: 'key-2' }));

    removeFromQueue(storage, 'key-1');

    expect(readQueue(storage).map((q) => q.idempotencyKey)).toEqual(['key-2']);
  });

  it('is a no-op for a key that is not there', () => {
    enqueue(storage, item());
    removeFromQueue(storage, 'never-existed');
    expect(readQueue(storage)).toHaveLength(1);
  });
});
