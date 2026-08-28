import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeAppealDetail } from './referee-appeal-detail';

/**
 * The screen `components/referee-home.tsx`'s appeal list opens: the machine's own call, the
 * evidence, and the two ruling controls. `rule_appeal()` is the sole judge (AD-1) — this
 * component sends one RPC call and reads back whatever the database decided, including a
 * raced refusal, rather than pre-computing anything itself.
 *
 * The ruling's own outcome is read directly off this appeal's own `penalty` row, by its own
 * fixed `penalty_id` — the one legal exception to this codebase's one-door-per-table rule
 * (`lib/chain.test.ts`), granted by Story 4.5's own "penalty: referee reads day and week" RLS
 * policy. An earlier version compared the day's *current* settlement id against the one this
 * appeal points at ("moved" meant approved) — that broke the moment a second, independent
 * thing (a later Grace Day, Story 5.1, spent on a residual non-appealed miss) could also move
 * the same settlement. Reading this appeal's own fixed row sidesteps the whole class of bug:
 * its `state` is a permanent record of what happened to *this* appeal, immune to anything
 * that happens later to a *different* row on a *different* settlement. `penaltyEqSpy` proves
 * every read queries by this exact `penalty_id`, never anything derived from the day's
 * current settlement.
 */

const getUser = vi.fn();
const rpc = vi.fn();
const penaltyEqSpy = vi.fn();
const createSignedUrlSpy = vi.fn();

const PENALTY_ID = 'penalty-1';

let profileResult: unknown = { data: { role: 'referee' }, error: null };
let appealResult: unknown = {
  data: {
    id: 'appeal-1',
    for_day: '2026-08-18',
    deadline: '2026-08-20T00:00:00+07:00',
    penalty_id: PENALTY_ID,
    commitment: { name: 'TryHackMe' },
  },
  error: null,
};
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
      if (table === 'penalty') {
        // .select('state').eq('id', appealRow.penalty_id).maybeSingle()
        return {
          select: () => ({
            eq: (...args: unknown[]) => {
              penaltyEqSpy(...args);
              return { maybeSingle: () => Promise.resolve(penaltyResult) };
            },
          }),
        };
      }
      if (table === 'evidence') {
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
  penaltyEqSpy.mockClear();
  createSignedUrlSpy.mockClear();
  replace.mockClear();
  push.mockClear();
  profileResult = { data: { role: 'referee' }, error: null };
  appealResult = {
    data: {
      id: 'appeal-1',
      for_day: '2026-08-18',
      deadline: '2026-08-20T00:00:00+07:00',
      penalty_id: PENALTY_ID,
      commitment: { name: 'TryHackMe' },
    },
    error: null,
  };
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
        for_day: '2026-08-18',
        deadline: '2026-08-20T00:00:00+07:00',
        penalty_id: PENALTY_ID,
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

  it('reloads and shows the resolved outcome once approval succeeds', async () => {
    renderDetail();
    await screen.findByRole('button', { name: 'He did it' });

    // rule_appeal(true) moves this appeal's own penalty row to `voided`, unconditionally —
    // 20260825090000_the_referee_rules.sql.
    penaltyResult = { data: { state: 'voided' }, error: null };
    penaltyEqSpy.mockClear();
    fireEvent.click(screen.getByRole('button', { name: 'He did it' }));

    expect(await screen.findByText('Voided. He has been notified.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
    expect(penaltyEqSpy).toHaveBeenCalledWith('id', PENALTY_ID);
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
  it('shows the voided outcome, with no ruling controls', async () => {
    penaltyResult = { data: { state: 'voided' }, error: null };
    renderDetail();

    expect(await screen.findByText('Voided. He has been notified.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: "He didn't" })).not.toBeInTheDocument();
    expect(penaltyEqSpy).toHaveBeenCalledWith('id', PENALTY_ID);
  });

  it('shows the owed outcome, with no ruling controls', async () => {
    penaltyResult = { data: { state: 'owed' }, error: null };
    renderDetail();

    expect(await screen.findByText('Converted to owed. He has been notified.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
  });

  it('shows the collected outcome, with no ruling controls (Story 4.7)', async () => {
    // Reachable: rule_appeal(false) rejects the appeal (owed), then the referee later marks
    // that same Penalty Collected from the "Owed penalties" list — a bookmark, browser back,
    // or simply reopening this screen afterward lands here. Without a branch for this state
    // the outcome area silently went blank (no case, no fallback).
    penaltyResult = { data: { state: 'collected' }, error: null };
    renderDetail();

    expect(
      await screen.findByText('Collected. The referee marked this debt paid.'),
    ).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: "He didn't" })).not.toBeInTheDocument();
  });

  it('shows a failed state when this appeal’s own penalty row cannot be found', async () => {
    penaltyResult = { data: null, error: null };
    renderDetail();

    expect(
      await screen.findByText("This appeal's own Penalty could not be found."),
    ).toBeInTheDocument();
  });
});

describe('an approved appeal whose corrected day has a residual, non-appealed miss (Story 5.1)', () => {
  it('still reads voided even after that residual amount is later spent as a Grace Day on a different settlement/penalty row', async () => {
    // rule_appeal(true) sets *this* appeal's own penalty_id row to `voided`
    // unconditionally (20260825090000_the_referee_rules.sql) — regardless of whether a
    // second, non-appealed miss the same day leaves the correction itself still `failed`
    // with its own fresh, `owed` penalty on a *different* settlement/penalty row. If that
    // residual amount is later forgiven by a Grace Day, apply_grace_days() only ever
    // touches that other row — never this appeal's own, which stays `voided` forever
    // (append-only, AD-9). This is exactly the case the old settlement-comparison approach
    // got wrong: it would have seen the day's settlement move (again) and had no way to
    // tell that move apart from a rejection later graced. Reading this exact row by its
    // own fixed penalty_id sidesteps the whole class of bug.
    penaltyResult = { data: { state: 'voided' }, error: null };
    renderDetail();

    expect(await screen.findByText('Voided. He has been notified.')).toBeInTheDocument();
    expect(
      screen.queryByText(
        'Converted to owed. He has been notified. The day was later forgiven by a Grace Day, unrelated to this appeal.',
      ),
    ).not.toBeInTheDocument();
    expect(penaltyEqSpy).toHaveBeenCalledWith('id', PENALTY_ID);
  });
});

describe('a rejected appeal later forgiven by an unrelated Grace Day (Story 5.1)', () => {
  it('never claims approved, and says the day was later forgiven instead', async () => {
    // rule_appeal(false) ("He didn't") leaves this appeal's own penalty row `owed` — it
    // never moves to a new settlement at all (Story 4.6's own boundary). A later Grace Day
    // spent on the same day can only ever reach this exact row if it was still owed at
    // fold-in time — grace_day_validate()'s own Never boundary excludes a `held` Penalty,
    // so a Grace Day can never land on a day still under open appeal — and
    // apply_grace_days() then waives it.
    penaltyResult = { data: { state: 'waived' }, error: null };
    renderDetail();

    expect(
      await screen.findByText(
        'Converted to owed. He has been notified. The day was later forgiven by a Grace Day, unrelated to this appeal.',
      ),
    ).toBeInTheDocument();
    // The false claim this fix exists to prevent.
    expect(screen.queryByText('Voided. He has been notified.')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'He did it' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: "He didn't" })).not.toBeInTheDocument();
    expect(penaltyEqSpy).toHaveBeenCalledWith('id', PENALTY_ID);
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
