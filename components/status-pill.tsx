import { STATE_PRESENTATION, type CommitmentState, type StateFamily } from '@/lib/commitment-state';

/**
 * A state label. Never a control.
 *
 * It carries a word as well as a tint, because colour is never the sole carrier of state
 * here — a user who cannot distinguish the four families must lose no information at all.
 * `aria-hidden` because the row already announces this state as part of one sentence, and
 * hearing it twice is worse than not seeing it once.
 *
 * `override` replaces the state-derived family and label when present (spec 3-3, D3). A live
 * quota position — `1/3 · 3 days` — is not a settlement verdict, so inventing a sixth
 * `CommitmentState` for it would be exactly the collapse `lib/commitment-state.ts`'s own header
 * warns against: a family standing for two different kinds of thing. Every existing caller
 * passes no `override` and renders exactly as before.
 */
export function StatusPill({
  state,
  override,
}: {
  state: CommitmentState;
  override?: { family: StateFamily; label: string };
}) {
  const { family, label } = override ?? STATE_PRESENTATION[state];
  return (
    <span className={`pill pill-${family}`} aria-hidden="true">
      {label}
    </span>
  );
}
