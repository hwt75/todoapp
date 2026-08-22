/**
 * How a chain reads.
 *
 * **There is deliberately no chain arithmetic here.** The rule — a miss breaks it, silence
 * breaks it, a day it was not owed is skipped — is written once, in `chain_current`, because
 * settlement is the only thing that can write the facts and Postgres is where settlement
 * runs. A reference implementation in TypeScript would be a second copy that nothing calls,
 * and Story 2.8 spent an afternoon on exactly that: the day-summary copy rules lived in two
 * languages and disagreed about a thousands separator within minutes of being written. A
 * second copy of the *chain* rule would disagree about something worse and later.
 *
 * So this file holds only what the client genuinely owns: how the number is written, how it
 * is spoken, and when it is shown at all.
 */

export interface Chain {
  /** Days it has held, up to and including the last day judged. Zero after a break. */
  currentDays: number;
  /** The longest it has ever run. Never decreases. */
  longestDays: number;
}

/**
 * The chain as it appears on a row, or null when there is nothing to say.
 *
 * `day 12`, not `12`. A bare number beside a status pill is a quantity of something unnamed,
 * and the row already carries a target that looks like a quantity.
 *
 * Zero returns null rather than `day 0`. A chain that has just broken says nothing on the
 * row; the place a reset is allowed to be visible is the Chains detail, where the longest
 * chain is beside it and the number is read against a record instead of against nothing.
 */
export function chainLabel(currentDays: number): string | null {
  return currentDays > 0 ? `day ${currentDays}` : null;
}

/**
 * How the chain reads aloud, as part of a row's single label.
 *
 * "day 12" is a written form. Spoken, it needs to be a phrase — a screen reader saying
 * "Gym, not yet done today, day 12" makes the listener work out what the twelve counts.
 */
export function chainSpoken(currentDays: number): string | null {
  if (currentDays <= 0) return null;
  return currentDays === 1 ? 'holding one day' : `holding ${currentDays} days`;
}

/**
 * The pair, as the Chains detail shows it.
 *
 * The adjacency is the point and not a layout preference. A reset read against zero says
 * *you have nothing*; read against a record it says *you have done better than this and you
 * did it yourself*. That difference is the whole reason this surface exists.
 */
export function chainAgainstRecord(chain: Chain): string {
  const current = chain.currentDays === 0 ? 'Broken' : `Day ${chain.currentDays}`;
  return `${current} · best ${chain.longestDays}`;
}

/** What a frozen day says about one commitment. Mirrors the `commitment_outcome` enum. */
export type CommitmentOutcome = 'held' | 'missed' | 'unanswered';

/**
 * How a past day reads in the calendar.
 *
 * `unanswered` is kept distinct from `missed` even though the money treats them the same.
 * The ledger's job is to be accurate about what happened, and "I said no" and "I said
 * nothing" are different things to have done — collapsing them would make the history
 * agree with the invoice and disagree with him.
 */
export const OUTCOME_PRESENTATION: Record<
  CommitmentOutcome,
  { family: 'held' | 'failed' | 'neutral'; label: string; spoken: string }
> = {
  held: { family: 'held', label: 'Held', spoken: 'held' },
  missed: { family: 'failed', label: 'Missed', spoken: 'missed' },
  unanswered: { family: 'neutral', label: 'No answer', spoken: 'never answered' },
};
