/**
 * The two decisions the morning gate was getting wrong.
 *
 * Both lived inside the component, where only a browser could reach them, and both were
 * found by review rather than by a test. They are here so they can be exercised without a
 * browser — which is what this codebase does with every rule that matters.
 */

import { dayInQuestion } from './declaration';

/**
 * What a failed write means: try again later, or never.
 *
 * The gate used to treat every failure as a lost network and tell the author his answer
 * was saved and would send when there was signal. For a policy refusal that is a lie he
 * cannot detect: the question is gone, the item retries forever against a rule that will
 * never accept it, and he believes he declared.
 *
 * A Postgres error means the server received the row, understood it, and refused —
 * permanent. Anything without a SQLSTATE never reached a decision, so it is worth
 * retrying.
 */
export type WriteOutcome = 'sent' | 'duplicate' | 'rejected' | 'unreachable';

/** A five-character SQLSTATE. `23505` is unique-violation, `42501` insufficient-privilege. */
const SQLSTATE = /^[0-9A-Z]{5}$/;

export function classifyWriteError(
  error: { code?: string; message?: string } | null,
): WriteOutcome {
  if (!error) return 'sent';

  // The answer is already recorded, and this attempt raced its own acknowledgement.
  // Success arriving out of order, not a failure.
  if (error.code === '23505') return 'duplicate';

  // The server decided. Retrying changes nothing, and saying "no connection" would be
  // false in a way the author cannot check.
  if (error.code && SQLSTATE.test(error.code)) return 'rejected';

  return 'unreachable';
}

/** Whether an outcome should stay in the queue to be tried again. */
export function shouldRetry(outcome: WriteOutcome): boolean {
  return outcome === 'unreachable';
}

/**
 * What a `23505` on `declaration` actually means: my own retry, or someone else's answer.
 *
 * `classifyWriteError` calls every unique-violation `'duplicate'` — "my own answer,
 * arrived out of order" — which is only true when the row that won the race carries the
 * *same* idempotency key as the attempt that just failed. FR-2a changes what else can
 * win that race: once a Penalty-carrying commitment's Auto-check has filed a `slipped`
 * declaration for a day, the author's own contradicting tap hits the exact same
 * `23505` — but it is not his own answer arriving late, it is the machine's answer
 * standing. Postgres's error carries the violated constraint, not the winning row's key,
 * so the only way to tell these apart is to ask what that row actually is.
 *
 * A `'conflict'` only proves the winning row wasn't filed by *this* attempt — never who
 * actually filed it. It could be an Auto-check, or the same author answering from a
 * second device; `declaration` carries nothing that tells the two apart (a recorded,
 * deferred gap — see `deferred-work.md`). Callers must not word a `'conflict'` as
 * Auto-check-specific.
 *
 * The caller is responsible for only calling this once the read that produced
 * `existingIdempotencyKey` is known to have succeeded — a `null` here must mean "no row",
 * never "the read failed," or a transient read failure reads as a permanent conflict.
 */
export function classifyConflict(
  existingIdempotencyKey: string | null,
  attemptedIdempotencyKey: string,
): 'duplicate' | 'conflict' {
  return existingIdempotencyKey === attemptedIdempotencyKey ? 'duplicate' : 'conflict';
}

/**
 * Whether the local day turned over between the question being drawn and answered.
 *
 * The gate renders the day from the instant the screen loaded; the database derives it
 * from the instant of the tap. Across local midnight those disagree, and the answer lands
 * on a day the author was never asked about while the day he *was* asked about stays open
 * — so it never settles, and he is asked again the next morning.
 *
 * The client must not fix this by sending a date: AD-6 gives the server that job, and two
 * places deriving a day is how they come to disagree in the first place. So the gate
 * detects the rollover and asks again rather than filing an answer against the wrong day.
 */
export function dayRolledOver(shownDay: string, tappedAt: Date): boolean {
  return dayInQuestion(tappedAt) !== shownDay;
}
