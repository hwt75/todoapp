import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MorningGate } from './morning-gate';
import type { OwedCommitment } from '@/lib/declaration';

/**
 * The blocking morning question — the surface with the most rules and, until now, no test.
 *
 * Two of them are load-bearing in a way a screenshot cannot show. The gate must block the *app*
 * and never the *device*: the accessibility review's single `high` finding was that a blocking
 * surface is the classic assistive-technology trap, so there is no `aria-modal`, no focus trap,
 * and nothing holding the VoiceOver rotor. And the two answers must be indistinguishable apart
 * from their words — tinting the honest answer green and the costly one red taxes telling the
 * truth, and nothing in this product can detect a lie.
 *
 * The write path is mocked at `createClient`, because what is under test is what the author sees
 * and what he can still do when the network is gone — not PostgREST.
 */

const insert = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({ from: () => ({ insert }) }),
}));

const gym: OwedCommitment = { id: 'c1', name: 'Gym', cadence: 'daily' };
const reading: OwedCommitment = { id: 'c2', name: 'Reading', cadence: 'weekly_quota' };

// A fixed morning, so the question names a day this test can state out loud.
//
// The clock is frozen to the same instant, and not for tidiness: the gate compares the day it
// drew the question from against the day of the tap, and a real clock would make every one of
// these tests read as a midnight rollover on any day but this one.
const morning = new Date('2026-08-19T07:30:00+07:00');

let user: ReturnType<typeof userEvent.setup>;

beforeEach(() => {
  insert.mockReset();
  insert.mockResolvedValue({ error: null });
  window.localStorage.clear();
  vi.useFakeTimers({ shouldAdvanceTime: true });
  vi.setSystemTime(morning);
  user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
});

afterEach(() => {
  vi.useRealTimers();
});

describe('the morning gate', () => {
  it('asks about yesterday, naming the commitment and the day', () => {
    render(<MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={vi.fn()} />);

    expect(screen.getByRole('heading')).toHaveTextContent('Yesterday');
    expect(screen.getByText('Did Gym hold on 2026-08-18?')).toBeInTheDocument();
  });

  it('asks one commitment at a time, and says how many are behind it', () => {
    // Four commitments on one screen invites answering them as a batch, and a batch answer
    // is the one most likely to be untrue for at least one of them.
    render(<MorningGate ownerId="u1" owing={[gym, reading]} now={morning} onAnswered={vi.fn()} />);

    expect(screen.getByText('Did Gym hold on 2026-08-18?')).toBeInTheDocument();
    expect(screen.queryByText(/Reading/)).not.toBeInTheDocument();
    expect(screen.getByText('1 more after this one.')).toBeInTheDocument();
  });

  it('offers exactly two answers and nothing else to do', () => {
    render(<MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={vi.fn()} />);

    const controls = screen.getAllByRole('button');
    expect(controls).toHaveLength(2);
    expect(controls.map((c) => c.textContent)).toEqual(['It held', 'I slipped']);
  });

  it('gives the two answers identical markup, so neither is the easy one', () => {
    render(<MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={vi.fn()} />);

    const [held, slipped] = screen.getAllByRole('button');

    // No class, no variant, no default, no pre-selection — the words are the only
    // difference. A styled pair would tax the honest answer, and declaring a slip is not
    // destructive, it is honest.
    expect(held.className).toBe(slipped.className);
    expect(held.getAttribute('type')).toBe(slipped.getAttribute('type'));
    expect(held.hasAttribute('autofocus')).toBe(slipped.hasAttribute('autofocus'));
    expect(held.getAttribute('aria-disabled')).toBe(slipped.getAttribute('aria-disabled'));
  });

  it('blocks the app without ever trapping the device', () => {
    const { container } = render(
      <MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={vi.fn()} />,
    );

    // The blocking is achieved by having nothing else to offer — the caller renders this
    // instead of the app. A rotor that cannot leave, or a Switch Control session with no
    // exit, would turn a design intention into a locked device.
    expect(container.querySelector('[aria-modal]')).toBeNull();
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(container.querySelector('[tabindex="-1"]')).toBeNull();
    expect(
      screen.getByText(/You can still close the app; the question will be waiting\./),
    ).toBeInTheDocument();
  });

  it('files the answer with the instant it was tapped, not the instant it was sent', async () => {
    const onAnswered = vi.fn();
    render(<MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={onAnswered} />);

    await user.click(screen.getByRole('button', { name: 'I slipped' }));

    expect(insert).toHaveBeenCalledOnce();
    const written = insert.mock.calls[0][0];
    expect(written.answer).toBe('slipped');
    expect(written.commitment_id).toBe('c1');
    // `answered_at` is the tap, and the whole supersession path depends on it: an answer
    // given in time and delivered after the deadline is a timely event delivered late.
    expect(Date.parse(written.answered_at)).not.toBeNaN();
    expect(written.idempotency_key).toBeTruthy();
    expect(onAnswered).toHaveBeenCalledWith('c1');
  });

  it('tells him it is saved on the device when the write does not go through', async () => {
    insert.mockResolvedValue({ error: { message: 'Failed to fetch' } });
    const onAnswered = vi.fn();
    render(<MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={onAnswered} />);

    await user.click(screen.getByRole('button', { name: 'It held' }));

    expect(await screen.findByText(/Saved on this device/)).toBeInTheDocument();
    // He answered. Being offline is not his failure to answer, so the gate lets him past
    // and the queue carries the tap instant with it.
    expect(onAnswered).toHaveBeenCalledWith('c1');
  });

  it('does not let him past when the server refused the answer', async () => {
    // A refusal is permanent — a rule that will never accept this write. Advancing would
    // tell him it is recorded when nothing is, and the day would expire against him.
    insert.mockResolvedValue({ error: { code: '42501', message: 'permission denied' } });
    const onAnswered = vi.fn();
    render(<MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={onAnswered} />);

    await user.click(screen.getByRole('button', { name: 'It held' }));

    expect(await screen.findByText(/Failed\./)).toBeInTheDocument();
    expect(onAnswered).not.toHaveBeenCalled();
  });

  it('refuses to file an answer against a day it was not asked about', async () => {
    // The question was drawn when the screen loaded; the database derives the day from the
    // tap. Across local midnight those disagree, and the client must not paper over it by
    // sending a date — AD-6 gives the server that job.
    const onAnswered = vi.fn();
    render(<MorningGate ownerId="u1" owing={[gym]} now={morning} onAnswered={onAnswered} />);

    // The screen has been open across local midnight — the shape this actually takes.
    vi.setSystemTime(new Date('2026-08-20T00:05:00+07:00'));

    await user.click(screen.getByRole('button', { name: 'It held' }));

    expect(await screen.findByText(/the day turned over/i)).toBeInTheDocument();
    expect(insert).not.toHaveBeenCalled();
    expect(onAnswered).not.toHaveBeenCalled();
  });

  it('draws nothing at all when there is nothing owed', () => {
    const { container } = render(
      <MorningGate ownerId="u1" owing={[]} now={morning} onAnswered={vi.fn()} />,
    );

    expect(container).toBeEmptyDOMElement();
  });
});
