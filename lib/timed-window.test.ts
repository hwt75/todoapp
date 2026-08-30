import { describe, expect, it } from 'vitest';
import {
  secondsOfDay,
  timedWindowFamily,
  timedWindowLabel,
  timedWindowOverride,
  timedWindowSpoken,
  timedWindowState,
  windowOpensAt,
  windowShutsAt,
  type TimedWindowPosition,
} from './timed-window';

/**
 * `Asia/Ho_Chi_Minh` is UTC+7 with no daylight saving, so every instant here is written as the
 * UTC one seven hours earlier — deliberately, rather than constructing a local Date and hoping
 * the machine running the tests agrees about its own zone. That is the whole reason the clock
 * read goes through `Intl` with an explicit `timeZone` (AD-6).
 */
function at(local: string): Date {
  const [h, m, s] = local.split(':').map(Number);
  return new Date(Date.UTC(2026, 7, 30, h - 7, m, s));
}

const unclaimed: TimedWindowPosition = {
  dueTime: '20:30:00',
  lateWindowMinutes: 30,
  claimed: false,
  proven: false,
};

describe('secondsOfDay', () => {
  it('reads the wall clock in Ho Chi Minh City, not the device zone', () => {
    expect(secondsOfDay(at('20:30:00'))).toBe(20 * 3600 + 30 * 60);
  });

  it('reads midnight as zero rather than 24 hours', () => {
    expect(secondsOfDay(at('00:00:00'))).toBe(0);
  });
});

describe('timedWindowState', () => {
  it('is ahead before the hour arrives', () => {
    expect(timedWindowState(unclaimed, at('08:00:00'))).toBe('ahead');
  });

  it('opens on the instant the window opens, not a second later', () => {
    expect(timedWindowState(unclaimed, at('20:29:59'))).toBe('ahead');
    expect(timedWindowState(unclaimed, at('20:30:00'))).toBe('open');
  });

  it('shuts on the instant the window shuts, not a second later', () => {
    expect(timedWindowState(unclaimed, at('20:59:59'))).toBe('open');
    expect(timedWindowState(unclaimed, at('21:00:00'))).toBe('shut');
  });

  it('stays shut for the rest of the day', () => {
    expect(timedWindowState(unclaimed, at('23:59:59'))).toBe('shut');
  });

  // What happened outranks the clock, in both directions — the two rules a state machine driven
  // by time alone would get wrong.
  it('reads claimed long after the window has shut, because the photo can still land', () => {
    expect(timedWindowState({ ...unclaimed, claimed: true }, at('23:00:00'))).toBe('claimed');
  });

  it('reads proven for the rest of the day rather than reverting to shut', () => {
    const proven = { ...unclaimed, claimed: true, proven: true };
    expect(timedWindowState(proven, at('20:35:00'))).toBe('proven');
    expect(timedWindowState(proven, at('23:59:00'))).toBe('proven');
  });

  it('honours a window that runs to the maximum without wrapping past midnight', () => {
    const long = { ...unclaimed, dueTime: '19:00:00', lateWindowMinutes: 240 };
    expect(timedWindowState(long, at('22:59:00'))).toBe('open');
    expect(timedWindowState(long, at('23:00:00'))).toBe('shut');
  });

  it('accepts an HH:MM time as well as the HH:MM:SS Postgres renders', () => {
    expect(timedWindowState({ ...unclaimed, dueTime: '20:30' }, at('20:31:00'))).toBe('open');
  });
});

describe('how each state reads', () => {
  it('shows the hour itself while the window is ahead', () => {
    expect(timedWindowLabel(unclaimed, 'ahead')).toBe('20:30');
    expect(timedWindowSpoken(unclaimed, 'ahead')).toBe('window opens at 20:30');
    expect(timedWindowFamily(unclaimed, 'ahead')).toBe('neutral');
  });

  it('names the closing time while the window is open', () => {
    expect(timedWindowLabel(unclaimed, 'open')).toBe('Open now');
    expect(timedWindowSpoken(unclaimed, 'open')).toBe('window open now, until 21:00');
    expect(timedWindowFamily(unclaimed, 'open')).toBe('urgent');
  });

  it('says the photo is what is still owed, and stays urgent rather than failed', () => {
    expect(timedWindowLabel(unclaimed, 'claimed')).toBe('Photo due');
    expect(timedWindowSpoken(unclaimed, 'claimed')).toBe('claimed, photo still needed by midnight');
    expect(timedWindowFamily(unclaimed, 'claimed')).toBe('urgent');
  });

  it('is the only state that earns the held family', () => {
    expect(timedWindowLabel(unclaimed, 'proven')).toBe('Proven');
    expect(timedWindowSpoken(unclaimed, 'proven')).toBe('claimed and proven');
    expect(timedWindowFamily(unclaimed, 'proven')).toBe('held');
  });

  // FR-10: nothing announces mid-day that the day is already lost. "nothing claimed" is a fact
  // about the window; "missed" would be a verdict, and settlement is the only thing that files one.
  it('says nothing claimed rather than missed once the window has shut', () => {
    expect(timedWindowLabel(unclaimed, 'shut')).toBe('Shut');
    expect(timedWindowSpoken(unclaimed, 'shut')).toBe('window shut, nothing claimed');
    expect(timedWindowFamily(unclaimed, 'shut')).toBe('failed');
  });

  it('reads shut audibly differently from ahead — CAP-7 in one assertion', () => {
    expect(timedWindowSpoken(unclaimed, 'shut')).not.toBe(timedWindowSpoken(unclaimed, 'ahead'));
    expect(timedWindowFamily(unclaimed, 'shut')).not.toBe(timedWindowFamily(unclaimed, 'ahead'));
  });

  it('folds family and label into one override', () => {
    expect(timedWindowOverride(unclaimed, 'shut')).toEqual({ family: 'failed', label: 'Shut' });
  });
});

describe('the window boundaries as clock times', () => {
  it('reports both ends', () => {
    expect(windowOpensAt(unclaimed)).toBe('20:30');
    expect(windowShutsAt(unclaimed)).toBe('21:00');
  });

  it('pads a single-digit hour', () => {
    expect(windowOpensAt({ ...unclaimed, dueTime: '07:05:00' })).toBe('07:05');
    expect(windowShutsAt({ ...unclaimed, dueTime: '07:05:00', lateWindowMinutes: 5 })).toBe(
      '07:10',
    );
  });
});
