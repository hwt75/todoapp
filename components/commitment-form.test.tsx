import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';
import { CommitmentForm } from './commitment-form';
import {
  EMPTY_DRAFT,
  KEPT_PHOTO_COPY,
  REFEREE_SIGN_OFF_COPY,
  TIMED_COMMITMENT_COPY,
  type CommitmentDraft,
} from '@/lib/commitment';

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

/**
 * Story 8.1 — the control that asks the referee for his signature.
 *
 * The inverse of the 6.8 block above. That one asserts the *absence* of cost copy, because a
 * photo that decides nothing must not borrow the timed warning's stakes. This flag does decide a
 * day from Story 8.2 on, so the sentence has to be there — and has to say the thing a database
 * cannot say: that his friend forgetting costs him nothing.
 *
 * Three disabled cases, mutually exclusive, each with its own sentence. The fourth refusal —
 * a photo — is deliberately not one of them: switching sign-off on switches the photo on, so the
 * author is never refused for a state he was not offered the chance to choose.
 */
describe('asking the referee to sign a commitment off', () => {
  const signable: CommitmentDraft = {
    ...EMPTY_DRAFT,
    name: 'Thuốc',
    requiresPhoto: true,
  };

  it('is disabled on a kind with nothing done to sign, and says so', async () => {
    render(<CommitmentForm hasReferee onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');

    expect(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label)).toBeDisabled();
    expect(screen.getByText(REFEREE_SIGN_OFF_COPY.wrongKind)).toBeInTheDocument();
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.autoChecked)).not.toBeInTheDocument();
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.noReferee)).not.toBeInTheDocument();
  });

  it('is disabled when a machine already answers, and says so', async () => {
    render(<CommitmentForm hasReferee onSave={vi.fn()} onCancel={vi.fn()} />);

    await userEvent.click(screen.getByLabelText('Account elsewhere'));

    expect(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label)).toBeDisabled();
    expect(screen.getByText(REFEREE_SIGN_OFF_COPY.autoChecked)).toBeInTheDocument();
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.wrongKind)).not.toBeInTheDocument();
  });

  it('is disabled with no referee paired, and says where to pair one', () => {
    // A *known* no. `has_paired_referee()` has to have answered before the control is greyed.
    render(<CommitmentForm hasReferee={false} onSave={vi.fn()} onCancel={vi.fn()} />);

    expect(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label)).toBeDisabled();
    expect(screen.getByText(REFEREE_SIGN_OFF_COPY.noReferee)).toBeInTheDocument();
    expect(screen.getByText(REFEREE_SIGN_OFF_COPY.noReferee).textContent).toMatch(/Settings/);
  });

  it('is left alone while the pairing is still unknown, rather than greyed on a guess', () => {
    // `undefined` is "not asked yet, or the asking failed" and is not a no. Greying on it would
    // be the form deciding an outcome the server was never asked about (AD-1), and the trigger
    // refuses the save with its own sentence if there really is nobody to ask.
    render(<CommitmentForm onSave={vi.fn()} onCancel={vi.fn()} />);

    expect(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label)).toBeEnabled();
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.noReferee)).not.toBeInTheDocument();
  });

  it('is offered once a referee is paired, with no explanation in the way', () => {
    render(<CommitmentForm hasReferee onSave={vi.fn()} onCancel={vi.fn()} />);

    expect(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label)).toBeEnabled();
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.noReferee)).not.toBeInTheDocument();
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.wrongKind)).not.toBeInTheDocument();
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.autoChecked)).not.toBeInTheDocument();
  });

  it('says nothing about a referee until the flag is on', async () => {
    render(<CommitmentForm hasReferee onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.queryByText(REFEREE_SIGN_OFF_COPY.warning)).not.toBeInTheDocument();

    await userEvent.click(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label));

    expect(screen.getByText(REFEREE_SIGN_OFF_COPY.warning)).toBeInTheDocument();
  });

  it('turns the photo requirement on with it', async () => {
    const onSave = vi.fn();
    render(<CommitmentForm hasReferee onSave={onSave} onCancel={vi.fn()} />);

    await userEvent.type(screen.getByLabelText('Name'), 'Thuốc');
    expect(screen.getByLabelText('Keep a photo against this')).not.toBeChecked();

    await userEvent.click(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label));

    // `commitment_sign_off_implies_photo` would refuse the save otherwise, for a state the
    // author was never offered the chance to choose.
    expect(screen.getByLabelText('Keep a photo against this')).toBeChecked();

    await userEvent.click(screen.getByRole('button', { name: 'Save' }));
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({ requiresRefereeApproval: true, requiresPhoto: true }),
    );
  });

  it('stops the photo helper promising the photo decides nothing', async () => {
    render(<CommitmentForm hasReferee onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.getByText(KEPT_PHOTO_COPY.untimed)).toBeInTheDocument();

    await userEvent.click(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label));

    // The A2 defect one step earlier: with sign-off on, the photo is exactly what the referee
    // reads, so a line saying nothing reads it is the app promising what the rules do not keep.
    expect(screen.queryByText(/never decides a day/)).not.toBeInTheDocument();
    expect(screen.getByText(KEPT_PHOTO_COPY.signedOff)).toBeInTheDocument();
  });

  /*
   * Story 8.3 — the same promise, on the day the author takes the flag *off*.
   *
   * Every test above drives the flag on only, which is why none of them caught this: the form
   * was the fourth reader of a flag every other reader takes **as of the day**, and it read the
   * live draft. Untick sign-off at 10:00 on a commitment that was flagged when the day began,
   * and this helper said "Nothing reads it: it never decides a day" while the widened referee
   * policies still let the referee open today's photograph and `sign_off_day()` still accepted a
   * refusal that costs a penalty. The condition moved to `|| signedOffToday`; the three
   * sentences did not change.
   */
  it('keeps naming the referee after sign-off is unticked on a day it was on', async () => {
    render(
      <CommitmentForm
        initial={{ ...signable, requiresRefereeApproval: true }}
        hasReferee
        signedOffToday
        onSave={vi.fn()}
        onCancel={vi.fn()}
      />,
    );

    await userEvent.click(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label));
    expect(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label)).not.toBeChecked();

    // The draft flag is now off and today's answer is still true, which is the whole of the
    // window this closes. The save is real and takes effect tomorrow; today the photograph is
    // still the thing his referee signs off on.
    expect(screen.queryByText(/never decides a day/)).not.toBeInTheDocument();
    expect(screen.getByText(KEPT_PHOTO_COPY.signedOff)).toBeInTheDocument();
  });

  it('says the photo decides nothing once the day it was flagged on has passed', async () => {
    // The same unticked draft, a day later: `signedOffToday` is now false, and the sentence is
    // true again. Without this the test above would pass on a form that had simply stopped
    // being able to say `untimed` at all.
    render(
      <CommitmentForm
        initial={{ ...signable, requiresRefereeApproval: true }}
        hasReferee
        signedOffToday={false}
        onSave={vi.fn()}
        onCancel={vi.fn()}
      />,
    );

    await userEvent.click(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label));

    expect(screen.getByText(/never decides a day/)).toBeInTheDocument();
    expect(screen.queryByText(KEPT_PHOTO_COPY.signedOff)).not.toBeInTheDocument();
  });

  it('falls back to the draft flag for a commitment that does not exist yet', async () => {
    // A new commitment has no id and therefore no history to read, so `signedOffToday` is
    // `undefined` — the same third state `hasReferee` carries, and it must not read as `false`
    // in one direction or `true` in the other. The draft alone governs, which is what this form
    // did before Story 8.3.
    render(<CommitmentForm hasReferee onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.getByText(KEPT_PHOTO_COPY.untimed)).toBeInTheDocument();

    await userEvent.click(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label));
    expect(screen.getByText(KEPT_PHOTO_COPY.signedOff)).toBeInTheDocument();
  });

  it('shows the conflict rather than swallowing it when an Auto-check is added afterwards', async () => {
    const onSave = vi.fn();
    render(
      <CommitmentForm
        initial={{ ...signable, requiresRefereeApproval: true }}
        hasReferee
        onSave={onSave}
        onCancel={vi.fn()}
      />,
    );

    await userEvent.click(screen.getByLabelText('Account elsewhere'));
    await userEvent.type(screen.getByLabelText('Account'), 'my-handle');

    // The flag is not silently cleared. The save is refused with a sentence, and the author
    // decides which of the two answers to this one question he wants.
    expect(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label)).toBeChecked();
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    expect(onSave).not.toHaveBeenCalled();
  });

  it('drops the flag when the kind that could carry it is switched away', async () => {
    const onSave = vi.fn();
    render(
      <CommitmentForm
        initial={{ ...signable, requiresRefereeApproval: true }}
        hasReferee
        onSave={onSave}
        onCancel={vi.fn()}
      />,
    );

    await userEvent.selectOptions(screen.getByLabelText('Kind'), 'abstain');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    // The photo stays; only the signature goes, because only the signature has a constraint
    // naming a control the author can no longer see.
    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({ requiresRefereeApproval: false, requiresPhoto: true }),
    );
  });
});

/**
 * Story 8.1 — the author is never locked out of his own flagged commitment.
 *
 * The database is deliberately kinder than a naive mirror would be. `commitment_sign_off_needs_a
 * _referee()` fires only on a write that turns the flag *on*, so a pairing revoked afterwards
 * leaves flagged days to auto-approve rather than making the row unsaveable — the SPEC's own
 * "no enforcement that a pairing stays", and Step 6 of the SQL test.
 *
 * A form that refused the save AND greyed the control would be stricter than the rule it mirrors,
 * and would leave him unable to save and unable to untick. Both halves are asserted here because
 * either alone is enough to trap him.
 */
describe('a flagged commitment whose referee is gone', () => {
  const flagged: CommitmentDraft = {
    ...EMPTY_DRAFT,
    name: 'Thuốc',
    requiresPhoto: true,
    requiresRefereeApproval: true,
  };

  for (const [when, hasReferee] of [
    ['the pairing was revoked', false],
    ['the pairing could not be read', undefined],
  ] as const) {
    it(`can still be saved when ${when}`, async () => {
      const onSave = vi.fn();
      render(
        <CommitmentForm
          initial={flagged}
          hasReferee={hasReferee}
          onSave={onSave}
          onCancel={vi.fn()}
        />,
      );

      expect(screen.getByRole('button', { name: 'Save' })).toBeEnabled();

      await userEvent.click(screen.getByRole('button', { name: 'Save' }));
      expect(onSave).toHaveBeenCalledWith(
        expect.objectContaining({ requiresRefereeApproval: true }),
      );
    });

    it(`can still be unticked when ${when}`, async () => {
      const onSave = vi.fn();
      render(
        <CommitmentForm
          initial={flagged}
          hasReferee={hasReferee}
          onSave={onSave}
          onCancel={vi.fn()}
        />,
      );

      // Never disabled while ticked. Whatever the refusal, the way out is the tick that caused it.
      const control = screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label);
      expect(control).toBeEnabled();

      await userEvent.click(control);
      expect(control).not.toBeChecked();

      // And clearing it leaves a saveable draft — the photo stays, which nothing refuses.
      await userEvent.click(screen.getByRole('button', { name: 'Save' }));
      expect(onSave).toHaveBeenCalledWith(
        expect.objectContaining({ requiresRefereeApproval: false, requiresPhoto: true }),
      );
    });
  }

  it('holds the photo on while sign-off is on, and hands it back when it comes off', async () => {
    render(<CommitmentForm initial={flagged} hasReferee onSave={vi.fn()} onCancel={vi.fn()} />);

    // `commitment_sign_off_implies_photo` refuses the combination outright, so a photo control
    // that could be unticked here would offer nothing but a refused save.
    const photo = screen.getByLabelText('Keep a photo against this');
    expect(photo).toBeChecked();
    expect(photo).toBeDisabled();

    await userEvent.click(screen.getByLabelText(REFEREE_SIGN_OFF_COPY.label));
    expect(screen.getByLabelText('Keep a photo against this')).toBeEnabled();
  });
});
