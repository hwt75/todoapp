import { StatusPill } from '@/components/status-pill';
import { CADENCE_LABELS, type CommitmentCadence } from '@/lib/commitment';
import { rowLabel, type CommitmentState } from '@/lib/commitment-state';

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
}: {
  commitment: RowCommitment;
  state: CommitmentState;
}) {
  return (
    <div
      className="row"
      role="group"
      aria-label={rowLabel(commitment.name, state, commitment.carries_penalty)}
    >
      <div className="row-main">
        <div className="row-name">{commitment.name}</div>
        <div className="row-muted" aria-hidden="true">
          {target(commitment)}
        </div>
      </div>
      <StatusPill state={state} />
    </div>
  );
}
