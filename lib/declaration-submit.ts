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
