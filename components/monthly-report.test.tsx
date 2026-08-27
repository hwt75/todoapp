import { render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MonthlyReport } from './monthly-report';

/**
 * The Monthly report (Story 5.4, FR-24): a frozen clock so "the most recently completed
 * month" is deterministic (2026-08-26 -> July 2026), and a thenable chain mock for
 * `@/lib/supabase/client` — every query this screen fires resolves through the same handful
 * of chained calls (`select`/`eq`/`gte`/`lt`/`is`), and a table queried more than once
 * (`settlement`, `appeal`) is served its results in the exact order the component's own
 * `Promise.all` array issues them. `penalty` (incurred, Epic 5 retrospective 2026-08-27
 * finding A3) and `penalty_current` (collected) are two different table names now, queried
 * once each, since the fix reads incurred figures off the base table with its own settlement
 * embedded rather than the "current" view.
 *
 * What is asserted here is `lib/monthly-report.ts`'s own folding, exercised through the real
 * component rather than called directly — at least one measure from each PRD §8 category:
 * primary (SM-1 Chains, SM-2 median days to return), secondary (SM-4 Silence episodes, SM-5
 * Referee activity, SM-3/SM-6 completion and answer rate), and counter-metric (SM-C1
 * Penalties, SM-C2 median days to acknowledge, SM-C3 appeal reject share) — plus the "no
 * data" fallbacks the I/O Matrix requires instead of a crash or a bare zero.
 */

function chain(result: unknown) {
  const node: Record<string, unknown> = {};
  const step = (): unknown => node;
  for (const method of ['select', 'eq', 'gte', 'lt', 'order', 'is', 'not', 'limit']) {
    node[method] = step;
  }
  node.maybeSingle = () => Promise.resolve(result);
  node.then = (resolve: (value: unknown) => void, reject?: (reason: unknown) => void) =>
    Promise.resolve(result).then(resolve, reject);
  return node;
}

const okEmpty = { data: [], error: null };

let chainResult: unknown = okEmpty;
let commitmentResult: unknown = okEmpty;
// Queried twice (failed, then clean) — one queue, shifted per call.
let settlementResults: unknown[] = [okEmpty, okEmpty];
let declarationResult: unknown = okEmpty;
// `penalty` (incurred) and `penalty_current` (collected) are two different tables now.
let penaltyResult: unknown = okEmpty;
let penaltyCurrentResult: unknown = okEmpty;
// Queried twice (outcomes, then ruled).
let appealResults: unknown[] = [okEmpty, okEmpty];
let silenceResult: unknown = okEmpty;
let rateResult: unknown = okEmpty;

const callCounts: Record<string, number> = {};

function nextFrom(table: string, queue: unknown[]): unknown {
  const index = callCounts[table] ?? 0;
  callCounts[table] = index + 1;
  return queue[index] ?? queue[queue.length - 1];
}

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      if (table === 'chain_current') return chain(chainResult);
      if (table === 'commitment') return chain(commitmentResult);
      if (table === 'settlement') {
        return chain(nextFrom('settlement', settlementResults));
      }
      if (table === 'declaration') return chain(declarationResult);
      if (table === 'penalty') return chain(penaltyResult);
      if (table === 'penalty_current') return chain(penaltyCurrentResult);
      if (table === 'appeal') return chain(nextFrom('appeal', appealResults));
      if (table === 'silence_episode') return chain(silenceResult);
      throw new Error(`Unexpected table in monthly-report test mock: ${table}`);
    },
    rpc: () => Promise.resolve(rateResult),
  }),
}));

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true });
  vi.setSystemTime(new Date('2026-08-26T10:00:00+07:00'));

  chainResult = okEmpty;
  commitmentResult = okEmpty;
  settlementResults = [okEmpty, okEmpty];
  declarationResult = okEmpty;
  penaltyResult = okEmpty;
  penaltyCurrentResult = okEmpty;
  appealResults = [okEmpty, okEmpty];
  silenceResult = okEmpty;
  rateResult = okEmpty;
  for (const key of Object.keys(callCounts)) delete callCounts[key];
});

afterEach(() => {
  vi.useRealTimers();
});

describe('the monthly report', () => {
  it('names the most recently completed month', async () => {
    render(<MonthlyReport onClose={() => {}} />);
    expect(
      await screen.findByText(/July 2026, the most recently completed month\./),
    ).toBeInTheDocument();
  });

  it('SM-1 (primary): Chains, read straight through with a name attached', async () => {
    chainResult = {
      data: [{ commitment_id: 'c1', current_days: 5, longest_days: 10 }],
      error: null,
    };
    commitmentResult = { data: [{ id: 'c1', name: 'Gym' }], error: null };

    render(<MonthlyReport onClose={() => {}} />);

    // The name and the figure are two elements in one row now, not one concatenated string,
    // so this asserts what the test's own title claims — that they stay attached — through
    // the row's accessible name rather than through how the two happen to be joined on screen.
    expect(await screen.findByRole('group', { name: 'Gym, Day 5 · best 10' })).toBeInTheDocument();
    expect(screen.getByText('Gym')).toBeInTheDocument();
    expect(screen.getByText('Day 5 · best 10')).toBeInTheDocument();
  });

  it('SM-2 (primary): median days to return after a Failed Day', async () => {
    settlementResults = [
      { data: [{ period: '2026-07-05' }], error: null }, // failed
      { data: [{ period: '2026-07-06' }], error: null }, // clean
    ];

    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByText('Median days to return after a Failed Day')).toBeInTheDocument();
    expect(screen.getByText('1 day')).toBeInTheDocument();
  });

  it('SM-2: reads "No data" rather than zero or a crash with no Failed days', async () => {
    render(<MonthlyReport onClose={() => {}} />);

    await screen.findByText('Median days to return after a Failed Day');
    expect(screen.getAllByText('No data').length).toBeGreaterThan(0);
  });

  it('SM-4 (secondary): counts Silence episodes for the month', async () => {
    silenceResult = {
      data: [{ started_day: '2026-07-03' }, { started_day: '2026-07-20' }],
      error: null,
    };

    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByText('2 episodes')).toBeInTheDocument();
  });

  it('SM-5 (secondary): reads active when the Referee ruled or collected this month', async () => {
    appealResults = [
      okEmpty, // outcomes
      { data: [{ id: 'a1' }], error: null }, // ruled
    ];

    render(<MonthlyReport onClose={() => {}} />);

    expect(
      await screen.findByText('The referee ruled on an appeal or collected a Penalty this month.'),
    ).toBeInTheDocument();
  });

  it('SM-5: reads inactive when neither signal fired this month', async () => {
    render(<MonthlyReport onClose={() => {}} />);

    expect(
      await screen.findByText(
        'The referee neither ruled on an appeal nor collected a Penalty this month.',
      ),
    ).toBeInTheDocument();
  });

  it('SM-3/SM-6 (secondary): per-commitment completion and the summed answer rate', async () => {
    commitmentResult = { data: [{ id: 'c1', name: 'Gym' }], error: null };
    rateResult = { data: [{ commitment_id: 'c1', asked: 30, answered: 28 }], error: null };

    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByRole('group', { name: 'Gym, 28 of 30 (93%)' })).toBeInTheDocument();
    // Twice over, and that is the point of this test: the per-commitment figure and the
    // account-wide one are separate measures that happen to read the same this month. They
    // used to be distinguishable only because the per-commitment one carried a `Gym: ` prefix
    // in the same text node; now each is its own row, so both are asserted by count.
    expect(screen.getAllByText('28 of 30 (93%)')).toHaveLength(2);
    expect(
      screen.getByRole('group', { name: 'Declaration answer rate, 28 of 30 (93%)' }),
    ).toBeInTheDocument();
  });

  it('SM-C1 (counter-metric): Penalties Incurred and Penalties Collected, two figures, never merged', async () => {
    penaltyResult = {
      data: [{ amount_dong: 500_000, settlement: { supersedes: null } }],
      error: null,
    };
    penaltyCurrentResult = {
      data: [{ amount_dong: 500_000 }, { amount_dong: 500_000 }],
      error: null,
    };

    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByText('Incurred: 1 · 500.000₫')).toBeInTheDocument();
    expect(screen.getByText('Collected: 2 · 1.000.000₫')).toBeInTheDocument();
  });

  it('SM-C1: excludes a corrective penalty from Incurred — its own settlement supersedes the original (Epic 5 retro, finding A3)', async () => {
    penaltyResult = {
      data: [
        { amount_dong: 500_000, settlement: { supersedes: null } },
        { amount_dong: 500_000, settlement: { supersedes: 'settlement-original' } },
      ],
      error: null,
    };

    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByText('Incurred: 1 · 500.000₫')).toBeInTheDocument();
  });

  it('SM-C1: reads "None." rather than "0 · 0₫" when a figure is zero — no penalties at all', async () => {
    render(<MonthlyReport onClose={() => {}} />);

    await screen.findByText('Penalties');
    expect(screen.getByText('Incurred: None.')).toBeInTheDocument();
    expect(screen.getByText('Collected: None.')).toBeInTheDocument();
  });

  it('SM-C2 (counter-metric): median days to acknowledge, via any Declaration answered', async () => {
    settlementResults = [
      { data: [{ period: '2026-07-05' }], error: null }, // failed
      okEmpty, // clean
    ];
    declarationResult = { data: [{ answered_at: '2026-07-06T00:30:00Z' }], error: null };

    render(<MonthlyReport onClose={() => {}} />);

    expect(
      await screen.findByText('Median days to acknowledge the first Failed Day'),
    ).toBeInTheDocument();
    // Both SM-2 and SM-C2 render "1 day" here — SM-2 reads "No data" (no clean day), so this
    // heading's own value is the one non-"No data" day-count on the page.
    expect(screen.getAllByText('1 day').length).toBeGreaterThan(0);
  });

  it('SM-C3 (counter-metric): appeals rejected as a share filed', async () => {
    appealResults = [
      {
        data: [
          { created_at: '2026-07-10', penalty: { state: 'owed' } },
          { created_at: '2026-07-11', penalty: { state: 'owed' } },
          { created_at: '2026-07-12', penalty: { state: 'voided' } },
        ],
        error: null,
      },
      okEmpty, // ruled
    ];

    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByText('Appeals rejected as a share filed')).toBeInTheDocument();
    expect(screen.getByText('2 of 3 rejected (67%)')).toBeInTheDocument();
  });

  it('SM-C3: reads "No data" rather than a divide-by-zero with no appeals filed', async () => {
    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByText('No data — no appeals filed this month.')).toBeInTheDocument();
  });

  it('surfaces a failed read rather than a partial or silently wrong report', async () => {
    chainResult = { data: null, error: { message: 'boom' } };

    render(<MonthlyReport onClose={() => {}} />);

    expect(await screen.findByText('boom')).toBeInTheDocument();
  });

  it('closes back to the caller', async () => {
    const onClose = vi.fn();
    render(<MonthlyReport onClose={onClose} />);

    (await screen.findByText('Back to today')).click();
    expect(onClose).toHaveBeenCalled();
  });
});
