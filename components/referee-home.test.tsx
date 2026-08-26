import { fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeHome } from './referee-home';

/**
 * The Referee's home surface: a count and a total of owed penalties, a real list of pending
 * appeals (Story 4.6), a real list of owed penalties with a copy-message and Mark Collected
 * control each (Story 4.7), and the two redirects that keep the wrong session off it. RLS
 * (AD-7) is the actual boundary for `penalty_current` and the `appeal` read behind both
 * lists — they already return nothing to anyone but a `role = 'referee'` session. The
 * missed-commitment names instead come from `referee_missed_commitments()`, a `security
 * definer` RPC that filters to `role_from_table() = 'referee'` rather than an RLS policy
 * (Story 4.5's `chain_current` regression — see the migration's own header), and
 * `mark_penalty_collected()` checks the same role itself before any row is read. What is
 * asserted here is that this screen reads what those functions/RLS already scope, renders
 * no ruling control or per-penalty detail route of its own (ruling lives on the detail
 * screen; a Penalty needs nothing beyond its own list row), and gets a doer or a signed-out
 * visitor off the screen without rendering the real content first.
 */

const getUser = vi.fn();
const signOut = vi.fn();
const rpc = vi.fn();
let profileResult: unknown = { data: { role: 'referee' }, error: null };
let penaltyResult: unknown = { data: [], error: null };
let appealResult: unknown = { data: [], error: null };
let missedCommitmentsResult: unknown = { data: [], error: null };
let markCollectedResult: unknown = { data: null, error: null };
// Story 5.3 — the escalated "gone quiet" episode, if any. Empty by default: most tests never
// see this row, the same way most never see an owed penalty.
let silenceResult: unknown = { data: [], error: null };

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
      if (table === 'silence_episode') {
        // `.select().is().not().order().limit()` — the last call in the chain resolves,
        // matching the shape `components/referee-home.tsx` actually builds.
        return {
          select: () => ({
            is: () => ({
              not: () => ({
                order: () => ({ limit: () => Promise.resolve(silenceResult) }),
              }),
            }),
          }),
        };
      }
      // penalty_current — no `.maybeSingle()`, a bare `.select()` resolves directly,
      // matching how `ledger.tsx`'s own `from(...).select(...)` reads behave.
      return { select: () => Promise.resolve(penaltyResult) };
    },
    // Both RPCs this screen calls go through here — dispatched by name, since
    // `referee_missed_commitments` (a read, resolved on load) and
    // `mark_penalty_collected` (a write, resolved on a click) need independent results.
    rpc: (name: string, ...args: unknown[]) => {
      rpc(name, ...args);
      if (name === 'referee_missed_commitments') {
        return Promise.resolve(missedCommitmentsResult);
      }
      return Promise.resolve(markCollectedResult);
    },
  }),
}));

const replace = vi.fn();
const push = vi.fn();
// A single, stable object — real `next/navigation`'s own useRouter() returns a stable
// reference across renders (it does not create a new object every call). A mock that
// returned `{ replace, push }` fresh each call would make useEffect's own `[router,
// reloadToken]` dependency array look changed on every render, re-triggering the effect
// indefinitely (findByText/waitFor assertions still pass because they resolve before that
// runaway settles — RTL's own automatic unmount between tests is what actually stops it) —
// an artifact of an inaccurate mock, never reachable in the real app.
const router = { replace, push };
vi.mock('next/navigation', () => ({
  useRouter: () => router,
}));

beforeEach(() => {
  getUser.mockResolvedValue({ data: { user: { id: 'ref-1' } }, error: null });
  signOut.mockResolvedValue({ error: null });
  profileResult = { data: { role: 'referee' }, error: null };
  penaltyResult = { data: [], error: null };
  appealResult = { data: [], error: null };
  missedCommitmentsResult = { data: [], error: null };
  markCollectedResult = { data: null, error: null };
  silenceResult = { data: [], error: null };
  rpc.mockClear();
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

  it('shows a count and a total of owed penalties, no matter the kind', async () => {
    penaltyResult = {
      data: [
        { state: 'held', amount_dong: 500_000, kind: 'day' },
        {
          id: 'penalty-week-1',
          state: 'owed',
          amount_dong: 500_000,
          kind: 'week',
          period: '2026-08-17',
          settlement_id: 'settlement-week-1',
          created_at: '2026-08-17T00:00:00Z',
        },
        {
          id: 'penalty-day-1',
          state: 'owed',
          amount_dong: 500_000,
          kind: 'day',
          period: '2026-08-18',
          settlement_id: 'settlement-day-1',
          created_at: '2026-08-18T00:00:00Z',
        },
      ],
      error: null,
    };
    render(<RefereeHome />);

    expect(await screen.findByText('1 appeal pending.')).toBeInTheDocument();
    expect(screen.getByText(/2 penalties owed, 1.000.000₫ total\./)).toBeInTheDocument();

    // Never a ruling control on this screen itself — that lives on the appeal detail screen.
    expect(screen.queryByText(/He did it/)).not.toBeInTheDocument();
    expect(screen.queryByText(/He didn't/)).not.toBeInTheDocument();
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

describe('the owed penalties list (Story 4.7)', () => {
  const owedRow = {
    id: 'penalty-1',
    state: 'owed',
    amount_dong: 500_000,
    kind: 'day',
    period: '2026-08-18',
    settlement_id: 'settlement-1',
    created_at: '2026-08-18T00:00:00Z',
  };

  beforeEach(() => {
    // jsdom does not implement navigator.clipboard by default — this is the first
    // clipboard use in the codebase (Boundaries). Every test below either defines it, or
    // deliberately removes/rejects it to prove the failure path.
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText: vi.fn().mockResolvedValue(undefined) },
    });
  });

  it('shows the amount, the day (with its year), and the commitment(s) missed, no composition required', async () => {
    penaltyResult = { data: [owedRow], error: null };
    missedCommitmentsResult = {
      data: [{ settlement_id: 'settlement-1', commitment_name: 'TryHackMe' }],
      error: null,
    };
    render(<RefereeHome />);

    expect(await screen.findByText('Owed penalties')).toBeInTheDocument();
    expect(screen.getByText('500.000₫ — TryHackMe')).toBeInTheDocument();
    // formatOwedDay, not formatDeadline — an owed Penalty persists indefinitely, so the day
    // carries its year, unlike the appeals list's own bare "Aug 18" above.
    expect(screen.getByText('Aug 18, 2026')).toBeInTheDocument();
  });

  it('dedupes commitment names — two settlement_commitment rows naming the same commitment render once', async () => {
    penaltyResult = { data: [owedRow], error: null };
    missedCommitmentsResult = {
      data: [
        { settlement_id: 'settlement-1', commitment_name: 'Reading' },
        { settlement_id: 'settlement-1', commitment_name: 'Reading' },
      ],
      error: null,
    };
    render(<RefereeHome />);

    expect(await screen.findByText('500.000₫ — Reading')).toBeInTheDocument();
  });

  it('names every missed commitment, joined — never just the first', async () => {
    penaltyResult = { data: [owedRow], error: null };
    missedCommitmentsResult = {
      data: [
        { settlement_id: 'settlement-1', commitment_name: 'TryHackMe' },
        { settlement_id: 'settlement-1', commitment_name: 'Gym' },
      ],
      error: null,
    };
    render(<RefereeHome />);

    expect(await screen.findByText('500.000₫ — Gym, TryHackMe')).toBeInTheDocument();
  });

  it('orders the list oldest first', async () => {
    penaltyResult = {
      data: [
        {
          ...owedRow,
          id: 'penalty-newer',
          period: '2026-08-20',
          settlement_id: 's-newer',
          created_at: '2026-08-20T00:00:00Z',
        },
        {
          ...owedRow,
          id: 'penalty-older',
          period: '2026-08-15',
          settlement_id: 's-older',
          created_at: '2026-08-15T00:00:00Z',
        },
      ],
      error: null,
    };
    render(<RefereeHome />);

    await screen.findByText('Owed penalties');
    const days = screen.getAllByText(/^Aug \d+, 2026$/).map((el) => el.textContent);
    expect(days).toEqual(['Aug 15, 2026', 'Aug 20, 2026']);
  });

  it('excludes a Held Penalty — invisible on the list until it is ruled on', async () => {
    penaltyResult = { data: [{ ...owedRow, state: 'held' }], error: null };
    render(<RefereeHome />);

    await screen.findByText(/appeal pending/);
    expect(screen.queryByText('Owed penalties')).not.toBeInTheDocument();
  });

  it('copies the pre-written message unchanged onto the clipboard', async () => {
    penaltyResult = { data: [owedRow], error: null };
    render(<RefereeHome />);

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Copy collection message for A commitment, Aug 18, 2026',
      }),
    );

    await vi.waitFor(() =>
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
        "todoapp says you owe 500.000₫ for Aug 18, 2026. I'm just the one collecting it. When are you free?",
      ),
    );
    expect(await screen.findByText('Copied.')).toBeInTheDocument();
  });

  it('shows a status message when the clipboard write is rejected — never silence', async () => {
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText: vi.fn().mockRejectedValue(new Error('denied')) },
    });
    penaltyResult = { data: [owedRow], error: null };
    render(<RefereeHome />);

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Copy collection message for A commitment, Aug 18, 2026',
      }),
    );

    expect(await screen.findByText('Could not copy the message.')).toBeInTheDocument();
  });

  it('shows the same status message when the clipboard API is unsupported entirely', async () => {
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: undefined });
    penaltyResult = { data: [owedRow], error: null };
    render(<RefereeHome />);

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Copy collection message for A commitment, Aug 18, 2026',
      }),
    );

    expect(await screen.findByText('Could not copy the message.')).toBeInTheDocument();
  });

  it('marks a Penalty collected — the row leaves the list once it reloads', async () => {
    penaltyResult = { data: [owedRow], error: null };
    render(<RefereeHome />);

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Mark collected for A commitment, Aug 18, 2026',
      }),
    );

    expect(rpc).toHaveBeenCalledWith('mark_penalty_collected', { p_penalty_id: 'penalty-1' });

    // Success reloads — the next read reflects the penalty no longer owed.
    penaltyResult = { data: [], error: null };
    await vi.waitFor(() => expect(screen.queryByText('Owed penalties')).not.toBeInTheDocument());
  });

  it('keeps the button disabled through the reload a successful Mark Collected triggers, not just until the RPC call itself resolves', async () => {
    // penaltyResult is deliberately never changed after the click, so the reload re-fetches
    // the identical still-owed row — the same button stays rendered throughout. The old bug
    // reset this row's own status to 'idle' as soon as the mark_penalty_collected call alone
    // resolved, well before the reload replaced anything — a window where a second click
    // would race the reload and hit the server's own "already resolved" guard right after a
    // real success.
    penaltyResult = { data: [owedRow], error: null };
    render(<RefereeHome />);

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Mark collected for A commitment, Aug 18, 2026',
      }),
    );

    // Wait for the reload's own second pass to have reached referee_missed_commitments() —
    // well past the point where mark_penalty_collected's own call already resolved.
    await vi.waitFor(() =>
      expect(rpc.mock.calls.filter((call) => call[0] === 'referee_missed_commitments').length).toBe(
        2,
      ),
    );

    expect(
      screen.getByRole('button', { name: 'Mark collected for A commitment, Aug 18, 2026' }),
    ).toBeDisabled();
  });

  it('shows the server’s own refusal and keeps the row — never a silent disappearance', async () => {
    penaltyResult = { data: [owedRow], error: null };
    markCollectedResult = {
      data: null,
      error: {
        message: 'This penalty has already been resolved -- collected already, or no longer owed.',
      },
    };
    render(<RefereeHome />);

    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Mark collected for A commitment, Aug 18, 2026',
      }),
    );

    expect(
      await screen.findByText(
        'This penalty has already been resolved -- collected already, or no longer owed.',
      ),
    ).toBeInTheDocument();
    // The row is still there — a refusal is surfaced, never a row that quietly vanished.
    expect(screen.getByText('Owed penalties')).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: 'Mark collected for A commitment, Aug 18, 2026' }),
    ).toBeInTheDocument();
  });

  it('gives each row a distinguishing accessible name for both controls', async () => {
    penaltyResult = {
      data: [
        owedRow,
        {
          ...owedRow,
          id: 'penalty-2',
          period: '2026-08-17',
          settlement_id: 's-2',
          created_at: '2026-08-17T00:00:00Z',
        },
      ],
      error: null,
    };
    render(<RefereeHome />);

    await screen.findByText('Owed penalties');
    expect(
      screen.getByRole('button', {
        name: 'Copy collection message for A commitment, Aug 17, 2026',
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('button', {
        name: 'Copy collection message for A commitment, Aug 18, 2026',
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: 'Mark collected for A commitment, Aug 17, 2026' }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: 'Mark collected for A commitment, Aug 18, 2026' }),
    ).toBeInTheDocument();
  });

  it('distinguishes two rows that share the same day (two different doer accounts) by commitment name', async () => {
    // The list is not scoped to one doer account — RLS grants the referee every account's
    // own Penalties (Story 4.5) — so two different accounts can each owe a same-day Penalty.
    // The day alone would render an identical accessible name for both.
    penaltyResult = {
      data: [owedRow, { ...owedRow, id: 'penalty-other-account', settlement_id: 'settlement-2' }],
      error: null,
    };
    missedCommitmentsResult = {
      data: [
        { settlement_id: 'settlement-1', commitment_name: 'TryHackMe' },
        { settlement_id: 'settlement-2', commitment_name: 'Gym' },
      ],
      error: null,
    };
    render(<RefereeHome />);

    await screen.findByText('Owed penalties');
    expect(
      screen.getByRole('button', { name: 'Copy collection message for TryHackMe, Aug 18, 2026' }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: 'Copy collection message for Gym, Aug 18, 2026' }),
    ).toBeInTheDocument();
  });

  it('includes a week-kind owed Penalty too — collectible, not merely counted (Story 3.4)', async () => {
    // Week Close (3.4, a Weekly Quota commitment failing its week) can also leave a Penalty
    // owed. Excluding it from this list would leave it counted in the summary above with no
    // control anywhere in the UI that could ever discharge it — uncollectable forever,
    // contradicting "the only way the debt is discharged... never written off automatically".
    const weekRow = {
      id: 'penalty-week-1',
      state: 'owed',
      amount_dong: 500_000,
      kind: 'week',
      period: '2026-08-17',
      settlement_id: 'settlement-week-1',
      created_at: '2026-08-17T00:00:00Z',
    };
    penaltyResult = { data: [weekRow], error: null };
    render(<RefereeHome />);

    // Week Close freezes no per-commitment outcome (lib/ledger.ts's own "Never") — the row
    // falls back to a generic label, an honest reflection of what a week-kind Penalty
    // actually has to name, rather than a fabricated commitment list. The week's own period
    // still renders as the day (with its year), same as any other row.
    expect(await screen.findByText('500.000₫ — A commitment')).toBeInTheDocument();
    expect(screen.getByText('Aug 17, 2026')).toBeInTheDocument();

    // A week-kind settlement id is never even asked about — referee_missed_commitments()
    // is never called at all when nothing day-kind is owed.
    await screen.findByText('500.000₫ — A commitment');
    expect(rpc).not.toHaveBeenCalledWith('referee_missed_commitments', expect.anything());

    // And it is just as collectible as any day-kind row.
    fireEvent.click(
      await screen.findByRole('button', {
        name: 'Mark collected for A commitment, Aug 17, 2026',
      }),
    );
    expect(rpc).toHaveBeenCalledWith('mark_penalty_collected', {
      p_penalty_id: 'penalty-week-1',
    });
  });

  it('asks referee_missed_commitments() about only the day-kind ids among a mixed list', async () => {
    const weekRow = {
      id: 'penalty-week-1',
      state: 'owed',
      amount_dong: 500_000,
      kind: 'week',
      period: '2026-08-17',
      settlement_id: 'settlement-week-1',
      created_at: '2026-08-17T00:00:00Z',
    };
    penaltyResult = { data: [owedRow, weekRow], error: null };
    render(<RefereeHome />);

    await screen.findByText('Owed penalties');
    // Both rows render...
    expect(screen.getByText('Aug 17, 2026')).toBeInTheDocument();
    expect(screen.getByText('Aug 18, 2026')).toBeInTheDocument();

    // ...but the function is only ever asked about the day-kind settlement, never the
    // week-kind one (which has no per-commitment rows to find anyway).
    await vi.waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('referee_missed_commitments', {
        p_settlement_ids: ['settlement-1'],
      }),
    );
  });
});

describe('the gone-quiet state (Story 5.3, FR-18)', () => {
  // A frozen clock, the same shape `morning-gate.test.tsx` uses — `daysSinceQuiet` reads
  // `new Date()` inside the component, and a real clock would make the day count this test
  // asserts drift with whatever day it happens to run on. 10:00 on the 23rd makes asked_day
  // (yesterday, in the fixed zone — `daysSinceQuiet`'s own reference point, matching
  // `enqueue_gate_reminders()`'s `local_now::date - 1`) the 22nd, so a `started_day` of the
  // 19th below reads 4 — the same figure the SQL formula would produce for the same instant.
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date('2026-08-23T10:00:00+07:00'));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('names the day count, alongside existing content rather than instead of it', async () => {
    penaltyResult = { data: [{ state: 'held', amount_dong: 500_000 }], error: null };
    silenceResult = { data: [{ started_day: '2026-08-19' }], error: null };
    render(<RefereeHome />);

    expect(await screen.findByText('1 appeal pending.')).toBeInTheDocument();
    expect(
      screen.getByText(
        "He hasn't opened this in 4 days. Nothing needs deciding — but he'd probably " +
          'rather hear from you than from the app.',
      ),
    ).toBeInTheDocument();
  });

  it('renders nothing when no episode has been escalated', async () => {
    render(<RefereeHome />);
    await screen.findByText(/Nothing for you right now/);

    expect(screen.queryByText(/hasn't opened this/)).not.toBeInTheDocument();
  });

  it('renders even when nothing else is pending or owed — it is not a new queue item', async () => {
    silenceResult = { data: [{ started_day: '2026-08-19' }], error: null };
    render(<RefereeHome />);

    expect(await screen.findByText(/hasn't opened this in 4 days/)).toBeInTheDocument();
    // The empty-state copy still renders too — the gone-quiet state coexists with it rather
    // than replacing it (Boundaries: "adds nothing to his queues" is not the same claim as
    // "the screen has nothing else to say").
    expect(screen.getByText(/Nothing for you right now/)).toBeInTheDocument();
  });

  it('names no amount and no commitment, and offers no action control', async () => {
    silenceResult = { data: [{ started_day: '2026-08-19' }], error: null };
    render(<RefereeHome />);

    const message = await screen.findByText(/hasn't opened this/);
    expect(message).toHaveTextContent('4 days');
    expect(message.textContent).not.toMatch(/₫/);
    // Only the pre-existing "Sign out" control exists on this screen when nothing else is
    // pending or owed — the gone-quiet state itself renders no button of its own.
    expect(screen.getAllByRole('button').map((b) => b.textContent)).toEqual(['Sign out']);
  });

  it('clears once the episode is satisfied — the RLS read simply returns nothing', async () => {
    // No fixture stamps escalated_at is not null and satisfied_at is null once a Declaration
    // lands (5.2's own trigger) — the policy itself stops matching the row, so the query
    // this component runs comes back empty exactly as it does by default here.
    silenceResult = { data: [], error: null };
    render(<RefereeHome />);
    await screen.findByText(/Nothing for you right now/);

    expect(screen.queryByText(/hasn't opened this/)).not.toBeInTheDocument();
  });
});
