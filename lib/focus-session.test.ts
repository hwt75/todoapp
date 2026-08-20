import { beforeEach, describe, expect, it } from 'vitest';
import {
  FOCUS_COPY,
  RUNNING_KEY,
  type QueuedFocusSession,
  type RunningSession,
  bankedAgainstTarget,
  bankedPercent,
  clearRunning,
  elapsedLabel,
  elapsedSeconds,
  formatDuration,
  formatElapsed,
  queuedSeconds,
  readRunning,
  shownMinutes,
  startSession,
} from './focus-session';

/**
 * The rules that make a session survive things nothing is running through.
 *
 * Every one of these would otherwise only be exercisable by locking a real phone, killing a
 * real app, or waiting until midnight — which is to say, never. They are here because the
 * whole point of the design is that a start instant plus a subtraction is enough, and this is
 * where that claim is checked.
 */

/** A Storage that behaves like the browser's without needing one. */
function fakeStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    clear: () => map.clear(),
    getItem: (k) => map.get(k) ?? null,
    key: (i) => [...map.keys()][i] ?? null,
    removeItem: (k) => void map.delete(k),
    setItem: (k, v) => void map.set(k, v),
  };
}

const STARTED_AT = '2026-08-20T02:20:00.000Z';

function session(overrides: Partial<RunningSession> = {}): RunningSession {
  return {
    idempotencyKey: 'key-1',
    commitmentId: 'commitment-1',
    startedAt: STARTED_AT,
    ...overrides,
  };
}

let storage: Storage;
beforeEach(() => {
  storage = fakeStorage();
});

describe('recording a start', () => {
  it('has nothing running until start is tapped', () => {
    expect(readRunning(storage)).toBeNull();
  });

  it('keeps the instant start was tapped, and nothing else', () => {
    expect(startSession(storage, session())).toEqual({ kind: 'started', session: session() });
    expect(readRunning(storage)).toEqual(session());
  });

  it('survives the app being killed, because nothing was running to kill', () => {
    startSession(storage, session());

    // A new page, a new process, a phone that was locked for three hours: all the same event.
    // The record is read back from storage and measured from its original instant.
    const reopened = readRunning(fromSameStorage(storage));
    expect(reopened?.startedAt).toBe(STARTED_AT);
  });

  it('does not restart the clock on a second tap', () => {
    startSession(storage, session());
    const again = startSession(storage, session({ idempotencyKey: 'key-2', startedAt: 'later' }));

    // The work began at the first instant. Keeping the second would quietly discard whatever
    // was done before the double tap, and he has no running process to tell him otherwise.
    expect(again).toEqual({ kind: 'already-running', session: session() });
    expect(readRunning(storage)?.startedAt).toBe(STARTED_AT);
  });

  it('refuses to start over another commitment, and says which it is', () => {
    // Not silently returning the foreign record: the screen would filter it out as not its own,
    // and the author would be left tapping a control that changes nothing on the one surface
    // whose entire job is making the tap feel like something happened.
    startSession(storage, session());
    const elsewhere = startSession(
      storage,
      session({ idempotencyKey: 'key-2', commitmentId: 'commitment-2' }),
    );

    expect(elsewhere).toEqual({ kind: 'running-elsewhere', session: session() });
    // And nothing was written over the session that is genuinely running.
    expect(readRunning(storage)).toEqual(session());
  });

  it('clears on stop', () => {
    startSession(storage, session());
    clearRunning(storage);
    expect(readRunning(storage)).toBeNull();
  });

  it('treats a corrupt record as nothing running rather than throwing at the surface', () => {
    storage.setItem(RUNNING_KEY, '{not json');
    expect(() => readRunning(storage)).not.toThrow();
    expect(readRunning(storage)).toBeNull();
  });

  it('refuses a record that cannot say when it started', () => {
    // Rendering `now − undefined` would put a figure on the screen with nothing behind it.
    storage.setItem(RUNNING_KEY, JSON.stringify({ idempotencyKey: 'k', commitmentId: 'c' }));
    expect(readRunning(storage)).toBeNull();
  });
});

describe('how long it has been going', () => {
  it('measures from the original instant, not from when the screen came back', () => {
    const now = new Date('2026-08-20T03:10:00.000Z');
    expect(elapsedSeconds(session(), now)).toBe(50 * 60);
  });

  it('does not stop at midnight, because there is nothing there to stop it', () => {
    // 23:50 to 00:20 in Asia/Ho_Chi_Minh — the boundary that decides which day the minutes
    // land on. Thirty minutes, one session, and the elapsed figure never resets.
    const across = session({ startedAt: '2026-08-20T16:50:00.000Z' });
    expect(elapsedSeconds(across, new Date('2026-08-20T17:20:00.000Z'))).toBe(30 * 60);
  });

  it('never counts backwards when the device clock jumps', () => {
    expect(elapsedSeconds(session(), new Date('2026-08-20T02:00:00.000Z'))).toBe(0);
  });
});

describe('how a duration reads', () => {
  it.each([
    [0, '0:00'],
    [50, '0:50'],
    [60, '1:00'],
    [180, '3:00'],
    [605, '10:05'],
  ])('%i minutes reads %s', (minutes, expected) => {
    expect(formatDuration(minutes)).toBe(expected);
  });

  it('shows seconds only on the figure that has to visibly run', () => {
    // `H:MM` would read 0:00 for a full minute after the tap, on the one screen whose whole
    // job is to make starting feel like something happened.
    expect(formatElapsed(0)).toBe('0:00:00');
    expect(formatElapsed(50 * 60 + 12)).toBe('0:50:12');
    expect(formatElapsed(36305)).toBe('10:05:05');
  });

  it('states the day against the quota', () => {
    expect(bankedAgainstTarget(50, 180)).toBe('0:50 of 3:00');
  });
});

describe("the bar's fraction", () => {
  it('reads the same ratio the text does', () => {
    expect(bankedPercent(50, 180)).toBeCloseTo((50 / 180) * 100);
  });

  it('caps at 100 when banked exceeds target, the same 200-of-180 the matrix names', () => {
    // The text still reads the true number — 3:20 of 3:00 — this is only the bar's own fill.
    expect(bankedPercent(200, 180)).toBe(100);
  });

  it('reads 100 exactly at the target, not a hair under from floating point', () => {
    expect(bankedPercent(180, 180)).toBe(100);
  });

  it('never goes negative', () => {
    expect(bankedPercent(-10, 180)).toBe(0);
  });

  it('renders an empty bar rather than dividing by zero for a target that cannot occur', () => {
    expect(bankedPercent(50, 0)).toBe(0);
  });
});

describe('what the screen may add of its own', () => {
  it('adds a queued session to the day so the screen does not lose time it was told about', () => {
    // Stopped without a network. The row has not reached `focus_day_minutes` yet, and dropping
    // it would mean telling him it was saved and then showing a total that says otherwise.
    expect(shownMinutes(1200, 1800)).toBe(50);
  });

  it('floors once, exactly as the day does', () => {
    // Three sittings of 20:20. Flooring each would bank 60 minutes of the 61 that were worked.
    expect(shownMinutes(0, 3 * 1220)).toBe(61);
    expect(shownMinutes(1220, 2 * 1220)).toBe(61);
  });

  it('measures a queued session from its own two instants', () => {
    const stopped: QueuedFocusSession = {
      idempotencyKey: 'key-1',
      ownerId: 'owner-1',
      commitmentId: 'commitment-1',
      startedAt: '2026-08-20T16:50:00.000Z',
      stoppedAt: '2026-08-20T17:20:00.000Z',
    };
    expect(queuedSeconds(stopped)).toBe(1800);
  });
});

describe('the copy', () => {
  it('says what EXPERIENCE.md says, including the sentence that makes him press start', () => {
    // The suspicion that the app is watching is the thing that stops him starting, and not
    // starting is the only real failure here.
    expect(FOCUS_COPY.unwatched).toBe(
      "Keeps running while your phone is locked. Nothing here watches what you're doing.",
    );
    expect(FOCUS_COPY.stop).toBe('Stop and bank it');
    expect(FOCUS_COPY.start).toBe('Start the clock');
    expect(FOCUS_COPY.banked).toBe('Banked today');
    expect(FOCUS_COPY.alreadyElsewhere).toBe(
      'A clock is already running on another commitment. Stop that one first.',
    );
  });

  it('keeps every sentence the screen can say out of the component', () => {
    // Including the ones it only says when something is wrong. A raw `String(error)` on this
    // screen is a stack trace shown to somebody already reluctant to open it, and a sentence
    // written in JSX is a copy rule nothing can test.
    for (const [name, sentence] of Object.entries(FOCUS_COPY)) {
      expect(typeof sentence, `${name} must be a string`).toBe('string');
      expect(sentence.trim(), `${name} must not be blank`).not.toBe('');
    }
  });

  it('names the running figure rather than leaving a bare number to be read out', () => {
    expect(elapsedLabel(50 * 60 + 12)).toBe('Running 0:50:12.');
  });
});

/** The same bytes, read by something that was not there when they were written. */
function fromSameStorage(original: Storage): Storage {
  const copy = fakeStorage();
  for (let i = 0; i < original.length; i += 1) {
    const key = original.key(i);
    if (key) copy.setItem(key, original.getItem(key)!);
  }
  return copy;
}
