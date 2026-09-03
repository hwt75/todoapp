import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Today } from './today';

/**
 * The screen the author opens under reluctance — and the one rule on it that no unit test and no
 * screenshot can see.
 *
 * The debt figure is drawn last in the DOM and put on top with CSS `order`, because a sighted
 * reader can look past a number and a VoiceOver user cannot skip what is read to them. Being told
 * your own debt first thing every morning is a cost this product does not need to add. A later
 * refactor that "tidies" the JSX by moving the block above the rows would break that silently and
 * look correct in the browser, so the order is asserted here rather than trusted to a comment.
 *
 * The two reads that go through views are asserted by name for the same reason as in
 * `chains-detail.test.tsx`: `penalty_current` rather than `penalty` is what stops a superseded
 * day from charging him twice, and it is one word.
 */

const rows: Record<string, unknown> = {};
const seen: string[] = [];
// One entry per `.from()` call, carrying every column that call's own `.eq()` chain named —
// distinct from a flat `{table, column}` list, because Story 5.1 reads `penalty_current`
// twice for two different purposes (the aggregate figure, unfiltered by kind; a day-only,
// state=owed read for Grace Day eligibility), and only a per-call record can still tell
// "the unfiltered one" apart from "the filtered one" sharing the same table name.
// `select` carries the column *string* alongside them (Story 6.8). Without it, deleting a
// column from a SELECT is invisible here: the mock ignores the string and every fixture supplies
// the field anyway, so the feature switches off in production with the suite still green.
const fromCalls: Array<{ table: string; columns: string[]; select?: string }> = [];
const inserted: Array<{ table: string; payload: unknown }> = [];
// What a `grace_day` insert comes back with (Story 5.1). Set per test; the default is a
// clean success — most tests here have nothing to do with spending one at all.
let graceInsertResult: unknown = { error: null };
// Story 6.3: what `supabase.storage.from(...).upload(...)` comes back with. Default clean.
let uploadResult: unknown = { error: null };
const uploaded: Array<{ bucket: string; path: string }> = [];

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    storage: {
      from: (bucket: string) => ({
        upload: (path: string) => {
          uploaded.push({ bucket, path });
          return Promise.resolve(uploadResult);
        },
      }),
    },
    from: (table: string) => {
      seen.push(table);
      let key = table;
      const call: (typeof fromCalls)[number] = { table, columns: [] };
      fromCalls.push(call);
      const result = () => rows[key] ?? { data: [], error: null };
      const query = {
        select: (columns?: string) => {
          if (typeof columns === 'string') call.select = columns;
          return query;
        },
        is: () => query,
        eq: (column: string, value: string) => {
          call.columns.push(column);
          if (column === 'kind') key = `${table}:${value}`;
          return query;
        },
        order: () => Promise.resolve(result()),
        maybeSingle: () => Promise.resolve(result()),
        insert: (payload: unknown) => {
          inserted.push({ table, payload });
          return Promise.resolve(graceInsertResult);
        },
        then: (resolve: (value: unknown) => unknown) => Promise.resolve(result()).then(resolve),
      };
      return query;
    },
  }),
}));

const gym = {
  id: 'c1',
  name: 'Gym',
  cadence: 'daily',
  carries_penalty: true,
  weekly_target: null,
  daily_minutes_target: null,
};

beforeEach(() => {
  seen.length = 0;
  fromCalls.length = 0;
  inserted.length = 0;
  graceInsertResult = { error: null };
  uploadResult = { error: null };
  uploaded.length = 0;
  for (const key of Object.keys(rows)) delete rows[key];
  rows.commitment = { data: [gym], error: null };
  rows.penalty_current = { data: [], error: null };
  rows.chain_current = { data: [], error: null };
  rows.weekly_quota_progress = { data: [], error: null };
  // Story 5.1 sane defaults so every pre-existing test here keeps rendering exactly as
  // before: nothing graceable, and an allowance that never disables the control by surprise.
  rows['settlement_current:day'] = { data: [], error: null };
  rows['penalty_current:day'] = { data: [], error: null };
  rows.grace_allowance_remaining = { data: { remaining: 2 }, error: null };
});

describe('the today screen', () => {
  it('reads the money and the chains through the views that follow a correction', async () => {
    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByRole('button', { name: /Gym/ });

    // `penalty_current`, never `penalty`: a penalty attached to a superseded verdict is
    // history rather than debt, and reading the base table would charge him for a day he
    // took back. Same for the chain, which is derived in exactly one place.
    expect(seen).toContain('penalty_current');
    expect(seen).toContain('chain_current');
    // And the live weekly-quota position (spec 3-3), the same discipline: one source, never
    // a client-side tally of raw declaration rows.
    expect(seen).toContain('weekly_quota_progress');
    expect(seen).not.toContain('penalty');
    expect(seen).not.toContain('settlement_commitment');
    expect(seen).not.toContain('declaration');
  });

  it('announces the commitments before the debt, whatever the layout shows', async () => {
    rows.penalty_current = { data: [{ amount_dong: 500000 }], error: null };

    const { container } = render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByRole('button', { name: /Gym/ });

    const order = [...container.querySelectorAll('.today-rows, .debt-block')].map(
      (el) => (el as HTMLElement).className,
    );
    // Rows first in the DOM, figure second. CSS puts the figure on top; a screen reader
    // follows this order and hears what he undertook before what it has cost him.
    expect(order).toEqual(['today-rows', 'debt-block']);
  });

  it('says nothing at all when nothing is owed', async () => {
    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByRole('button', { name: /Gym/ });

    // A large `0` in failed-tint is a decoration that says nothing and charges him the
    // reluctance of opening a screen with a red area on it.
    expect(screen.queryByText(/Owed/)).not.toBeInTheDocument();
  });

  it('states the debt as one fact, and opens the ledger from it', async () => {
    rows.penalty_current = {
      data: [{ amount_dong: 500000 }, { amount_dong: 500000 }],
      error: null,
    };
    const onOpenLedger = vi.fn();

    render(
      <Today
        ownerId="u1"
        onOpenLedger={onOpenLedger}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
      />,
    );

    const debt = await screen.findByRole('button', { name: /Owed since you started/ });
    // One label rather than three fragments, and the total is a sum of what still stands.
    expect(debt).toHaveAccessibleName('Owed since you started: 1.000.000₫. Opens the ledger.');

    await userEvent.click(debt);
    expect(onOpenLedger).toHaveBeenCalledOnce();
  });

  it("counts a week's own penalty toward what is owed, same as a day's (3.4)", async () => {
    // `penalty_current` carries both `kind = 'day'` and `kind = 'week'` rows since Story
    // 3.4, and this screen's read is deliberately unfiltered by kind — a Failed Week costs
    // the same real money as a Failed Day, and "what is owed" is one number, not two. The
    // read itself is asserted to carry no `kind` filter, since that is the one line a later
    // "consistency" edit (mirroring the Ledger's own `.eq('kind', 'day')`) could add and
    // silently drop week debt from this screen while the Ledger still shows it.
    rows.penalty_current = { data: [{ amount_dong: 500000 }], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    await screen.findByRole('button', { name: /Owed since you started/ });
    // Two `penalty_current` reads exist since Story 5.1 (the other one is day-only, for
    // Grace Day eligibility) — this call is identified as the aggregate one specifically by
    // carrying no `kind` filter at all, distinct from the other by its own column list.
    expect(
      fromCalls.some((c) => c.table === 'penalty_current' && !c.columns.includes('kind')),
    ).toBe(true);
  });

  it('never claims a verdict for a day that has not ended', async () => {
    rows.chain_current = { data: [{ commitment_id: 'c1', current_days: 4 }], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    // FR-10 forbids a mid-day verdict, so every row is honestly `not yet` — and the chain
    // beside it is yesterday's number, which is a different claim and an allowed one.
    expect(await screen.findByRole('button', { name: /Gym/ })).toHaveAccessibleName(
      'Gym, not yet done today, holding 4 days, missing this costs money',
    );
  });

  it('merges a weekly quota row into the commitment it belongs to, by commitment_id', async () => {
    const weeklyGym = {
      id: 'c1',
      name: 'Gym',
      cadence: 'weekly_quota',
      carries_penalty: false,
      weekly_target: 3,
      daily_minutes_target: null,
    };
    rows.commitment = { data: [weeklyGym], error: null };
    rows.weekly_quota_progress = {
      data: [{ commitment_id: 'c1', held: 1, target: 3, days_remaining: 3 }],
      error: null,
    };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    // The pill reads the live position, and the row's one accessibility label states the same
    // thing aloud rather than falling back to "not yet done today" beside it.
    expect(await screen.findByText('1/3 · 3 days')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Gym/ })).toHaveAccessibleName(
      'Gym, 1 of 3 this week, 3 days left',
    );
  });

  it('keys a weekly quota row correctly when a non-quota row shares the render', async () => {
    // The realistic shape: most accounts have a mix of cadences on Today at once. This is the
    // only case that can expose a wrong key in `Object.fromEntries(quotas...)` — a single-row
    // fixture can accidentally pass even with the wrong commitment_id, or with `quotas` merged
    // by array position rather than by id.
    const weeklyGym = {
      id: 'c1',
      name: 'Gym',
      cadence: 'weekly_quota',
      carries_penalty: false,
      weekly_target: 3,
      daily_minutes_target: null,
    };
    const dailyReading = {
      id: 'c2',
      name: 'Reading',
      cadence: 'daily',
      carries_penalty: false,
      weekly_target: null,
      daily_minutes_target: null,
    };
    rows.commitment = { data: [weeklyGym, dailyReading], error: null };
    rows.weekly_quota_progress = {
      data: [{ commitment_id: 'c1', held: 1, target: 3, days_remaining: 3 }],
      error: null,
    };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    // The weekly row reads its own position, by its own id.
    expect(await screen.findByText('1/3 · 3 days')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Gym/ })).toHaveAccessibleName(
      'Gym, 1 of 3 this week, 3 days left',
    );

    // The daily row, which `weekly_quota_progress` has no row for at all, must keep its
    // ordinary state-derived rendering rather than inheriting Gym's position or going blank.
    expect(screen.getByRole('button', { name: /Reading/ })).toHaveAccessibleName(
      'Reading, not yet done today',
    );
    // Exactly one quota pill on screen — the merge did not fan the one quota row out to both
    // commitments.
    expect(screen.getAllByText('1/3 · 3 days')).toHaveLength(1);
  });

  it('leaves a commitment with no weekly-quota row exactly as before', async () => {
    // `gym` here is a Daily commitment, so `weekly_quota_progress` has nothing for it — the
    // merge must not invent a position for a commitment the view was never asked about.
    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(await screen.findByRole('button', { name: /Gym/ })).toHaveAccessibleName(
      'Gym, not yet done today, missing this costs money',
    );
  });

  it('opens a chain with the commitment the row was drawn from', async () => {
    const onOpenChain = vi.fn();
    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={onOpenChain} onOpenFocus={vi.fn()} />,
    );

    await userEvent.click(await screen.findByRole('button', { name: /Gym/ }));

    expect(onOpenChain).toHaveBeenCalledExactlyOnceWith(gym);
  });

  it('sends an hours-quota row to the timer, because it has no chain to open', async () => {
    // `commitments_owing()` excludes this cadence, so it never reaches `settlement_commitment`
    // and `chain_current` has nothing for it — its Chains detail is empty by construction. The
    // fork is here rather than in the row so `commitment-row.tsx` stays a component that opens
    // a thing rather than one that knows which thing.
    const hours = {
      id: 'c2',
      name: 'Company work',
      cadence: 'daily_hours_quota',
      carries_penalty: false,
      weekly_target: null,
      daily_minutes_target: 180,
    };
    rows.commitment = { data: [gym, hours], error: null };
    const onOpenChain = vi.fn();
    const onOpenFocus = vi.fn();

    render(
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={onOpenChain}
        onOpenFocus={onOpenFocus}
      />,
    );

    await userEvent.click(await screen.findByRole('button', { name: /Company work/ }));
    expect(onOpenFocus).toHaveBeenCalledExactlyOnceWith(hours);
    expect(onOpenChain).not.toHaveBeenCalled();

    // And every other cadence still goes where it always did.
    await userEvent.click(screen.getByRole('button', { name: /Gym/ }));
    expect(onOpenChain).toHaveBeenCalledExactlyOnceWith(gym);
    expect(onOpenFocus).toHaveBeenCalledOnce();
  });

  // Settings used to be a full-size bordered button standing alone under this screen's
  // heading — the most prominent object on the one screen whose subject is supposed to be
  // prominent instead. It moved to the tab bar (`components/tabbar.tsx`), which
  // `app/page.tsx` renders outside this component, and which therefore keeps the property
  // the button was placed here for: Settings stays reachable when every read below fails.
  it('offers no navigation of its own — the tab bar owns it', async () => {
    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    await screen.findByRole('button', { name: /Gym/ });
    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();
  });

  it('tells an empty setup apart from a broken read', async () => {
    rows.commitment = { data: [], error: null };
    const { unmount } = render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    expect(await screen.findByText(/Nothing set up yet/)).toBeInTheDocument();
    unmount();

    rows.commitment = { data: null, error: { message: 'permission denied' } };
    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByText(/Nothing set up yet/)).not.toBeInTheDocument();
  });

  it('surfaces a failed penalties, chains, quotas, or Grace Days read instead of rendering as if nothing were owed or held', async () => {
    for (const table of [
      'penalty_current',
      'chain_current',
      'weekly_quota_progress',
      'settlement_current:day',
      'penalty_current:day',
      'grace_allowance_remaining',
    ]) {
      rows.commitment = { data: [gym], error: null };
      rows.penalty_current = { data: [], error: null };
      rows.chain_current = { data: [], error: null };
      rows.weekly_quota_progress = { data: [], error: null };
      rows['settlement_current:day'] = { data: [], error: null };
      rows['penalty_current:day'] = { data: [], error: null };
      rows.grace_allowance_remaining = { data: { remaining: 2 }, error: null };
      rows[table] = { data: null, error: { message: `${table} unreadable` } };

      const { unmount } = render(
        <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
      );

      expect(await screen.findByText(new RegExp(`${table} unreadable`))).toBeInTheDocument();
      unmount();
    }
  });

  describe('Grace Day, on the Day summary (Story 5.1)', () => {
    it('offers the control on a Failed, owed day and always states how many remain', async () => {
      rows['settlement_current:day'] = {
        data: [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
        error: null,
      };
      rows['penalty_current:day'] = {
        data: [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
        error: null,
      };
      rows.grace_allowance_remaining = { data: { remaining: 2 }, error: null };

      render(
        <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
      );

      expect(await screen.findByRole('button', { name: /Spend a Grace Day/ })).toBeInTheDocument();
      expect(screen.getByText('2 Grace Days remaining this month.')).toBeInTheDocument();
    });

    it('filters to verdict = failed server-side, rather than pulling the account’s entire day-kind settlement history', async () => {
      rows['settlement_current:day'] = {
        data: [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
        error: null,
      };
      rows['penalty_current:day'] = {
        data: [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
        error: null,
      };

      render(
        <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
      );
      await screen.findByRole('button', { name: /Spend a Grace Day/ });

      const settlementCall = fromCalls.find(
        (c) => c.table === 'settlement_current' && c.columns.includes('verdict'),
      );
      expect(settlementCall).toBeDefined();
      expect(settlementCall?.columns).toEqual(expect.arrayContaining(['kind', 'verdict']));
    });

    it('says nothing at all when nothing is graceable — the same "say nothing it cannot support" rule as the rest of this screen', async () => {
      render(
        <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
      );

      await screen.findByRole('button', { name: /Gym/ });
      expect(screen.queryByRole('button', { name: /Spend a Grace Day/ })).not.toBeInTheDocument();
    });

    it('sends owner_id and the row’s own for_day, and does not claim Waived before the fold-in runs', async () => {
      rows['settlement_current:day'] = {
        data: [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
        error: null,
      };
      rows['penalty_current:day'] = {
        data: [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
        error: null,
      };

      render(
        <Today
          ownerId="owner-42"
          onOpenLedger={vi.fn()}
          onOpenChain={vi.fn()}
          onOpenFocus={vi.fn()}
        />,
      );

      await userEvent.click(await screen.findByRole('button', { name: /Spend a Grace Day/ }));

      expect(inserted).toEqual([
        { table: 'grace_day', payload: { owner_id: 'owner-42', for_day: '2026-08-18' } },
      ]);
      expect(
        await screen.findByText('Grace Day spent. This day clears within the hour.'),
      ).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /Spend a Grace Day/ })).not.toBeInTheDocument();
    });

    it('shows the server’s own refusal verbatim on a failed spend', async () => {
      rows['settlement_current:day'] = {
        data: [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
        error: null,
      };
      rows['penalty_current:day'] = {
        data: [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
        error: null,
      };
      graceInsertResult = {
        error: {
          code: 'P0001',
          message: 'Both Grace Days for this month have already been spent.',
        },
      };

      render(
        <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
      );

      await userEvent.click(await screen.findByRole('button', { name: /Spend a Grace Day/ }));

      expect(
        await screen.findByText('Both Grace Days for this month have already been spent.'),
      ).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Spend a Grace Day/ })).toBeEnabled();
    });

    it('never double-decrements the shown allowance on an already-spent (23505) outcome', async () => {
      // A second, still-open row proves it: if the count had wrongly dropped, that row's
      // own figure would say so even though the spent row's own control disappears either
      // way. Mirrors `components/ledger.tsx`'s identical test.
      rows['settlement_current:day'] = {
        data: [
          { period: '2026-08-19', verdict: 'failed', missed_count: 1 },
          { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
        ],
        error: null,
      };
      rows['penalty_current:day'] = {
        data: [
          { amount_dong: 500000, state: 'owed', period: '2026-08-19' },
          { amount_dong: 500000, state: 'owed', period: '2026-08-18' },
        ],
        error: null,
      };
      graceInsertResult = { error: { code: '23505', message: 'duplicate key value' } };

      render(
        <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
      );
      await screen.findAllByText('2 Grace Days remaining this month.');

      await userEvent.click(
        await screen.findByRole('button', { name: 'Spend a Grace Day for 2026-08-18' }),
      );

      expect(
        await screen.findByText('Grace Day spent. This day clears within the hour.'),
      ).toBeInTheDocument();
      // The still-open row (2026-08-19) must keep reading 2, not drop to 1.
      expect(await screen.findByText('2 Grace Days remaining this month.')).toBeInTheDocument();
      expect(screen.queryByText('1 Grace Day remaining this month.')).not.toBeInTheDocument();
    });
  });
});

/**
 * Story 6.2 — claiming a timed commitment from Today.
 *
 * The window itself is not tested here and is not implemented here: `declaration_derive_day()`
 * decides whether a tap was inside it, and `supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql`
 * drives both of its edges. What this screen owns is offering the control only where there is a
 * moment to claim, and never reporting a refusal as a save.
 */
const pill = {
  id: 'c2',
  name: 'Pill',
  cadence: 'daily',
  carries_penalty: false,
  weekly_target: null,
  daily_minutes_target: null,
  due_time: '20:00:00',
  late_window_minutes: 30,
};

/**
 * Story 6.5 made the claim control conditional on the window actually being open, so every test
 * below has to say when it is. 20:10 local sits inside `pill`'s own 20:00 + 30 window.
 *
 * `shouldAdvanceTime` keeps `await` working normally under fake timers; the frozen instant is
 * what the screen's own clock reads, and `advanceTimersByTime` is what moves it.
 */
function atLocalTime(hhmm: string): void {
  const [h, m] = hhmm.split(':').map(Number);
  vi.useFakeTimers({ shouldAdvanceTime: true });
  vi.setSystemTime(new Date(Date.UTC(2026, 7, 30, h - 7, m, 0)));
}

describe('claiming a timed commitment', () => {
  beforeEach(() => atLocalTime('20:10'));
  afterEach(() => vi.useRealTimers());

  it('offers no claim at all when nothing carries a time', async () => {
    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByRole('button', { name: /Gym/ });

    expect(screen.queryByRole('button', { name: /^Claim/ })).not.toBeInTheDocument();
  });

  it('offers it for the timed commitment and not for the untimed one beside it', async () => {
    rows.commitment = { data: [gym, pill], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(await screen.findByRole('button', { name: 'Claim Pill' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim Gym' })).not.toBeInTheDocument();
  });

  it('sends the instant of the tap and never a day', async () => {
    rows.commitment = { data: [pill], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.click(await screen.findByRole('button', { name: 'Claim Pill' }));

    // AD-6: the client sends when he tapped. Which day that belongs to is the server's call,
    // and a client that sent a date could pick a day whose window is still open.
    const claim = inserted.find((i) => i.table === 'declaration');
    expect(claim).toBeDefined();
    expect(claim?.payload).toMatchObject({ commitment_id: 'c2', answer: 'held' });
    expect(claim?.payload).not.toHaveProperty('for_day');
    expect(await screen.findByText(/claimed for today/)).toBeInTheDocument();
  });

  it('reports a refusal rather than reporting a claim that did not happen', async () => {
    rows.commitment = { data: [pill], error: null };
    // The server's own sentence, passed through rather than reworded: it names the window,
    // which is more than this screen could say without keeping a second copy of the rule.
    graceInsertResult = {
      error: {
        code: 'P0001',
        message: 'This commitment could be claimed from 20:00 for 30 minutes.',
      },
    };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.click(await screen.findByRole('button', { name: 'Claim Pill' }));

    expect(await screen.findByText(/Not claimed/)).toBeInTheDocument();
    expect(screen.getByText(/could be claimed from 20:00 for 30 minutes/)).toBeInTheDocument();
    expect(screen.queryByText(/claimed for today/)).not.toBeInTheDocument();
  });

  it('says the claim is on the device, dated when it was tapped, with no connection', async () => {
    rows.commitment = { data: [pill], error: null };
    // No SQLSTATE: the write never reached a decision, so it is worth retrying.
    graceInsertResult = { error: { message: 'Failed to fetch' } };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.click(await screen.findByRole('button', { name: 'Claim Pill' }));

    expect(await screen.findByText(/dated when you tapped/)).toBeInTheDocument();
  });
});

/**
 * Story 6.3 — the photo that proves a claim.
 *
 * The rules live in `evidence_derive_owner()` and are driven from the database side by
 * `supabase/tests/6-3-evidence-detaches-from-an-appeal.sql`. What this screen owns is offering
 * the control only when there is a row to attach to, and never reporting a refusal as a save.
 */
function photoTakenOn(day: string): File {
  // Noon local, so no timezone edge decides what day this file claims to be from.
  const at = new Date(`${day}T12:00:00+07:00`).getTime();
  return new File(['x'], 'proof.jpg', { type: 'image/jpeg', lastModified: at });
}

function todayLocal(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Ho_Chi_Minh' }).format(new Date());
}

describe('proving a claim with a photo', () => {
  beforeEach(() => atLocalTime('20:10'));
  afterEach(() => vi.useRealTimers());

  it('offers nothing to upload before the claim is made', async () => {
    rows.commitment = { data: [pill], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByRole('button', { name: 'Claim Pill' });

    expect(screen.queryByLabelText('Proof')).not.toBeInTheDocument();
  });

  it('offers it once the claim has landed and come back with a row to attach to', async () => {
    rows.commitment = { data: [pill], error: null };
    rows.declaration = { data: { id: 'decl-1' }, error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.click(await screen.findByRole('button', { name: 'Claim Pill' }));

    expect(await screen.findByLabelText('Proof')).toBeInTheDocument();
  });

  it('offers nothing to upload for a claim still in the offline queue', async () => {
    rows.commitment = { data: [pill], error: null };
    rows.declaration = { data: { id: 'decl-1' }, error: null };
    graceInsertResult = { error: { message: 'Failed to fetch' } };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.click(await screen.findByRole('button', { name: 'Claim Pill' }));

    // Evidence references a declaration row by id, and a queued claim has no row. The claim
    // survives having no signal; the photo does not, and pretending otherwise would offer an
    // upload that could only fail.
    await screen.findByText(/dated when you tapped/);
    expect(screen.queryByLabelText('Proof')).not.toBeInTheDocument();
  });

  it('stores the photo under the claim it proves', async () => {
    rows.commitment = { data: [pill], error: null };
    rows.declaration = { data: { id: 'decl-1' }, error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.click(await screen.findByRole('button', { name: 'Claim Pill' }));
    await userEvent.upload(await screen.findByLabelText('Proof'), photoTakenOn(todayLocal()));

    // The path leads with the declaration's own id — that is what the bucket's policy reads
    // via storage.foldername(name) to derive access from its owner.
    expect(uploaded).toHaveLength(1);
    expect(uploaded[0].bucket).toBe('appeal-evidence');
    expect(uploaded[0].path.startsWith('decl-1/')).toBe(true);

    const evidence = inserted.find((i) => i.table === 'evidence');
    expect(evidence?.payload).toMatchObject({ declaration_id: 'decl-1' });
    // Never sent: the trigger derives it from the claim, which is the whole of NFR4.
    expect(evidence?.payload).not.toHaveProperty('owner_id');
    expect(await screen.findByText('Proof saved.')).toBeInTheDocument();
  });

  it('refuses a photo from another day before it reaches Storage', async () => {
    rows.commitment = { data: [pill], error: null };
    rows.declaration = { data: { id: 'decl-1' }, error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.click(await screen.findByRole('button', { name: 'Claim Pill' }));
    await userEvent.upload(await screen.findByLabelText('Proof'), photoTakenOn('2020-01-01'));

    expect(await screen.findByText(/not taken today/)).toBeInTheDocument();
    // An evidently wrong file never becomes an object nobody will ever read.
    expect(uploaded).toHaveLength(0);
  });
});

/**
 * Story 6.5 — where the window stands, on the surface itself.
 *
 * The state machine is `lib/timed-window.ts` and is driven to the second by its own tests; the
 * view underneath is driven by `supabase/tests/6-5-today-shows-where-the-window-stands.sql`.
 * What this screen owns is the join: the pill and the control beneath it read the same fold, a
 * claim already made is never offered a second time, and the row changes on its own clock.
 */
describe('where the window stands', () => {
  afterEach(() => vi.useRealTimers());

  it('says when the window opens, and offers nothing to tap before it does', async () => {
    atLocalTime('08:00');
    rows.commitment = { data: [pill], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(
      await screen.findByRole('button', { name: /window opens at 20:00/ }),
    ).toBeInTheDocument();
    expect(screen.getByText('20:00')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim Pill' })).not.toBeInTheDocument();
  });

  // CAP-7's own success condition, in one test: shut and ahead must not read the same, and the
  // difference must not be carried by colour alone — so it is asserted on the spoken sentence.
  it('reads a shut window differently from one still ahead', async () => {
    atLocalTime('22:00');
    rows.commitment = { data: [pill], error: null };

    const { container } = render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(
      await screen.findByRole('button', { name: /window shut, nothing claimed/ }),
    ).toBeInTheDocument();
    expect(screen.getByText('Shut')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim Pill' })).not.toBeInTheDocument();
    // Not an empty bordered card either. A frame around nothing is the screen saying something
    // it has nothing to say — the pill above already carries the whole state.
    expect(container.querySelector('.card-pad')).toBeNull();
  });

  it('shuts the window while the screen sits open, with nothing tapped', async () => {
    atLocalTime('20:29');
    rows.commitment = { data: [pill], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    expect(await screen.findByText('Open now')).toBeInTheDocument();

    // Past 20:30, and one tick of the screen's own clock later. No re-render is requested, no
    // read is repeated, and nothing is tapped.
    await act(async () => {
      vi.advanceTimersByTime(90_000);
    });

    expect(screen.getByText('Shut')).toBeInTheDocument();
    expect(screen.queryByText('Open now')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim Pill' })).not.toBeInTheDocument();
  });

  // The defect this story exists to close on the client side: before it, the claim control was
  // offered again after a reload and the second tap was refused, while the photo the day
  // actually needed had become unreachable.
  it('picks a claim back up after a reload, with the photo still to attach', async () => {
    atLocalTime('20:40');
    rows.commitment = { data: [pill], error: null };
    rows.timed_claim_today = {
      data: [{ commitment_id: 'c2', declaration_id: 'decl-9', proven: false }],
      error: null,
    };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(await screen.findByLabelText('Proof')).toBeInTheDocument();
    expect(screen.getByText('Photo due')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim Pill' })).not.toBeInTheDocument();
  });

  it('is the only state that reads as finished, and asks for nothing more', async () => {
    atLocalTime('20:40');
    rows.commitment = { data: [pill], error: null };
    rows.timed_claim_today = {
      data: [{ commitment_id: 'c2', declaration_id: 'decl-9', proven: true }],
      error: null,
    };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(await screen.findByRole('button', { name: /claimed and proven/ })).toBeInTheDocument();
    expect(screen.getByText('Proven')).toBeInTheDocument();
    expect(screen.queryByLabelText('Proof')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim Pill' })).not.toBeInTheDocument();
  });

  it('reads today through the view and never the declaration table', async () => {
    atLocalTime('20:10');
    rows.commitment = { data: [pill], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByRole('button', { name: 'Claim Pill' });

    expect(seen).toContain('timed_claim_today');
    expect(seen).not.toContain('declaration');
    expect(seen).not.toContain('evidence');
  });

  it('fails the whole screen when that read fails, rather than showing a window it guessed', async () => {
    atLocalTime('20:10');
    rows.commitment = { data: [pill], error: null };
    rows.timed_claim_today = { data: null, error: { message: 'nope' } };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(await screen.findByText('nope')).toBeInTheDocument();
  });

  it('re-reads itself when the local day turns over, rather than ticking on stale answers', async () => {
    atLocalTime('23:59');
    rows.commitment = { data: [pill], error: null };
    rows.timed_claim_today = {
      data: [{ commitment_id: 'c2', declaration_id: 'decl-9', proven: true }],
      error: null,
    };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    expect(await screen.findByText('Proven')).toBeInTheDocument();

    // Midnight. Yesterday's claim is not today's, and the server says so — but only if the
    // screen asks again.
    rows.timed_claim_today = { data: [], error: null };
    await act(async () => {
      vi.advanceTimersByTime(120_000);
    });

    expect(await screen.findByText('20:00')).toBeInTheDocument();
    expect(screen.queryByText('Proven')).not.toBeInTheDocument();
  });

  it('leaves an untimed commitment exactly as it was', async () => {
    atLocalTime('22:00');

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    expect(
      await screen.findByRole('button', { name: /Gym, not yet done today/ }),
    ).toBeInTheDocument();
    expect(screen.getByText('Not yet')).toBeInTheDocument();
    expect(screen.queryByText('Shut')).not.toBeInTheDocument();
  });
});

/**
 * Story 6.8 — a photo kept against a commitment and a day, deciding nothing.
 *
 * The database side is driven by `supabase/tests/6-8-a-photo-i-can-keep-against-any-commitment.sql`.
 * What this screen owns is the offer: a control that needs no claim, no due time and no open
 * window, that belongs to the local day it is looked at on, and that never appears twice on one
 * row beside Epic 6's own timed proof control.
 */
const sketchbook = {
  id: 'c3',
  name: 'Sketchbook',
  cadence: 'daily',
  carries_penalty: false,
  weekly_target: null,
  daily_minutes_target: null,
  due_time: null,
  late_window_minutes: null,
  requires_photo: true,
};

describe('keeping a photo against a commitment', () => {
  afterEach(() => vi.useRealTimers());

  it.each(['00:05', '11:30', '23:50'])('offers the control at %s, with no claim', async (hhmm) => {
    atLocalTime(hhmm);
    rows.commitment = { data: [sketchbook], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    // No Claim button anywhere: there is no window to be inside of, which is the whole point.
    expect(await screen.findByLabelText('Proof — Sketchbook')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Claim/ })).not.toBeInTheDocument();
  });

  it('selects the column, so the whole feature cannot be switched off by a query edit', async () => {
    atLocalTime('11:30');
    rows.commitment = { data: [sketchbook], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByLabelText('Proof — Sketchbook');

    // Asserted on the query rather than on the render, because the render cannot see it: the
    // fixture above supplies `requires_photo` whether or not the SELECT asked for it, so every
    // other test here would stay green with the column dropped and no control would ever appear
    // for a real account.
    const read = fromCalls.find((c) => c.table === 'commitment');
    expect(read?.select).toContain('requires_photo');
  });

  it('offers nothing for a commitment that is not marked', async () => {
    atLocalTime('11:30');
    rows.commitment = { data: [{ ...sketchbook, requires_photo: false }], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByRole('button', { name: /Sketchbook/ });

    expect(screen.queryByLabelText('Proof — Sketchbook')).not.toBeInTheDocument();
  });

  it('stores the photo under the commitment and the day, with no claim in sight', async () => {
    atLocalTime('11:30');
    rows.commitment = { data: [sketchbook], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.upload(
      await screen.findByLabelText('Proof — Sketchbook'),
      photoTakenOn(todayLocal()),
    );

    // The path leads with the commitment's own id — that is what the bucket's policy reads via
    // storage.foldername(name) to derive access from its owner.
    expect(uploaded).toHaveLength(1);
    expect(uploaded[0].bucket).toBe('appeal-evidence');
    expect(uploaded[0].path.startsWith('c3/')).toBe(true);

    const evidence = inserted.find((i) => i.table === 'evidence');
    expect(evidence?.payload).toMatchObject({ commitment_id: 'c3', for_day: todayLocal() });
    // Exactly one parent, and never the owner: the trigger derives it (NFR4), and a second
    // parent would be refused by `evidence_exactly_one_parent`.
    expect(evidence?.payload).not.toHaveProperty('declaration_id');
    expect(evidence?.payload).not.toHaveProperty('owner_id');
    expect(await screen.findByText('Proof saved.')).toBeInTheDocument();
  });

  it('refuses a photo from another day before it reaches Storage', async () => {
    atLocalTime('11:30');
    rows.commitment = { data: [sketchbook], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.upload(
      await screen.findByLabelText('Proof — Sketchbook'),
      photoTakenOn('2020-01-01'),
    );

    expect(await screen.findByText(/not taken today/)).toBeInTheDocument();
    expect(uploaded).toHaveLength(0);
  });

  it('files against the new day once midnight has passed, never the day before', async () => {
    atLocalTime('23:59');
    rows.commitment = { data: [sketchbook], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByLabelText('Proof — Sketchbook');

    await act(async () => {
      vi.advanceTimersByTime(120_000);
    });

    await userEvent.upload(
      await screen.findByLabelText('Proof — Sketchbook'),
      photoTakenOn('2026-08-31'),
    );

    // No back-filling. Yesterday's control is gone with yesterday, and the trigger refuses a
    // `for_day` that has already ended anyway — this is the half that never asks it to.
    const evidence = inserted.find((i) => i.table === 'evidence');
    expect(evidence?.payload).toMatchObject({ commitment_id: 'c3', for_day: '2026-08-31' });
  });

  it('clears yesterday’s outcome when the local day turns over', async () => {
    atLocalTime('23:59');
    rows.commitment = { data: [sketchbook], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.upload(
      await screen.findByLabelText('Proof — Sketchbook'),
      photoTakenOn('2026-08-30'),
    );
    expect(await screen.findByText('Proof saved.')).toBeInTheDocument();

    await act(async () => {
      vi.advanceTimersByTime(120_000);
    });

    // The control goes at midnight with the day it belonged to, and so does what it reported.
    // A "Proof saved." left standing over this morning's empty control is the screen claiming
    // something for a day it is no longer showing.
    expect(screen.queryByText('Proof saved.')).not.toBeInTheDocument();
    expect(await screen.findByLabelText('Proof — Sketchbook')).toBeInTheDocument();
  });

  it('lets the same file be chosen again after the upload failed', async () => {
    atLocalTime('11:30');
    rows.commitment = { data: [sketchbook], error: null };
    uploadResult = { error: { message: 'Failed to fetch' } };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    const input = await screen.findByLabelText('Proof — Sketchbook');
    const photo = photoTakenOn(todayLocal());

    await userEvent.upload(input, photo);
    // `findAllBy`: an upload failure reports `EVIDENCE_COPY.failed` as both the heading and the
    // reason, so the sentence is legitimately on screen twice.
    expect(await screen.findAllByText(/Proof not saved/)).not.toHaveLength(0);
    expect(uploaded).toHaveLength(1);

    // The retry an author would actually make is picking the same photo again. A file input
    // fires no change event when the selection has not changed, so unless the value is cleared
    // this second attempt does nothing at all under a message still saying the save failed.
    uploadResult = { error: null };
    await userEvent.upload(input, photo);

    expect(uploaded).toHaveLength(2);
    expect(await screen.findByText('Proof saved.')).toBeInTheDocument();
  });

  it('announces a failure as loudly as a save', async () => {
    atLocalTime('11:30');
    rows.commitment = { data: [sketchbook], error: null };
    uploadResult = { error: { message: 'Failed to fetch' } };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await userEvent.upload(
      await screen.findByLabelText('Proof — Sketchbook'),
      photoTakenOn(todayLocal()),
    );

    // Both outcomes are a `role="status"` live region. Announcing only the success is how a
    // screen-reader user ends the day believing a photo landed that never did.
    const statuses = await screen.findAllByRole('status');
    expect(statuses.some((el) => el.textContent?.includes('Proof not saved.'))).toBe(true);
  });

  it('shows only the timed control when a commitment carries both', async () => {
    atLocalTime('20:40');
    rows.commitment = { data: [{ ...pill, requires_photo: true }], error: null };
    rows.timed_claim_today = {
      data: [{ commitment_id: 'c2', declaration_id: 'decl-9', proven: false }],
      error: null,
    };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );

    // One control, one meaning: a timed commitment's photo *is* Epic 6's proof, and two upload
    // controls on one row would be two answers to one question.
    expect(await screen.findByLabelText('Proof')).toBeInTheDocument();
    expect(screen.queryByLabelText('Proof — Pill')).not.toBeInTheDocument();
  });

  it('offers no control at all for a timed commitment outside its window', async () => {
    atLocalTime('08:00');
    rows.commitment = { data: [{ ...pill, requires_photo: true }], error: null };

    render(
      <Today ownerId="u1" onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    await screen.findByText('20:00');

    // The flag does not reopen a timed commitment's own window. Epic 6 owns that row entirely.
    expect(screen.queryByLabelText('Proof')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Proof — Pill')).not.toBeInTheDocument();
  });
});
