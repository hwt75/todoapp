import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ChainsDetail } from './chains-detail';

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

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => ({
      select: (columns: string) => {
        const query = {
          eq: (column: string, value: unknown) => {
            seen.push({ table, columns, column, value });
            return Object.assign(Promise.resolve(rows[table] ?? { data: [], error: null }), {
              maybeSingle: () => Promise.resolve(rows[table] ?? { data: null, error: null }),
            });
          },
        };
        return query;
      },
    }),
  }),
}));

beforeEach(() => {
  seen.length = 0;
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

    // Both reads go through a `*_current` view. Reading `settlement_commitment` directly is
    // what made the number follow a supersession while the calendar beside it kept showing
    // the superseded verdict's marks forever.
    expect(seen.map((s) => s.table).sort()).toEqual([
      'chain_current',
      'settlement_commitment_current',
    ]);

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
});
