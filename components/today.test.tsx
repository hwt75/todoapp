import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
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
const fromCalls: Array<{ table: string; columns: string[] }> = [];
const inserted: Array<{ table: string; payload: unknown }> = [];
// What a `grace_day` insert comes back with (Story 5.1). Set per test; the default is a
// clean success — most tests here have nothing to do with spending one at all.
let graceInsertResult: unknown = { error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      seen.push(table);
      let key = table;
      const call = { table, columns: [] as string[] };
      fromCalls.push(call);
      const result = () => rows[key] ?? { data: [], error: null };
      const query = {
        select: () => query,
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
        onOpenSettings={vi.fn()}
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
    );

    expect(await screen.findByRole('button', { name: /Gym/ })).toHaveAccessibleName(
      'Gym, not yet done today, missing this costs money',
    );
  });

  it('opens a chain with the commitment the row was drawn from', async () => {
    const onOpenChain = vi.fn();
    render(
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={onOpenChain}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
        onOpenSettings={vi.fn()}
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

  it('opens settings the same way it opens the ledger or a chain — a callback it owns', async () => {
    const onOpenSettings = vi.fn();
    render(
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={onOpenSettings}
      />,
    );

    await userEvent.click(screen.getByRole('button', { name: 'Settings' }));
    expect(onOpenSettings).toHaveBeenCalledOnce();
  });

  it('tells an empty setup apart from a broken read', async () => {
    rows.commitment = { data: [], error: null };
    const { unmount } = render(
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
    );
    expect(await screen.findByText(/Nothing set up yet/)).toBeInTheDocument();
    unmount();

    rows.commitment = { data: null, error: { message: 'permission denied' } };
    render(
      <Today
        ownerId="u1"
        onOpenLedger={vi.fn()}
        onOpenChain={vi.fn()}
        onOpenFocus={vi.fn()}
        onOpenSettings={vi.fn()}
      />,
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
        <Today
          ownerId="u1"
          onOpenLedger={vi.fn()}
          onOpenChain={vi.fn()}
          onOpenFocus={vi.fn()}
          onOpenSettings={vi.fn()}
        />,
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
        <Today
          ownerId="u1"
          onOpenLedger={vi.fn()}
          onOpenChain={vi.fn()}
          onOpenFocus={vi.fn()}
          onOpenSettings={vi.fn()}
        />,
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
        <Today
          ownerId="u1"
          onOpenLedger={vi.fn()}
          onOpenChain={vi.fn()}
          onOpenFocus={vi.fn()}
          onOpenSettings={vi.fn()}
        />,
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
        <Today
          ownerId="u1"
          onOpenLedger={vi.fn()}
          onOpenChain={vi.fn()}
          onOpenFocus={vi.fn()}
          onOpenSettings={vi.fn()}
        />,
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
          onOpenSettings={vi.fn()}
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
        <Today
          ownerId="u1"
          onOpenLedger={vi.fn()}
          onOpenChain={vi.fn()}
          onOpenFocus={vi.fn()}
          onOpenSettings={vi.fn()}
        />,
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
        <Today
          ownerId="u1"
          onOpenLedger={vi.fn()}
          onOpenChain={vi.fn()}
          onOpenFocus={vi.fn()}
          onOpenSettings={vi.fn()}
        />,
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
