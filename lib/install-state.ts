/**
 * Whether the app is running as an installed home-screen app or as a browser tab.
 *
 * This matters more than it looks: on iOS, notifications are delivered only to an
 * app launched from its home-screen icon. Opening the same URL in a tab produces
 * failures that look like broken code rather than a wrong launch, so the rule is
 * kept here as a pure function — testable without a device, and in one place.
 */

export type InstallState = 'unknown' | 'installed' | 'browser';

/**
 * Every display mode that means "launched as an app". A manifest change to
 * fullscreen or minimal-ui must not silently reclassify an installed user as a
 * browser visitor and nag them forever.
 */
const INSTALLED_DISPLAY_MODES = ['standalone', 'fullscreen', 'minimal-ui'] as const;

export interface InstallSignals {
  /** True when any installed display mode matches — the standard signal. */
  displayModeInstalled: boolean;
  /** `navigator.standalone` — legacy iOS Safari, still set on home-screen launches. */
  iosLegacyStandalone: boolean;
}

export function resolveInstallState(signals: InstallSignals): InstallState {
  return signals.displayModeInstalled || signals.iosLegacyStandalone ? 'installed' : 'browser';
}

/**
 * Reads the signals from the live browser. Never call during render or on the server.
 *
 * Reads from `globalThis` rather than `window` — identical in a browser, but it
 * keeps the function callable and testable without a DOM implementation.
 *
 * Defensive about `matchMedia`: some embedded WebViews omit it, and a throw here
 * would leave the state stuck at 'unknown', which renders no guidance at all.
 */
export function readInstallSignals(): InstallSignals {
  const g = globalThis as typeof globalThis & {
    matchMedia?: (query: string) => { matches: boolean };
    navigator?: { standalone?: boolean };
  };

  return {
    displayModeInstalled:
      typeof g.matchMedia === 'function' &&
      INSTALLED_DISPLAY_MODES.some((mode) => g.matchMedia!(`(display-mode: ${mode})`).matches),
    iosLegacyStandalone: g.navigator?.standalone === true,
  };
}
