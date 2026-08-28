import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeSignup } from './referee-signup';

/**
 * Where an invitation is spent. The screen `referee-login.tsx` refuses to be.
 *
 * Two properties carry the whole security argument and are asserted directly: the screen is
 * inert without a token, and it never states which account is being created until the server
 * has said so. Everything else here is about not stranding a referee whose invitation was
 * spent by a request that then failed for some other reason — the account exists at that
 * point, and telling them to try the link again would be advice that cannot work.
 */

const invoke = vi.fn();
const signInWithPassword = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    functions: { invoke: (name: string, options: unknown) => invoke(name, options) },
    auth: { signInWithPassword },
  }),
}));

const replace = vi.fn();
let search = new URLSearchParams('token=tok-abc');

vi.mock('next/navigation', () => ({
  useRouter: () => ({ replace }),
  useSearchParams: () => search,
}));

async function choosePassword(password = 'longenough', confirmation = password) {
  await userEvent.type(screen.getByPlaceholderText(/^Password, at least/), password);
  await userEvent.type(screen.getByPlaceholderText('Repeat the password'), confirmation);
}

beforeEach(() => {
  invoke.mockReset();
  signInWithPassword.mockReset();
  replace.mockClear();
  search = new URLSearchParams('token=tok-abc');
});

describe('the referee signs himself up', () => {
  it('is inert without a token, and says why rather than showing a dead form', async () => {
    search = new URLSearchParams('');
    render(<RefereeSignup />);

    expect(screen.getByText(/needs an invitation link/i)).toBeInTheDocument();
    expect(screen.queryByPlaceholderText(/^Password, at least/)).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Create my account' })).not.toBeInTheDocument();
  });

  it('never names the account before the server does', () => {
    // A token in the query string is written by whoever sent the link. If this screen ever
    // renders an address taken from it, that address is the sender's claim, not a fact.
    search = new URLSearchParams('token=tok-abc&email=attacker@example.com');
    render(<RefereeSignup />);

    expect(screen.queryByText(/attacker@example.com/)).not.toBeInTheDocument();
  });

  it('sends the token and the chosen password, then signs in and lands on /referee', async () => {
    invoke.mockResolvedValue({ data: { email: 'ref@example.com' }, error: null });
    signInWithPassword.mockResolvedValue({
      data: { user: { id: 'r1' }, session: { access_token: 't' } },
      error: null,
    });

    render(<RefereeSignup />);
    await choosePassword();
    await userEvent.click(screen.getByRole('button', { name: 'Create my account' }));

    expect(invoke).toHaveBeenCalledWith('accept-referee-invite', {
      body: { token: 'tok-abc', password: 'longenough' },
    });
    // Signed in with the address the *server* returned, never with anything from the link.
    expect(signInWithPassword).toHaveBeenCalledWith({
      email: 'ref@example.com',
      password: 'longenough',
    });
    expect(replace).toHaveBeenCalledWith('/referee');
  });

  it('will not submit a password below the floor, or one the confirmation disagrees with', async () => {
    render(<RefereeSignup />);

    expect(screen.getByRole('button', { name: 'Create my account' })).toBeDisabled();

    await choosePassword('short', 'short');
    expect(screen.getByRole('button', { name: 'Create my account' })).toBeDisabled();

    await userEvent.clear(screen.getByPlaceholderText(/^Password, at least/));
    await userEvent.clear(screen.getByPlaceholderText('Repeat the password'));
    await choosePassword('longenough', 'longenaugh');

    expect(screen.getByText('The two passwords do not match.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Create my account' })).toBeDisabled();
    expect(invoke).not.toHaveBeenCalled();
  });

  it('shows the server refusal verbatim — expired and already used are different problems', async () => {
    invoke.mockResolvedValue({
      data: null,
      error: { message: 'This invitation has expired. Ask for a new link.' },
    });

    render(<RefereeSignup />);
    await choosePassword();
    await userEvent.click(screen.getByRole('button', { name: 'Create my account' }));

    expect(
      await screen.findByText('This invitation has expired. Ask for a new link.'),
    ).toBeInTheDocument();
    expect(replace).not.toHaveBeenCalled();
  });

  it('refuses a 200 that does not say which account was created', async () => {
    invoke.mockResolvedValue({ data: {}, error: null });

    render(<RefereeSignup />);
    await choosePassword();
    await userEvent.click(screen.getByRole('button', { name: 'Create my account' }));

    expect(await screen.findByText(/did not say which account was created/i)).toBeInTheDocument();
    // Nothing to sign in as, so nothing was attempted.
    expect(signInWithPassword).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
  });

  it('sends the referee to the login screen when the account exists but no session came back', async () => {
    invoke.mockResolvedValue({ data: { email: 'ref@example.com' }, error: null });
    signInWithPassword.mockResolvedValue({
      data: { user: { id: 'r1' }, session: null },
      error: null,
    });

    render(<RefereeSignup />);
    await choosePassword();
    await userEvent.click(screen.getByRole('button', { name: 'Create my account' }));

    // Not "try again": the invitation is spent, and retrying it is the one thing that cannot
    // work. The account is real, so signing in normally is the actual next step.
    expect(await screen.findByText(/Sign in at \/referee\/login/)).toBeInTheDocument();
    expect(replace).not.toHaveBeenCalled();
  });
});
