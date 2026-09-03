import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FocusSession } from './focus-session';
import { FOCUS_COPY, FOCUS_QUEUE_KEY, RUNNING_KEY } from '@/lib/focus-session';
import { QUEUE_KEY } from '@/lib/offline-queue';
import { EVIDENCE_COPY } from '@/lib/evidence';

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
/** Overrides `insertResult` for one specific `idempotency_key`, so a test can make two items in
 *  the same flush pass resolve differently — one accepted, one refused. */
let insertResultByKey: Record<string, { error: { code?: string; message: string } | null }> = {};
let bankedSeconds: number | null = null;
let bankedError: { message: string } | null = null;
let commitmentResult: { data: unknown; error: { message: string } | null } = {
  data: { daily_minutes_target: 180 },
  error: null,
};
/** Story 6.9: what the `evidence` read comes back with, and what each path signs to. */
let evidenceResult: unknown = { data: [], error: null };
let signedByPath: Record<string, unknown> = {};
const signCalls: Array<{ paths: string[]; ttl: number }> = [];

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
        // Story 6.9's evidence read filters `for_day` with `.in`, and it is recorded for the
        // same reason `.eq` is: a dropped day filter would show yesterday's record under
        // today's figure and no assertion here would notice.
        in: (column: string, value: unknown) => {
          filters.push([table, column, String(value)]);
          return query;
        },
        // Scoped to `evidence` on purpose. An unscoped `then` hands evidence rows to whatever
        // else is ever awaited without `.maybeSingle()`, which would make a read of the wrong
        // table look like it worked.
        then: (resolve: (value: unknown) => unknown) =>
          Promise.resolve(
            table === 'evidence'
              ? evidenceResult
              : { data: null, error: { message: `focus-session.test.tsx: unawaitable ${table}` } },
          ).then(resolve),
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
          const key = (payload as { idempotency_key: string }).idempotency_key;
          return Promise.resolve(insertResultByKey[key] ?? insertResult);
        },
      };
      return query;
    },
    storage: {
      from: () => ({
        createSignedUrls: (paths: string[], ttl: number) => {
          signCalls.push({ paths, ttl });
          return Promise.resolve({
            data: paths.map(
              (path) =>
                signedByPath[path] ?? {
                  path,
                  error: null,
                  signedUrl: `https://signed.test/${path}`,
                },
            ),
            error: null,
          });
        },
      }),
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
  insertResultByKey = {};
  bankedSeconds = null;
  bankedError = null;
  commitmentResult = { data: { daily_minutes_target: 180 }, error: null };
  evidenceResult = { data: [], error: null };
  signedByPath = {};
  signCalls.length = 0;
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

describe('the bar', () => {
  it('sits beside the banked total, reflecting the same fraction the text reads', async () => {
    bankedSeconds = 3000; // 50 of 180
    const { container } = render(view());
    await screen.findByRole('group', { name: 'Banked today, 0:50 of 3:00' });

    const fill = container.querySelector('.quota-bar-fill');
    expect(fill).toHaveStyle({ width: `${(50 / 180) * 100}%` });
  });

  it('caps visually at 100% when banked exceeds target, while the text keeps the true number', async () => {
    bankedSeconds = 200 * 60; // 200 of 180 — the matrix's own over-target row
    const { container } = render(view());
    await screen.findByRole('group', { name: 'Banked today, 3:20 of 3:00' });

    const fill = container.querySelector('.quota-bar-fill');
    expect(fill).toHaveStyle({ width: '100%' });
  });

  it('is hidden from assistive tech, since the row already announces the same number as text', async () => {
    bankedSeconds = 3000;
    const { container } = render(view());
    await screen.findByRole('group', { name: 'Banked today, 0:50 of 3:00' });

    expect(container.querySelector('.quota-bar')).toHaveAttribute('aria-hidden', 'true');
  });

  it('is absent when the total itself could not be read', async () => {
    bankedError = { message: 'Failed to fetch' };
    alreadyRunning();
    const { container } = render(view());
    await screen.findByText(FOCUS_COPY.stillRuns);

    expect(container.querySelector('.quota-bar')).toBeNull();
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

  it('does not claim the session just stopped failed when a different queued item was refused in the same pass', async () => {
    // A stale item from an unrelated earlier session is already sitting in the queue, and the
    // server will refuse it permanently — but the session about to be stopped here is a
    // different one, with its own key, and the server accepts it.
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
    insertResultByKey['stale-key'] = {
      error: { code: '23514', message: 'violates check constraint focus_session_stops_after…' },
    };
    // `insertResult` (the default every other key falls back to) stays a clean success — this
    // is what the just-stopped session's own insert receives.

    alreadyRunning();
    render(view());

    await userEvent.click(await screen.findByRole('button', { name: FOCUS_COPY.stop }));

    // The one flush pass processed both: the stale item was dropped as permanently refused, and
    // the session just stopped went through. Nothing here may say the current session failed —
    // that would be exactly the false "your work was not banked" this screen exists to prevent.
    expect(screen.queryByText(FOCUS_COPY.notBanked)).not.toBeInTheDocument();
    expect(await screen.findByRole('button', { name: FOCUS_COPY.start })).toBeInTheDocument();
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

/**
 * Story 6.9 — the photo, on the only screen this cadence opens.
 *
 * `commitments_owing()` excludes `daily_hours_quota`, so `chain_current` has nothing for one and
 * its Chains detail is empty by construction — Today routes the tap here instead. If the photo
 * were not here it would be nowhere at all for this kind of commitment.
 */
describe('the photo kept for the day on screen', () => {
  function filed(id: string, day: string, path: string) {
    return { id, commitment_id: 'c1', for_day: day, storage_path: path };
  }

  it('shows it, read for the day the screen reports on', async () => {
    evidenceResult = { data: [filed('e1', TODAY, 'c1/e1-proof.jpg')], error: null };
    render(view());

    const image = await screen.findByAltText(EVIDENCE_COPY.photoAlt(1, 1));
    expect(image).toHaveAttribute('src', 'https://signed.test/c1/e1-proof.jpg');
    expect(signCalls).toEqual([{ paths: ['c1/e1-proof.jpg'], ttl: 3600 }]);

    // This screen's own `day`, and no second clock: the same instant the figure is drawn from.
    expect(filters).toContainEqual(['evidence', 'commitment_id', String(['c1'])]);
    expect(filters).toContainEqual(['evidence', 'for_day', String([TODAY])]);
  });

  it('says nothing about photos when there are none', async () => {
    render(view());
    await settle();

    expect(screen.queryByRole('img')).not.toBeInTheDocument();
    expect(screen.queryByText(/could not be loaded/)).not.toBeInTheDocument();
  });

  it('counts a photo it could not sign rather than showing a shorter list', async () => {
    evidenceResult = {
      data: [filed('e1', TODAY, 'c1/e1-one.jpg'), filed('e2', TODAY, 'c1/e2-two.jpg')],
      error: null,
    };
    signedByPath = {
      'c1/e2-two.jpg': { path: 'c1/e2-two.jpg', error: 'Object not found', signedUrl: null },
    };

    render(view());

    expect(await screen.findByAltText(EVIDENCE_COPY.photoAlt(1, 1))).toBeInTheDocument();
    expect(screen.getAllByRole('img')).toHaveLength(1);
    expect(screen.getByText(EVIDENCE_COPY.photosFailed(1))).toBeInTheDocument();
  });

  it('counts a photo whose signed URL will not load', async () => {
    evidenceResult = { data: [filed('e1', TODAY, 'c1/e1-one.jpg')], error: null };
    render(view());

    const image = await screen.findByAltText(EVIDENCE_COPY.photoAlt(1, 1));
    // The screen this matters most on: a signed URL is good for an hour, and a session against
    // a three-hour target sits open far longer than that.
    await act(async () => {
      image.dispatchEvent(new Event('error'));
    });

    expect(screen.queryByRole('img')).not.toBeInTheDocument();
    expect(screen.getByText(EVIDENCE_COPY.photosFailed(1))).toBeInTheDocument();
  });

  it('takes yesterday’s note off the screen when the day turns over', async () => {
    // A running session, because that is what makes this screen's own clock tick and therefore
    // what moves `day` across local midnight — the same instant the figure is drawn from.
    alreadyRunning();
    evidenceResult = { data: null, error: { message: 'permission denied' } };
    render(view());
    expect(await screen.findByText(EVIDENCE_COPY.photosUnreadable)).toBeInTheDocument();

    // Midnight. The images are day-filtered and would have gone on their own, but a count and a
    // failure sentence carry no day of their own — left alone, yesterday's note sits over the
    // new day's figure.
    evidenceResult = { data: [], error: null };
    await act(async () => {
      vi.setSystemTime(new Date('2026-08-20T17:30:00.000Z'));
      vi.advanceTimersByTime(1000);
    });
    await settle();

    expect(screen.queryByText(EVIDENCE_COPY.photosUnreadable)).not.toBeInTheDocument();
  });

  it('keeps the clock when the photo read fails, and says why', async () => {
    evidenceResult = { data: null, error: { message: 'permission denied' } };
    render(view());

    // The clock outranks the screen here as everywhere else on it: a photo that cannot be read
    // costs him a record, and must never cost him the control that banks his work.
    expect(await screen.findByText(EVIDENCE_COPY.photosUnreadable)).toBeInTheDocument();
    expect(screen.getByText(/permission denied/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: FOCUS_COPY.start })).toBeInTheDocument();
  });
});
