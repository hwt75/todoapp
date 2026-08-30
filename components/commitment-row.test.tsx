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

  it('shows the live position once one is supplied, and states it aloud too', () => {
    // The sibling of the guard above: `weekly_quota_progress` (spec 3-3) is a source the row
    // is allowed to draw from, unlike a client-side tally. `3×` from the target string still
    // shows in the muted line — quotaPosition replaces the pill and the spoken sentence, not
    // the setup line beneath the name.
    render(
      <CommitmentRow
        commitment={{ ...gym, cadence: 'weekly_quota', weekly_target: 3 }}
        state="not_yet"
        quotaPosition={{ held: 1, target: 3, daysRemaining: 3 }}
      />,
    );

    expect(screen.getByText('1/3 · 3 days')).toBeInTheDocument();
    expect(screen.getByText(/3×/)).toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName('Gym, 1 of 3 this week, 3 days left');
  });

  it('flips the live position to the met label and family once the target is reached', () => {
    render(
      <CommitmentRow
        commitment={{ ...gym, cadence: 'weekly_quota', weekly_target: 3 }}
        state="not_yet"
        quotaPosition={{ held: 3, target: 3, daysRemaining: 4 }}
      />,
    );

    const pill = screen.getByText('3/3');
    expect(pill).toHaveClass('pill-held');
    expect(screen.queryByText(/day/)).not.toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName('Gym, 3 of 3 this week, held');
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

/**
 * Story 6.5 — the window state, through the same two seams the Weekly Quota position uses.
 *
 * The clock arithmetic itself belongs to `lib/timed-window.ts` and is driven to the second
 * there. What the row owns is which of two positions takes the pill when a commitment carries
 * both, and that the sentence a screen reader hears never disagrees with what the pill shows.
 */
const pill: RowCommitment = {
  ...gym,
  name: 'Pill',
  due_time: '20:00:00',
  late_window_minutes: 30,
};

/** 20:10 in Ho Chi Minh City, written as the UTC instant so no machine's own zone decides. */
const at = (hhmm: string) => {
  const [h, m] = hhmm.split(':').map(Number);
  return new Date(Date.UTC(2026, 7, 30, h - 7, m, 0));
};

const unclaimed = { dueTime: '20:00:00', lateWindowMinutes: 30, claimed: false, proven: false };

describe('a timed commitment row', () => {
  it('shows the hour it opens, and says so aloud', () => {
    render(
      <CommitmentRow
        commitment={pill}
        state="not_yet"
        windowPosition={unclaimed}
        now={at('08:00')}
      />,
    );

    expect(screen.getByText('20:00')).toHaveClass('pill-neutral');
    expect(screen.getByRole('group')).toHaveAccessibleName('Pill, window opens at 20:00');
  });

  it('reads shut as failed, and never as a verdict for a day still running', () => {
    render(
      <CommitmentRow
        commitment={pill}
        state="not_yet"
        windowPosition={unclaimed}
        now={at('22:00')}
      />,
    );

    expect(screen.getByText('Shut')).toHaveClass('pill-failed');
    // "nothing claimed", never "missed": settlement is the only thing that files a verdict.
    expect(screen.getByRole('group')).toHaveAccessibleName('Pill, window shut, nothing claimed');
  });

  it('keeps the state it was given underneath — a window is not a verdict', () => {
    render(
      <CommitmentRow
        commitment={pill}
        state="not_yet"
        windowPosition={{ ...unclaimed, claimed: true, proven: true }}
        now={at('20:40')}
      />,
    );

    expect(screen.getByText('Proven')).toHaveClass('pill-held');
  });

  // A timed Weekly Quota commitment carries both positions at once (Story 6.4, decision 6).
  it('gives the pill to the window and keeps the week in the sentence', () => {
    render(
      <CommitmentRow
        commitment={{ ...pill, cadence: 'weekly_quota', weekly_target: 3 }}
        state="not_yet"
        windowPosition={unclaimed}
        quotaPosition={{ held: 1, target: 3, daysRemaining: 3 }}
        now={at('20:10')}
      />,
    );

    expect(screen.getByText('Open now')).toHaveClass('pill-urgent');
    expect(screen.queryByText('1/3 · 3 days')).not.toBeInTheDocument();
    expect(screen.getByRole('group')).toHaveAccessibleName(
      'Pill, window open now, until 20:30, 1 of 3 this week, 3 days left',
    );
  });

  it('is untouched without an instant to read the window against', () => {
    render(<CommitmentRow commitment={pill} state="not_yet" windowPosition={unclaimed} />);

    expect(screen.getByText('Not yet')).toHaveClass('pill-neutral');
    expect(screen.getByRole('group')).toHaveAccessibleName('Pill, not yet done today');
  });
});
