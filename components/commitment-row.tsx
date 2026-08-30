import { StatusPill } from '@/components/status-pill';
import { chainLabel } from '@/lib/chain';
import { CADENCE_LABELS, type CommitmentCadence } from '@/lib/commitment';
import { rowLabel, type CommitmentState } from '@/lib/commitment-state';
import {
  timedWindowOverride,
  timedWindowSpoken,
  timedWindowState,
  type TimedWindowPosition,
} from '@/lib/timed-window';
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
  /** `HH:MM:SS` as Postgres renders a `time`, or null on an untimed commitment (Story 6.1). */
  due_time?: string | null;
  late_window_minutes?: number | null;
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
  windowPosition,
  now,
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
  /**
   * Where this commitment's window stands today (Story 6.5), for a timed one. Rendered through
   * the same two seams `quotaPosition` uses — the pill's `override` and `rowLabel`'s
   * `spokenOverride` — because a window state is no more a settled verdict than a live quota
   * position is, and `stateToday()` still honestly returns `not_yet` underneath both.
   */
  windowPosition?: TimedWindowPosition;
  /**
   * The instant the window state is read against. Owned by the caller rather than read here, so
   * one clock ticks for the whole screen and a test can name the moment it is asserting.
   */
  now?: Date;
}) {
  // Never named `window`: shadowing the global one inside a component is how a later edit
  // reaching for `window.localStorage` silently reads a string union instead.
  const windowState = windowPosition && now ? timedWindowState(windowPosition, now) : undefined;

  // A timed Weekly Quota commitment carries both positions at once (Story 6.4, decision 6). The
  // window takes the pill because it is the half that can still be acted on today and the half
  // that shuts; the week's position keeps its place in the spoken sentence, which is the one
  // surface with room for both.
  const override =
    windowPosition && windowState
      ? timedWindowOverride(windowPosition, windowState)
      : quotaPosition
        ? weeklyQuotaOverride(quotaPosition)
        : undefined;

  const spokenOverride = [
    windowPosition && windowState ? timedWindowSpoken(windowPosition, windowState) : undefined,
    quotaPosition ? weeklyQuotaSpoken(quotaPosition) : undefined,
  ]
    .filter(Boolean)
    .join(', ');

  const label = rowLabel(
    commitment.name,
    state,
    commitment.carries_penalty,
    chainDays,
    // Empty when the row carries neither position — `rowLabel` must fall back to the state
    // table's own wording then, not to a blank sentence.
    spokenOverride || undefined,
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
