import { fireEvent, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
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

// `settlement_current` and `penalty_current` are each queried twice — once filtered to
// `kind = 'day'`, once to `kind = 'week'` — so the mock has to answer those two calls
// differently rather than returning the same canned rows to both. It tracks the last
// `.eq('kind', …)` seen per table and keys the fixture lookup on it, falling back to the
// bare table name for a read that carries no kind filter at all (`declaration`).
const inserted: Array<{ table: string; payload: unknown }> = [];
// What a `grace_day` insert comes back with. Set per test; the default is a clean success —
// most tests here have nothing to do with spending one at all.
let graceInsertResult: unknown = { error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      let key = table;
      const query = {
        select: () => query,
        eq: (column: string, value: string) => {
          if (column === 'kind') key = `${table}:${value}`;
          return query;
        },
        // `grace_allowance_remaining` is read with `.select('remaining').maybeSingle()` —
        // no `.eq()` in between — so `key` stays the bare table name.
        maybeSingle: () => Promise.resolve(rows[key] ?? { data: null, error: null }),
        insert: (payload: unknown) => {
          inserted.push({ table, payload });
          return Promise.resolve(graceInsertResult);
        },
        then: (resolve: (value: unknown) => unknown) =>
          Promise.resolve(rows[key] ?? { data: [], error: null }).then(resolve),
      };
      return query;
    },
  }),
}));

beforeEach(() => {
  for (const key of Object.keys(rows)) delete rows[key];
  inserted.length = 0;
  graceInsertResult = { error: null };
  // A sane default so every test that never mentions Grace Days keeps compiling and
  // rendering exactly as before — most of this file predates Story 5.1 entirely.
  rows.grace_allowance_remaining = { data: { remaining: 2 }, error: null };
});

function withDays(settlements: unknown[], penalties: unknown[] = [], misses: unknown[] = []) {
  rows['settlement_current:day'] = { data: settlements, error: null };
  rows['penalty_current:day'] = { data: penalties, error: null };
  rows.declaration = { data: misses, error: null };
}

function withWeeks(settlements: unknown[], penalties: unknown[] = []) {
  rows['settlement_current:week'] = { data: settlements, error: null };
  rows['penalty_current:week'] = { data: penalties, error: null };
}

function withGraceRemaining(remaining: number) {
  rows.grace_allowance_remaining = { data: { remaining }, error: null };
}

describe('the ledger', () => {
  it('names the money once, after the fact, in đồng he would recognise', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
      [{ for_day: '2026-08-18', commitment: { name: 'No fap', carries_penalty: true } }],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    // 500.000₫ — dots, not commas. The same rendering the evening summary uses, and the one
    // the two copies of that rule disagreed about once.
    expect(await screen.findByText(/500\.000₫/)).toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName('2026-08-18, owed 500.000₫, for No fap');
  });

  it('says what a failed day was failed for, rather than only what it cost', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 2 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
      [
        { for_day: '2026-08-18', commitment: { name: 'No fap', carries_penalty: true } },
        { for_day: '2026-08-18', commitment: { name: 'TryHackMe', carries_penalty: true } },
      ],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

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
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-16' }],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

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
        { amount_dong: 500000, state: 'owed', period: '2026-08-18' },
        { amount_dong: 500000, state: 'owed', period: '2026-08-17' },
      ],
      [
        { for_day: '2026-08-18', commitment: { name: 'No fap', carries_penalty: true } },
        { for_day: '2026-08-17', commitment: { name: 'No fap', carries_penalty: true } },
      ],
    );

    const { container } = render(<Ledger ownerId="u1" onClose={vi.fn()} />);
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

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    // A penalty-free slip is not a debt and must not appear as one on the money screen.
    expect(await screen.findByRole('group')).toHaveAccessibleName('2026-08-18, clean');
    expect(screen.queryByText(/Morning walk/)).not.toBeInTheDocument();
  });

  it('tells an empty history apart from a broken read', async () => {
    withDays([]);
    const { unmount } = render(<Ledger ownerId="u1" onClose={vi.fn()} />);
    expect(await screen.findByText('No day has been judged yet.')).toBeInTheDocument();
    unmount();

    rows['settlement_current:day'] = { data: null, error: { message: 'permission denied' } };
    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByText('No day has been judged yet.')).not.toBeInTheDocument();
  });

  it('surfaces a failed penalties, misses, week, or Grace Days read instead of rendering an incomplete ledger', async () => {
    for (const key of [
      'penalty_current:day',
      'declaration',
      'settlement_current:week',
      'penalty_current:week',
      'grace_allowance_remaining',
    ]) {
      withDays([]);
      withWeeks([]);
      rows[key] = { data: null, error: { message: `${key} unreadable` } };

      const { unmount } = render(<Ledger ownerId="u1" onClose={vi.fn()} />);

      expect(await screen.findByText(new RegExp(`${key} unreadable`))).toBeInTheDocument();
      unmount();
    }
  });
});

describe('Contest, on an eligible owed failed-day row (Story 4.4)', () => {
  it('offers Contest for a machine-filed miss when onOpenAppeal is wired up', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
      [
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-1',
          filed_by: 'auto_check',
          commitment: { name: 'TryHackMe', carries_penalty: true },
        },
      ],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} onOpenAppeal={vi.fn()} />);

    expect(await screen.findByRole('button', { name: 'Contest TryHackMe' })).toBeInTheDocument();
  });

  it('calls onOpenAppeal with the commitment, the day and the amount', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
      [
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-1',
          filed_by: 'auto_check',
          commitment: { name: 'TryHackMe', carries_penalty: true },
        },
      ],
    );

    const onOpenAppeal = vi.fn();
    render(<Ledger ownerId="u1" onClose={vi.fn()} onOpenAppeal={onOpenAppeal} />);

    fireEvent.click(await screen.findByRole('button', { name: 'Contest TryHackMe' }));

    expect(onOpenAppeal).toHaveBeenCalledWith({
      commitmentId: 'commitment-1',
      commitmentName: 'TryHackMe',
      forDay: '2026-08-18',
      amountDong: 500000,
    });
  });

  it('never offers Contest without onOpenAppeal wired up', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
      [
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-1',
          filed_by: 'auto_check',
          commitment: { name: 'TryHackMe', carries_penalty: true },
        },
      ],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    await screen.findByText('2026-08-18');
    expect(screen.queryByRole('button', { name: /Contest/ })).not.toBeInTheDocument();
  });

  it('never offers Contest for the author’s own honest slip', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
      [
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-1',
          filed_by: 'doer',
          commitment: { name: 'No fap', carries_penalty: true },
        },
      ],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} onOpenAppeal={vi.fn()} />);

    await screen.findByText('2026-08-18');
    expect(screen.queryByRole('button', { name: /Contest/ })).not.toBeInTheDocument();
  });

  it('names Held and Dropped, distinct from Owed, once a Penalty has moved off owed', async () => {
    withDays(
      [
        { period: '2026-08-19', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
      ],
      [
        { amount_dong: 500000, state: 'held', period: '2026-08-19' },
        { amount_dong: 500000, state: 'dropped', period: '2026-08-18' },
      ],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByText('Held')).toBeInTheDocument();
    expect(screen.getByText('Dropped')).toBeInTheDocument();
    expect(screen.queryByText('Owed')).not.toBeInTheDocument();
  });

  it("names Collected, distinct from Owed, once the referee has marked a Penalty paid", async () => {
    // A `collected` Penalty is the same settlement's own row transitioned in place (Story
    // 4.7's `mark_penalty_collected()` writes no new settlement) — unlike `voided`, which
    // only ever lands on a superseded settlement `penalty_current` never surfaces, this state
    // is genuinely reachable through the doer's own Ledger read. The pill already read
    // "Collected" correctly; this proves the row's accessible name does too, rather than
    // falling through to the "owed" default and telling a screen-reader user he still owes it.
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'collected', period: '2026-08-18' }],
      [
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-1',
          filed_by: 'doer',
          commitment: { name: 'No fap', carries_penalty: true },
        },
      ],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByText('Collected')).toBeInTheDocument();
    expect(screen.queryByText('Owed')).not.toBeInTheDocument();
    expect(
      screen.getByRole('group', { name: '2026-08-18, collected, for No fap' }),
    ).toBeInTheDocument();
  });

  it('names Collected, never Expired, on a day that otherwise closed expired (Epic 4 retro, finding A6)', async () => {
    // A day can close `expired` (silence from some *other* commitment) while still freezing
    // one commitment's own machine-filed `missed` and its Penalty, which can still resolve
    // to `collected`. Before this fix, the aria-label ternary checked `verdict === 'expired'`
    // before `state === 'collected'`, so a paid debt kept announcing "expired unanswered,
    // owed ..." forever.
    withDays(
      [{ period: '2026-08-18', verdict: 'expired', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'collected', period: '2026-08-18' }],
      [
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-1',
          filed_by: 'auto_check',
          commitment: { name: 'No fap', carries_penalty: true },
        },
      ],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByText('Collected')).toBeInTheDocument();
    expect(
      screen.getByRole('group', { name: '2026-08-18, collected, for No fap' }),
    ).toBeInTheDocument();
  });

  it('colours Held urgent rather than failed, and Dropped held rather than failed', async () => {
    // `held`'s own colour family is deliberately `pill-urgent`, not `pill-held` — a Held
    // Penalty still needs attention (epic-4-context.md's own naming-collision warning), so
    // it must never share a class with either "resolved" (pill-held) or "lost" (pill-failed).
    withDays(
      [
        { period: '2026-08-19', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
      ],
      [
        { amount_dong: 500000, state: 'held', period: '2026-08-19' },
        { amount_dong: 500000, state: 'dropped', period: '2026-08-18' },
      ],
    );

    const { container } = render(<Ledger ownerId="u1" onClose={vi.fn()} />);
    await screen.findByText('Held');

    const heldRow = screen.getByRole('group', { name: /2026-08-19/ });
    const droppedRow = screen.getByRole('group', { name: /2026-08-18/ });

    expect(heldRow.querySelector('.pill')?.className).toContain('pill-urgent');
    expect(droppedRow.querySelector('.pill')?.className).toContain('pill-held');
    expect(container.querySelectorAll('.pill-failed')).toHaveLength(0);
  });

  it('sends each Contest button on a multi-miss Failed Day to its own commitment', async () => {
    // A Failed Day can carry more than one appealable machine-filed miss (FR-13's bundled
    // Penalty). Every prior Contest test here fixtures exactly one, which cannot tell "the
    // button's own data" apart from "the only miss's data" — this fixtures two, so a mixup
    // between rows in the .map() (e.g. every button firing with the last iteration's miss)
    // would fail here even though it would pass every single-miss test above.
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 2 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
      [
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-1',
          filed_by: 'auto_check',
          commitment: { name: 'TryHackMe', carries_penalty: true },
        },
        {
          for_day: '2026-08-18',
          commitment_id: 'commitment-2',
          filed_by: 'auto_check',
          commitment: { name: 'No fap', carries_penalty: true },
        },
      ],
    );

    const onOpenAppeal = vi.fn();
    render(<Ledger ownerId="u1" onClose={vi.fn()} onOpenAppeal={onOpenAppeal} />);

    fireEvent.click(await screen.findByRole('button', { name: 'Contest No fap' }));
    expect(onOpenAppeal).toHaveBeenCalledWith({
      commitmentId: 'commitment-2',
      commitmentName: 'No fap',
      forDay: '2026-08-18',
      amountDong: 500000,
    });

    onOpenAppeal.mockClear();
    fireEvent.click(screen.getByRole('button', { name: 'Contest TryHackMe' }));
    expect(onOpenAppeal).toHaveBeenCalledWith({
      commitmentId: 'commitment-1',
      commitmentName: 'TryHackMe',
      forDay: '2026-08-18',
      amountDong: 500000,
    });
  });
});

describe('Grace Day, on a Failed, owed day (Story 5.1)', () => {
  it('offers the control and always states how many remain', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
    );
    withGraceRemaining(2);

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByRole('button', { name: /Spend a Grace Day/ })).toBeInTheDocument();
    expect(screen.getByText('2 Grace Days remaining this month.')).toBeInTheDocument();
  });

  it('never offers it on a clean or expired day, or once the Penalty has moved off owed', async () => {
    withDays(
      [
        { period: '2026-08-20', verdict: 'clean', missed_count: 0 },
        { period: '2026-08-19', verdict: 'expired', missed_count: 1 },
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
      ],
      [
        { amount_dong: 500000, state: 'owed', period: '2026-08-19' },
        { amount_dong: 500000, state: 'held', period: '2026-08-18' },
      ],
    );
    withGraceRemaining(2);

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    await screen.findByText('2026-08-20');
    expect(screen.queryByRole('button', { name: /Spend a Grace Day/ })).not.toBeInTheDocument();
  });

  it('sends owner_id and the row’s own for_day, and reports success without claiming Waived yet', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
    );
    withGraceRemaining(2);

    render(<Ledger ownerId="owner-42" onClose={vi.fn()} />);

    await userEvent.click(await screen.findByRole('button', { name: /Spend a Grace Day/ }));

    expect(inserted).toEqual([
      { table: 'grace_day', payload: { owner_id: 'owner-42', for_day: '2026-08-18' } },
    ]);
    expect(
      await screen.findByText('Grace Day spent. This day clears within the hour.'),
    ).toBeInTheDocument();
    // The correction is folded in later, so the pill must not jump to Waived on its own —
    // that would be a claim the server has not made yet.
    expect(screen.queryByText('Waived')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Spend a Grace Day/ })).not.toBeInTheDocument();
  });

  it('decrements the shown allowance locally after a successful spend', async () => {
    withDays(
      [
        { period: '2026-08-19', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
      ],
      [
        { amount_dong: 500000, state: 'owed', period: '2026-08-19' },
        { amount_dong: 500000, state: 'owed', period: '2026-08-18' },
      ],
    );
    withGraceRemaining(2);

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);
    await screen.findAllByText('2 Grace Days remaining this month.');

    // Each row's own control now has a distinguishing accessible name (day and/or amount) —
    // no more falling back to array indexing to tell the two rows' buttons apart.
    await userEvent.click(
      await screen.findByRole('button', { name: 'Spend a Grace Day for 2026-08-18' }),
    );

    // Both rows share the one count, so the still-open row must show the new figure too.
    expect(await screen.findByText('1 Grace Day remaining this month.')).toBeInTheDocument();
    expect(screen.queryByText('2 Grace Days remaining this month.')).not.toBeInTheDocument();
  });

  it('gives each row a distinguishing accessible name, never sharing one identical name across rows', async () => {
    withDays(
      [
        { period: '2026-08-19', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
      ],
      [
        { amount_dong: 500000, state: 'owed', period: '2026-08-19' },
        { amount_dong: 500000, state: 'owed', period: '2026-08-18' },
      ],
    );
    withGraceRemaining(2);

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(
      await screen.findByRole('button', { name: 'Spend a Grace Day for 2026-08-19' }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: 'Spend a Grace Day for 2026-08-18' }),
    ).toBeInTheDocument();
  });

  it('disables the control once the allowance reads exhausted, but still names the reason', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
    );
    withGraceRemaining(0);

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByText('No Grace Days remaining this month.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Spend a Grace Day/ })).toBeDisabled();
  });

  it('shows the server’s own refusal verbatim, and leaves the control usable to try again', async () => {
    withDays(
      [{ period: '2026-08-18', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-18' }],
    );
    withGraceRemaining(2);
    graceInsertResult = {
      error: { code: 'P0001', message: 'This day’s Penalty is not eligible for a Grace Day.' },
    };

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    await userEvent.click(await screen.findByRole('button', { name: /Spend a Grace Day/ }));

    expect(
      await screen.findByText('This day’s Penalty is not eligible for a Grace Day.'),
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Spend a Grace Day/ })).toBeEnabled();
  });

  it('never double-decrements the shown allowance on an already-spent (23505) outcome', async () => {
    // No new row was actually written this time — the count the last read returned already
    // accounts for that day's own earlier spend (this attempt's own retry, or a second one
    // racing it). Decrementing again here would undercount what genuinely remains. A second,
    // still-open row proves it: if the count had wrongly dropped, that row's own figure
    // would say so even though this row's own control disappears once spent either way.
    withDays(
      [
        { period: '2026-08-19', verdict: 'failed', missed_count: 1 },
        { period: '2026-08-18', verdict: 'failed', missed_count: 1 },
      ],
      [
        { amount_dong: 500000, state: 'owed', period: '2026-08-19' },
        { amount_dong: 500000, state: 'owed', period: '2026-08-18' },
      ],
    );
    withGraceRemaining(2);
    graceInsertResult = { error: { code: '23505', message: 'duplicate key value' } };

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);
    await screen.findAllByText('2 Grace Days remaining this month.');

    await userEvent.click(
      await screen.findByRole('button', { name: 'Spend a Grace Day for 2026-08-18' }),
    );

    expect(
      await screen.findByText('Grace Day spent. This day clears within the hour.'),
    ).toBeInTheDocument();
    // The still-open row (2026-08-19) must keep reading 2, not drop to 1.
    expect(await screen.findByText('2 Grace Days remaining this month.')).toBeInTheDocument();
    expect(screen.queryByText('1 Grace Day remaining this month.')).not.toBeInTheDocument();
  });

  it('never appears on a week row', async () => {
    withDays([]);
    withWeeks(
      [{ period: '2026-08-17', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-17' }],
    );
    withGraceRemaining(2);

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    await screen.findByText('Week of 2026-08-17');
    expect(screen.queryByRole('button', { name: /Spend a Grace Day/ })).not.toBeInTheDocument();
  });
});

describe('a week row (3.4)', () => {
  it('renders distinctly from a day row, both by class and by name', async () => {
    withDays([]);
    withWeeks(
      [{ period: '2026-08-17', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-17' }],
    );

    const { container } = render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByText('Week of 2026-08-17')).toBeInTheDocument();
    const weekRow = container.querySelector('.row-week');
    expect(weekRow).not.toBeNull();
    expect(weekRow?.className).toContain('row');
  });

  it('names no commitment — Week Close freezes no per-commitment outcome', async () => {
    withDays([]);
    withWeeks(
      [{ period: '2026-08-17', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-17' }],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByRole('group')).toHaveAccessibleName(
      'Week of 2026-08-17, owed 500.000₫',
    );
    expect(screen.getByText(/Fell short/)).toBeInTheDocument();
  });

  it('a clean week reads clean, with no amount and no tint', async () => {
    withDays([]);
    withWeeks([{ period: '2026-08-10', verdict: 'clean', missed_count: 0 }]);

    const { container } = render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByRole('group')).toHaveAccessibleName('Week of 2026-08-10, clean');
    for (const row of container.querySelectorAll('.row')) {
      expect(row.className.split(' ')).not.toContain('pill-failed');
    }
    expect(container.querySelectorAll('.pill-held')).toHaveLength(1);
  });

  it("does not alter an existing day row's list when a week row exists", async () => {
    withDays([{ period: '2026-08-18', verdict: 'clean', missed_count: 0 }], [], []);
    withWeeks(
      [{ period: '2026-08-17', verdict: 'failed', missed_count: 1 }],
      [{ amount_dong: 500000, state: 'owed', period: '2026-08-17' }],
    );

    render(<Ledger ownerId="u1" onClose={vi.fn()} />);

    expect(await screen.findByRole('group', { name: '2026-08-18, clean' })).toBeInTheDocument();
    expect(
      screen.getByRole('group', { name: 'Week of 2026-08-17, owed 500.000₫' }),
    ).toBeInTheDocument();
  });
});
