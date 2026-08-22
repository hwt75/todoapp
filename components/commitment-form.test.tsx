import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { CommitmentForm } from './commitment-form';
import { EMPTY_DRAFT, type CommitmentDraft } from '@/lib/commitment';

/**
 * Create or edit one commitment.
 *
 * `lib/commitment.test.ts` covers the rules; this covers the two things the form itself is
 * responsible for, both of which are ways the author could be told something untrue.
 *
 * **Switching cadence clears the previous cadence's target.** Otherwise a stale `weeklyTarget`
 * survives the switch, the form looks fine, and the database refuses the save on a constraint
 * about a field no longer on screen — `2-2-commitment-rules.sql` step 1 drives that refusal from
 * the other side, and this is the half that stops it happening at all.
 *
 * **Delete asks first, and says what it does not do.** The word is wrong on purpose: the UI says
 * delete, the database sets `archived_at`, and the history stays. Telling him his record is gone
 * when it is not would be the more comfortable lie.
 */

const weekly: CommitmentDraft = {
  ...EMPTY_DRAFT,
  name: 'Gym',
  cadence: 'weekly_quota',
  weeklyTarget: 3,
  weekStartDay: 1,
};

describe('the commitment form', () => {
  it('asks only for the targets the cadence actually needs', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    // Daily needs nothing beyond a name.
    expect(screen.queryByLabelText('Times a week')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Hours a day')).not.toBeInTheDocument();

    await userEvent.selectOptions(screen.getByLabelText('Cadence'), 'weekly_quota');
    expect(screen.getByLabelText('Times a week')).toBeInTheDocument();
    expect(screen.getByLabelText('Week starts on')).toBeInTheDocument();
    expect(screen.queryByLabelText('Hours a day')).not.toBeInTheDocument();
  });

  it('drops a target when the cadence that needed it is switched away', async () => {
    const onSave = vi.fn();
    render(<CommitmentForm initial={weekly} onSave={onSave} onCancel={vi.fn()} />);

    await userEvent.selectOptions(screen.getByLabelText('Cadence'), 'daily');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    // A leftover `3×` on a daily commitment is a number that would later be counted, and
    // the constraint refusing it names a field the author can no longer see.
    expect(onSave).toHaveBeenCalledOnce();
    expect(onSave.mock.calls[0][0]).toMatchObject({
      cadence: 'daily',
      weeklyTarget: null,
      weekStartDay: null,
    });
  });

  it('stores hours as minutes, because one unit at rest is one rounding decision', async () => {
    const onSave = vi.fn();
    render(<CommitmentForm onSave={onSave} onCancel={vi.fn()} />);

    await userEvent.type(screen.getByLabelText('Name'), 'Deep work');
    await userEvent.selectOptions(screen.getByLabelText('Cadence'), 'daily_hours_quota');
    await userEvent.type(screen.getByLabelText('Hours a day'), '1.5');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    expect(onSave.mock.calls[0][0]).toMatchObject({ dailyMinutesTarget: 90 });
  });

  it('will not save a half-filled form, and says which half', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    // Nothing typed: the save is unavailable and the reason is on screen rather than
    // waiting behind a click.
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    expect(screen.getByRole('list')).toBeInTheDocument();

    await userEvent.type(screen.getByLabelText('Name'), 'Gym');
    expect(screen.getByRole('button', { name: 'Save' })).toBeEnabled();
  });

  it('says plainly that nothing can check an abstain commitment', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    expect(screen.getByText(/None run yet/)).toBeInTheDocument();

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');

    // There is no sensor for a thing not done. Saying so is what keeps the morning answer
    // from looking like a formality the machine could have covered.
    expect(screen.getByText(/There is no sensor for a thing not done/)).toBeInTheDocument();
  });

  it('offers no Auto-check that could be turned on today', () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    const checks = screen
      .getAllByRole('checkbox')
      .filter((box) => box !== screen.getByLabelText(/Missing this costs money/));
    // Every one is disabled and unchecked. A togglable check that never runs is a promise
    // the product would break on the first day it mattered.
    for (const box of checks) {
      expect(box).toBeDisabled();
      expect(box).not.toBeChecked();
    }
  });

  it('never deletes on the first tap, and says the history stays', async () => {
    const onDelete = vi.fn();
    render(
      <CommitmentForm initial={weekly} onSave={vi.fn()} onCancel={vi.fn()} onDelete={onDelete} />,
    );

    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));
    expect(onDelete).not.toHaveBeenCalled();

    // The UI says delete; the database archives. Saying his record is gone would be the
    // more comfortable lie, and a ledger that cannot explain itself is the cost.
    expect(screen.getByText(/Its history stays in the ledger/)).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Keep it' }));
    expect(onDelete).not.toHaveBeenCalled();
    expect(screen.queryByText(/Its history stays in the ledger/)).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, delete it' }));
    expect(onDelete).toHaveBeenCalledOnce();
  });

  it('offers no delete at all on something that does not exist yet', () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.queryByRole('button', { name: 'Delete' })).not.toBeInTheDocument();
  });

  it('stops accepting taps while a save is in flight', () => {
    render(<CommitmentForm initial={weekly} busy onSave={vi.fn()} onCancel={vi.fn()} />);

    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled();
  });
});
