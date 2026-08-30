/**
 * Where a timed commitment's window stands right now, and how that reads on the pill and aloud.
 *
 * `lifecycle.md` names the states and this file is their only client-side implementation. Two
 * halves make one state: the clock, which is entirely local arithmetic, and the two facts only
 * the server knows — was today claimed, did a photo land — which arrive from
 * `public.timed_claim_today` (Story 6.5's migration) and never from a client-side tally of raw
 * `declaration` rows (AD-8).
 *
 * The clock is here rather than on the server because CAP-7 asks for the shut state to become
 * visible "without opening anything or refreshing": a state fetched at 20:29 is wrong at 20:31,
 * and no read can fix that. It is a *display* decision only. Whether a claim is accepted stays
 * with `declaration_derive_day()` (20260828140000), which refuses a tap outside the window in
 * the author's own words — this file never writes that sentence itself, and a device with a
 * wrong clock therefore loses the offer of a control, never the truth about its day.
 *
 * Mirrors `lib/weekly-quota.ts` exactly in shape: a position in, `state`/`label`/`spoken`/
 * `family`/`override` out, and no arithmetic beyond what it is given.
 */

import type { StateFamily } from './commitment-state';
import { ZONE } from './declaration';

/** The states `lifecycle.md` names for one local day of one timed commitment. */
export type TimedWindowState = 'ahead' | 'open' | 'claimed' | 'proven' | 'shut';

export interface TimedWindowPosition {
  /** `HH:MM:SS` as Postgres renders a `time` — `HH:MM` is accepted too. */
  dueTime: string;
  /** 5 to 240, enforced by `commitment_late_window_is_a_window` (20260828130000). */
  lateWindowMinutes: number;
  /** A declaration for today exists — `timed_claim_today.declaration_id is not null`. */
  claimed: boolean;
  /** A photo has landed on that claim — `timed_claim_today.proven`. */
  proven: boolean;
}

const CLOCK = new Intl.DateTimeFormat('en-GB', {
  timeZone: ZONE,
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hour12: false,
});

/**
 * Seconds since local midnight, whatever the device believes its own zone is.
 *
 * Seconds rather than minutes, and half-open at both ends, because that is exactly what
 * `declaration_derive_day()` compares: a tap at 20:29:59.5 is inside a window ending at 20:30
 * and a tap at 20:30:00.0 is not. A minute-resolution mirror would offer a control for half a
 * minute after the server had begun refusing it.
 */
export function secondsOfDay(at: Date): number {
  const parts = Object.fromEntries(CLOCK.formatToParts(at).map((p) => [p.type, p.value]));
  // Intl renders midnight as 24 in some engines under hour12: false.
  const hour = Number(parts.hour) % 24;
  return hour * 3600 + Number(parts.minute) * 60 + Number(parts.second);
}

/** Seconds since midnight of an `HH:MM` or `HH:MM:SS` wall-clock time. */
function secondsOfTime(time: string): number {
  const [h, m, s] = time.split(':').map(Number);
  return h * 3600 + m * 60 + (s || 0);
}

/** `HH:MM` from seconds since midnight. The window cannot cross midnight, so this never wraps. */
function clockLabel(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}

/** When the window opens, `HH:MM`. */
export function windowOpensAt(position: TimedWindowPosition): string {
  return clockLabel(secondsOfTime(position.dueTime));
}

/** When the window shuts, `HH:MM`. */
export function windowShutsAt(position: TimedWindowPosition): string {
  return clockLabel(secondsOfTime(position.dueTime) + position.lateWindowMinutes * 60);
}

/**
 * The state this window is in at `now`.
 *
 * What happened outranks what the clock says, in both directions: a claim filed at 20:31 still
 * reads `claimed` at 23:00 because its photo can land until midnight, and a proven day stays
 * proven for the rest of the day rather than reverting to `shut` when the window closes.
 */
export function timedWindowState(position: TimedWindowPosition, now: Date): TimedWindowState {
  if (position.proven) return 'proven';
  if (position.claimed) return 'claimed';

  const opens = secondsOfTime(position.dueTime);
  const at = secondsOfDay(now);

  if (at < opens) return 'ahead';
  if (at < opens + position.lateWindowMinutes * 60) return 'open';
  return 'shut';
}

/**
 * The pill's visible text.
 *
 * `ahead` shows the hour itself rather than a word: before the window opens, the only thing
 * worth knowing is when it does, and the row is otherwise silent about a commitment there is
 * nothing to do about yet.
 */
export function timedWindowLabel(
  position: TimedWindowPosition,
  state = timedWindowState(position, new Date()),
): string {
  switch (state) {
    case 'ahead':
      return windowOpensAt(position);
    case 'open':
      return 'Open now';
    case 'claimed':
      return 'Photo due';
    case 'proven':
      return 'Proven';
    case 'shut':
      return 'Shut';
  }
}

/**
 * How the same state reads aloud, as part of the row's one accessibility label.
 *
 * `StatusPill`'s own label is `aria-hidden`, so this is the only sentence a screen reader gets
 * for the row — and "not yet done today" beside a pill reading `Shut` would be the two
 * disagreeing. The shut sentence says *nothing claimed* rather than *missed*: the day is not
 * over, and FR-10 forbids announcing a verdict for a day still running.
 */
export function timedWindowSpoken(
  position: TimedWindowPosition,
  state = timedWindowState(position, new Date()),
): string {
  switch (state) {
    case 'ahead':
      return `window opens at ${windowOpensAt(position)}`;
    case 'open':
      return `window open now, until ${windowShutsAt(position)}`;
    case 'claimed':
      return 'claimed, photo still needed by midnight';
    case 'proven':
      return 'claimed and proven';
    case 'shut':
      return 'window shut, nothing claimed';
  }
}

/**
 * The pill family.
 *
 * `urgent` covers both states that are still actionable and still cost money if left — the open
 * window and the claim whose photo has not arrived. `failed` is earned only once nothing but a
 * Grace Day can help, which is the same thing `missed` means everywhere else in this product.
 * `held` stays rationed to the one state that is genuinely finished (`DESIGN.md`).
 */
export function timedWindowFamily(
  position: TimedWindowPosition,
  state = timedWindowState(position, new Date()),
): StateFamily {
  switch (state) {
    case 'ahead':
      return 'neutral';
    case 'open':
    case 'claimed':
      return 'urgent';
    case 'proven':
      return 'held';
    case 'shut':
      return 'failed';
  }
}

/** The whole `StatusPill` override in one call — label and family together. */
export function timedWindowOverride(
  position: TimedWindowPosition,
  state = timedWindowState(position, new Date()),
): { family: StateFamily; label: string } {
  return { family: timedWindowFamily(position, state), label: timedWindowLabel(position, state) };
}
