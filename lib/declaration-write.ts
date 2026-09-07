/**
 * The one path a declaration takes to the server.
 *
 * This lived inside `components/morning-gate.tsx` until Story 6.2, which was fine while the
 * morning question was the only way to say anything about a commitment. A timed commitment is
 * claimed from Today instead, and it needs every rule this path already carries: the instant of
 * the tap is what is stored, a retry lands once, a duplicate is told apart from someone else's
 * row, and a refusal is never reported as a save.
 *
 * Copying it would have been the one thing `lib/offline-queue.ts` says in its own header must
 * not happen — two implementations of "flushing twice produces one row" would drift, and the
 * drift would be invisible until it cost money. So it moved here whole rather than being
 * written a second time, and the gate now calls it.
 *
 * `lib/declaration-submit.ts` keeps the pure classifiers this file leans on. They are separate
 * because they are testable without a browser or a network, and this file is not.
 */

import { createClient } from '@/lib/supabase/client';
import { dayDeclarationLandsOn } from '@/lib/declaration';
import { enqueue, flush, removeFromQueue, type QueuedDeclaration } from '@/lib/offline-queue';
import { classifyConflict, classifyWriteError, shouldRetry } from '@/lib/declaration-submit';

/**
 * A queued declaration, plus the one thing the *read* side needs.
 *
 * `declaration_derive_day()` owns `for_day` and derives it from `answeredAt` (AD-6); this flag
 * exists so the duplicate-versus-conflict read below looks on the day the server will have
 * chosen. Absent on items queued before Story 6.2, which were all untimed, so the falsy default
 * is also the correct one for that read.
 *
 * Since Epic 6 retrospective item 38 it is also *sent*, as `claimed_timed` — not as a value the
 * server uses, but as the assertion it checks. An item can sit in this queue for days, and the
 * commitment it names can stop being timed while it waits; the server compares what this
 * remembered against what the log says governed that day and refuses the mismatch, rather than
 * quietly filing a claim against the day before the one it was tapped on. An item queued by an
 * older client carries no flag at all, and `undefined` must reach the server as null — "not
 * asserted" — rather than as false, which would assert the opposite of what was meant.
 *
 * Declared here rather than in `lib/offline-queue.ts` because the queue is generic over its
 * item type on purpose and has no business knowing what a due time is.
 */
export interface QueuedClaim extends QueuedDeclaration {
  timed?: boolean;
}

export type SubmitOutcome =
  /**
   * The server has it. `declarationId` is present only for a timed claim, which is the only
   * caller that needs one — a photo references the row it proves (Story 6.3), and a morning
   * answer has nothing to attach. Null when the read that would fetch it failed: the claim
   * itself still landed, and reporting it as unsent over a failed follow-up read would be a
   * worse lie than offering no upload control.
   */
  | { kind: 'sent'; declarationId?: string | null }
  /** No connection; it is in the queue and will be tried again. */
  | { kind: 'queued' }
  /** The server decided, and retrying would change nothing. Nothing was recorded. */
  | { kind: 'refused'; reason: string };

/**
 * Enqueue one declaration, flush everything waiting, and say what became of *this* one.
 *
 * The flush walks the whole queue, not only the item just added — a stale item from an
 * earlier offline session carries its own instant and its own day. Every decision below is
 * therefore made per item, from that item's own `answeredAt`, and only the item whose key
 * matches this call is allowed to set this call's outcome.
 */
export async function submitDeclaration(
  storage: Storage,
  claim: QueuedClaim,
): Promise<SubmitOutcome> {
  enqueue(storage, claim);

  let refusal: string | null = null;
  let landedId: string | null = null;

  const outcome = await flush<QueuedClaim>(storage, async (pending) => {
    const { error } = await createClient()
      .from('declaration')
      .insert({
        owner_id: pending.ownerId,
        commitment_id: pending.commitmentId,
        idempotency_key: pending.idempotencyKey,
        answer: pending.answer,
        answered_at: pending.answeredAt,
        // Checked against the due-time log, never trusted. `?? null` rather than `?? false`:
        // an item queued before this shipped asserts nothing, and asserting "untimed" on its
        // behalf would refuse a claim that is perfectly good.
        claimed_timed: pending.timed ?? null,
      });

    const result = classifyWriteError(error);

    // The id of the row this claim just created, for the photo that will reference it.
    // Read back rather than returned by the insert, so the insert keeps the plain shape every
    // existing caller and its tests already use — and only for a timed claim, because the
    // morning answer has nothing to attach and should not pay for a round trip it never uses.
    if (result === 'sent' && pending.timed && pending.idempotencyKey === claim.idempotencyKey) {
      const { data: landed } = await createClient()
        .from('declaration')
        .select('id')
        .eq('commitment_id', pending.commitmentId)
        .eq('for_day', dayDeclarationLandsOn(new Date(pending.answeredAt), true))
        .maybeSingle();

      landedId = (landed?.id as string | undefined) ?? null;
    }

    // A 23505 alone doesn't say whether this is my own answer arriving out of order or
    // someone else's already sitting there — Postgres's error carries the violated
    // constraint, not the winning row's key. FR-2a changes what else can win that race: once
    // a Penalty-carrying commitment's Auto-check has filed the day, a contradicting tap here
    // must not look like it succeeded (Story 4.3).
    if (result === 'duplicate') {
      const { data: existing, error: readError } = await createClient()
        .from('declaration')
        .select('id,idempotency_key')
        .eq('commitment_id', pending.commitmentId)
        // Derived from this item's own instant, and from whether its commitment is timed —
        // a claim lands on the day it was made, a morning answer on the day before it.
        // Looking on the wrong day would find nothing and read a duplicate as a conflict.
        .eq('for_day', dayDeclarationLandsOn(new Date(pending.answeredAt), pending.timed ?? false))
        .maybeSingle();

      // The read that tells "my own retry" apart from "someone else's row" can itself fail —
      // the same flaky connection that produced this retry in the first place. Treat that
      // like any other unreachable write: stay queued, try again later. Never report a
      // conflict on a read that did not actually complete.
      if (readError) return 'failed';

      const conflict = classifyConflict(existing?.idempotency_key ?? null, pending.idempotencyKey);

      // This attempt's own answer, arriving out of order. The row it is a duplicate of is the
      // row a photo would attach to, so its id is the one to carry back.
      if (conflict === 'duplicate' && pending.idempotencyKey === claim.idempotencyKey) {
        landedId = (existing?.id as string | undefined) ?? null;
      }

      if (conflict === 'conflict') {
        if (pending.idempotencyKey === claim.idempotencyKey) {
          // Not "an Auto-check" specifically: `classifyConflict` only proves the row wasn't
          // filed by this attempt, never who actually filed it — it could just as well be
          // the same author answering from a second device.
          refusal =
            'This day has already been answered — from another device, or by an Auto-check ' +
            'if one is attached — before this reached the server. Reopen the app and it ' +
            'will be gone from what is still owed.';
        }
        // Retrying changes nothing — this row will never accept it. Leaving it queued would
        // retry forever against a day that is already, and permanently, decided.
        removeFromQueue(storage, pending.idempotencyKey);
      }

      return 'sent';
    }

    // A refusal is permanent. Keeping it queued would retry forever against a rule that will
    // never accept it, while the author is told it is safely saved. Story 6.2 adds a new way
    // to earn one: a claim tapped outside its commitment's late window. The server's own
    // sentence is passed through rather than reworded, because it names the window.
    if (result === 'rejected' && pending.idempotencyKey === claim.idempotencyKey) {
      refusal = error?.message ?? 'The server refused this answer.';
    }
    if (result === 'rejected') {
      removeFromQueue(storage, pending.idempotencyKey);
    }

    return shouldRetry(result) ? 'failed' : 'sent';
  });

  if (refusal) return { kind: 'refused', reason: refusal };

  return outcome.kept.includes(claim.idempotencyKey)
    ? { kind: 'queued' }
    : { kind: 'sent', declarationId: landedId };
}
