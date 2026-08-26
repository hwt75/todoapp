import { useEffect } from 'react';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
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

// This screen's own role read (Story 4.5 — a referee session is redirected to /referee).
// `'doer'` here keeps every existing test on its original path; the redirect itself has its
// own coverage below.
let profileRole: string | null = 'doer';
// Set by the render-time-reset test below to make one profile read hang until the test
// resolves it by hand, rather than resolving immediately like every other test's reads do —
// see that test's own comment for why.
let nextReadIsDeferred = false;
let pendingRoleRead:
  ((value: { data: { role: string | null } | null; error: null }) => void) | null = null;
// Story 5.2: `app/page.tsx` now also reads `silence_episode` directly (not through a mocked
// hook, the same way `role` is read inline). `null` here is every existing test's own case —
// no active episode, so this screen's original routing is exercised exactly as before.
let activeSilenceEpisode: { started_day: string } | null = null;
vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      if (table === 'silence_episode') {
        return {
          select: () => ({
            is: () => ({
              maybeSingle: () => Promise.resolve({ data: activeSilenceEpisode, error: null }),
            }),
          }),
        };
      }

      return {
        select: () => ({
          maybeSingle: () => {
            if (nextReadIsDeferred) {
              nextReadIsDeferred = false;
              return new Promise((resolve) => {
                pendingRoleRead = resolve;
              });
            }
            return Promise.resolve({ data: { role: profileRole }, error: null });
          },
        }),
      };
    },
  }),
}));

const replace = vi.fn();
vi.mock('next/navigation', () => ({
  useRouter: () => ({ replace }),
}));

vi.mock('@/components/sign-in', () => ({
  SignIn: ({ onAccountChange }: { onAccountChange: (id: string | null) => void }) => {
    // The real component resolves a session asynchronously; this mirrors that by reporting
    // after mount rather than mid-render, which is what the real one does too.
    useEffect(() => {
      onAccountChange('u1');
    }, [onAccountChange]);
    // A second account signing in without a sign-out between — exactly the case
    // `app/page.tsx`'s own render-time role reset exists for. Only the render-time-reset
    // test below ever clicks this; every other test leaves it alone.
    return (
      <button type="button" onClick={() => onAccountChange('u2')}>
        Switch account
      </button>
    );
  },
}));

vi.mock('@/components/commitment-list', () => ({ CommitmentList: () => null }));
vi.mock('@/components/push-probe', () => ({ PushProbe: () => null }));
vi.mock('@/components/morning-gate', () => ({ MorningGate: () => null }));
vi.mock('@/components/silence-intervention', () => ({
  SilenceIntervention: ({ startedDay }: { startedDay: string }) => (
    <p>{`Silence intervention screen: started ${startedDay}`}</p>
  ),
}));
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
  Settings: ({
    onClose,
    onOpenMonthlyReport,
  }: {
    onClose: () => void;
    onOpenMonthlyReport: () => void;
  }) => (
    <div>
      <p>Settings screen</p>
      <button type="button" onClick={onClose}>
        Back to today
      </button>
      <button type="button" onClick={onOpenMonthlyReport}>
        Open monthly report
      </button>
    </div>
  ),
}));

// Story 5.4: a third screen in the same ternary chain, reached only from Settings.
vi.mock('@/components/monthly-report', () => ({
  MonthlyReport: ({ onClose }: { onClose: () => void }) => (
    <div>
      <p>Monthly report screen</p>
      <button type="button" onClick={onClose}>
        Back to today
      </button>
    </div>
  ),
}));

beforeEach(() => {
  profileRole = 'doer';
  nextReadIsDeferred = false;
  pendingRoleRead = null;
  activeSilenceEpisode = null;
  replace.mockClear();
});

describe('the app shell', () => {
  it('redirects a referee session to /referee and renders nothing of the doer screen', async () => {
    profileRole = 'referee';
    render(<Home />);

    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/referee'));
    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();
  });

  it("resets away from the previous account's role the instant a second account signs in, before the new read resolves", async () => {
    // u1 resolves to 'doer' immediately — the doer shell (Today, via its "Settings" stand-in)
    // is on screen and `role` holds a real, resolved value: 'doer', not 'unknown'.
    render(<Home />);
    expect(await screen.findByRole('button', { name: 'Settings' })).toBeInTheDocument();

    // Arm the *next* profile read to hang until this test resolves it by hand, then switch
    // straight to a second account with no sign-out between — `SignIn`'s own mock reports u2
    // via the same `onAccountChange` callback a real re-auth would use. If `app/page.tsx`'s
    // reset only ran inside the Effect that starts this second read (the shape this story's
    // review flagged, rather than the render-time guard that replaced it), `role` would still
    // read u1's resolved 'doer' for at least one more render — and the doer shell below would
    // still be on screen right here, one commit before this second read has any answer at all.
    nextReadIsDeferred = true;
    await userEvent.click(screen.getByRole('button', { name: 'Switch account' }));

    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();

    // Only now does the second read get an answer — u2 is the referee, and the redirect this
    // story exists to build completes.
    pendingRoleRead?.({ data: { role: 'referee' }, error: null });
    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/referee'));
  });

  it('renders the Silence intervention ahead of Today when an active episode exists', async () => {
    activeSilenceEpisode = { started_day: '2026-08-19' };
    render(<Home />);

    expect(
      await screen.findByText('Silence intervention screen: started 2026-08-19'),
    ).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();
  });

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

  it('opens the Monthly report from Settings and returns to Settings, not Today (Story 5.4)', async () => {
    render(<Home />);

    await userEvent.click(await screen.findByRole('button', { name: 'Settings' }));
    expect(await screen.findByText('Settings screen')).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Open monthly report' }));

    // The Monthly report is on screen, Settings' own content gone with it.
    expect(await screen.findByText('Monthly report screen')).toBeInTheDocument();
    expect(screen.queryByText('Settings screen')).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Back to today' }));

    // Closing it falls back to the prior screen (Settings, still open underneath), never
    // straight to Today — showSettings was never cleared by opening the report.
    expect(await screen.findByText('Settings screen')).toBeInTheDocument();
    expect(screen.queryByText('Monthly report screen')).not.toBeInTheDocument();
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
