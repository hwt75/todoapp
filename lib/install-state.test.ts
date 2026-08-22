import { describe, expect, it, vi } from 'vitest';
import { readInstallSignals, resolveInstallState } from './install-state';

describe('resolveInstallState', () => {
  it('reports browser when neither signal is present', () => {
    expect(resolveInstallState({ displayModeInstalled: false, iosLegacyStandalone: false })).toBe(
      'browser',
    );
  });

  it('reports installed on the standard display-mode signal', () => {
    expect(resolveInstallState({ displayModeInstalled: true, iosLegacyStandalone: false })).toBe(
      'installed',
    );
  });

  it('reports installed on the legacy iOS signal alone', () => {
    // Older iOS home-screen launches set navigator.standalone without matching
    // the display-mode query. Missing this reads as "not installed" on a device
    // that is installed, and the install message would nag forever.
    expect(resolveInstallState({ displayModeInstalled: false, iosLegacyStandalone: true })).toBe(
      'installed',
    );
  });

  it('reports installed when both signals agree', () => {
    expect(resolveInstallState({ displayModeInstalled: true, iosLegacyStandalone: true })).toBe(
      'installed',
    );
  });
});

describe('readInstallSignals', () => {
  function stubMatchMedia(installedModes: string[]) {
    vi.stubGlobal(
      'matchMedia',
      vi.fn((query: string) => ({
        matches: installedModes.some((mode) => query.includes(mode)),
        media: query,
      })),
    );
  }

  it('detects standalone', () => {
    stubMatchMedia(['standalone']);
    expect(readInstallSignals().displayModeInstalled).toBe(true);
    vi.unstubAllGlobals();
  });

  it('detects fullscreen and minimal-ui as installed too', () => {
    // A later manifest change to either mode must not reclassify an installed
    // user as a browser visitor.
    for (const mode of ['fullscreen', 'minimal-ui']) {
      stubMatchMedia([mode]);
      expect(readInstallSignals().displayModeInstalled, mode).toBe(true);
      vi.unstubAllGlobals();
    }
  });

  it('reports not-installed for an ordinary browser tab', () => {
    stubMatchMedia([]);
    expect(readInstallSignals().displayModeInstalled).toBe(false);
    vi.unstubAllGlobals();
  });

  it('survives a browser with no matchMedia rather than throwing', () => {
    // A throw here would freeze the page at 'unknown', which used to render no
    // guidance at all — the one thing this screen exists to say.
    vi.stubGlobal('matchMedia', undefined);
    expect(() => readInstallSignals()).not.toThrow();
    expect(readInstallSignals().displayModeInstalled).toBe(false);
    vi.unstubAllGlobals();
  });
});
