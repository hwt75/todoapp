'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { formatDong } from '@/lib/money';
import type { PenaltyState } from '@/lib/ledger';
import { REFEREE_HOME_COPY, summarizeReferee, type RefereeSummary } from '@/lib/referee';

type View =
  { kind: 'loading' } | ({ kind: 'ready' } & RefereeSummary) | { kind: 'failed'; reason: string };

/**
 * The Referee's home surface (Story 4.5, FR-19) — a count and a total, nothing else.
 *
 * **What this screen deliberately does not have.** No ruling controls (*He did it* / *He
 * didn't*, Story 4.6) and no collection controls (Mark Collected, a copyable message, Story
 * 4.7) — those stories build them. No per-item list either: the I/O Matrix's own non-empty
 * state is "a count and a total, no per-item detail or actions."
 *
 * **What guards this screen is RLS, not this component.** `penalty_current` and
 * `settlement_current` already return zero rows to anything but a `role = 'referee'`
 * session (`20260824160000_the_referee_has_his_own_way_in.sql`) — the redirects below are
 * UX polish for a doer or a signed-out visitor who lands here directly, never the
 * enforcement boundary (AD-7).
 *
 * **Zero notification permissions, no focus trap (NFR3, NFR15).** Nothing here touches the
 * `Notification` API, and every control is a plain button or link in document order — there
 * is no dialog, no `aria-modal`, nothing capturing focus.
 */
export function RefereeHome() {
  const router = useRouter();
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const supabase = createClient();
      const { data: userData, error: userError } = await supabase.auth.getUser();
      if (cancelled) return;

      if (userError || !userData.user) {
        router.replace('/referee/login');
        return;
      }

      const { data: profile, error: profileError } = await supabase
        .from('profile')
        .select('role')
        .maybeSingle();
      if (cancelled) return;

      if (profileError) {
        setView({ kind: 'failed', reason: profileError.message });
        return;
      }

      // Not this story's business to enforce (AD-7) — only to avoid showing a doer session
      // an empty referee shell it can never populate through RLS anyway.
      if ((profile as { role?: string } | null)?.role !== 'referee') {
        router.replace('/');
        return;
      }

      const { data: penalties, error: penaltiesError } = await supabase
        .from('penalty_current')
        .select('state,amount_dong');
      if (cancelled) return;

      if (penaltiesError) {
        setView({ kind: 'failed', reason: penaltiesError.message });
        return;
      }

      setView({
        kind: 'ready',
        ...summarizeReferee(
          (penalties ?? []).map((row) => ({
            state: row.state as PenaltyState,
            amountDong: row.amount_dong as number,
          })),
        ),
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [router]);

  async function signOut() {
    await createClient().auth.signOut();
    router.replace('/referee/login');
  }

  return (
    <main>
      <section>
        <h1>{REFEREE_HOME_COPY.title}</h1>

        {view.kind === 'loading' && <p>{REFEREE_HOME_COPY.loading}</p>}

        {view.kind === 'failed' && (
          <p role="status">
            <strong>{REFEREE_HOME_COPY.failed}</strong> {view.reason}
          </p>
        )}

        {view.kind === 'ready' && view.pendingAppeals === 0 && view.owedCount === 0 && (
          <p>{REFEREE_HOME_COPY.empty}</p>
        )}

        {view.kind === 'ready' && (view.pendingAppeals > 0 || view.owedCount > 0) && (
          <>
            {view.pendingAppeals > 0 && (
              <p>{REFEREE_HOME_COPY.pendingAppeals(view.pendingAppeals)}</p>
            )}
            {view.owedCount > 0 && (
              <p>
                {REFEREE_HOME_COPY.owedPenalties(view.owedCount, formatDong(view.owedTotalDong))}
              </p>
            )}
          </>
        )}

        <button type="button" onClick={() => void signOut()}>
          {REFEREE_HOME_COPY.signOut}
        </button>
      </section>
    </main>
  );
}
