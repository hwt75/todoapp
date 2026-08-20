import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Ledger } from './ledger';

/**
 * Every day that has been judged — the surface Story 2.6 built and nothing rendered until now.
 *
 * `lib/ledger.test.ts` covers `buildLedger`, the fold. What it cannot cover is the rule this
 * screen exists to keep: **no row is tinted, on any day**. The Ledger is structurally a list of
 * failures, reached in one tap from Today on exactly the worst day, so it is the surface most
 * likely to become a wall of red — and retreating from the sight of his own record is the
 * author's documented failure mode. Colour lives in the pill and nowhere else.
 *
 * The other rule asserted here is that money is named after the fact and never as a threat, and
 * that a day closed on the clock reads differently from a day he admitted to. The ledger must not
 * merge those two: they cost the same and they are not the same fact about him.
 */

const rows: Record<string, unknown> = {};

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      const result = () => rows[table] ?? { data: [], error: null };
      const query = {
        select: () => query,
        eq: () => query,
        then: (resolve: (value: unknown) => unknown) => Promise.resolve(result()).then(resolve),
      };
      return query;
    },
  }),
}));

beforeEach(() => {
  for (const key of Object.keys(rows)) delete rows[key];
});

function withDays(settlements: unknown[], penalties: unknown[] = [], misses: unknown[] = []) {
  rows.settlement_current = { data: settlements, error: null };
  rows.penalty_current = { data: penalties, error: null };
  rows.declaration = { data: misses, error: null };
}

describe('the ledger', () => {
  it('names the money once, after the fact, in đồng he would recognise', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', settlement: { period: '2026-08-18' } }],
      [{ for_day: '2026-08-18', commitment: { name: 'No fap', carries_penalty: true } }],
    );

    render(<Ledger onClose={vi.fn()} />);

    // 500.000₫ — dots, not commas. The same rendering the evening summary uses, and the one
    // the two copies of that rule disagreed about once.
    expect(await screen.findByText(/500\.000₫/)).toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName('2026-08-18, owed 500.000₫, for No fap');
  });

  it('says what a failed day was failed for, rather than only what it cost', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 2 }],
      [{ amount_dong: 500000, state: 'owed', settlement: { period: '2026-08-18' } }],
      [
        { for_day: '2026-08-18', commitment: { name: 'No fap', carries_penalty: true } },
        { for_day: '2026-08-18', commitment: { name: 'TryHackMe', carries_penalty: true } },
      ],
    );

    render(<Ledger onClose={vi.fn()} />);

    // One flat penalty however many were missed (FR-13) — and the row still names both, so
    // the amount is explicable rather than something that merely happened to him.
    expect(await screen.findByRole('group')).toHaveAccessibleName(
      '2026-08-18, owed 500.000₫, for No fap and TryHackMe',
    );
    expect(screen.getAllByText(/500\.000₫/)).toHaveLength(1);
  });

  it('keeps a day closed on the clock distinct from a day he admitted to', async () => {
    withDays(
      [{ period: '2026-08-16', verdict: 'expired', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', settlement: { period: '2026-08-16' } }],
    );

    render(<Ledger onClose={vi.fn()} />);

    // Silence costs exactly what honesty costs, or silence becomes the cheaper answer. The
    // ledger charges the same and says a different thing, because they are different facts.
    expect(await screen.findByRole('group')).toHaveAccessibleName(
      '2026-08-16, expired unanswered, owed 500.000₫',
    );
    expect(screen.getByText(/Went unanswered/)).toBeInTheDocument();
  });

  it('never tints a row, on any day', async () => {
    withDays(
      [
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-17', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-16', verdict: 'clean', missed_count: 0 },
      ],
      [
        { amount_dong: 500000, state: 'owed', settlement: { period: '2026-08-18' } },
        { amount_dong: 500000, state: 'owed', settlement: { period: '2026-08-17' } },
      ],
      [
        { for_day: '2026-08-18', commitment: { name: 'No fap', carries_penalty: true } },
        { for_day: '2026-08-17', commitment: { name: 'No fap', carries_penalty: true } },
      ],
    );

    const { container } = render(<Ledger onClose={vi.fn()} />);
    await screen.findByText('2026-08-16');

    for (const row of container.querySelectorAll('.row')) {
      // The row class and nothing else. A tinted row here is a wall of red on the screen
      // reached in one tap on the worst day of the month.
      expect(row.className).toBe('row');
    }
    expect(container.querySelectorAll('.pill-failed')).toHaveLength(2);
    expect(container.querySelectorAll('.pill-held')).toHaveLength(1);
  });

  it('ignores a miss on a commitment that costs nothing', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'clean', missed_count: 0 }],
      [],
      [{ for_day: '2026-08-18', commitment: { name: 'Morning walk', carries_penalty: false } }],
    );

    render(<Ledger onClose={vi.fn()} />);

    // A penalty-free slip is not a debt and must not appear as one on the money screen.
    expect(await screen.findByRole('group')).toHaveAccessibleName('2026-08-18, clean');
    expect(screen.queryByText(/Morning walk/)).not.toBeInTheDocument();
  });

  it('tells an empty history apart from a broken read', async () => {
    withDays([]);
    const { unmount } = render(<Ledger onClose={vi.fn()} />);
    expect(await screen.findByText('No day has been judged yet.')).toBeInTheDocument();
    unmount();

    rows.settlement_current = { data: null, error: { message: 'permission denied' } };
    render(<Ledger onClose={vi.fn()} />);

    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByText('No day has been judged yet.')).not.toBeInTheDocument();
  });
});
