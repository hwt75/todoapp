'use client';

import { useEffect, useState } from 'react';
import { commitmentsOwing, dayInQuestion, type OwedCommitment } from '@/lib/declaration';
import { createClient } from '@/lib/supabase/client';

interface GateState {
  owing: OwedCommitment[];
  now: Date;
  markAnswered: (commitmentId: string) => void;
}

/**
 * What the morning gate needs to know, and nothing else.
 *
 * Every decision about *who owes what* is made by `commitmentsOwing`, which is pure and
 * tested against both sides of every boundary. This hook only fetches the three things
 * that function needs — the hour he agreed to, his commitments, and what has already been
 * filed for the day — and gets out of the way.
 */
export function useGate(ownerId: string | null): GateState {
  const [owing, setOwing] = useState<OwedCommitment[]>([]);
  const [now, setNow] = useState(() => new Date());

  useEffect(() => {
    // No setState for the signed-out case — the React Compiler rejects it, rightly, and
    // the empty list is derived below rather than stored.
    if (!ownerId) return;

    let cancelled = false;

    async function load() {
      const supabase = createClient();
      const at = new Date();
      const day = dayInQuestion(at);

      const [{ data: profile }, { data: commitments }, { data: filed }, { data: governing }] =
        await Promise.all([
          supabase.from('profile').select('morning_hour').maybeSingle(),
          // `due_time` is read for what it decides rather than for what it says: a commitment
          // that carries one is claimed on its own day and must not be asked about here
          // (`isAskedNextMorning()`, Story 6.2). The *live* value only says what is true now,
          // which is the wrong question — see the merge below.
          supabase.from('commitment').select('id,name,cadence,archived_at,due_time'),
          supabase.from('declaration').select('commitment_id').eq('for_day', day),
          // What actually governed the day being asked about, from the same door
          // `enqueue_gate_reminders()` and `settle_day()` read (2026-09-07).
          supabase.from('morning_question_day').select('commitment_id,governing_due_time'),
        ]);

      if (cancelled) return;

      /**
       * The day the question is about, not the day it is being asked on.
       *
       * A commitment whose time was switched on part-way through that day was governed by no
       * time at all then, so the day belongs to this question — and `declaration_derive_day()`
       * says exactly that when it refuses a same-day claim on such a day. Reading the live
       * column here skipped it, and with both routes closed the day settled as silence with a
       * penalty. That was live on the project for part of 2026-09-07.
       *
       * A failed view read falls back to the live column rather than to "ask about nothing":
       * the fallback is the behaviour of the day before this fix, and asking too little is the
       * failure that costs money while asking too much only costs a question.
       */
      const governedBy = new Map(
        (governing ?? []).map((g) => [
          g.commitment_id as string,
          (g.governing_due_time as string | null) ?? null,
        ]),
      );

      setNow(at);
      setOwing(
        commitmentsOwing(
          (commitments ?? []).map((c) => ({
            ...c,
            due_time: governedBy.has(c.id as string)
              ? governedBy.get(c.id as string)
              : (c.due_time as string | null),
          })),
          (filed ?? []).map((d) => d.commitment_id as string),
          at,
          (profile?.morning_hour as number | undefined) ?? 7,
        ),
      );
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [ownerId]);

  return {
    // Derived rather than stored, so signing out empties the gate without an effect
    // writing state on the way past.
    owing: ownerId ? owing : [],
    now,
    // Removed locally rather than refetched: the answer may be sitting in the offline
    // queue, in which case the server does not know about it yet and a refetch would ask
    // the same question again.
    markAnswered: (commitmentId: string) =>
      setOwing((current) => current.filter((c) => c.id !== commitmentId)),
  };
}
