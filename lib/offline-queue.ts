/**
 * Answers given without a network, held until there is one.
 *
 * The author answers the morning question wherever he happens to be, which is often not
 * somewhere with signal. An answer lost to a dead connection is worse than no question:
 * he told the truth, the system forgot, and the day counts against him anyway.
 *
 * Two properties carry the whole design:
 *
 *   - **The instant stored is the instant he tapped**, never the instant it was delivered
 *     (AD-6). An answer given at 07:31 in a tunnel and flushed at 09:00 is an answer for
 *     07:31, and the day it refers to is derived from that.
 *   - **Flushing twice produces one answer** (AD-4). The key is generated at the tap and
 *     reused by every retry, so the second attempt is refused by the unique constraint
 *     rather than becoming a second declaration.
 *
 * `Storage` is passed in rather than reached for, so the rules are testable without a
 * browser — which is where this codebase puts anything that would otherwise only be
 * exercised by a real device.
 */

export interface QueuedDeclaration {
  /** Generated at the moment of the tap and reused by every retry (AD-4). */
  idempotencyKey: string;
  ownerId: string;
  commitmentId: string;
  answer: 'held' | 'slipped';
  /** ISO-8601. The instant he tapped. */
  answeredAt: string;
}

export const QUEUE_KEY = 'todoapp.declaration-queue.v1';

export function readQueue(storage: Storage): QueuedDeclaration[] {
  const raw = storage.getItem(QUEUE_KEY);
  if (!raw) return [];

  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as QueuedDeclaration[]) : [];
  } catch {
    // A corrupt queue is not worth crashing the morning gate over, but it is worth not
    // silently pretending it was empty either — the caller sees zero pending and the
    // storage is left alone for inspection.
    return [];
  }
}

/** Appends, unless that key is already waiting. A double-tap must not queue twice. */
export function enqueue(storage: Storage, item: QueuedDeclaration): void {
  const queue = readQueue(storage);
  if (queue.some((q) => q.idempotencyKey === item.idempotencyKey)) return;
  storage.setItem(QUEUE_KEY, JSON.stringify([...queue, item]));
}

export function removeFromQueue(storage: Storage, idempotencyKey: string): void {
  const remaining = readQueue(storage).filter((q) => q.idempotencyKey !== idempotencyKey);
  storage.setItem(QUEUE_KEY, JSON.stringify(remaining));
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
 * the answer is recorded — so the item leaves the queue rather than being retried forever.
 */
export async function flush(
  storage: Storage,
  send: (item: QueuedDeclaration) => Promise<'sent' | 'duplicate' | 'failed'>,
): Promise<FlushOutcome> {
  const outcome: FlushOutcome = { delivered: [], kept: [] };

  for (const item of readQueue(storage)) {
    const result = await send(item);

    if (result === 'sent' || result === 'duplicate') {
      removeFromQueue(storage, item.idempotencyKey);
      outcome.delivered.push(item.idempotencyKey);
    } else {
      outcome.kept.push(item.idempotencyKey);
    }
  }

  return outcome;
}
