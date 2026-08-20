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

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      seen.push(table);
      const result = () => rows[table] ?? { data: [], error: null };
      const query = {
        select: () => query,
        is: () => query,
        eq: () => query,
        order: () => Promise.resolve(result()),
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
  for (const key of Object.keys(rows)) delete rows[key];
  rows.commitment = { data: [gym], error: null };
  rows.penalty_current = { data: [], error: null };
  rows.chain_current = { data: [], error: null };
});

describe('the today screen', () => {
  it('reads the money and the chains through the views that follow a correction', async () => {
    render(<Today onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />);
    await screen.findByRole('button', { name: /Gym/ });

    // `penalty_current`, never `penalty`: a penalty attached to a superseded verdict is
    // history rather than debt, and reading the base table would charge him for a day he
    // took back. Same for the chain, which is derived in exactly one place.
    expect(seen).toContain('penalty_current');
    expect(seen).toContain('chain_current');
    expect(seen).not.toContain('penalty');
    expect(seen).not.toContain('settlement_commitment');
  });

  it('announces the commitments before the debt, whatever the layout shows', async () => {
    rows.penalty_current = { data: [{ amount_dong: 500000 }], error: null };

    const { container } = render(
      <Today onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
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
    render(<Today onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />);
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

    render(<Today onOpenLedger={onOpenLedger} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />);

    const debt = await screen.findByRole('button', { name: /Owed since you started/ });
    // One label rather than three fragments, and the total is a sum of what still stands.
    expect(debt).toHaveAccessibleName('Owed since you started: 1.000.000₫. Opens the ledger.');

    await userEvent.click(debt);
    expect(onOpenLedger).toHaveBeenCalledOnce();
  });

  it('never claims a verdict for a day that has not ended', async () => {
    rows.chain_current = { data: [{ commitment_id: 'c1', current_days: 4 }], error: null };

    render(<Today onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />);

    // FR-10 forbids a mid-day verdict, so every row is honestly `not yet` — and the chain
    // beside it is yesterday's number, which is a different claim and an allowed one.
    expect(await screen.findByRole('button', { name: /Gym/ })).toHaveAccessibleName(
      'Gym, not yet done today, holding 4 days, missing this costs money',
    );
  });

  it('opens a chain with the commitment the row was drawn from', async () => {
    const onOpenChain = vi.fn();
    render(<Today onOpenLedger={vi.fn()} onOpenChain={onOpenChain} onOpenFocus={vi.fn()} />);

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

    render(<Today onOpenLedger={vi.fn()} onOpenChain={onOpenChain} onOpenFocus={onOpenFocus} />);

    await userEvent.click(await screen.findByRole('button', { name: /Company work/ }));
    expect(onOpenFocus).toHaveBeenCalledExactlyOnceWith(hours);
    expect(onOpenChain).not.toHaveBeenCalled();

    // And every other cadence still goes where it always did.
    await userEvent.click(screen.getByRole('button', { name: /Gym/ }));
    expect(onOpenChain).toHaveBeenCalledExactlyOnceWith(gym);
    expect(onOpenFocus).toHaveBeenCalledOnce();
  });

  it('tells an empty setup apart from a broken read', async () => {
    rows.commitment = { data: [], error: null };
    const { unmount } = render(
      <Today onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />,
    );
    expect(await screen.findByText(/Nothing set up yet/)).toBeInTheDocument();
    unmount();

    rows.commitment = { data: null, error: { message: 'permission denied' } };
    render(<Today onOpenLedger={vi.fn()} onOpenChain={vi.fn()} onOpenFocus={vi.fn()} />);

    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByText(/Nothing set up yet/)).not.toBeInTheDocument();
  });
});
