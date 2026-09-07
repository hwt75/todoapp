import { createElement } from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useGate } from '@/lib/use-gate';

/**
 * The hook that decides what the morning question asks about — and, until 2026-09-07, the only
 * decision in this product of that weight with no test at all.
 *
 * That absence is why a regression reached the live project. `20260907100000` moved
 * `declaration_derive_day()` onto `due_time_as_of()`, so on the day a due time is switched on the
 * server refuses a same-day claim and names this question as the way to answer instead. This hook
 * read the live `commitment.due_time`, so it skipped exactly that commitment: the claim was
 * refused, the question was never asked, and settlement charged the author for the silence.
 *
 * What is asserted here is only the seam this hook owns — which value decides whether a
 * commitment is asked about. `commitmentsOwing` is pure and tested against every other boundary
 * in `lib/declaration.test.ts`; nothing here re-tests it.
 *
 * It sits under `components/` rather than beside the hook because rendering needs a DOM, and the
 * `lib` vitest project runs in node: `vitest.config` gives jsdom to `components/**` only.
 */

const rows: Record<string, unknown> = {};

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      const result = () => rows[table] ?? { data: [], error: null };
      const query = {
        select: () => query,
        eq: () => query,
        maybeSingle: () => Promise.resolve(result()),
        then: (resolve: (value: unknown) => unknown) => Promise.resolve(result()).then(resolve),
      };
      return query;
    },
  }),
}));

/** Surfaces the one thing the hook returns that this file is about. */
function Probe() {
  const { owing } = useGate('u1');
  return createElement(
    'ul',
    null,
    owing.map((c) => createElement('li', { key: c.id }, c.name)),
  );
}

const gym = { id: 'c1', name: 'Gym', cadence: 'daily', archived_at: null, due_time: null };
/** Live column says timed. What that means for *yesterday* is the view's to say. */
const pill = { id: 'c2', name: 'Pill', cadence: 'daily', archived_at: null, due_time: '20:00' };

beforeEach(() => {
  for (const key of Object.keys(rows)) delete rows[key];
  // Hour 0, so the question is being asked whatever time this file runs at.
  rows.profile = { data: { morning_hour: 0 }, error: null };
  rows.declaration = { data: [], error: null };
});

describe('which value decides whether a commitment is asked about', () => {
  it('asks about a day no time governed, even though the commitment carries one now', async () => {
    rows.commitment = { data: [pill], error: null };
    rows.morning_question_day = {
      data: [{ commitment_id: 'c2', governing_due_time: null }],
      error: null,
    };

    render(createElement(Probe));

    // The commitment whose time was switched on part-way through yesterday. The server refuses a
    // same-day claim for that day and points here; if this question skips it too, the day cannot
    // be answered at all and settles as silence with a penalty.
    expect(await screen.findByText('Pill')).toBeInTheDocument();
  });

  it('does not ask about a day a time governed all the way through', async () => {
    rows.commitment = { data: [pill], error: null };
    rows.morning_question_day = {
      data: [{ commitment_id: 'c2', governing_due_time: '20:00' }],
      error: null,
    };

    render(createElement(Probe));

    // Decided at its own midnight. Asking again offers a second, softer answer to a day the
    // machine has already judged.
    await waitFor(() => expect(screen.queryByText('Gym')).not.toBeInTheDocument());
    expect(screen.queryByText('Pill')).not.toBeInTheDocument();
  });

  it('still asks about an ordinary untimed commitment', async () => {
    rows.commitment = { data: [gym], error: null };
    rows.morning_question_day = {
      data: [{ commitment_id: 'c1', governing_due_time: null }],
      error: null,
    };

    render(createElement(Probe));

    expect(await screen.findByText('Gym')).toBeInTheDocument();
  });

  it('falls back to the live column when the governing read gives nothing', async () => {
    rows.commitment = { data: [gym, pill], error: null };
    rows.morning_question_day = { data: [], error: null };

    render(createElement(Probe));

    // Asking too little is what costs money; asking too much costs a question. So a view that
    // answers nothing leaves the behaviour exactly as it was before the view existed, rather
    // than silently emptying the morning question.
    expect(await screen.findByText('Gym')).toBeInTheDocument();
    expect(screen.queryByText('Pill')).not.toBeInTheDocument();
  });
});
