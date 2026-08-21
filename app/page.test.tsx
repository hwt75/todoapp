import { useEffect } from 'react';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import Home from './page';

/**
 * The routing this screen owns: which of Today, the Ledger, Chains detail, a Focus Session and
 * Settings is on screen, and how each one gets back.
 *
 * Every child here is a genuine network reader — commitments, gate state, install detection —
 * so this test replaces every one of them with a stand-in that renders nothing but a button
 * wired to the prop under test. What is real is `page.tsx`'s own state and the ternary that
 * switches between children on it. Nothing here exercised that switch before this story added a
 * `showSettings` branch to it (spec 3.0, verification-gap review, 2026-08-21) — a broken wire, an
 * inverted branch, or a button calling the wrong setter would all have shipped undetected.
 *
 * Story 3.1 added a second branch, `focusOf`, to the same ternary without extending this file —
 * reintroducing the exact gap it was written to close (spec 3.1, verification-gap review,
 * 2026-08-21). The `Today` stub below now exposes both callbacks for the same reason.
 */

vi.mock('@/lib/use-gate', () => ({
  useGate: () => ({ owing: [], now: new Date(), markAnswered: vi.fn() }),
}));

vi.mock('@/components/sign-in', () => ({
  SignIn: ({ onAccountChange }: { onAccountChange: (id: string | null) => void }) => {
    // The real component resolves a session asynchronously; this mirrors that by reporting
    // after mount rather than mid-render, which is what the real one does too.
    useEffect(() => {
      onAccountChange('u1');
    }, [onAccountChange]);
    return null;
  },
}));

vi.mock('@/components/commitment-list', () => ({ CommitmentList: () => null }));
vi.mock('@/components/push-probe', () => ({ PushProbe: () => null }));
vi.mock('@/components/morning-gate', () => ({ MorningGate: () => null }));
vi.mock('@/components/ledger', () => ({ Ledger: () => null }));
vi.mock('@/components/chains-detail', () => ({ ChainsDetail: () => null }));

vi.mock('@/components/focus-session', () => ({
  FocusSession: ({
    commitmentId,
    name,
    onClose,
  }: {
    commitmentId: string;
    name: string;
    onClose: () => void;
  }) => (
    <div>
      <p>{`Focus Session screen: ${name} (${commitmentId})`}</p>
      <button type="button" onClick={onClose}>
        Back to today
      </button>
    </div>
  ),
}));

vi.mock('@/components/today', () => ({
  Today: ({
    onOpenSettings,
    onOpenFocus,
  }: {
    onOpenSettings: () => void;
    onOpenFocus: (commitment: { id: string; name: string }) => void;
  }) => (
    <>
      <button type="button" onClick={onOpenSettings}>
        Settings
      </button>
      <button type="button" onClick={() => onOpenFocus({ id: 'c1', name: 'Company work' })}>
        Open Company work
      </button>
    </>
  ),
}));

vi.mock('@/components/settings', () => ({
  Settings: ({ onClose }: { onClose: () => void }) => (
    <div>
      <p>Settings screen</p>
      <button type="button" onClick={onClose}>
        Back to today
      </button>
    </div>
  ),
}));

describe('the app shell', () => {
  it('swaps Today for Settings and back, through the callbacks it owns', async () => {
    render(<Home />);

    // Today first — the launch destination.
    const openSettings = await screen.findByRole('button', { name: 'Settings' });
    expect(screen.queryByText('Settings screen')).not.toBeInTheDocument();

    await userEvent.click(openSettings);

    // Settings now on screen, Today's own trigger gone with it.
    expect(await screen.findByText('Settings screen')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Back to today' }));

    // Today again, Settings gone.
    expect(await screen.findByRole('button', { name: 'Settings' })).toBeInTheDocument();
    expect(screen.queryByText('Settings screen')).not.toBeInTheDocument();
  });

  it('swaps Today for the Focus Session and back, with the tapped commitment carried through', async () => {
    render(<Home />);

    const openFocus = await screen.findByRole('button', { name: 'Open Company work' });
    await userEvent.click(openFocus);

    // The Focus Session is on screen, carrying the exact commitment Today reported the tap for
    // — not a hardcoded or stale one.
    expect(await screen.findByText('Focus Session screen: Company work (c1)')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Open Company work' })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Back to today' }));

    // Today again, the Focus Session gone.
    expect(await screen.findByRole('button', { name: 'Open Company work' })).toBeInTheDocument();
    expect(screen.queryByText(/Focus Session screen/)).not.toBeInTheDocument();
  });
});
