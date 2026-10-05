/**
 * What the offline queue says about today's timed claims (Epic 6 retrospective item 48).
 *
 * A timed claim tapped with no connection sits in the queue, dated when it was tapped, and lands
 * on that day whenever it is finally sent (`declaration_derive_day()` reads `answered_at`). Until
 * midnight that is harmless: the photo waits for the row and the day is still open. After
 * midnight it is not. The claim will still land on the day it was tapped, but that day has
 * closed, every photo for it is refused (`evidence_derive_owner()`), and a timed day is decided at
 * midnight by whether a photo landed. Nothing said so: the row went on reading "dated when you
 * tapped" on a day that was no longer the day on screen, or, after a reload, said nothing at all.
 *
 * So this reads the queue itself rather than this session's memory of it. The queue is what
 * survives a reload, and it carries the instant of every tap, which is the one fact that decides
 * whether a claim's day is still today.
 */

import { dayDeclarationLandsOn } from '@/lib/declaration';
import type { QueuedClaim } from '@/lib/declaration-write';
import { formatOwedDay } from '@/lib/referee';

export interface QueuedTimedClaims {
  /** Commitments with a timed claim still on this device for the day on screen. */
  today: ReadonlySet<string>;
  /** Commitments with a timed claim still on this device for a day that has already closed,
   *  mapped to that day (`YYYY-MM-DD`). The latest one wins if there are several. */
  stranded: ReadonlyMap<string, string>;
}

export const NO_QUEUED_CLAIMS: QueuedTimedClaims = { today: new Set(), stranded: new Map() };

/**
 * Sort the queue's timed claims by whether their day is still the one on screen.
 *
 * Untimed items are the morning gate's and are ignored: they answer for the day before the tap by
 * design, and the gate has its own account of them. The day a timed item lands on is the server's
 * own rule, mirrored by `dayDeclarationLandsOn()`; this never invents a second one.
 */
export function queuedTimedClaims(queue: QueuedClaim[], localDay: string): QueuedTimedClaims {
  const today = new Set<string>();
  const stranded = new Map<string, string>();

  for (const item of queue) {
    if (!item.timed) continue;
    const day = dayDeclarationLandsOn(new Date(item.answeredAt), true);

    if (day === localDay) {
      today.add(item.commitmentId);
    } else if (day < localDay) {
      const seen = stranded.get(item.commitmentId);
      if (seen === undefined || day > seen) stranded.set(item.commitmentId, day);
    }
  }

  return { today, stranded };
}

/** Every sentence a queued timed claim is described with. */
export const QUEUED_CLAIM_COPY = {
  /** Still today: it goes when there is a connection, and the day is still open for its photo. */
  queued:
    'Saved on this device — there is no connection right now. It will go when there is one, ' +
    'dated when you tapped.',
  /**
   * Its day has closed. Said plainly, because nothing the author does now can prove it: the
   * claim still goes, dated when he tapped, but no photo can reach a day that has ended. The Grace
   * Day is named because it is the only remedy that exists, and named conditionally because it
   * only reaches a day that failed.
   */
  stranded: (day: string): string =>
    `Your claim for ${formatOwedDay(new Date(`${day}T12:00:00+07:00`))} was still on this ` +
    'device at midnight. It will still be sent, dated when you tapped, but that day has closed, ' +
    'so no photo can prove it now. If the day fails, a Grace Day is the only way back.',
} as const;
