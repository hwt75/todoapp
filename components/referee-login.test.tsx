import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeLogin } from './referee-login';

/**
 * The Referee's own way in, and the one thing it must never offer: a "Create account" path.
 * Pairing from Settings is the only way a referee account is ever made (Story 4.5's own
 * Never boundary) — this screen is sign-in only, mirroring `sign-in.tsx`'s
 * `signInWithPassword` shape and nothing else of it.
 */

const signInWithPassword = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    auth: { signInWithPassword },
  }),
}));

const replace = vi.fn();
vi.mock('next/navigation', () => ({
  useRouter: () => ({ replace }),
}));

async function signIn() {
  await userEvent.type(screen.getByPlaceholderText('you@example.com'), 'ref@example.com');
  await userEvent.type(screen.getByPlaceholderText('Password'), 'hunter2');
  await userEvent.click(screen.getByRole('button', { name: 'Sign in' }));
}

beforeEach(() => {
  signInWithPassword.mockReset();
  replace.mockClear();
});

describe('referee sign-in', () => {
  it('never offers a way to create an account', () => {
    render(<RefereeLogin />);
    expect(screen.queryByRole('button', { name: /create account/i })).not.toBeInTheDocument();
  });

  it('goes to /referee once a session is actually issued', async () => {
    signInWithPassword.mockResolvedValue({
      data: { user: { id: 'r1' }, session: { access_token: 't' } },
      error: null,
    });
    render(<RefereeLogin />);

    await signIn();

    expect(replace).toHaveBeenCalledWith('/referee');
  });

  it('repeats a failed sign-in verbatim rather than a generic summary', async () => {
    signInWithPassword.mockResolvedValue({
      data: { user: null, session: null },
      error: { message: 'Invalid login credentials' },
    });
    render(<RefereeLogin />);

    await signIn();

    expect(await screen.findByText('Invalid login credentials')).toBeInTheDocument();
    expect(replace).not.toHaveBeenCalled();
  });

  it('does not claim a session that was never issued', async () => {
    signInWithPassword.mockResolvedValue({
      data: { user: { id: 'r1' }, session: null },
      error: null,
    });
    render(<RefereeLogin />);

    await signIn();

    expect(await screen.findByText(/no session was issued/)).toBeInTheDocument();
    expect(replace).not.toHaveBeenCalled();
  });

  it('will not submit a password the server would only reject', async () => {
    render(<RefereeLogin />);

    expect(screen.getByRole('button', { name: 'Sign in' })).toBeDisabled();

    await userEvent.type(screen.getByPlaceholderText('you@example.com'), 'ref@example.com');
    await userEvent.type(screen.getByPlaceholderText('Password'), 'short');
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeDisabled();
  });
});
