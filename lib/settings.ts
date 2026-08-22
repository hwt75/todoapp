/**
 * How a switch the app cannot flip reads on a screen.
 *
 * Two of the three Settings rows describe state the product does not own: notification permission
 * is granted or refused by iOS, and home-screen installation is done by adding or deleting an
 * icon. `EXPERIENCE.md` § Settings is explicit that these are "shown with what breaks if they are
 * off, in plain language, not as toggles alone" — a toggle implies the app can turn the thing off,
 * and a control that appears to do something it cannot is the failure this product can least
 * afford. The symptom of a broken delivery channel is silence, and silence looks exactly like the
 * product working while being ignored.
 *
 * So each state gets a sentence, and the sentences live here rather than inside JSX: they are copy
 * rules, and a rule that cannot be tested is a rule that erodes. This is the same arrangement
 * `lib/commitment-state.ts` uses for the row states.
 */

import type { InstallState } from './install-state';

/** The three answers the browser can give. `default` means it has never been asked. */
export type PermissionState = 'default' | 'granted' | 'denied';

export interface SettingRow {
  /** What the state is, in two or three words. Never a bare enum value. */
  state: string;
  /** What breaks, or does not, while it is in this state. One sentence. */
  consequence: string;
  /**
   * Whether the app genuinely has a control for this state.
   *
   * True only where tapping something would actually change the answer. iOS prompts for
   * notification permission exactly once; after that, every call returns the standing answer and a
   * button would be a lie with a tap target.
   */
  actionable: boolean;
}

export const PERMISSION_ROWS: Record<PermissionState, SettingRow> = {
  default: {
    state: 'Not asked yet',
    consequence:
      'Nothing reaches you until this is on — no morning question, no evening summary. The app opens and waits, which is exactly the failure it was built to prevent.',
    actionable: true,
  },
  granted: {
    state: 'On',
    consequence: 'The morning question and the evening summary arrive on your lock screen.',
    actionable: false,
  },
  denied: {
    state: 'Off',
    consequence:
      'iOS will not ask again from inside the app. Turn it back on in Settings → Notifications → todoapp; until then nothing this product sends will reach you.',
    actionable: false,
  },
};

export const INSTALL_ROWS: Record<InstallState, SettingRow> = {
  installed: {
    state: 'Installed',
    consequence: 'Launched from the home screen, which is the only way iOS delivers push at all.',
    actionable: false,
  },
  browser: {
    state: 'Running in a browser tab',
    consequence:
      'iOS delivers push only to an app opened from its home-screen icon. Add this to the home screen with Share → Add to Home Screen, then open it from the icon — a notification subscription made here silently receives nothing.',
    actionable: false,
  },
  // Before the display-mode check has run. Says what it is rather than guessing installed, because
  // guessing wrong in that direction hides the row that matters most.
  unknown: {
    state: 'Checking',
    consequence: 'Working out whether this was opened from the home screen or from a browser tab.',
    actionable: false,
  },
};

/**
 * How the morning hour reads back to the author.
 *
 * `07:00`, not `7`. The column is an integer and the question is a time of day; a bare number
 * beside the words "morning hour" is a quantity of something unnamed.
 */
export function hourLabel(hour: number): string {
  return `${String(hour).padStart(2, '0')}:00`;
}

/**
 * Whether an hour may be sent at all.
 *
 * The database refuses anything outside 0–23 through `profile_morning_hour_range`, and it stays
 * the authority. This exists so the form does not spend a round trip being told what a clock is —
 * never to clamp, because a silently clamped hour is a blocking question arriving at a time the
 * author did not choose.
 */
export function isSendableHour(hour: number): boolean {
  return Number.isInteger(hour) && hour >= 0 && hour <= 23;
}
