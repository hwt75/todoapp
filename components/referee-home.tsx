'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { formatDeadline } from '@/lib/appeal';
import { formatDong } from '@/lib/money';
import type { PenaltyState } from '@/lib/ledger';
import {
  REFEREE_HOME_COPY,
  summarizeReferee,
  type PendingAppealRow,
  type RefereeSummary,
} from '@/lib/referee';

type View =
  | { kind: 'loading' }
  | ({ kind: 'ready' } & RefereeSummary & { appeals: PendingAppealRow[] })
  | { kind: 'failed'; reason: string };

/**
 * The Referee's home surface (Story 4.5 FR-19; Story 4.6 adds the list) — a count and a
 * total, plus a real list of pending appeals to open, each linking to its own ruling screen.
 *
 * **What this screen still deliberately does not have.** No ruling controls of its own
 * (*He did it* / *He didn't* live on `components/referee-appeal-detail.tsx`, reached by
 * opening a row) and no collection controls (Mark Collected, a copyable message, Story
 * 4.7's own goal).
 *
 * **What guards this screen is RLS, not this component.** `penalty_current` and the
 * `appeal`/`commitment`/`penalty` read behind the list already return zero rows to anything
 * but a `role = 'referee'` session (`20260824160000_the_referee_has_his_own_way_in.sql`,
 * `20260825090000_the_referee_rules.sql`) — the redirects below are UX polish for a doer or
 * a signed-out visitor who lands here directly, never the enforcement boundary (AD-7).
 *
 * **Zero notification permissions, no focus trap (NFR3, NFR15).** Nothing here touches the
 * `Notification` API, and every control is a plain button in document order — there is no
 * dialog, no `aria-modal`, nothing capturing focus.
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

      // The list itself (Story 4.6): every appeal whose linked Penalty still reads `held`
      // — `!inner` on the embed so the filter narrows the appeal rows returned, not merely
      // the joined commitment/penalty fields on rows that would otherwise still come back.
      // `penalty_current` above already can't answer this — it carries no appeal id or
      // commitment name to link a count back to a row.
      const { data: appeals, error: appealsError } = await supabase
        .from('appeal')
        .select('id,for_day,commitment:commitment_id(name),penalty:penalty_id!inner(state)')
        .eq('penalty.state', 'held')
        .order('for_day', { ascending: false });
      if (cancelled) return;

      if (appealsError) {
        setView({ kind: 'failed', reason: appealsError.message });
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
        appeals: (appeals ?? []).map((row) => ({
          id: row.id as string,
          forDay: row.for_day as string,
          commitmentName: (row.commitment as unknown as { name: string } | null)?.name ?? null,
        })),
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

        {/* The real list (Story 4.6): day and commitment name, each opening its own ruling
            screen. Nothing here renders He did it/He didn't itself — button-action (UX-DR6)
            keeps at most one action card above the fold, and that card is the detail
            screen's own, reached by opening a row. */}
        {view.kind === 'ready' && view.appeals.length > 0 && (
          <section aria-label={REFEREE_HOME_COPY.appealsHeading}>
            <h2>{REFEREE_HOME_COPY.appealsHeading}</h2>
            {view.appeals.map((appeal) => {
              // `for_day` is a plain calendar date (`YYYY-MM-DD`), never a timestamptz —
              // parsed as UTC midnight, formatDeadline's own Asia/Ho_Chi_Minh conversion
              // only ever shifts it forward within the same calendar day, so this always
              // lands on the date the row itself names. Same formatting convention as
              // `components/referee-appeal-detail.tsx`'s own deadline, for consistency.
              const day = formatDeadline(new Date(appeal.forDay));
              const commitmentName = appeal.commitmentName ?? 'A commitment';

              return (
                <div className="row" key={appeal.id}>
                  <div className="row-main">
                    <div className="row-name">{commitmentName}</div>
                    {/* Not aria-hidden: the day is part of what identifies this row, not
                        decoration — a screen-reader user needs it too. */}
                    <div className="row-muted">{day}</div>
                  </div>
                  <button
                    type="button"
                    // Every row's button otherwise shares the identical accessible name
                    // ("Open"), which a screen-reader user cannot tell apart from any
                    // other row's.
                    aria-label={`Open appeal for ${commitmentName}, ${day}`}
                    onClick={() => router.push(`/referee/appeals/${appeal.id}`)}
                  >
                    {REFEREE_HOME_COPY.openAppeal}
                  </button>
                </div>
              );
            })}
          </section>
        )}

        <button type="button" onClick={() => void signOut()}>
          {REFEREE_HOME_COPY.signOut}
        </button>
      </section>
    </main>
  );
}
