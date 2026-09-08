import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeSession } from './referee-session';

/**
 * The right-hand half of the referee's brand bar: who is signed in, and the way out.
 *
 * Two things here are worth a test rather than a reading. It must render *nothing at all*
 * when signed out — the sign-in and accept-invite screens show the wordmark alone, and a
 * "Sign out" offered to somebody with no session is a control that can only fail. And Sign
 * out must be reachable from every referee screen, which is the whole reason it moved here
 * from the foot of `referee-home`: from an appeal he had been sent to rule on, there was
 * previously no way out without navigating back first.
 */

const getUser = vi.fn();
const signOut = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({ auth: { getUser, signOut } }),
}));

const replace = vi.fn();
let pathname = '/referee';

vi.mock('next/navigation', () => ({
  useRouter: () => ({ replace }),
  usePathname: () => pathname,
}));

beforeEach(() => {
  pathname = '/referee';
  getUser.mockReset();
  getUser.mockResolvedValue({ data: { user: { email: 'nam@example.com' } }, error: null });
  signOut.mockReset();
  signOut.mockResolvedValue({ error: null });
  replace.mockClear();
});

describe('the referee brand bar’s session half', () => {
  it('names the signed-in account and offers the way out', async () => {
    render(<RefereeSession />);

    expect(await screen.findByText('nam@example.com')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Sign out' })).toBeInTheDocument();
  });

  it('renders nothing at all when there is no session', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: null });
    const { container } = render(<RefereeSession />);

    // Awaited rather than asserted immediately: an empty render is also what the first frame
    // looks like, so a synchronous check would pass without the read having happened.
    await vi.waitFor(() => expect(getUser).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument();
  });

  it('names nobody when the read fails, rather than guessing', async () => {
    // Failing toward "signed out" hides a control that would not have worked anyway. Failing
    // the other way would leave a stale email in the bar naming the wrong account.
    getUser.mockResolvedValue({ data: { user: null }, error: { message: 'network' } });
    const { container } = render(<RefereeSession />);

    await vi.waitFor(() => expect(getUser).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
  });

  it('signs out and lands on the sign-in screen', async () => {
    render(<RefereeSession />);
    await userEvent.click(await screen.findByRole('button', { name: 'Sign out' }));

    expect(signOut).toHaveBeenCalled();
    expect(replace).toHaveBeenCalledWith('/referee/login');
  });

  it('stops naming the account before the navigation resolves', async () => {
    // The router is mocked, so nothing actually navigates here — which is exactly the window
    // this guards. Between the click and the new route painting, the bar must not keep
    // naming a session that has already ended.
    render(<RefereeSession />);
    await userEvent.click(await screen.findByRole('button', { name: 'Sign out' }));

    expect(screen.queryByText('nam@example.com')).not.toBeInTheDocument();
  });

  it('re-reads the session when the route changes', async () => {
    // How a fresh sign-in reaches the bar: both ways in end in a `router.replace`, so the
    // path moving is the signal. Without this the bar would stay empty after signing in
    // until something else remounted it.
    getUser.mockResolvedValue({ data: { user: null }, error: null });
    pathname = '/referee/login';
    const { rerender } = render(<RefereeSession />);
    await vi.waitFor(() => expect(getUser).toHaveBeenCalledTimes(1));

    getUser.mockResolvedValue({ data: { user: { email: 'nam@example.com' } }, error: null });
    pathname = '/referee';
    rerender(<RefereeSession />);

    expect(await screen.findByText('nam@example.com')).toBeInTheDocument();
  });

  it('traps no focus and opens nothing — the way out is a plain button', async () => {
    render(<RefereeSession />);
    await screen.findByRole('button', { name: 'Sign out' });

    expect(document.querySelector('[aria-modal]')).toBeNull();
    expect(document.querySelectorAll('dialog')).toHaveLength(0);
  });

  it('does not announce the separator between the account and the control', async () => {
    render(<RefereeSession />);
    await screen.findByText('nam@example.com');

    // The middle dot is punctuation between a name and a control, not content. A screen
    // reader reading "nam@example.com middle dot Sign out" gains nothing from the middle.
    expect(screen.getByText('·')).toHaveAttribute('aria-hidden', 'true');
  });
});
