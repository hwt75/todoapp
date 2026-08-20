import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FocusSession } from './focus-session';
import { FOCUS_COPY, FOCUS_QUEUE_KEY, RUNNING_KEY } from '@/lib/focus-session';
import { QUEUE_KEY } from '@/lib/offline-queue';

/**
 * The surface that answers the one cadence Epic 2 could create and never measure.
 *
 * What is asserted here is the set of promises that would otherwise only be checkable by locking
 * a real phone: a session is still running when the screen comes back because nothing was running
 * to lose, the figure visibly moves, a stop sends two instants and no date, a stop without a
 * network keeps its minutes visible rather than appearing to lose them, and a refusal never
 * claims to have banked anything.
 *
 * **Which globals are faked, and why it matters.** `Date` is pinned so the elapsed figure is
 * exact and the day-boundary arithmetic does not depend on what time of day the suite runs.
 * `setInterval` and `clearInterval` are faked so the tick can be driven and counted — a suite
 * that only froze `Date` would never fire the timer, and every assertion about a *running*
 * figure would be a static snapshot. `setTimeout` is deliberately left real, which is what keeps
 * `userEvent` and `waitFor` behaving normally.
 */

/** 12:00 in Asia/Ho_Chi_Minh, comfortably inside one local day. */
const NOW = new Date('2026-08-20T05:00:00.000Z');
const TODAY = '2026-08-20';
const FIFTY_MINUTES_AGO = new Date('2026-08-20T04:10:00.000Z').toISOString();

const insert = vi.fn();
/** Every `.eq(column, value)` the screen filtered a read by, tagged with its table. */
const filters: string[][] = [];
let insertResult: { error: { code?: string; message: string } | null } = { error: null };
let bankedSeconds: number | null = null;
let bankedError: { message: string } | null = null;
let commitmentResult: { data: unknown; error: { message: string } | null } = {
  data: { daily_minutes_target: 180 },
  error: null,
};

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      const query = {
        select: () => query,
        // Recorded rather than ignored: without this the two `.eq` calls that scope the banked
        // read to this commitment and to today could both be deleted and every test would still
        // pass, while the screen quietly reported somebody else's minutes for the wrong day.
        eq: (column: string, value: unknown) => {
          filters.push([table, column, String(value)]);
          return query;
        },
        maybeSingle: () =>
          Promise.resolve(
            table === 'commitment'
              ? commitmentResult
              : bankedError
                ? { data: null, error: bankedError }
                : {
                    data: bankedSeconds === null ? null : { seconds: bankedSeconds },
                    error: null,
                  },
          ),
        insert: (payload: unknown) => {
          insert(table, payload);
          return Promise.resolve(insertResult);
        },
      };
      return query;
    },
  }),
}));

function view(onClose = vi.fn()) {
  return <FocusSession ownerId="u1" commitmentId="c1" name="Company work" onClose={onClose} />;
}

/** Puts a session on this device without going through the screen to do it. */
function alreadyRunning(startedAt = FIFTY_MINUTES_AGO, commitmentId = 'c1') {
  window.localStorage.setItem(
    RUNNING_KEY,
    JSON.stringify({ idempotencyKey: 'key-1', commitmentId, startedAt }),
  );
  return startedAt;
}

function queue() {
  return JSON.parse(window.localStorage.getItem(FOCUS_QUEUE_KEY) ?? '[]') as {
    idempotencyKey: string;
  }[];
}

/** Lets the mount effects' promises settle without waiting on a timer. */
async function settle() {
  await act(async () => {});
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'] });
  vi.setSystemTime(NOW);
  insert.mockReset();
  filters.length = 0;
  insertResult = { error: null };
  bankedSeconds = null;
  bankedError = null;
  commitmentResult = { data: { daily_minutes_target: 180 }, error: null };
  window.localStorage.clear();
});

afterEach(() => {
  vi.useRealTimers();
});

describe('starting', () => {
  it('offers one control, and the sentence that is the reason he presses it', async () => {
    render(view());

    // The suspicion that the app is watching is what stops him starting, and not starting is
    // the only real failure here — so the sentence is readable *before* the tap, not after.
    expect(await screen.findByText(FOCUS_COPY.unwatched)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: FOCUS_COPY.start })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: FOCUS_COPY.stop })).not.toBeInTheDocument();
  });

  it('records a start instant on this device and writes nothing anywhere else', async () => {
    render(view());
    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.start }));

    expect(screen.getByRole('timer')).toHaveAccessibleName('Running 0:00:00.');
    expect(JSON.parse(window.localStorage.getItem(RUNNING_KEY)!)).toMatchObject({
      commitmentId: 'c1',
      startedAt: NOW.toISOString(),
    });

    // A session is a fact recorded at stop. A row written at start would need an update policy
    // on an insert-only schema, and a start tapped offline could not be corrected by a stop
    // tapped offline — the queue would carry an amendment to a row that does not exist yet.
    expect(insert).not.toHaveBeenCalled();
  });

  it('is still running when the screen comes back, measured from the original instant', async () => {
    // The app killed, the phone locked, three hours in the background: all the same event,
    // because nothing was running to be stopped.
    alreadyRunning();
    render(view());

    expect(await screen.findByText('0:50:00')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: FOCUS_COPY.start })).not.toBeInTheDocument();
  });

  it('says so rather than doing nothing when another commitment is running', async () => {
    // A silent no-op here is the worst failure available on this screen: the author taps the one
    // control the surface exists for and nothing at all changes.
    alreadyRunning(FIFTY_MINUTES_AGO, 'c2');
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.start }));

    expect(screen.getByText(FOCUS_COPY.alreadyElsewhere)).toBeInTheDocument();
    // And the other commitment's session was not overwritten by the attempt.
    expect(JSON.parse(window.localStorage.getItem(RUNNING_KEY)!)).toMatchObject({
      commitmentId: 'c2',
    });
  });

  it('makes stop the only filled button on the screen', async () => {
    alreadyRunning();
    const { container } = render(view());
    await screen.findByRole('button', { name: FOCUS_COPY.stop });

    const filled = [...container.querySelectorAll('button.action')].map((b) => b.textContent);
    expect(filled).toEqual([FOCUS_COPY.stop]);
  });
});

describe('the figure runs', () => {
  it('moves once a second, because that is the whole claim of tapping start', async () => {
    alreadyRunning();
    render(view());
    await settle();

    expect(screen.getByText('0:50:00')).toBeInTheDocument();

    act(() => void vi.advanceTimersByTime(5000));

    expect(screen.getByText('0:50:05')).toBeInTheDocument();
    expect(screen.getByRole('timer')).toHaveAccessibleName('Running 0:50:05.');
  });

  it('runs no timer at all while nothing is running', async () => {
    render(view());
    await settle();

    // Nothing is being counted anywhere, so there is nothing to keep alive. A screen that ticked
    // while idle would be the first thing in this product doing work nobody asked for.
    expect(vi.getTimerCount()).toBe(0);
  });

  it('stops ticking when the screen goes away', async () => {
    alreadyRunning();
    const { unmount } = render(view());
    await settle();

    expect(vi.getTimerCount()).toBe(1);
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('moves onto the new day at midnight rather than reporting yesterday', async () => {
    // 23:50 local, fifty seconds of session left before the boundary. The figure keeps running —
    // nothing splits a session — but "Banked today" must stop meaning yesterday.
    vi.setSystemTime(new Date('2026-08-20T16:50:00.000Z'));
    alreadyRunning(new Date('2026-08-20T16:40:00.000Z').toISOString());
    render(view());
    await settle();

    expect(filters).toContainEqual(['focus_day_minutes', 'for_day', '2026-08-20']);

    act(() => void vi.advanceTimersByTime(11 * 60 * 1000));
    await settle();

    expect(filters).toContainEqual(['focus_day_minutes', 'for_day', '2026-08-21']);
    // And the session itself never stopped or reset.
    expect(screen.getByText('0:21:00')).toBeInTheDocument();
  });
});

describe('banking', () => {
  it('reads the day scoped to this commitment and to today', async () => {
    render(view());
    await screen.findByRole('button', { name: FOCUS_COPY.start });

    expect(filters).toContainEqual(['focus_day_minutes', 'commitment_id', 'c1']);
    expect(filters).toContainEqual(['focus_day_minutes', 'for_day', TODAY]);
    expect(filters).toContainEqual(['commitment', 'id', 'c1']);
  });

  it('sends both instants, the key from the start tap, and no date at all', async () => {
    alreadyRunning();
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    expect(insert).toHaveBeenCalledOnce();
    const [table, payload] = insert.mock.calls[0];
    expect(table).toBe('focus_session');
    expect(payload).toEqual({
      owner_id: 'u1',
      commitment_id: 'c1',
      // Minted at the start tap and reused by every retry (AD-4).
      idempotency_key: 'key-1',
      started_at: FIFTY_MINUTES_AGO,
      stopped_at: NOW.toISOString(),
    });
    // The day and the duration are the database's (AD-1, AD-6). Either one appearing in this
    // payload would be the client deciding which day the minutes landed on.
    expect(payload).not.toHaveProperty('for_day');
    expect(payload).not.toHaveProperty('duration_seconds');
  });

  it('clears the running record and goes back to offering a start', async () => {
    alreadyRunning();
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    expect(window.localStorage.getItem(RUNNING_KEY)).toBeNull();
    expect(await screen.findByRole('button', { name: FOCUS_COPY.start })).toBeInTheDocument();
  });

  it('states the day against the target, read from the view rather than counted here', async () => {
    bankedSeconds = 3000;
    render(view());

    // `0:50 of 3:00`, the reading EXPERIENCE.md § KF-2 specifies.
    expect(
      await screen.findByRole('group', { name: 'Banked today, 0:50 of 3:00' }),
    ).toBeInTheDocument();
  });

  it('shows two sessions summed and floored once, because that is what the view returns', async () => {
    // Three sittings of 20 minutes 20 seconds are 61 minutes. Flooring each session instead of
    // the day would show 60 and lose a minute of work that happened.
    bankedSeconds = 3660;
    render(view());

    expect(
      await screen.findByRole('group', { name: 'Banked today, 1:01 of 3:00' }),
    ).toBeInTheDocument();
  });
});

describe('without a network', () => {
  beforeEach(() => {
    // No SQLSTATE: the server never reached a decision, so this is worth retrying.
    insertResult = { error: { message: 'Failed to fetch' } };
    alreadyRunning();
  });

  it('keeps the session and says so, rather than losing it', async () => {
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    expect(await screen.findByText(FOCUS_COPY.queuedOffline)).toBeInTheDocument();
    expect(queue().map((q) => q.idempotencyKey)).toEqual(['key-1']);
  });

  it('keeps sessions in their own queue, never in the declaration one', async () => {
    // The one guard the defaulted key parameter needs: `enqueue` and `flush` both fall back to
    // the declaration queue, so a dropped argument would put sessions where the morning gate
    // reads answers — and the gate would flush them at a table that has no such columns.
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    expect(queue()).toHaveLength(1);
    expect(window.localStorage.getItem(QUEUE_KEY)).toBeNull();
  });

  it('does not lose time it has just told him was saved', async () => {
    // Fifty minutes are queued and none of them have reached `focus_day_minutes`. Showing
    // `0:00 of 3:00` immediately after saying the session was saved is the screen contradicting
    // itself, so the queued seconds are added and the sum floored once — the way the view
    // floors it. That number is displayed and never sent anywhere.
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    expect(
      await screen.findByRole('group', { name: 'Banked today, 0:50 of 3:00' }),
    ).toBeInTheDocument();
  });

  it('sends what is waiting as soon as the screen opens', async () => {
    // A queue that only drains when the author happens to stop another session on this same
    // screen is a queue that drains by coincidence.
    render(view());
    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));
    expect(queue()).toHaveLength(1);

    insert.mockReset();
    insertResult = { error: null };
    render(view());
    await settle();

    expect(insert).toHaveBeenCalledOnce();
    expect(queue()).toEqual([]);
  });

  it('sends what is waiting when the network comes back', async () => {
    render(view());
    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    insert.mockReset();
    insertResult = { error: null };
    await act(async () => {
      window.dispatchEvent(new Event('online'));
    });

    expect(insert).toHaveBeenCalledOnce();
    expect(queue()).toEqual([]);
  });

  it('replays under the original key, so the server can refuse the second', async () => {
    render(view());
    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));
    await screen.findByText(FOCUS_COPY.queuedOffline);

    // The connection comes back. The session waiting in the queue goes under the key it was
    // minted with — which is what lets the unique constraint, rather than the client, be the
    // thing that guarantees one row.
    insert.mockReset();
    insertResult = { error: null };
    await userEvent.click(screen.getByRole('button', { name: FOCUS_COPY.start }));
    await userEvent.click(screen.getByRole('button', { name: FOCUS_COPY.stop }));

    const keys = insert.mock.calls.map(
      ([, payload]) => (payload as { idempotency_key: string }).idempotency_key,
    );
    expect(keys.filter((k) => k === 'key-1')).toEqual(['key-1']);
    expect(queue()).toEqual([]);
  });

  it('treats a duplicate as delivered rather than retrying it forever', async () => {
    // A previous flush got through and its acknowledgement did not, so the row already exists.
    // The session is recorded — that is success, and keeping it queued would mean retrying
    // something that already worked until the end of time.
    insertResult = { error: { code: '23505', message: 'duplicate key value' } };
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    expect(queue()).toEqual([]);
    expect(screen.queryByText(FOCUS_COPY.notBanked)).not.toBeInTheDocument();
  });
});

describe('a refusal', () => {
  it('says what was refused and never claims to have banked it', async () => {
    // The trigger's two refusals — a commitment settled by his word, and one he does not own —
    // and the check constraint's. All permanent: retrying changes nothing, and telling him it
    // was saved would be a lie he has no way to check.
    insertResult = {
      error: {
        code: 'P0001',
        message: 'A focus session may only be banked against a Put hours in commitment.',
      },
    };
    alreadyRunning();
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    expect(await screen.findByText(FOCUS_COPY.notBanked)).toBeInTheDocument();
    expect(screen.getByText(/Put hours in commitment/)).toBeInTheDocument();
    // Nothing left waiting to be retried, and the day's total has not moved.
    expect(queue()).toEqual([]);
    expect(screen.getByRole('group', { name: 'Banked today, 0:00 of 3:00' })).toBeInTheDocument();
  });

  it('reports a refusal of something other than the session just stopped', async () => {
    // An older item the server will never accept is dropped from the queue either way. Dropping
    // it without a word is the queue quietly losing work while the screen looks fine.
    window.localStorage.setItem(
      FOCUS_QUEUE_KEY,
      JSON.stringify([
        {
          idempotencyKey: 'stale-key',
          ownerId: 'u1',
          commitmentId: 'c1',
          startedAt: '2026-08-19T02:00:00.000Z',
          stoppedAt: '2026-08-19T01:00:00.000Z',
        },
      ]),
    );
    insertResult = {
      error: { code: '23514', message: 'violates check constraint focus_session_stops_after…' },
    };

    render(view());
    await settle();

    expect(await screen.findByText(FOCUS_COPY.notBanked)).toBeInTheDocument();
    expect(screen.getByText(/focus_session_stops_after/)).toBeInTheDocument();
    expect(queue()).toEqual([]);
  });

  it('still offers stop when the day could not be read, so the work can be banked', async () => {
    // The frozen matrix row "Stopped with no network" requires exactly this: opening the screen
    // offline with a session running must not make it impossible to bank. A failed read costs a
    // number; a hidden stop control costs the session.
    bankedError = { message: 'Failed to fetch' };
    alreadyRunning();
    render(view());

    expect(await screen.findByRole('button', { name: FOCUS_COPY.stop })).toBeInTheDocument();
    expect(screen.getByRole('timer')).toHaveAccessibleName('Running 0:50:00.');
    expect(screen.getByText(FOCUS_COPY.stillRuns)).toBeInTheDocument();
    // The number it could not read is absent rather than invented as a zero.
    expect(screen.queryByRole('group', { name: /Banked today/ })).not.toBeInTheDocument();
  });

  it('refuses the screen outright for a row that cannot carry sessions', async () => {
    // Every `daily_hours_quota` commitment has a target by the biconditional check, so a missing
    // one never means "nothing banked yet" — it means this is not the surface for this row, and
    // a clock offered here is one whose every stop the database will refuse.
    commitmentResult = { data: { daily_minutes_target: null }, error: null };
    render(view());

    expect(await screen.findByText(FOCUS_COPY.notAnHoursQuota)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: FOCUS_COPY.start })).not.toBeInTheDocument();
    expect(screen.queryByRole('group', { name: /Banked today/ })).not.toBeInTheDocument();
  });

  it('says what failed rather than showing a total it never read', async () => {
    commitmentResult = { data: null, error: { message: 'permission denied' } };
    render(view());

    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByRole('group', { name: /Banked today/ })).not.toBeInTheDocument();
  });
});

describe('leaving', () => {
  it('goes back to today', async () => {
    const onClose = vi.fn();
    render(view(onClose));

    await userEvent.click(screen.getByRole('button', { name: 'Back to today' }));
    expect(onClose).toHaveBeenCalledOnce();
  });
});
