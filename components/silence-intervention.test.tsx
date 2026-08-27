import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { SilenceIntervention } from './silence-intervention';
import type { OwedCommitment } from '@/lib/declaration';

/**
 * Story 5.2 (FR-16): the day-two Silence intervention.
 *
 * Two things this file exists to prove, per the spec's own I/O Matrix. First, the copy
 * variant: "Declarations pending" when `owing` (the same signal `app/page.tsx` already uses
 * for MorningGate) is non-empty, "No Declarations pending" when it is not — never a debt
 * figure, an itemized list, or red anywhere in either. Second, the one concrete action: only
 * the "pending" variant renders MorningGate, unchanged, and hands it the exact `owing`/`now`/
 * `onAnswered` this component itself received — no second, parallel way to answer a Declaration.
 */

const maybeSingle = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: () => ({ select: () => ({ maybeSingle }) }),
  }),
}));

vi.mock('@/components/morning-gate', () => ({
  MorningGate: ({ ownerId, owing }: { ownerId: string; owing: OwedCommitment[] }) => (
    <p>{`MorningGate: ${ownerId}, ${owing.map((o) => o.name).join(', ')}`}</p>
  ),
}));

const gym: OwedCommitment = { id: 'c1', name: 'Gym', cadence: 'daily' };
const now = new Date('2026-08-21T07:30:00+07:00');

beforeEach(() => {
  maybeSingle.mockReset();
  maybeSingle.mockResolvedValue({ data: { remaining: 2 }, error: null });
});

describe('the Silence intervention', () => {
  it('names one concrete thing to do and opens no Declaration UI when nothing is outstanding', async () => {
    render(
      <SilenceIntervention
        ownerId="u1"
        startedDay="2026-08-19"
        owing={[]}
        now={now}
        onAnswered={vi.fn()}
        onOpenSettings={vi.fn()}
        onOpenLedger={vi.fn()}
      />,
    );

    expect(screen.getByRole('heading')).toHaveTextContent('Two quiet days');
    expect(
      await screen.findByText(
        "Two quiet days. This is the part where it usually ends. It doesn't have to. Do one thing today — TryHackMe, twenty minutes.",
      ),
    ).toBeInTheDocument();
    expect(screen.queryByText(/MorningGate/)).not.toBeInTheDocument();
    // No debt figure, no itemized list, no red — the copy above is the whole screen apart
    // from the Grace Days sentence (itself a digit, deliberately shown) and, when pending,
    // MorningGate. Checks for `formatDong`'s own unambiguous `₫` marker (2026-08-26 review
    // finding: the previous `\d,000` regex would miss any other money-shaped figure, e.g.
    // "$50") rather than a plain digit, since a bare digit alone is not itself a debt figure.
    expect(document.body.textContent).not.toContain('₫');
  });

  it('offers a way out once nothing is outstanding — Epic 5 retro, 2026-08-27, finding A4', async () => {
    const onOpenSettings = vi.fn();
    const onOpenLedger = vi.fn();
    render(
      <SilenceIntervention
        ownerId="u1"
        startedDay="2026-08-19"
        owing={[]}
        now={now}
        onAnswered={vi.fn()}
        onOpenSettings={onOpenSettings}
        onOpenLedger={onOpenLedger}
      />,
    );

    await screen.findByRole('heading');

    screen.getByRole('button', { name: 'Settings' }).click();
    expect(onOpenSettings).toHaveBeenCalledTimes(1);

    screen.getByRole('button', { name: 'Open the Ledger' }).click();
    expect(onOpenLedger).toHaveBeenCalledTimes(1);
  });

  it('never offers the escape hatch while MorningGate is the one concrete action (UX-DR6)', async () => {
    render(
      <SilenceIntervention
        ownerId="u1"
        startedDay="2026-08-19"
        owing={[gym]}
        now={now}
        onAnswered={vi.fn()}
        onOpenSettings={vi.fn()}
        onOpenLedger={vi.fn()}
      />,
    );

    await screen.findByText(/MorningGate/);
    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Open the Ledger' })).not.toBeInTheDocument();
  });

  it('names the specific outstanding days and opens MorningGate, unchanged, when 1+ are pending', async () => {
    const onAnswered = vi.fn();
    render(
      <SilenceIntervention
        ownerId="u1"
        startedDay="2026-08-19"
        owing={[gym]}
        now={now}
        onAnswered={onAnswered}
        onOpenSettings={vi.fn()}
        onOpenLedger={vi.fn()}
      />,
    );

    // 2026-08-19 is a Wednesday in Asia/Ho_Chi_Minh; the pair named is it and the day right
    // after it — the exact two asked-days enqueue_gate_reminders() itself checked.
    expect(
      await screen.findByText(
        "Two quiet days. This is the part where it usually ends. It doesn't have to. Wednesday and Thursday close tonight — answer them, and do one thing today.",
      ),
    ).toBeInTheDocument();

    // MorningGate itself, unchanged, carrying the exact owing list this component received —
    // no second, invented declaration-answering UI.
    expect(await screen.findByText('MorningGate: u1, Gym')).toBeInTheDocument();
  });

  it('states Grace Days remaining from the one source every spend surface reads', async () => {
    maybeSingle.mockResolvedValue({ data: { remaining: 1 }, error: null });
    render(
      <SilenceIntervention
        ownerId="u1"
        startedDay="2026-08-19"
        owing={[]}
        now={now}
        onAnswered={vi.fn()}
        onOpenSettings={vi.fn()}
        onOpenLedger={vi.fn()}
      />,
    );

    expect(await screen.findByText('1 Grace Day remaining this month.')).toBeInTheDocument();
  });

  it('surfaces a failed Grace Days read rather than silently treating it as zero', async () => {
    maybeSingle.mockResolvedValue({ data: null, error: { message: 'network error' } });
    render(
      <SilenceIntervention
        ownerId="u1"
        startedDay="2026-08-19"
        owing={[]}
        now={now}
        onAnswered={vi.fn()}
        onOpenSettings={vi.fn()}
        onOpenLedger={vi.fn()}
      />,
    );

    expect(await screen.findByText('network error')).toBeInTheDocument();
    expect(screen.queryByText(/Grace Day.* remaining/)).not.toBeInTheDocument();
  });
});
