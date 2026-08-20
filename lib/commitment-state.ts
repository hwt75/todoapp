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

import { chainSpoken } from './chain';
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

  // The only family that reads as good, which is why it stays scarce. An earlier note here
  // said Story 2.9 would replace this label with the chain count. It did not, and could not:
  // `EXPERIENCE.md` § Component Patterns puts the chain inside the pill on the `held` state,
  // but no row is ever `held` today — FR-10 forbids a mid-day verdict — so a chain living
  // there would never render on any row, ever. The chain is its own element beside the pill.
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
 * Still returns `not_yet` for everything, and now for a different reason than when it was
 * written. Settlement exists as of Story 2.5 — but it closes a day *after* that day has
 * ended, and this screen shows *today*. A day still in progress has no verdict by
 * construction, so there is nothing for this function to read.
 *
 * That is also FR-10 holding: nothing may announce mid-day that the day is already lost,
 * and a screen that could show a verdict for today would be the first thing to break it.
 *
 * The settled verdicts become visible in the Ledger (Story 2.6), which is a list of days
 * that have ended. Not here.
 */
export function stateToday(_commitment: { cadence: CommitmentCadence }): CommitmentState {
  return 'not_yet';
}

/**
 * How a row reads to a screen reader: one label, not two.
 *
 * VoiceOver announcing "Gym" and then "Not yet" as separate elements makes the user
 * assemble the sentence themselves, every row, every morning.
 *
 * `spokenOverride` replaces `STATE_PRESENTATION[state].spoken` when present — the parallel to
 * `StatusPill`'s own `override` prop (spec 3-3, D3). A live quota position such as
 * `1/3 · 3 days` is not one of the five settled states `stateToday` can honestly return, so
 * without this the row would fall back to "not yet done today" while the pill beside it says
 * something else entirely. Every existing caller is unaffected: omitting it keeps the state
 * table's own wording exactly as before.
 */
export function rowLabel(
  name: string,
  state: CommitmentState,
  costsMoney: boolean,
  chainDays = 0,
  spokenOverride?: string,
): string {
  // Name, state, then chain — the order `EXPERIENCE.md` § Accessibility specifies, and the
  // order they matter in. The chain is history; it must not arrive before what today is.
  const parts = [name, spokenOverride ?? STATE_PRESENTATION[state].spoken];
  const chain = chainSpoken(chainDays);
  if (chain) parts.push(chain);
  if (costsMoney) parts.push('missing this costs money');
  return parts.join(', ');
}
