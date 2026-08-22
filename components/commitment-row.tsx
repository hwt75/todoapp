import { StatusPill } from '@/components/status-pill';
import { chainLabel } from '@/lib/chain';
import { CADENCE_LABELS, type CommitmentCadence } from '@/lib/commitment';
import { rowLabel, type CommitmentState } from '@/lib/commitment-state';
import {
  weeklyQuotaOverride,
  weeklyQuotaSpoken,
  type WeeklyQuotaPosition,
} from '@/lib/weekly-quota';

export interface RowCommitment {
  id: string;
  name: string;
  cadence: CommitmentCadence;
  carries_penalty: boolean;
  weekly_target: number | null;
  daily_minutes_target: number | null;
}

/**
 * What the commitment is set up to be — its target, not its progress.
 *
 * Progress is a derived value and settlement owns every one of those (AD-8). A weekly row
 * reading `0/3` would claim the author has done nothing this week when the truth is that
 * nothing has been recorded either way, and those are different statements.
 */
function target(commitment: RowCommitment): string {
  const parts: string[] = [CADENCE_LABELS[commitment.cadence]];
  if (commitment.weekly_target !== null) parts.push(`${commitment.weekly_target}×`);
  if (commitment.daily_minutes_target !== null) {
    parts.push(`${commitment.daily_minutes_target / 60}h`);
  }
  if (commitment.carries_penalty) parts.push('costs money');
  return parts.join(' · ');
}

/**
 * One commitment, as every surface after this one will draw it.
 *
 * Name left, state right, hairline above, and the row itself never tinted. The whole row
 * is one accessibility label rather than several elements, so a screen reader says
 * "Gym, not yet done today" instead of making the listener assemble that sentence for
 * every row, every morning.
 */
export function CommitmentRow({
  commitment,
  state,
  chainDays = 0,
  onOpen,
  quotaPosition,
}: {
  commitment: RowCommitment;
  state: CommitmentState;
  /** Days this commitment has held. Zero shows nothing at all — never `day 0`. */
  chainDays?: number;
  /** Opens the Chains detail. Without it the row stays a group rather than a control. */
  onOpen?: (commitment: RowCommitment) => void;
  /**
   * A Weekly Quota commitment's live position from `weekly_quota_progress` (spec 3-3). When
   * given, it replaces the pill and the row's spoken sentence via `StatusPill`'s `override` and
   * `rowLabel`'s `spokenOverride` — `state` itself is untouched, since a live position is not
   * one of the five settled states `stateToday` can honestly return (D3). Without it the row
   * keeps its AD-8 guard exactly as before: a target, never a progress it cannot know.
   */
  quotaPosition?: WeeklyQuotaPosition;
}) {
  const override = quotaPosition ? weeklyQuotaOverride(quotaPosition) : undefined;
  const spokenOverride = quotaPosition ? weeklyQuotaSpoken(quotaPosition) : undefined;
  const label = rowLabel(
    commitment.name,
    state,
    commitment.carries_penalty,
    chainDays,
    spokenOverride,
  );
  const chain = chainLabel(chainDays);

  const inside = (
    <>
      <div className="row-main">
        <div className="row-name">{commitment.name}</div>
        <div className="row-muted" aria-hidden="true">
          {target(commitment)}
        </div>
      </div>
      {/* The chain sits beside the pill and never inside it, and never carries a colour.
          DESIGN.md rations the `held` family on purpose; a green chain on every row makes
          the whole screen the colour that is supposed to mean something. */}
      {chain && (
        <div className="row-chain" aria-hidden="true">
          {chain}
        </div>
      )}
      <StatusPill state={state} override={override} />
    </>
  );

  if (!onOpen) {
    return (
      <div className="row" role="group" aria-label={label}>
        {inside}
      </div>
    );
  }

  return (
    <button
      type="button"
      className="row row-open"
      aria-label={label}
      onClick={() => onOpen(commitment)}
    >
      {inside}
    </button>
  );
}
