'use client';

import { useState } from 'react';
import { dayInQuestion, questionFor, type OwedCommitment } from '@/lib/declaration';
import { submitDeclaration, type QueuedClaim } from '@/lib/declaration-write';
import { dayRolledOver } from '@/lib/declaration-submit';

type Sending =
  { kind: 'idle' } | { kind: 'sending' } | { kind: 'queued' } | { kind: 'failed'; reason: string };

/**
 * The morning question, and the one thing on the screen until it is answered.
 *
 * **It blocks the app and never the device.** There is no focus trap here, no
 * `aria-modal`, and no interception of the back gesture — deliberately. The accessibility
 * review's one `high` finding was that a blocking gate is the classic assistive-technology
 * trap: a VoiceOver rotor that cannot leave, or a Switch Control session with no exit,
 * turns a design intention into a locked device.
 *
 * So the blocking is achieved by *having nothing else to offer*. The caller renders this
 * instead of the rest of the app, so there is genuinely nothing else to navigate to, and
 * every ordinary escape still works: the app closes, the notification is dismissable at
 * the OS level, and the rotor moves freely because nothing is holding it.
 *
 * **The two answers look identical**, and that is the load-bearing rule of the whole
 * design system. Tinting the honest answer green and the costly one red taxes telling the
 * truth, and nothing in this product can detect a lie. A single false declaration destroys
 * the mechanism in a way that losing money does not.
 */
export function MorningGate({
  ownerId,
  owing,
  now,
  onAnswered,
}: {
  ownerId: string;
  owing: OwedCommitment[];
  now: Date;
  onAnswered: (commitmentId: string) => void;
}) {
  const [sending, setSending] = useState<Sending>({ kind: 'idle' });

  // One at a time. Four commitments on one screen invites answering them as a batch, and a
  // batch answer is the one most likely to be untrue for at least one of them.
  const commitment = owing[0];
  const day = dayInQuestion(now);

  if (!commitment) return null;

  async function answer(value: 'held' | 'slipped') {
    setSending({ kind: 'sending' });

    // Everything below can throw — a client built without its environment, a blocked
    // localStorage, a missing crypto in a non-secure context. Unhandled, the state stays
    // `sending`, both controls stay disabled, and because the gate is deliberately the only
    // thing on screen the app becomes a dead page with two greyed buttons. Blocking by
    // having nothing else to offer must never become blocking by being broken.
    try {
      const tappedAt = new Date();

      // The question was drawn from the instant this screen loaded; the database derives
      // the day from the instant of the tap. Across local midnight those disagree, and the
      // answer would land on a day he was never asked about while the day he *was* asked
      // about stayed open forever. The client must not fix that by sending a date — AD-6
      // gives the server that job — so it notices and asks again.
      if (dayRolledOver(day, tappedAt)) {
        setSending({
          kind: 'failed',
          reason:
            'The day turned over while this was open, so this answer would have been filed ' +
            'against the wrong one. Reopen the app and the question will be asked again for ' +
            'the right day.',
        });
        return;
      }

      const queued: QueuedClaim = {
        idempotencyKey: crypto.randomUUID(),
        ownerId,
        commitmentId: commitment.id,
        answer: value,
        answeredAt: tappedAt.toISOString(),
        // The morning question is only ever asked about untimed commitments — a timed one
        // is claimed on its own day from Today, and `commitmentsOwing()` filters it out of
        // this list entirely (Story 6.2).
        timed: false,
      };

      // One implementation of enqueue, flush, classify and remove, shared with Today.
      const outcome = await submitDeclaration(window.localStorage, queued);

      if (outcome.kind === 'refused') {
        // Not advanced past the question: nothing was recorded, so he has not answered.
        setSending({ kind: 'failed', reason: outcome.reason });
        return;
      }

      setSending(outcome.kind === 'queued' ? { kind: 'queued' } : { kind: 'idle' });
      onAnswered(commitment.id);
    } catch (error) {
      setSending({ kind: 'failed', reason: String(error) });
    }
  }

  return (
    <section className="screen">
      {/* No control beside the title. The gate is the whole screen, and the whole screen is
          the question — there is nowhere else to go from here by design. */}
      <header className="screen-head">
        <h1>Yesterday</h1>
      </header>

      <div className="card card-pad stack">
        <p>{questionFor(commitment, day)}</p>

        {owing.length > 1 && <p className="row-muted">{owing.length - 1} more after this one.</p>}

        {/* Two controls, identical in every way but their words. No default, no
            pre-selection, and no confirmation on either — declaring a slip is not
            destructive, it is honest, and friction there would tax the truth.

            `actions-equal` rather than the ordinary `actions`: with natural widths the longer
            word would take the wider button, and a difference in size between the honest
            answer and the costly one is exactly the thumb on the scale the rule above forbids. */}
        <div className="actions actions-equal">
          <button
            type="button"
            disabled={sending.kind === 'sending'}
            onClick={() => void answer('held')}
          >
            It held
          </button>
          <button
            type="button"
            disabled={sending.kind === 'sending'}
            onClick={() => void answer('slipped')}
          >
            I slipped
          </button>
        </div>
      </div>

      {sending.kind === 'queued' && (
        <p className="row-muted">
          Saved on this device — there is no connection right now. It will go when there is one,
          dated when you answered.
        </p>
      )}

      {sending.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {sending.reason}
        </p>
      )}

      <p className="row-muted">
        Nothing else is here until this is answered. You can still close the app; the question will
        be waiting.
      </p>
    </section>
  );
}
