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

      const [{ data: profile }, { data: commitments }, { data: filed }] = await Promise.all([
        supabase.from('profile').select('morning_hour').maybeSingle(),
        // `due_time` is read for what it decides rather than for what it says: a commitment
        // that carries one is claimed on its own day and must not be asked about here
        // (`isAskedNextMorning()`, Story 6.2).
        supabase.from('commitment').select('id,name,cadence,archived_at,due_time'),
        supabase.from('declaration').select('commitment_id').eq('for_day', day),
      ]);

      if (cancelled) return;

      setNow(at);
      setOwing(
        commitmentsOwing(
          commitments ?? [],
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
