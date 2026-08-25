import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeAppealDetail } from './referee-appeal-detail';

/**
 * The screen `components/referee-home.tsx`'s appeal list opens: the machine's own call, the
 * evidence, and the two ruling controls. `rule_appeal()` is the sole judge (AD-1) — this
 * component sends one RPC call and reads back whatever the database decided, including a
 * raced refusal, rather than pre-computing anything itself.
 *
 * The ruling's own outcome is read through `settlement_current`/`penalty_current` — never
 * `.from('penalty')` directly (this codebase's one-door-per-table rule, `lib/chain.test.ts`)
 * — by comparing the day's current settlement id against the one the appeal itself points
 * at: unchanged means the appeal's own Penalty still stands (held/owed/dropped); changed
 * means the ruling's own correction superseded it (voided). `settlementResult`/
 * `penaltyResult` below stand in for that pair of reads. Approved is a fact about the appeal
 * regardless of what the corrected day ends up owing, so the `penalty_current` read is
 * skipped entirely on that path — `penaltyCurrentEqSpy` proves it.
 */

const getUser = vi.fn();
const rpc = vi.fn();
const penaltyCurrentEqSpy = vi.fn();
const createSignedUrlSpy = vi.fn();

const ORIGINAL_SETTLEMENT = 'settlement-1';
const CORRECTION_SETTLEMENT = 'settlement-2';

let profileResult: unknown = { data: { role: 'referee' }, error: null };
let appealResult: unknown = {
  data: {
    id: 'appeal-1',
    owner_id: 'owner-1',
    for_day: '2026-08-18',
    deadline: '2026-08-20T00:00:00+07:00',
    settlement_id: ORIGINAL_SETTLEMENT,
    commitment: { name: 'TryHackMe' },
  },
  error: null,
};
let settlementResult: unknown = { data: { id: ORIGINAL_SETTLEMENT }, error: null };
let penaltyResult: unknown = { data: { state: 'held' }, error: null };
let evidenceResult: unknown = { data: [], error: null };
let signedUrlResult: unknown = {
  data: { signedUrl: 'https://storage.example.test/signed/proof.jpg' },
  error: null,
};
let rpcResult: unknown = { data: null, error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    auth: { getUser },
    from: (table: string) => {
      if (table === 'profile') {
        return { select: () => ({ maybeSingle: () => Promise.resolve(profileResult) }) };
      }
      if (table === 'appeal') {
        return {
          select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve(appealResult) }) }),
        };
      }
      if (table === 'settlement_current') {
        // .select().eq('subject', ...).eq('period', ...).eq('kind', 'day').maybeSingle()
        const query = {
          eq: () => query,
          maybeSingle: () => Promise.resolve(settlementResult),
        };
        return { select: () => query };
      }
      if (table === 'penalty_current') {
        return {
          select: () => ({
            eq: (...args: unknown[]) => {
              penaltyCurrentEqSpy(...args);
              return { maybeSingle: () => Promise.resolve(penaltyResult) };
            },
          }),
        };
      }
      if (table === 'appeal_evidence') {
        return { select: () => ({ eq: () => Promise.resolve(evidenceResult) }) };
      }
      throw new Error(`referee-appeal-detail.test.tsx: unexpected table ${table}`);
    },
    storage: {
      from: () => ({
        createSignedUrl: (...args: unknown[]) => {
          createSignedUrlSpy(...args);
          return Promise.resolve(signedUrlResult);
        },
      }),
    },
    rpc: (...args: unknown[]) => {
      rpc(...args);
      return Promise.resolve(rpcResult);
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
  rpc.mockClear();
  penaltyCurrentEqSpy.mockClear();
  createSignedUrlSpy.mockClear();
  replace.mockClear();
  push.mockClear();
  profileResult = { data: { role: 'referee' }, error: null };
  appealResult = {
    data: {
      id: 'appeal-1',
      owner_id: 'owner-1',
      for_day: '2026-08-18',
      deadline: '2026-08-20T00:00:00+07:00',
      settlement_id: ORIGINAL_SETTLEMENT,
      commitment: { name: 'TryHackMe' },
    },
    error: null,
  };
  settlementResult = { data: { id: ORIGINAL_SETTLEMENT }, error: null };
  penaltyResult = { data: { state: 'held' }, error: null };
  evidenceResult = { data: [], error: null };
  signedUrlResult = {
    data: { signedUrl: 'https://storage.example.test/signed/proof.jpg' },
    error: null,
  };
  rpcResult = { data: null, error: null };
});

function renderDetail() {
  return render(<RefereeAppealDetail appealId="appeal-1" />);
}

describe('the machine’s call', () => {
  it('names the commitment and the day, generic and honest', async () => {
    renderDetail();
    expect(
      await screen.findByText('TryHackMe, 2026-08-18. Account elsewhere reported a miss.'),
    ).toBeInTheDocument();
    expect(screen.getByText('500.000₫')).toBeInTheDocument();
  });

  it('falls back to a generic name when the joined commitment cannot be read', async () => {
    appealResult = {
      data: {
        id: 'appeal-1',
        owner_id: 'owner-1',
        for_day: '2026-08-18',
        deadline: '2026-08-20T00:00:00+07:00',
        settlement_id: ORIGINAL_SETTLEMENT,
        commitment: null,
      },
      error: null,
    };
    renderDetail();
    expect(
      await screen.findByText('A commitment, 2026-08-18. Account elsewhere reported a miss.'),
    ).toBeInTheDocument();
  });
});

describe('evidence', () => {
  it('says none is attached when there is none', async () => {
    renderDetail();
    expect(await screen.findByText('No evidence attached.')).toBeInTheDocument();
  });

  it('loads each attached item through a signed URL, with an hour-long TTL', async () => {
    evidenceResult = {
      data: [{ id: 'evidence-1', storage_path: 'appeal-1/proof.jpg' }],
      error: null,
    };
    renderDetail();

    const image = await screen.findByAltText(
      'Evidence photo 1 of 1 the doer submitted with this appeal.',
    );
    expect(image).toHaveAttribute('src', 'https://storage.example.test/signed/proof.jpg');
    // Long enough for an actual review, not the one-minute window a reviewer flagged as
    // failing mid-review with no explanation.
    expect(createSignedUrlSpy).toHaveBeenCalledWith('appeal-1/proof.jpg', 3600);
  });

  it('numbers each attachment distinctly for a screen-reader user', async () => {
    evidenceResult = {
      data: [
        { id: 'evidence-1', storage_path: 'appeal-1/one.jpg' },
        { id: 'evidence-2', storage_path: 'appeal-1/two.jpg' },
      ],
      error: null,
    };
    renderDetail();

    expect(
      await screen.findByAltText('Evidence photo 1 of 2 the doer submitted with this appeal.'),
    ).toBeInTheDocument();
    expect(
      screen.getByAltText('Evidence photo 2 of 2 the doer submitted with this appeal.'),
    ).toBeInTheDocument();
  });

  it('surfaces a note when signing fails, rather than silently shrinking the list', async () => {
    evidenceResult = {
      data: [
        { id: 'evidence-1', storage_path: 'appeal-1/one.jpg' },
        { id: 'evidence-2', storage_path: 'appeal-1/two.jpg' },
      ],
      error: null,
    };
    signedUrlResult = { data: null, error: { message: 'signing failed' } };
    renderDetail();

    expect(await screen.findByText('2 evidence items could not be loaded.')).toBeInTheDocument();
    // Never conflated with "nothing was ever attached" — that would hide the failure.
    expect(screen.queryByText('No evidence attached.')).not.toBeInTheDocument();
  });

  it('uses singular phrasing for exactly one failure', async () => {
    evidenceResult = {
      data: [{ id: 'evidence-1', storage_path: 'appeal-1/one.jpg' }],
      error: null,
    };
    signedUrlResult = { data: null, error: { message: 'signing failed' } };
    renderDetail();

    expect(await screen.findByText('1 evidence item could not be loaded.')).toBeInTheDocument();
  });
});

describe('a Held Penalty, awaiting ruling', () => {
  it('offers both controls and the timeout note, written for the referee', async () => {
    renderDetail();

    expect(await screen.findByRole('button', { name: 'He did it' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: "He didn't" })).toBeInTheDocument();
    expect(
      screen.getByText("Ignore this and it's dropped in his favor on Aug 20."),
    ).toBeInTheDocument();
  });

  it('calls rule_appeal(true) for "He did it"', async () => {
    renderDetail();
    fireEvent.click(await screen.findByRole('button', { name: 'He did it' }));

    expect(rpc).toHaveBeenCalledWith('rule_appeal', {
      p_appeal_id: 'appeal-1',
      p_approved: true,
    });
  });

  it('calls rule_appeal(false) for "He didn\'t"', async () => {
    renderDetail();
    fireEvent.click(await screen.findByRole('button', { name: "He didn't" }));

    expect(rpc).toHaveBeenCalledWith('rule_appeal', {
      p_appeal_id: 'appeal-1',
      p_approved: false,
    });
  });

  it('reloads and shows the resolved outcome once approval succeeds, skipping the penalty_current read entirely', async () => {
    renderDetail();
    await screen.findByRole('button', { name: 'He did it' });

    // Approval superseded the day's own settlement with a correction — the day happens to
    // read clean afterward, but "voided" follows from the settlement having moved, not from
    // that.
    settlementResult = { data: { id: CORRECTION_SETTLEMENT }, error: null };
    penaltyCurrentEqSpy.mockClear();
    fireEvent.click(screen.getByRole('button', { name: 'He did it' }));

    expect(await screen.findByText('Voided. He has been notified.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
    // Approved is a fact about this appeal regardless of what the corrected day ends up
    // owing — nothing the penalty_current read could answer is used, so it must not run.
    expect(penaltyCurrentEqSpy).not.toHaveBeenCalled();
  });

  it('still reads voided when a different, non-appealed miss leaves the corrected day owing', async () => {
    renderDetail();
    await screen.findByRole('button', { name: 'He did it' });

    settlementResult = { data: { id: CORRECTION_SETTLEMENT }, error: null };
    fireEvent.click(screen.getByRole('button', { name: 'He did it' }));

    expect(await screen.findByText('Voided. He has been notified.')).toBeInTheDocument();
  });

  it('reloads and shows the resolved outcome once rejection succeeds', async () => {
    renderDetail();
    await screen.findByRole('button', { name: "He didn't" });

    penaltyResult = { data: { state: 'owed' }, error: null };
    fireEvent.click(screen.getByRole('button', { name: "He didn't" }));

    expect(await screen.findByText('Converted to owed. He has been notified.')).toBeInTheDocument();
  });

  it('shows the server’s own refusal verbatim on a raced ruling, and reloads to the state it actually resolved to', async () => {
    renderDetail();
    await screen.findByRole('button', { name: 'He did it' });

    rpcResult = {
      data: null,
      error: {
        message: 'This appeal has already been resolved -- by an earlier ruling or by timing out.',
      },
    };
    penaltyResult = { data: { state: 'dropped' }, error: null };

    fireEvent.click(screen.getByRole('button', { name: 'He did it' }));

    expect(
      await screen.findByText(
        'This one is no longer open — it timed out and dropped in his favor before you got to it.',
      ),
    ).toBeInTheDocument();
  });
});

describe('an already-resolved appeal', () => {
  it('shows the voided outcome, with no ruling controls, and never reads penalty_current', async () => {
    settlementResult = { data: { id: CORRECTION_SETTLEMENT }, error: null };
    renderDetail();

    expect(await screen.findByText('Voided. He has been notified.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: "He didn't" })).not.toBeInTheDocument();
    expect(penaltyCurrentEqSpy).not.toHaveBeenCalled();
  });

  it('shows the owed outcome, with no ruling controls', async () => {
    penaltyResult = { data: { state: 'owed' }, error: null };
    renderDetail();

    expect(await screen.findByText('Converted to owed. He has been notified.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
  });
});

describe('access', () => {
  it('sends a signed-out visitor to the referee login', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: null });
    renderDetail();

    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/referee/login'));
  });

  it('sends a doer session away rather than rendering the ruling screen for it', async () => {
    profileResult = { data: { role: 'doer' }, error: null };
    renderDetail();

    await vi.waitFor(() => expect(replace).toHaveBeenCalledWith('/'));
    expect(screen.queryByText('TryHackMe')).not.toBeInTheDocument();
  });

  it('shows a not-found state when the appeal does not exist or is not the referee’s to read', async () => {
    appealResult = { data: null, error: null };
    renderDetail();

    expect(
      await screen.findByText('No such appeal, or it is no longer yours to read.'),
    ).toBeInTheDocument();
  });
});

describe('navigation', () => {
  it('goes back to the referee home', async () => {
    renderDetail();
    fireEvent.click(await screen.findByRole('button', { name: 'Back to appeals' }));
    expect(push).toHaveBeenCalledWith('/referee');
  });
});
