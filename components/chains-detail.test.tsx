import { act, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ChainsDetail } from './chains-detail';
import { EVIDENCE_COPY } from '@/lib/evidence';

/**
 * The Chains detail — the surface Epic 2's retrospective found reading a base table (A2).
 *
 * The fix was a view; this is the guard on the client side of it, and it is deliberately about
 * *which door the component knocks on* as much as what it draws. `lib/chain.test.ts` fails the
 * build on any shipped file containing `.from('settlement_commitment')`, which catches the
 * spelling; this catches the shape — the columns asked for, and the filter applied.
 *
 * The rest is what the surface exists for: a broken chain read against a record rather than
 * against zero, and a history of failures that must not become a wall of red on the day it is
 * most likely to be opened.
 */

const rows: Record<string, unknown> = {};
const seen: { table: string; columns: string; column?: string; value?: unknown }[] = [];
/** Story 6.9: what `createSignedUrls` comes back with, per storage path. Anything absent signs
 *  cleanly. */
let signedByPath: Record<string, unknown> = {};
const signCalls: Array<{ paths: string[]; ttl: number }> = [];
/** Held open by a test that needs the signing round trip to still be in flight while it looks
 *  at the screen. Null means signing resolves immediately, which is what every other test
 *  here wants. */
let holdSigning: Promise<void> | null = null;

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => ({
      // Chainable, and only then awaitable. Story 6.9's evidence read filters on two columns,
      // and a query object that resolved on the first `.eq()` could not express that — worse,
      // it would have made a second filter look applied when it never ran.
      select: (columns: string) => {
        const query = {
          eq: (column: string, value: unknown) => {
            seen.push({ table, columns, column, value });
            return query;
          },
          in: (column: string, value: unknown) => {
            seen.push({ table, columns, column, value });
            return query;
          },
          maybeSingle: () => Promise.resolve(rows[table] ?? { data: null, error: null }),
          then: (resolve: (value: unknown) => unknown) =>
            Promise.resolve(rows[table] ?? { data: [], error: null }).then(resolve),
        };
        return query;
      },
    }),
    storage: {
      from: () => ({
        createSignedUrls: async (paths: string[], ttl: number) => {
          signCalls.push({ paths, ttl });
          if (holdSigning) await holdSigning;
          return {
            data: paths.map(
              (path) =>
                signedByPath[path] ?? {
                  path,
                  error: null,
                  signedUrl: `https://signed.test/${path}`,
                },
            ),
            error: null,
          };
        },
      }),
    },
  }),
}));

beforeEach(() => {
  seen.length = 0;
  signedByPath = {};
  signCalls.length = 0;
  holdSigning = null;
  for (const key of Object.keys(rows)) delete rows[key];
});

describe('the chains detail', () => {
  it('reads the chain and the calendar through the views that follow a correction', async () => {
    rows.chain_current = { data: { current_days: 3, longest_days: 9 }, error: null };
    rows.settlement_commitment_current = {
      data: [{ outcome: 'held', period: '2026-08-18' }],
      error: null,
    };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);
    await screen.findByText('Day 3 · best 9');
    // The photo read is its own pass, after the history is already on screen (Story 6.9), so
    // it has to be waited for rather than assumed to have happened by now.
    await waitFor(() => expect(seen.some((s) => s.table === 'evidence')).toBe(true));

    // Both reads go through a `*_current` view. Reading `settlement_commitment` directly is
    // what made the number follow a supersession while the calendar beside it kept showing
    // the superseded verdict's marks forever. `evidence` joins them in Story 6.9 and is a
    // base table on purpose: it carries no verdict and nothing supersedes it.
    expect([...new Set(seen.map((s) => s.table))].sort()).toEqual([
      'chain_current',
      'evidence',
      'settlement_commitment_current',
    ]);
    // And each is asked exactly once per open — the identity check above cannot see a second,
    // duplicate read of the same table, which is a real cost on a screen reached by tapping.
    expect(seen.filter((s) => s.table === 'chain_current')).toHaveLength(1);
    expect(seen.filter((s) => s.table === 'settlement_commitment_current')).toHaveLength(1);
    // Two filters, one read: `commitment_id` and `for_day`.
    expect(seen.filter((s) => s.table === 'evidence')).toHaveLength(2);

    const calendar = seen.find((s) => s.table === 'settlement_commitment_current');
    // `period` comes from the view rather than from a join back to `settlement`, which is
    // the join that used to reach past the correction.
    expect(calendar?.columns).toBe('outcome,period');
    expect(calendar?.column).toBe('commitment_id');
    expect(calendar?.value).toBe('c1');
  });

  it('never shows the current chain without the longest beside it', async () => {
    rows.chain_current = { data: { current_days: 0, longest_days: 30 }, error: null };
    rows.settlement_commitment_current = { data: [], error: null };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    // "Broken · best 30", never "Day 0". A reset read against zero says *you have nothing*;
    // read against a record it says *you have done better than this, and you did it
    // yourself* — which is the whole reason this surface exists.
    const pair = await screen.findByText(/best 30/);
    expect(pair).toHaveTextContent('Broken');
    expect(pair).not.toHaveTextContent('Day 0');
  });

  it('treats no history at all as a real state rather than an error', async () => {
    rows.chain_current = { data: null, error: null };
    rows.settlement_commitment_current = { data: [], error: null };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    expect(await screen.findByText('No day has been judged for this yet.')).toBeInTheDocument();
    expect(screen.getByText('Broken · best 0')).toBeInTheDocument();
    expect(screen.queryByText(/Failed\./)).not.toBeInTheDocument();
  });

  it('draws the newest day first, and keeps silence distinct from a miss', async () => {
    rows.chain_current = { data: { current_days: 0, longest_days: 2 }, error: null };
    rows.settlement_commitment_current = {
      data: [
        { outcome: 'held', period: '2026-08-16' },
        { outcome: 'unanswered', period: '2026-08-18' },
        { outcome: 'missed', period: '2026-08-17' },
      ],
      error: null,
    };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);
    await screen.findByText('2026-08-18');

    const days = screen.getAllByRole('group').map((g) => g.getAttribute('aria-label'));
    expect(days).toEqual(['2026-08-18, never answered', '2026-08-17, missed', '2026-08-16, held']);

    // The money treats a miss and a silence the same. The history must not: "I said no" and
    // "I said nothing" are different things to have done, so they never share a word.
    expect(screen.getByText('No answer')).toBeInTheDocument();
    expect(screen.getByText('Missed')).toBeInTheDocument();
  });

  it('keeps colour out of the neutral outcomes, so a history is not a wall of red', async () => {
    rows.chain_current = { data: { current_days: 0, longest_days: 1 }, error: null };
    rows.settlement_commitment_current = {
      data: [{ outcome: 'unanswered', period: '2026-08-18' }],
      error: null,
    };

    const { container } = render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);
    await screen.findByText('2026-08-18');

    // This list is structurally a history of failures and is opened on the day it just
    // broke. `unanswered` is neutral for that reason, and the pill is `aria-hidden` because
    // the row already says it in one sentence.
    const pill = container.querySelector('.pill');
    expect(pill).toHaveClass('pill-neutral');
    expect(pill).toHaveAttribute('aria-hidden', 'true');
  });

  it('says what failed when the read fails, rather than showing an empty history', async () => {
    rows.chain_current = { data: null, error: { message: 'permission denied' } };
    rows.settlement_commitment_current = { data: [], error: null };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    // An empty calendar and a failed read look identical, and one of them means his history
    // is gone. They must never be drawn the same way.
    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByText('No day has been judged for this yet.')).not.toBeInTheDocument();
  });

  it('says what failed when only the calendar read fails, not just the chain read', async () => {
    rows.chain_current = { data: { current_days: 3, longest_days: 9 }, error: null };
    rows.settlement_commitment_current = { data: null, error: { message: 'calendar unreadable' } };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    expect(await screen.findByText(/calendar unreadable/)).toBeInTheDocument();
  });
});

/**
 * Story 6.9 — the photo, on the day it was kept for.
 *
 * This screen's own rule is that nothing here is computed. A read does not violate it; a derived
 * "this day should have had a photo" would, which is why no day is ever told it is missing one.
 */
describe('the photos a commitment carries', () => {
  function filed(id: string, day: string, path: string) {
    return { id, commitment_id: 'c1', for_day: day, storage_path: path };
  }

  it('draws the history before the photos, never behind them', async () => {
    rows.chain_current = { data: { current_days: 3, longest_days: 9 }, error: null };
    rows.settlement_commitment_current = {
      data: [{ outcome: 'held', period: '2026-08-18' }],
      error: null,
    };
    rows.evidence = { data: [filed('e1', '2026-08-18', 'c1/e1-proof.jpg')], error: null };

    // Signing is left in flight, which is the whole point: before this the screen awaited it
    // before setting the ready view at all, so a slow round trip held the chain and calendar on
    // "Working…" — the opposite of the component's own note that a history which cannot show
    // its photos is still the history.
    let release = () => {};
    holdSigning = new Promise<void>((resolve) => {
      release = resolve;
    });

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    await screen.findByText('Day 3 · best 9');
    expect(screen.getByText('2026-08-18')).toBeInTheDocument();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();

    // And the photo arrives afterwards, into the row it belongs to.
    release();
    const image = await screen.findByAltText(EVIDENCE_COPY.photoAlt(1, 1));
    expect(image.closest('.row')?.getAttribute('aria-label')).toBe('2026-08-18, held');
  });

  it('shows each day’s photo inside that day’s own row', async () => {
    rows.chain_current = { data: { current_days: 0, longest_days: 2 }, error: null };
    rows.settlement_commitment_current = {
      data: [
        { outcome: 'held', period: '2026-08-18' },
        { outcome: 'missed', period: '2026-08-17' },
      ],
      error: null,
    };
    rows.evidence = { data: [filed('e1', '2026-08-18', 'c1/e1-proof.jpg')], error: null };

    const { container } = render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    const image = await screen.findByAltText(EVIDENCE_COPY.photoAlt(1, 1));
    expect(image).toHaveAttribute('src', 'https://signed.test/c1/e1-proof.jpg');
    expect(signCalls).toEqual([{ paths: ['c1/e1-proof.jpg'], ttl: 3600 }]);

    // And the day with none renders exactly as it always has: one image on the screen, no
    // placeholder and no sentence about a photo that was never owed.
    expect(container.querySelectorAll('img')).toHaveLength(1);
    expect(screen.queryByText(/could not be loaded/)).not.toBeInTheDocument();
  });

  it('asks only about this commitment and only about the days it lists', async () => {
    rows.chain_current = { data: { current_days: 1, longest_days: 1 }, error: null };
    rows.settlement_commitment_current = {
      data: [{ outcome: 'held', period: '2026-08-18' }],
      error: null,
    };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);
    await screen.findByText('2026-08-18');
    await waitFor(() => expect(seen.some((s) => s.table === 'evidence')).toBe(true));

    const evidence = seen.filter((s) => s.table === 'evidence');
    // No back-filling and no widening: it asks about the days already on screen, and about one
    // commitment — his own, which is all RLS would return anyway.
    expect(evidence.map((s) => [s.column, s.value])).toEqual([
      ['commitment_id', ['c1']],
      ['for_day', ['2026-08-18']],
    ]);
    expect(evidence[0].columns).toBe('id,commitment_id,for_day,storage_path');
  });

  it('reads nothing at all when there is no judged day to ask about', async () => {
    rows.chain_current = { data: null, error: null };
    rows.settlement_commitment_current = { data: [], error: null };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);
    await screen.findByText('No day has been judged for this yet.');

    expect(seen.some((s) => s.table === 'evidence')).toBe(false);
  });

  it('counts a photo it could not sign rather than shortening the list', async () => {
    rows.chain_current = { data: { current_days: 0, longest_days: 2 }, error: null };
    rows.settlement_commitment_current = {
      data: [
        { outcome: 'held', period: '2026-08-18' },
        { outcome: 'held', period: '2026-08-17' },
      ],
      error: null,
    };
    rows.evidence = {
      data: [
        filed('e1', '2026-08-18', 'c1/e1-one.jpg'),
        filed('e2', '2026-08-17', 'c1/e2-two.jpg'),
      ],
      error: null,
    };
    signedByPath = {
      'c1/e2-two.jpg': { path: 'c1/e2-two.jpg', error: 'Object not found', signedUrl: null },
    };

    const { container } = render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    await screen.findByAltText(EVIDENCE_COPY.photoAlt(1, 1));
    expect(container.querySelectorAll('img')).toHaveLength(1);
    expect(screen.getByText(EVIDENCE_COPY.photosFailed(1))).toBeInTheDocument();
  });

  it('counts a photo whose signed URL will not load', async () => {
    rows.chain_current = { data: { current_days: 1, longest_days: 1 }, error: null };
    rows.settlement_commitment_current = {
      data: [{ outcome: 'held', period: '2026-08-18' }],
      error: null,
    };
    rows.evidence = { data: [filed('e1', '2026-08-18', 'c1/e1-one.jpg')], error: null };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);
    const image = await screen.findByAltText(EVIDENCE_COPY.photoAlt(1, 1));

    // An hour-old signed URL is a real state on a screen nobody has to leave. A broken frame
    // says nothing; the count says what every other missing photo says.
    await act(async () => {
      image.dispatchEvent(new Event('error'));
    });

    expect(screen.queryByRole('img')).not.toBeInTheDocument();
    expect(screen.getByText(EVIDENCE_COPY.photosFailed(1))).toBeInTheDocument();
  });

  it('keeps the history readable when the photo read itself fails, and says why', async () => {
    rows.chain_current = { data: { current_days: 1, longest_days: 1 }, error: null };
    rows.settlement_commitment_current = {
      data: [{ outcome: 'held', period: '2026-08-18' }],
      error: null,
    };
    rows.evidence = { data: null, error: { message: 'permission denied' } };

    render(<ChainsDetail commitmentId="c1" name="Gym" onClose={vi.fn()} />);

    // The history is still the history. A photo read that failed says so, with the server's own
    // words, and takes nothing else down with it.
    expect(await screen.findByText('2026-08-18')).toBeInTheDocument();
    expect(await screen.findByText(EVIDENCE_COPY.photosUnreadable)).toBeInTheDocument();
    expect(screen.getByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByText(/^Failed\./)).not.toBeInTheDocument();
  });
});
