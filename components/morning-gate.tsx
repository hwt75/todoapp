'use client';

import { useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { dayInQuestion, questionFor, type OwedCommitment } from '@/lib/declaration';
import { enqueue, flush, type QueuedDeclaration } from '@/lib/offline-queue';

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

    // Both generated at the moment of the tap, not at send time (AD-4, AD-6). An answer
    // given in a tunnel is dated when it was given, and a retry reuses this key so the
    // server refuses the second rather than recording it twice.
    const queued: QueuedDeclaration = {
      idempotencyKey: crypto.randomUUID(),
      ownerId,
      commitmentId: commitment.id,
      answer: value,
      answeredAt: new Date().toISOString(),
    };

    enqueue(window.localStorage, queued);

    const outcome = await flush(window.localStorage, async (pending) => {
      const { error } = await createClient().from('declaration').insert({
        owner_id: pending.ownerId,
        commitment_id: pending.commitmentId,
        idempotency_key: pending.idempotencyKey,
        answer: pending.answer,
        answered_at: pending.answeredAt,
      });

      if (!error) return 'sent';
      // 23505 is the unique constraint: this answer is already recorded, which is success
      // arriving out of order rather than a failure.
      return error.code === '23505' ? 'duplicate' : 'failed';
    });

    if (outcome.kept.includes(queued.idempotencyKey)) {
      // Held, not lost. He answered; the network did not cooperate; the answer is safe and
      // will go when there is signal. Saying otherwise would make him answer twice.
      setSending({ kind: 'queued' });
    } else {
      setSending({ kind: 'idle' });
    }

    onAnswered(commitment.id);
  }

  return (
    <section>
      <h1>Yesterday</h1>

      <p>{questionFor(commitment, day)}</p>

      {owing.length > 1 && <p className="row-muted">{owing.length - 1} more after this one.</p>}

      {/* Two controls, identical in every way but their words. No default, no
          pre-selection, and no confirmation on either — declaring a slip is not
          destructive, it is honest, and friction there would tax the truth. */}
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
