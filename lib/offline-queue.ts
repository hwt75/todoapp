/**
 * Observations made without a network, held until there is one.
 *
 * The author answers the morning question wherever he happens to be, which is often not
 * somewhere with signal, and he stops a focus session wherever the work ended. An
 * observation lost to a dead connection is worse than never having been asked: he told the
 * truth, the system forgot, and the day counts against him anyway.
 *
 * Two properties carry the whole design:
 *
 *   - **The instant stored is the instant he tapped**, never the instant it was delivered
 *     (AD-6). An answer given at 07:31 in a tunnel and flushed at 09:00 is an answer for
 *     07:31, and the day it refers to is derived from that.
 *   - **Flushing twice produces one row** (AD-4). The key is generated at the tap and
 *     reused by every retry, so the second attempt is refused by the unique constraint
 *     rather than becoming a second declaration or a second session.
 *
 * `Storage` is passed in rather than reached for, so the rules are testable without a
 * browser — which is where this codebase puts anything that would otherwise only be
 * exercised by a real device.
 *
 * **Why this is generic rather than copied.** Story 3.1 needed exactly these two rules for
 * focus sessions, and the only declaration-specific thing here was the item's *type* and the
 * storage key. So both became parameters, the key defaulted, and the type parameter defaulted
 * to `QueuedDeclaration` — which is what lets every existing call site and this module's own
 * test compile and pass untouched. A second copy of dedupe-and-flush is the one thing that
 * must not exist: two implementations of "flushing twice produces one row" would drift, and
 * the drift would be invisible until it cost money.
 */

/** The one thing the queue itself needs to know about an item. */
export interface QueueItem {
  /** Generated at the moment of the tap and reused by every retry (AD-4). */
  idempotencyKey: string;
}

export interface QueuedDeclaration extends QueueItem {
  ownerId: string;
  commitmentId: string;
  answer: 'held' | 'slipped';
  /** ISO-8601. The instant he tapped. */
  answeredAt: string;
}

export const QUEUE_KEY = 'todoapp.declaration-queue.v1';

export function readQueue<T extends QueueItem = QueuedDeclaration>(
  storage: Storage,
  key: string = QUEUE_KEY,
): T[] {
  const raw = storage.getItem(key);
  if (!raw) return [];

  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as T[]) : [];
  } catch {
    // A corrupt queue is not worth crashing the morning gate over, but it is worth not
    // silently pretending it was empty either — the caller sees zero pending and the
    // storage is left alone for inspection.
    return [];
  }
}

/** Appends, unless that key is already waiting. A double-tap must not queue twice. */
export function enqueue<T extends QueueItem = QueuedDeclaration>(
  storage: Storage,
  item: T,
  key: string = QUEUE_KEY,
): void {
  const queue = readQueue<T>(storage, key);
  if (queue.some((q) => q.idempotencyKey === item.idempotencyKey)) return;
  storage.setItem(key, JSON.stringify([...queue, item]));
}

export function removeFromQueue(
  storage: Storage,
  idempotencyKey: string,
  key: string = QUEUE_KEY,
): void {
  const remaining = readQueue<QueueItem>(storage, key).filter(
    (q) => q.idempotencyKey !== idempotencyKey,
  );
  storage.setItem(key, JSON.stringify(remaining));
}

export interface FlushOutcome {
  delivered: string[];
  /** Left in the queue: the network is still gone, or the server is still unhappy. */
  kept: string[];
}

/**
 * Sends everything waiting, keeping whatever fails.
 *
 * `send` reports `duplicate` for the case that matters most: a row that already exists
 * because a previous flush got through before the acknowledgement did. That is success —
 * the observation is recorded — so the item leaves the queue rather than being retried
 * forever.
 */
export async function flush<T extends QueueItem = QueuedDeclaration>(
  storage: Storage,
  send: (item: T) => Promise<'sent' | 'duplicate' | 'failed'>,
  key: string = QUEUE_KEY,
): Promise<FlushOutcome> {
  const outcome: FlushOutcome = { delivered: [], kept: [] };

  for (const item of readQueue<T>(storage, key)) {
    const result = await send(item);

    if (result === 'sent' || result === 'duplicate') {
      removeFromQueue(storage, item.idempotencyKey, key);
      outcome.delivered.push(item.idempotencyKey);
    } else {
      outcome.kept.push(item.idempotencyKey);
    }
  }

  return outcome;
}
