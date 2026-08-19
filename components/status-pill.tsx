import { STATE_PRESENTATION, type CommitmentState } from '@/lib/commitment-state';

/**
 * A state label. Never a control.
 *
 * It carries a word as well as a tint, because colour is never the sole carrier of state
 * here — a user who cannot distinguish the four families must lose no information at all.
 * `aria-hidden` because the row already announces this state as part of one sentence, and
 * hearing it twice is worse than not seeing it once.
 */
export function StatusPill({ state }: { state: CommitmentState }) {
  const { family, label } = STATE_PRESENTATION[state];
  return (
    <span className={`pill pill-${family}`} aria-hidden="true">
      {label}
    </span>
  );
}
