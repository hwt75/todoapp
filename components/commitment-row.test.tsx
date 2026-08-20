import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { CommitmentRow, type RowCommitment } from './commitment-row';

/**
 * The row is the component every later surface reuses, and until now nothing rendered it.
 *
 * Epic 2's retrospective counted eleven components and zero component tests — the UI half of
 * Stories 2.3, 2.6 and 2.9, and the only half a check under `supabase/tests/` cannot reach. The
 * rules asserted here are the ones DESIGN.md and EXPERIENCE.md argue for rather than the ones a
 * snapshot would catch: what a screen reader hears, what colour is allowed to carry on its own,
 * and when a row is a control at all.
 */

const gym: RowCommitment = {
  id: 'c1',
  name: 'Gym',
  cadence: 'daily',
  carries_penalty: false,
  weekly_target: null,
  daily_minutes_target: null,
};

describe('a commitment row', () => {
  it('says one sentence rather than making the listener assemble it', () => {
    // "Gym, not yet done today" — not a name, then a pill, then a chain, each announced
    // separately. Every row, every morning, is the reason this is one label.
    render(<CommitmentRow commitment={gym} state="not_yet" />);

    const row = screen.getByRole('group');
    expect(row).toHaveAccessibleName('Gym, not yet done today');
  });

  it('names the money in the sentence, because a tint cannot', () => {
    render(<CommitmentRow commitment={{ ...gym, carries_penalty: true }} state="not_yet" />);

    expect(screen.getByRole('group')).toHaveAccessibleName(
      'Gym, not yet done today, missing this costs money',
    );
  });

  it('never lets colour be the only carrier of a state', () => {
    // The pill is `aria-hidden`, so its word is not read out — but it is on the screen for
    // anyone who cannot tell the four tint families apart, and the label carries the same
    // fact for anyone who cannot see it at all.
    render(<CommitmentRow commitment={gym} state="missed" />);

    expect(screen.getByText('Missed')).toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName('Gym, missed');
  });

  it('speaks the chain as a phrase and shows it as a written form', () => {
    render(<CommitmentRow commitment={gym} state="not_yet" chainDays={12} />);

    // "day 12" on the row; "holding 12 days" in the ear. A screen reader saying "Gym, not
    // yet done today, day 12" makes the listener work out what twelve counts.
    expect(screen.getByText('day 12')).toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName(
      'Gym, not yet done today, holding 12 days',
    );
  });

  it('says nothing at all about a chain that has just broken', () => {
    render(<CommitmentRow commitment={gym} state="missed" chainDays={0} />);

    // Never `day 0`. A row is not where a reset gets to be visible — that is the Chains
    // detail, where the longest chain is beside it and zero is read against a record.
    expect(screen.queryByText(/day 0/)).not.toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName('Gym, missed');
  });

  it('shows the target it is set up for, never a progress it cannot know', () => {
    render(
      <CommitmentRow
        commitment={{ ...gym, cadence: 'weekly_quota', weekly_target: 3 }}
        state="not_yet"
      />,
    );

    // `3×`, not `0/3`. Settlement owns every derived value (AD-8), and a row claiming
    // nothing has been done this week says something the screen cannot know.
    expect(screen.getByText(/3×/)).toBeInTheDocument();
    expect(screen.queryByText(/0\/3/)).not.toBeInTheDocument();
  });

  it('is a group until it has somewhere to go, and then it is a button', () => {
    const { rerender } = render(<CommitmentRow commitment={gym} state="not_yet" />);
    expect(screen.queryByRole('button')).not.toBeInTheDocument();

    const onOpen = vi.fn();
    rerender(<CommitmentRow commitment={gym} state="not_yet" onOpen={onOpen} />);
    expect(screen.getByRole('button')).toHaveAccessibleName('Gym, not yet done today');
  });

  it('opens with the commitment it was drawn from', async () => {
    const onOpen = vi.fn();
    render(<CommitmentRow commitment={gym} state="not_yet" onOpen={onOpen} />);

    await userEvent.click(screen.getByRole('button'));

    expect(onOpen).toHaveBeenCalledExactlyOnceWith(gym);
  });
});
