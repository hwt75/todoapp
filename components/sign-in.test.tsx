import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { SignIn } from './sign-in';

/**
 * Sign-in, and the two things it must never do quietly.
 *
 * **It must not flatten an auth failure into a friendly summary.** The exact message separates a
 * wrong password from an unconfirmed account from a project whose signups are disabled — three
 * very different problems with three different fixes, and this is the first surface anyone meets.
 *
 * **It must not report a session it did not get.** Creating an account while email confirmation is
 * still on returns a user and no session; on iOS the confirmation link opens Safari rather than
 * the installed app, so the one surface that can receive push stays signed out. Showing "signed
 * in" there would hide the single most confusing failure this product has.
 *
 * The role shown is display only — every access decision belongs to a policy (AD-7) — so what is
 * asserted is that an unreadable role says so rather than defaulting to something plausible.
 */

const auth = {
  getUser: vi.fn(),
  signInWithPassword: vi.fn(),
  signUp: vi.fn(),
  signOut: vi.fn(),
};
let profileResult: unknown = { data: { role: 'doer' }, error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    auth,
    from: () => ({
      select: () => ({ maybeSingle: () => Promise.resolve(profileResult) }),
    }),
  }),
}));

async function signIn() {
  await userEvent.type(screen.getByPlaceholderText('you@example.com'), 'a@example.com');
  await userEvent.type(screen.getByPlaceholderText(/Password/), 'hunter2');
  await userEvent.click(screen.getByRole('button', { name: 'Sign in' }));
}

beforeEach(() => {
  auth.getUser.mockResolvedValue({ data: { user: null }, error: null });
  auth.signInWithPassword.mockResolvedValue({
    data: { user: { id: 'u1', email: 'a@example.com' }, session: { access_token: 't' } },
    error: null,
  });
  auth.signUp.mockReset();
  auth.signOut.mockResolvedValue({ error: null });
  profileResult = { data: { role: 'doer' }, error: null };
});

describe('sign-in', () => {
  it('will not submit an address or a password the server would only reject', async () => {
    render(<SignIn />);
    await screen.findByText(/Signing in creates the account/);

    expect(screen.getByRole('button', { name: 'Sign in' })).toBeDisabled();

    await userEvent.type(screen.getByPlaceholderText('you@example.com'), 'a@example.com');
    await userEvent.type(screen.getByPlaceholderText(/Password/), 'short');
    // Six characters is the project's own minimum. Sending five costs a round trip to be
    // told something the form already knew.
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeDisabled();

    await userEvent.type(screen.getByPlaceholderText(/Password/), 'er');
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeEnabled();
  });

  it('tells the caller which account everything afterwards belongs to', async () => {
    const onAccountChange = vi.fn();
    render(<SignIn onAccountChange={onAccountChange} />);
    await screen.findByText(/Signing in creates the account/);

    await signIn();

    expect(await screen.findByText(/Signed in as a@example.com/)).toBeInTheDocument();
    expect(onAccountChange).toHaveBeenLastCalledWith('u1');
  });

  it('repeats the failure verbatim rather than summarising it', async () => {
    auth.signInWithPassword.mockResolvedValue({
      data: { user: null, session: null },
      error: { message: 'Invalid login credentials' },
    });
    render(<SignIn />);
    await screen.findByText(/Signing in creates the account/);

    await signIn();

    // "Something went wrong" would flatten a wrong password, an unconfirmed account and a
    // project with signups disabled into one sentence with three different fixes.
    expect(await screen.findByText('Invalid login credentials')).toBeInTheDocument();
  });

  it('refuses to call an account without a session signed in', async () => {
    auth.signUp.mockResolvedValue({
      data: { user: { id: 'u1', email: 'a@example.com' }, session: null },
      error: null,
    });
    const onAccountChange = vi.fn();
    render(<SignIn onAccountChange={onAccountChange} />);
    await screen.findByText(/Signing in creates the account/);

    await userEvent.type(screen.getByPlaceholderText('you@example.com'), 'a@example.com');
    await userEvent.type(screen.getByPlaceholderText(/Password/), 'hunter2');
    await userEvent.click(screen.getByRole('button', { name: 'Create account' }));

    // The account exists and has no session until a link is clicked — which on iOS lands
    // in Safari, not in the installed app that can receive push. The message names the
    // exact setting to turn off.
    expect(await screen.findByText(/email confirmation is still on/)).toBeInTheDocument();
    expect(onAccountChange).not.toHaveBeenCalledWith('u1');
  });

  it('says the role is not readable rather than guessing one', async () => {
    profileResult = { data: null, error: null };
    render(<SignIn />);
    await screen.findByText(/Signing in creates the account/);

    await signIn();

    // Either the trigger that creates the profile did not run, or a policy is denying the
    // read. Both are worth knowing before anything is built on this account.
    // The role reads `not readable` where a role would be, and the paragraph beside it
    // names both things that could have caused it.
    expect(await screen.findByText('not readable')).toBeInTheDocument();
    expect(screen.getByText(/policy is denying the read/)).toBeInTheDocument();
  });

  it('restores a session that already exists, without asking again', async () => {
    auth.getUser.mockResolvedValue({
      data: { user: { id: 'u1', email: 'a@example.com' } },
      error: null,
    });
    const onAccountChange = vi.fn();

    render(<SignIn onAccountChange={onAccountChange} />);

    expect(await screen.findByText(/Signed in as a@example.com/)).toBeInTheDocument();
    expect(screen.queryByPlaceholderText('you@example.com')).not.toBeInTheDocument();
    expect(onAccountChange).toHaveBeenCalledWith('u1');
  });

  it('hands the account back as gone when signing out', async () => {
    auth.getUser.mockResolvedValue({
      data: { user: { id: 'u1', email: 'a@example.com' } },
      error: null,
    });
    const onAccountChange = vi.fn();
    render(<SignIn onAccountChange={onAccountChange} />);
    await screen.findByText(/Signed in as a@example.com/);

    await userEvent.click(screen.getByRole('button', { name: 'Sign out' }));

    expect(auth.signOut).toHaveBeenCalledOnce();
    expect(onAccountChange).toHaveBeenLastCalledWith(null);
    expect(await screen.findByPlaceholderText('you@example.com')).toBeInTheDocument();
  });
});
