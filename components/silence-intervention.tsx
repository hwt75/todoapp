'use client';

import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { MorningGate } from '@/components/morning-gate';
import { formatGraceAllowance } from '@/lib/grace';
import { SILENCE_COPY, silenceCopy } from '@/lib/silence';
import type { OwedCommitment } from '@/lib/declaration';

type View =
  | { kind: 'loading' }
  | { kind: 'ready'; graceRemaining: number }
  | { kind: 'failed'; reason: string };

/**
 * Story 5.2 (FR-16): the day-two Silence intervention.
 *
 * `app/page.tsx` renders this ahead of the ordinary Declaration gate whenever an active
 * `silence_episode` exists for this account — see that file's own comment for why that check
 * lives there rather than here. This component owns what is left: the Grace Days sentence
 * (`grace_allowance_remaining`, the one source every spend surface reads — never a second
 * computation, `lib/grace.ts`) and the two verbatim copy variants (`lib/silence.ts`).
 *
 * No debt figure, no itemized miss list, no red (Story 5.2's own Never boundary) — neutral
 * text and the existing `row-muted` class only.
 *
 * When Declarations are outstanding (`owing.length > 0`, the exact signal `app/page.tsx`
 * already uses to decide whether MorningGate has anything to ask), the one concrete action is
 * MorningGate itself, rendered unchanged directly beneath the copy rather than behind a second,
 * invented control — opening it is not a separate step from seeing it. Answering it (any
 * Declaration, any day) ends the episode via `declaration_satisfies_silence()`; the routine
 * screen returns on the next load (I/O Matrix: "Declaration answered mid-episode" — this
 * component does not attempt to react live within the same session, matching the spec's own
 * stated boundary).
 */
export function SilenceIntervention({
  ownerId,
  startedDay,
  owing,
  now,
  onAnswered,
}: {
  ownerId: string;
  /** `silence_episode.started_day` — the earlier of the two quiet asked-days that opened it. */
  startedDay: string;
  owing: OwedCommitment[];
  now: Date;
  onAnswered: (commitmentId: string) => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    createClient()
      .from('grace_allowance_remaining')
      .select('remaining')
      .maybeSingle()
      .then(({ data, error }) => {
        if (cancelled) return;

        // A real doer session always has exactly one row here (grace_allowance_remaining's
        // own `where role = 'doer'`) — mirrors components/today.tsx's identical treatment: no
        // row without an error is itself a failure to surface, never a silent "0 remaining".
        if (error || !data) {
          setView({
            kind: 'failed',
            reason: error?.message ?? 'No Grace Days allowance found for this account.',
          });
          return;
        }

        setView({ kind: 'ready', graceRemaining: data.remaining as number });
      });

    return () => {
      cancelled = true;
    };
  }, [ownerId]);

  const pending = owing.length > 0;

  return (
    <section>
      <h1>{SILENCE_COPY.title}</h1>

      <p>{silenceCopy(pending, startedDay)}</p>

      {view.kind === 'loading' && <p>Working…</p>}

      {view.kind === 'failed' && (
        <p>
          <strong>{SILENCE_COPY.failed}</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && (
        <p className="row-muted">{formatGraceAllowance(view.graceRemaining)}</p>
      )}

      {pending && <MorningGate ownerId={ownerId} owing={owing} now={now} onAnswered={onAnswered} />}
    </section>
  );
}
