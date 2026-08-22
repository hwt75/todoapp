import { describe, expect, it } from 'vitest';
import {
  INSTALL_ROWS,
  PERMISSION_ROWS,
  hourLabel,
  isSendableHour,
  type PermissionState,
} from './settings';
import type { InstallState } from './install-state';

describe('what a switch the app cannot flip says', () => {
  it('gives every state a sentence, so none of them renders as an enum', () => {
    // A row reading `denied` is a row that sent the author to a search engine.
    for (const row of [...Object.values(PERMISSION_ROWS), ...Object.values(INSTALL_ROWS)]) {
      expect(row.state.trim()).not.toBe('');
      expect(row.consequence.trim().length).toBeGreaterThan(20);
    }
  });

  it('covers exactly the answers a browser can give', () => {
    const states: PermissionState[] = ['default', 'granted', 'denied'];
    expect(Object.keys(PERMISSION_ROWS).sort()).toEqual([...states].sort());
  });

  it('covers exactly the install states the resolver can produce', () => {
    const states: InstallState[] = ['unknown', 'installed', 'browser'];
    expect(Object.keys(INSTALL_ROWS).sort()).toEqual([...states].sort());
  });

  it('offers a control only where tapping one would change the answer', () => {
    // iOS prompts once. After that every call returns the standing answer, so a button on
    // `granted` or `denied` is a lie with a tap target.
    expect(PERMISSION_ROWS.default.actionable).toBe(true);
    expect(PERMISSION_ROWS.granted.actionable).toBe(false);
    expect(PERMISSION_ROWS.denied.actionable).toBe(false);

    // The app cannot install or uninstall itself under any of the three.
    for (const row of Object.values(INSTALL_ROWS)) {
      expect(row.actionable).toBe(false);
    }
  });

  it('names where the real switch is when the app no longer has one', () => {
    expect(PERMISSION_ROWS.denied.consequence).toMatch(/Settings/);
    expect(INSTALL_ROWS.browser.consequence).toMatch(/Add to Home Screen/);
  });

  it('says what does not arrive, rather than only that something is off', () => {
    // "Notifications are disabled" is a status. "Nothing reaches you until this is on — no
    // morning question, no evening summary" is the reason to care.
    expect(PERMISSION_ROWS.default.consequence).toMatch(/morning question/);
    expect(PERMISSION_ROWS.default.consequence).toMatch(/summary/);
  });

  it('does not guess installed before the check has run', () => {
    // Guessing wrong in that direction hides the row that matters most: without home-screen
    // installation there is no push at all, and without push there is no product.
    expect(INSTALL_ROWS.unknown.state).not.toMatch(/Installed/);
  });
});

describe('the morning hour', () => {
  it('reads as a time of day rather than a number', () => {
    expect(hourLabel(7)).toBe('07:00');
    expect(hourLabel(19)).toBe('19:00');
    expect(hourLabel(0)).toBe('00:00');
  });

  it('accepts every hour a clock has, and nothing else', () => {
    expect(isSendableHour(0)).toBe(true);
    expect(isSendableHour(23)).toBe(true);
    expect(isSendableHour(24)).toBe(false);
    expect(isSendableHour(-1)).toBe(false);
  });

  it('refuses anything that is not a whole hour', () => {
    // `smallint` would truncate 7.5 to 7 without complaint, and the author would have asked
    // for half past and been given the hour.
    expect(isSendableHour(7.5)).toBe(false);
    expect(isSendableHour(Number.NaN)).toBe(false);
  });
});
