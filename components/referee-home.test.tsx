import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeHome } from './referee-home';

/**
 * The Referee's home surface: a count and a total of owed penalties, a real list of pending
 * appeals (Story 4.6), and the two redirects that keep the wrong session off it. RLS (AD-7)
 * is the actual boundary — `penalty_current` and the `appeal` read behind the list already
 * return nothing to anyone but a `role = 'referee'` session — so what is asserted here is
 * that this screen reads what RLS would already have scoped, renders no ruling or
 * collection control of its own (those live on the detail screen and Story 4.7,
 * respectively), and gets a doer or a signed-out visitor off the screen without rendering
 * the real content first.
 */

const getUser = vi.fn();
const signOut = vi.fn();
let profileResult: unknown = { data: { role: 'referee' }, error: null };
let penaltyResult: unknown = { data: [], error: null };
let appealResult: unknown = { data: [], error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    auth: { getUser, signOut },
    from: (table: string) => {
      if (table === 'profile') {
        return { select: () => ({ maybeSingle: () => Promise.resolve(profileResult) }) };
      }
      if (table === 'appeal') {
        // `.select().eq().order()` — the last call in the chain resolves, matching the
        // shape `components/referee-home.tsx` actually builds.
        return { select: () => ({ eq: () => ({ order: () => Promise.resolve(appealResult) }) }) };
      }
      // penalty_current — no `.maybeSingle()`, a bare `.select()` resolves directly,
      // matching how `ledger.tsx`'s own `from(...).select(...)` reads behave.
      return { select: () => Promise.resolve(penaltyResult) };
    },
  }),
}));

const replace = vi.fn();
const push = vi.fn();
vi.mock('next/navigation', () => ({
  useRouter: () => ({ replace, push }),
}));

beforeEach(() => {
  getUser.mockResolvedValue({ data: { user: { id: 'ref-1' } }, error: null });
  signOut.mockResolvedValue({ error: null });
  profileResult = { data: { role: 'referee' }, error: null };
  penaltyResult = { data: [], error: null };
  appealResult = { data: [], error: null };
  replace.mockClear();
  push.mockClear();
});

describe('the referee home surface', () => {
  it('renders the empty state when nothing is pending or owed', async () => {
    render(<RefereeHome />);

    expect(
      await screen.findByText('Nothing for you right now. 0 appeals pending, 0 penalties owed.'),
    ).toBeInTheDocument();
  });

  it('shows a count and a total of owed penalties, with no per-penalty list', async () => {
    penaltyResult = {
      data: [
        { state: 'held', amount_dong: 500_000 },
        { state: 'owed', amount_dong: 500_000 },
        { state: 'owed', amount_dong: 500_000 },
      ],
      error: null,
    };
    render(<RefereeHome />);

    expect(await screen.findByText('1 appeal pending.')).toBeInTheDocument();
    expect(screen.getByText(/2 penalties owed, 1.000.000₫ total\./)).toBeInTheDocument();

    // Never a ruling or collection control on this screen itself, and never a per-penalty
    // list — Mark Collected is Story 4.7's own goal, unbuilt here.
    expect(screen.queryByText(/He did it/)).not.toBeInTheDocument();
    expect(screen.queryByText(/He didn't/)).not.toBeInTheDocument();
    expect(screen.queryByText(/Mark Collected/)).not.toBeInTheDocument();
  });

  it('renders a real list of pending appeals, day and commitment name, each opening its own screen', async () => {
    penaltyResult = { data: [{ state: 'held', amount_dong: 500_000 }], error: null };
    appealResult = {
      data: [{ id: 'appeal-1', for_day: '2026-08-18', commitment: { name: 'TryHackMe' } }],
      error: null,
    };
    render(<RefereeHome />);

    expect(await screen.findByText('TryHackMe')).toBeInTheDocument();
    // Formatted the same way `components/referee-appeal-detail.tsx`'s own deadline is
    // (`formatDeadline`), not the raw ISO date — and not aria-hidden, so a screen-reader
    // user gets the day too.
    expect(screen.getByText('Aug 18')).toBeInTheDocument();

    // Every row's button otherwise shares the identical accessible name ("Open") — the
    // accessible name has to distinguish which row it belongs to.
    fireEvent.click(screen.getByRole('button', { name: 'Open appeal for TryHackMe, Aug 18' }));
    expect(push).toHaveBeenCalledWith('/referee/appeals/appeal-1');
  });

  it('gives each row a distinguishing accessible name — not every row sharing "Open"', async () => {
    penaltyResult = {
      data: [
        { state: 'held', amount_dong: 500_000 },
        { state: 'held', amount_dong: 500_000 },
      ],
      error: null,
    };
    appealResult = {
      data: [
        { id: 'appeal-1', for_day: '2026-08-18', commitment: { name: 'TryHackMe' } },
        { id: 'appeal-2', for_day: '2026-08-17', commitment: { name: 'Gym' } },
      ],
      error: null,
    };
    render(<RefereeHome />);

    const first = await screen.findByRole('button', {
      name: 'Open appeal for TryHackMe, Aug 18',
    });
    const second = screen.getByRole('button', { name: 'Open appeal for Gym, Aug 17' });

    fireEvent.click(first);
    expect(push).toHaveBeenCalledWith('/referee/appeals/appeal-1');

    fireEvent.click(second);
    expect(push).toHaveBeenCalledWith('/referee/appeals/appeal-2');
  });

  it('falls back to a generic name when the joined commitment cannot be read', async () => {
    penaltyResult = { data: [{ state: 'held', amount_dong: 500_000 }], error: null };
    appealResult = {
      data: [{ id: 'appeal-1', for_day: '2026-08-18', commitment: null }],
      error: null,
    };
    render(<RefereeHome />);

    expect(await screen.findByText('A commitment')).toBeInTheDocument();
  });

  it('renders no list section when nothing is pending', async () => {
    render(<RefereeHome />);
    await screen.findByText(/Nothing for you right now/);

    expect(screen.queryByRole('button', { name: /Open appeal for/ })).not.toBeInTheDocument();
  });

  it('sends a signed-out visitor to the referee login, not the doer one', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: null });
    render(<RefereeHome />);

    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/referee/login'));
  });

  it('sends a doer session away rather than rendering the referee shell for it', async () => {
    profileResult = { data: { role: 'doer' }, error: null };
    render(<RefereeHome />);

    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/'));
    expect(screen.queryByText(/appeals pending/)).not.toBeInTheDocument();
  });

  it('requires no notification permission and traps no focus — every control is a plain button', async () => {
    render(<RefereeHome />);
    await screen.findByText(/Nothing for you right now/);

    expect(document.querySelector('[aria-modal]')).toBeNull();
    expect(document.querySelectorAll('dialog')).toHaveLength(0);
    expect(screen.getByRole('button', { name: 'Sign out' })).toBeInTheDocument();
  });
});
