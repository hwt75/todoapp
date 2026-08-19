/**
 * What state a commitment can be in, and what that state looks like.
 *
 * This mapping is the contract Story 2.3 exists to establish. Every later surface — the
 * ledger, the day summary, the referee's screens — reads a state from here rather than
 * deciding for itself what "missed" is coloured, which is exactly the decision that goes
 * wrong when three screens each make it separately.
 *
 * The states are built; the code that *produces* them is not. Until settlement exists
 * (Story 2.5) the only state a commitment can truthfully be in is `not_yet`, and
 * `stateToday` returns nothing else.
 */

import type { CommitmentCadence } from './commitment';

export type CommitmentState = 'not_yet' | 'held' | 'missed' | 'appealing' | 'waived';

export const COMMITMENT_STATES: readonly CommitmentState[] = [
  'not_yet',
  'held',
  'missed',
  'appealing',
  'waived',
];

/**
 * The four colour families from DESIGN.md, each with exactly one meaning. A family that
 * means two things means nothing, which is why `appealing` gets `urgent` rather than
 * borrowing `failed`.
 */
export type StateFamily = 'neutral' | 'held' | 'urgent' | 'failed';

export interface StatePresentation {
  family: StateFamily;
  /** Shown inside the pill. Never empty: colour is never the sole carrier of state. */
  label: string;
  /** How the state reads aloud, as part of the row's single accessibility label. */
  spoken: string;
}

export const STATE_PRESENTATION: Record<CommitmentState, StatePresentation> = {
  // It is ten in the morning. A thing not yet done is not a failure and must never be
  // tinted as one.
  not_yet: { family: 'neutral', label: 'Not yet', spoken: 'not yet done today' },

  // The only family that reads as good, which is why it stays scarce. Story 2.9 replaces
  // this label with the chain count.
  held: { family: 'held', label: 'Held', spoken: 'held' },

  missed: { family: 'failed', label: 'Missed', spoken: 'missed' },

  // Urgent, never failed. Money on hold is money the author might keep, and styling it as
  // money already gone would tell him he has lost something he has not.
  appealing: { family: 'urgent', label: 'On hold', spoken: 'on hold, pending appeal' },

  // A grace day resolved the failure in his favour. It belongs with the days that
  // resolved rather than the days that did not, which is what earns it a tint at all.
  waived: { family: 'held', label: 'Waived', spoken: 'waived by a grace day' },
};

/**
 * The state a commitment is in today.
 *
 * Deliberately returns `not_yet` for everything. Settlement owns every derived value
 * (AD-8) and does not exist yet, so any other answer would be invented rather than
 * computed. The signature takes the commitment so that the story adding settlement
 * changes this function's body and nothing that calls it.
 */
export function stateToday(_commitment: { cadence: CommitmentCadence }): CommitmentState {
  return 'not_yet';
}

/**
 * How a row reads to a screen reader: one label, not two.
 *
 * VoiceOver announcing "Gym" and then "Not yet" as separate elements makes the user
 * assemble the sentence themselves, every row, every morning.
 */
export function rowLabel(name: string, state: CommitmentState, costsMoney: boolean): string {
  const parts = [name, STATE_PRESENTATION[state].spoken];
  if (costsMoney) parts.push('missing this costs money');
  return parts.join(', ');
}
