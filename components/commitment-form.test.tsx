import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { CommitmentForm } from './commitment-form';
import { EMPTY_DRAFT, TIMED_COMMITMENT_COPY, type CommitmentDraft } from '@/lib/commitment';

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

const timed: CommitmentDraft = {
  ...EMPTY_DRAFT,
  name: 'Pill',
  dueTime: '20:00',
  lateWindowMinutes: 30,
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

    expect(screen.getByText(/Location with dwell, Phone movement and Timer/)).toBeInTheDocument();

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');

    // There is no sensor for a thing not done. Saying so is what keeps the morning answer
    // from looking like a formality the machine could have covered.
    expect(screen.getByText(/There is no sensor for a thing not done/)).toBeInTheDocument();
  });

  it('disables every Auto-check on an abstain commitment, including Account elsewhere', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');

    // Two checkboxes on this form are not Auto-checks and are never disabled by kind: money,
    // and the photo an author keeps for himself (Story 6.8, which every kind can carry).
    const checks = screen
      .getAllByRole('checkbox')
      .filter(
        (box) =>
          box !== screen.getByLabelText(/Missing this costs money/) &&
          box !== screen.getByLabelText('Keep a photo against this'),
      );
    // Every one is disabled and unchecked, Account elsewhere included: there is no sensor
    // for a thing not done, so the checkbox stays disabled exactly as it was before Story
    // 4.1 wired it up for every other kind.
    for (const box of checks) {
      expect(box).toBeDisabled();
      expect(box).not.toBeChecked();
    }
  });

  it('unchecks Account elsewhere when switching to a kind with no sensor for it', async () => {
    // A linked commitment edited into Avoid it must not leave the checkbox checked and
    // disabled at once — that would be a control with no way left to uncheck it.
    render(
      <CommitmentForm
        initial={{
          ...EMPTY_DRAFT,
          name: 'TryHackMe',
          autoCheckEnabled: true,
          autoCheckAccountRef: 'my-handle',
        }}
        onSave={vi.fn()}
        onCancel={vi.fn()}
      />,
    );

    expect(screen.getByLabelText('Account elsewhere')).toBeChecked();

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');

    const accountElsewhere = screen.getByLabelText('Account elsewhere');
    expect(accountElsewhere).toBeDisabled();
    expect(accountElsewhere).not.toBeChecked();
  });

  it('offers Account elsewhere as a live checkbox, and leaves the rest disabled', () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    // Account elsewhere is the one Auto-check Story 4.1 wires up.
    const accountElsewhere = screen.getByLabelText('Account elsewhere');
    expect(accountElsewhere).toBeEnabled();
    expect(accountElsewhere).not.toBeChecked();

    // Location/Phone/Timer stay disabled placeholders — Epic 4 does not build them yet.
    for (const label of ['Location with dwell', 'Phone movement', 'Timer']) {
      const box = screen.getByLabelText(label);
      expect(box).toBeDisabled();
      expect(box).not.toBeChecked();
    }
  });

  it('asks for an account only once Account elsewhere is checked, and needs it non-blank', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.type(screen.getByLabelText('Name'), 'TryHackMe');
    expect(screen.queryByLabelText('Account')).not.toBeInTheDocument();

    await userEvent.click(screen.getByLabelText('Account elsewhere'));
    expect(screen.getByLabelText('Account')).toBeInTheDocument();
    // No live fetch or validation happens at link time — only that something was typed.
    expect(screen.getByText(/needs an account identifier/)).toBeInTheDocument();
    // The problem text alone doesn't stop a save — confirm the button is actually the
    // thing enforcing it.
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();

    await userEvent.type(screen.getByLabelText('Account'), 'my-handle');
    expect(screen.getByRole('button', { name: 'Save' })).toBeEnabled();
  });

  it('discloses the machine-stands rule only once both the Penalty and an Auto-check are on', async () => {
    // FR-2a's disclosure has to be seen at setup time, before it ever costs money — not
    // discovered the day it first matters. Guarded by exactly the same "both toggles" that
    // decides whether FR-2a can even apply, no more and no less.
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    const disclosure = /the Auto-check's result will stand once it reports a miss/;

    // Neither toggle on.
    expect(screen.queryByText(disclosure)).not.toBeInTheDocument();

    // Penalty on, no Auto-check yet.
    await userEvent.click(screen.getByLabelText(/Missing this costs money/));
    expect(screen.queryByText(disclosure)).not.toBeInTheDocument();

    // Both on.
    await userEvent.click(screen.getByLabelText('Account elsewhere'));
    expect(screen.getByText(disclosure)).toBeInTheDocument();

    // Auto-check back off, Penalty still on: gone again.
    await userEvent.click(screen.getByLabelText('Account elsewhere'));
    expect(screen.queryByText(disclosure)).not.toBeInTheDocument();
  });

  it('never discloses the machine-stands rule on a commitment nothing can check', async () => {
    // An abstain commitment can carry a Penalty but never an Auto-check (no sensor for a
    // thing not done) -- checksPossible being false must suppress the disclosure even with
    // carriesPenalty on, the same guard commitment-form.tsx itself uses.
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.click(screen.getByLabelText(/Missing this costs money/));
    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');

    expect(
      screen.queryByText(/the Auto-check's result will stand once it reports a miss/),
    ).not.toBeInTheDocument();
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

/**
 * Story 6.1 — the time controls.
 *
 * `lib/commitment.test.ts` covers the rules. This covers the three things the form itself is
 * responsible for: offering the controls only where a moment exists, not leaving a time behind
 * on a commitment that can no longer carry one, and saying what a time costs before it is saved.
 */
describe('the time of day on a commitment form', () => {
  it('is offered on a commitment with a moment, and not on one without', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.getByLabelText('Time of day')).toBeInTheDocument();

    // Nothing happens at an instant when the commitment is a thing not done.
    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');
    expect(screen.queryByLabelText('Time of day')).not.toBeInTheDocument();

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'do');
    expect(screen.getByLabelText('Time of day')).toBeInTheDocument();

    // And an Hours-per-day commitment is judged by banked minutes, never by a moment.
    await userEvent.selectOptions(screen.getByLabelText('Cadence'), 'daily_hours_quota');
    expect(screen.queryByLabelText('Time of day')).not.toBeInTheDocument();
  });

  it('asks for a window only once a time is set, and fills in a default', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.queryByLabelText('Late window, in minutes')).not.toBeInTheDocument();

    await userEvent.type(screen.getByLabelText('Time of day'), '20:00');

    // The two are refused separately by the database, so offering them one at a time would
    // show the author a problem he had not yet had a chance to cause.
    expect(screen.getByLabelText('Late window, in minutes')).toHaveValue(30);
  });

  it('says what a time costs, in full, before it is saved', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.queryByText(TIMED_COMMITMENT_COPY.warning)).not.toBeInTheDocument();

    await userEvent.type(screen.getByLabelText('Time of day'), '20:00');
    expect(screen.getByText(TIMED_COMMITMENT_COPY.warning)).toBeInTheDocument();
  });

  it('drops a time when the kind that could carry it is switched away', async () => {
    const onSave = vi.fn();
    render(<CommitmentForm initial={timed} onSave={onSave} onCancel={vi.fn()} />);

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    // A leftover time on an abstention is refused by a constraint naming a field the author
    // can no longer see — the same failure mode a stale cadence target has.
    expect(onSave).toHaveBeenCalledOnce();
    expect(onSave.mock.calls[0][0]).toMatchObject({ dueTime: null, lateWindowMinutes: null });
  });

  it('will not save a window that runs past midnight, and says so', async () => {
    const onSave = vi.fn();
    render(
      <CommitmentForm
        initial={{ ...timed, dueTime: '23:30', lateWindowMinutes: 60 }}
        onSave={onSave}
        onCancel={vi.fn()}
      />,
    );

    expect(screen.getByText('The late window has to end before midnight.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    expect(onSave).not.toHaveBeenCalled();
  });
});

/**
 * Story 6.8 — the checkbox for a photo that decides nothing.
 *
 * Two properties, both of which a later "consistency" edit could plausibly break: it is offered
 * where a time is not, and it carries no warning. `TIMED_COMMITMENT_COPY.warning` exists because
 * a missing photo on a timed commitment costs 500,000₫; putting the same sentence here would be
 * a lie about the stakes, since nothing at all is at stake.
 */
describe('keeping a photo against a commitment', () => {
  it('is offered on an Avoid-it commitment, which can never carry a time', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');

    expect(screen.queryByLabelText('Time of day')).not.toBeInTheDocument();
    expect(screen.getByLabelText('Keep a photo against this')).toBeInTheDocument();
  });

  it('is offered on an Hours-per-day commitment too', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.selectOptions(screen.getByLabelText('Cadence'), 'daily_hours_quota');

    expect(screen.queryByLabelText('Time of day')).not.toBeInTheDocument();
    expect(screen.getByLabelText('Keep a photo against this')).toBeInTheDocument();
  });

  it('says nothing about failed days, because none is true', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.click(screen.getByLabelText('Keep a photo against this'));

    expect(screen.queryByText(TIMED_COMMITMENT_COPY.warning)).not.toBeInTheDocument();
    expect(screen.queryByText(/failed day/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/Grace Day/i)).not.toBeInTheDocument();
  });

  it('does not name what settles the day, which differs by cadence', async () => {
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.selectOptions(screen.getByLabelText('Cadence'), 'daily_hours_quota');

    // An Hours-per-day commitment is judged by banked Focus minutes and never by a declaration
    // (`commitments_owing()` excludes the cadence outright), so a line promising that "your
    // morning answer still settles this" would be false on exactly this screen.
    // Asserted on the help line itself, not on the screen: the Auto-checks block beside it
    // legitimately says "never by a morning answer" about this very cadence.
    const help = screen.getByText(/never decides a day/);
    expect(help.textContent).not.toMatch(/morning answer/);
    expect(help.textContent).not.toMatch(/settles/);
  });

  it('does not contradict the timed warning when a time is set', async () => {
    render(<CommitmentForm initial={timed} onSave={vi.fn()} onCancel={vi.fn()} />);

    // Both lines are on screen at once. The timed warning says the photo settles the day; the
    // untimed line says nothing reads it. Only one of them can be true of this commitment, and
    // Today shows only Epic 6's own control for it — so this one says so instead.
    expect(screen.getByText(TIMED_COMMITMENT_COPY.warning)).toBeInTheDocument();
    expect(screen.queryByText(/never decides a day/)).not.toBeInTheDocument();
    expect(screen.getByText(/adds nothing while it has a time/)).toBeInTheDocument();
  });

  it('is off until it is switched on, and reaches the save as it was left', async () => {
    const onSave = vi.fn();
    render(<CommitmentForm onSave={onSave} onCancel={vi.fn()} />);

    await userEvent.type(screen.getByLabelText('Name'), 'Sketchbook');
    expect(screen.getByLabelText('Keep a photo against this')).not.toBeChecked();

    await userEvent.click(screen.getByLabelText('Keep a photo against this'));
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ requiresPhoto: true }));
  });

  it('keeps the flag when the kind changes to one that cannot be timed', async () => {
    const onSave = vi.fn();
    render(<CommitmentForm initial={timed} onSave={onSave} onCancel={vi.fn()} />);

    await userEvent.click(screen.getByLabelText('Keep a photo against this'));
    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    // The time goes with the kind; the photo does not. A flag that quietly switched itself off
    // would only ever be discovered by the record that never got kept.
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({ dueTime: null, requiresPhoto: true }),
    );
  });
});
