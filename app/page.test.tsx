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
vi.mock('@/components/focus-session', () => ({ FocusSession: () => null }));

vi.mock('@/components/today', () => ({
  Today: ({ onOpenSettings }: { onOpenSettings: () => void }) => (
    <button type="button" onClick={onOpenSettings}>
      Settings
    </button>
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
});
