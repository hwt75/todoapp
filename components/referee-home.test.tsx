import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeHome } from './referee-home';

/**
 * The Referee's home surface: a count and a total, and the two redirects that keep the
 * wrong session off it. RLS (AD-7) is the actual boundary — `penalty_current` already
 * returns nothing to anyone but a `role = 'referee'` session — so what is asserted here is
 * that this screen reads what RLS would already have scoped, renders only a count and a
 * total (never a per-item list, never a ruling or collection control — those are Stories
 * 4.6/4.7), and gets a doer or a signed-out visitor off the screen without rendering the
 * real content first.
 */

const getUser = vi.fn();
const signOut = vi.fn();
let profileResult: unknown = { data: { role: 'referee' }, error: null };
let penaltyResult: unknown = { data: [], error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    auth: { getUser, signOut },
    from: (table: string) =>
      table === 'profile'
        ? { select: () => ({ maybeSingle: () => Promise.resolve(profileResult) }) }
        : // No `.maybeSingle()` for penalty_current — a bare `.select()` resolves directly,
          // matching how `ledger.tsx`'s own `from(...).select(...)` reads behave.
          { select: () => Promise.resolve(penaltyResult) },
  }),
}));

const replace = vi.fn();
vi.mock('next/navigation', () => ({
  useRouter: () => ({ replace }),
}));

beforeEach(() => {
  getUser.mockResolvedValue({ data: { user: { id: 'ref-1' } }, error: null });
  signOut.mockResolvedValue({ error: null });
  profileResult = { data: { role: 'referee' }, error: null };
  penaltyResult = { data: [], error: null };
  replace.mockClear();
});

describe('the referee home surface', () => {
  it('renders the empty state when nothing is pending or owed', async () => {
    render(<RefereeHome />);

    expect(
      await screen.findByText('Nothing for you right now. 0 appeals pending, 0 penalties owed.'),
    ).toBeInTheDocument();
  });

  it('shows a count and a total, never a per-item list', async () => {
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

    // Never a ruling or collection control — those are Stories 4.6/4.7.
    expect(screen.queryByText(/He did it/)).not.toBeInTheDocument();
    expect(screen.queryByText(/He didn't/)).not.toBeInTheDocument();
    expect(screen.queryByText(/Mark Collected/)).not.toBeInTheDocument();
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
