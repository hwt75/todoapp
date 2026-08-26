'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { formatDeadline } from '@/lib/appeal';
import { formatDong } from '@/lib/money';
import type { LedgerKind, PenaltyState } from '@/lib/ledger';
import {
  OWED_PENALTIES_COPY,
  REFEREE_HOME_COPY,
  collectionMessage,
  daysSinceQuiet,
  formatOwedDay,
  summarizeReferee,
  type OwedPenaltyRow,
  type PendingAppealRow,
  type RefereeSummary,
} from '@/lib/referee';

type View =
  | { kind: 'loading' }
  | ({ kind: 'ready' } & RefereeSummary & {
        appeals: PendingAppealRow[];
        owedPenalties: OwedPenaltyRow[];
        // Story 5.3, FR-18 — the episode's own started_day when an escalated, still-open
        // Silence episode exists; null otherwise. RLS ("silence_episode: referee reads
        // escalated", 20260826100000) already scopes the read below to exactly this state —
        // an unescalated or already-satisfied episode simply does not come back.
        goneQuietSince: string | null;
      })
  | { kind: 'failed'; reason: string };

/** One penalty row's own copy/mark-collected status — keyed by penalty id so one row's
 *  transient state never bleeds into another's, and kept outside `View` so a failed Mark
 *  Collected's own message survives the row staying on screen (Never reload away from a
 *  refusal the referee still needs to read — see `markCollected` below). */
type RowStatus = 'idle' | 'busy' | 'failed';

/**
 * The Referee's home surface (Story 4.5 FR-19; Story 4.6 adds the appeals list; Story 4.7
 * adds the owed-penalties list) — two counts, a real list of pending appeals to open, and a
 * real list of owed penalties, each with a pre-written copy-to-clipboard collection message
 * and a Mark Collected control.
 *
 * **What this screen still deliberately does not have.** No ruling controls of its own (*He
 * did it* / *He didn't* live on `components/referee-appeal-detail.tsx`, reached by opening an
 * appeal row) and no per-penalty detail route — unlike an Appeal, a Penalty needs nothing
 * beyond what already fits on its list row (Never boundary).
 *
 * **What guards this screen is RLS and two function-level role checks, not this component.**
 * `penalty_current` and the `appeal`/`commitment`/`penalty` reads behind both lists already
 * return zero rows to anything but a `role = 'referee'` session
 * (`20260824160000_the_referee_has_his_own_way_in.sql`,
 * `20260825090000_the_referee_rules.sql`). The commitment names behind the owed-penalties
 * list instead come from `referee_missed_commitments()`, a `security definer` function
 * (`20260825100000_the_app_does_the_asking.sql`) rather than a new RLS policy on
 * `settlement_commitment` — that table is also `chain_current`'s own base table, so an RLS
 * grant on it would silently reopen a surface Story 4.5 keeps off-limits to the referee; the
 * function filters to `role_from_table() = 'referee'` instead (a non-referee caller gets
 * nothing back, never an error — AD-7's own read convention). The redirects below are UX
 * polish for a doer or a signed-out visitor who lands here directly, never the enforcement
 * boundary itself (AD-7).
 *
 * **A failed Mark Collected never reloads the list away.** Success removes the row (it is no
 * longer owed); a refusal — a double-click, or a race with something else that already
 * resolved it — leaves the row exactly where it was with its own failure message attached,
 * because the row disappearing *is* the only feedback a silent reload would give, and the
 * Boundaries require the referee see the refusal, not guess at it from an item quietly
 * vanishing.
 *
 * **Zero notification permissions, no focus trap (NFR3, NFR15).** Nothing here touches the
 * `Notification` API, and every control is a plain button in document order — there is no
 * dialog, no `aria-modal`, nothing capturing focus.
 */
export function RefereeHome() {
  const router = useRouter();
  const [view, setView] = useState<View>({ kind: 'loading' });
  const [reloadToken, setReloadToken] = useState(0);
  const [markStatus, setMarkStatus] = useState<Record<string, RowStatus>>({});
  const [markErrors, setMarkErrors] = useState<Record<string, string>>({});
  const [copyStatus, setCopyStatus] = useState<Record<string, 'idle' | 'copied' | 'failed'>>({});

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

      // `id`/`kind`/`period`/`settlement_id`/`created_at` alongside `state`/`amount_dong`:
      // `summarizeReferee` below only reads the latter two (every kind, every state), but
      // the owed-penalties list (Story 4.7) needs the rest to filter, sort and look up
      // missed commitments without a second round trip to `penalty_current` itself.
      const { data: penalties, error: penaltiesError } = await supabase
        .from('penalty_current')
        .select('id,state,amount_dong,kind,period,settlement_id,created_at');
      if (cancelled) return;

      if (penaltiesError) {
        setView({ kind: 'failed', reason: penaltiesError.message });
        return;
      }

      const penaltyRows = (penalties ?? []) as Array<{
        id: string;
        state: PenaltyState;
        amount_dong: number;
        kind: LedgerKind;
        period: string;
        settlement_id: string;
        created_at: string;
      }>;

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

      // The escalated "gone quiet" state (Story 5.3, FR-18) — at most one row matches in
      // practice (`silence_episode_one_active` is a per-owner partial unique index, and this
      // codebase pairs at most one referee with, in practice, one doer), but the read makes
      // no such assumption itself: oldest first and take the first, the same defensive shape
      // the appeals/owed-penalties lists above already use rather than assuming
      // single-account scoping.
      const { data: quietRows, error: quietError } = await supabase
        .from('silence_episode')
        .select('started_day')
        .is('satisfied_at', null)
        .not('escalated_at', 'is', null)
        .order('started_day', { ascending: true })
        .limit(1);
      if (cancelled) return;

      if (quietError) {
        setView({ kind: 'failed', reason: quietError.message });
        return;
      }

      const goneQuietSince =
        (quietRows?.[0] as { started_day?: string } | undefined)?.started_day ?? null;

      // Owed penalties (Story 4.7), oldest first — "uncollected debts age visibly" is
      // satisfied by surfacing the oldest debt first (Always boundary), not a counter.
      // Every kind, day or week: a week-kind Penalty (Week Close, 3.4 — a Weekly Quota
      // commitment failing its week) is just as much a debt as a day-kind one, and the
      // Acceptance Criteria's own "the only way the debt is discharged... never written off
      // automatically" means every owed Penalty has to be reachable here. Filtering to
      // `kind = 'day'` would leave a week-kind one counted in the summary above but
      // uncollectable through any control in the UI — invisible, not "aging visibly".
      const owedPenaltyRows = penaltyRows
        .filter((row) => row.state === 'owed')
        .sort((a, b) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : 0));

      const missedBySettlement = new Map<string, string[]>();

      // Week Close freezes no per-commitment outcome (`lib/ledger.ts`'s own "Never") — so
      // only the day-kind subset is worth asking here; a week-kind settlement_id would come
      // back with nothing, and the render below already falls back to "A commitment" for a
      // row with no names.
      const dayKindSettlementIds = owedPenaltyRows
        .filter((row) => row.kind === 'day')
        .map((row) => row.settlement_id);

      if (dayKindSettlementIds.length > 0) {
        // `referee_missed_commitments()`, a security definer function — never a direct read
        // of `settlement_commitment`/`settlement_commitment_current`. That table is also
        // `chain_current`'s own base table (`security_invoker`), so an RLS policy granting
        // the referee `select` on it would silently also grant `chain_current`, a
        // doer-facing surface Story 4.5's own frozen Intent keeps off-limits to the referee
        // (`20260825100000_the_app_does_the_asking.sql`'s own header explains the incident).
        const { data: missedRows, error: missedError } = await supabase.rpc(
          'referee_missed_commitments',
          { p_settlement_ids: dayKindSettlementIds },
        );
        if (cancelled) return;

        if (missedError) {
          setView({ kind: 'failed', reason: missedError.message });
          return;
        }

        for (const row of missedRows ?? []) {
          const settlementId = row.settlement_id as string;
          const name = (row.commitment_name as string | null) ?? 'A commitment';
          missedBySettlement.set(settlementId, [
            ...(missedBySettlement.get(settlementId) ?? []),
            name,
          ]);
        }
      }

      const owedPenalties: OwedPenaltyRow[] = owedPenaltyRows.map((row) => ({
        id: row.id,
        forDay: row.period,
        amountDong: row.amount_dong,
        // A day whose Penalty stems from more than one missed commitment names all of them
        // (Always boundary) — deduped (two settlement_commitment rows can legitimately name
        // the same commitment's own name twice — the join has no uniqueness guarantee on
        // `name` itself) and sorted the same way `lib/ledger.ts`'s own `missed` field is, for
        // a stable, predictable order rather than insertion sequence. Empty for a week-kind
        // row (never queried above, per the day-only scope right above) — the render falls
        // back to "A commitment", an honest reflection of what a Weekly Quota Penalty
        // actually has to name rather than a fabricated commitment list.
        missedCommitments: Array.from(
          new Set(missedBySettlement.get(row.settlement_id) ?? []),
        ).sort(),
      }));

      setView({
        kind: 'ready',
        ...summarizeReferee(
          penaltyRows.map((row) => ({
            state: row.state,
            amountDong: row.amount_dong,
          })),
        ),
        appeals: (appeals ?? []).map((row) => ({
          id: row.id as string,
          forDay: row.for_day as string,
          commitmentName: (row.commitment as unknown as { name: string } | null)?.name ?? null,
        })),
        owedPenalties,
        goneQuietSince,
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [router, reloadToken]);

  async function signOut() {
    await createClient().auth.signOut();
    router.replace('/referee/login');
  }

  /**
   * Mark Collected (FR-21) — the only way a debt is ever discharged. `mark_penalty_collected()`
   * is the sole judge (AD-1): this sends one RPC call and reads back whatever it decided.
   * Success reloads the list, which is how the row leaves it (the Acceptance Criteria's own
   * words). A refusal — a double-click, or a race with anything else that could have moved
   * this Penalty off `owed` — never reloads: the row would simply vanish with no explanation,
   * which is not what "Referee sees 'already resolved'" means (Boundaries). It stays, with
   * the server's own message attached, until something else reloads the screen.
   *
   * A successful call deliberately does *not* reset this row's own status back to `'idle'` —
   * the reload it triggers is still in flight for a moment (a real network round trip), and
   * resetting early would leave the button clickable again during that window. A second click
   * landing in it would hit the server's own guarded transition and read as "already
   * resolved" right after what the referee just experienced as a success. The button instead
   * stays disabled/busy until the reload itself replaces this row — which it always does on a
   * real success, since a winning call's own guarded update is what made the Penalty stop
   * being `owed` in the first place.
   */
  async function markCollected(penaltyId: string) {
    setMarkStatus((status) => ({ ...status, [penaltyId]: 'busy' }));

    const supabase = createClient();
    const { error } = await supabase.rpc('mark_penalty_collected', {
      p_penalty_id: penaltyId,
    });

    if (error) {
      setMarkStatus((status) => ({ ...status, [penaltyId]: 'failed' }));
      setMarkErrors((errors) => ({ ...errors, [penaltyId]: error.message }));
      return;
    }

    setReloadToken((token) => token + 1);
  }

  /**
   * The copy control. Places `collectionMessage`'s own pre-written text on the clipboard
   * unchanged — no compose field, no editable message (Never boundary). This is the first
   * `navigator.clipboard` use in this codebase: an unsupported browser, a denied permission
   * and an insecure context all surface here the same way, as a status message rather than
   * silence (matching the failure-surfacing bar Story 4.6 set for evidence loading).
   */
  async function copyMessage(penalty: OwedPenaltyRow) {
    const text = collectionMessage(penalty.amountDong, new Date(penalty.forDay));

    try {
      if (!navigator.clipboard?.writeText) {
        throw new Error('Clipboard API unavailable');
      }
      await navigator.clipboard.writeText(text);
      setCopyStatus((status) => ({ ...status, [penalty.id]: 'copied' }));
    } catch {
      setCopyStatus((status) => ({ ...status, [penalty.id]: 'failed' }));
    }
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

        {/* Story 5.3, FR-18 — alongside the appeals/penalties content above, never replacing
            it, and never a new queue item: no action control, no amount, no commitment name.
            Renders whenever an escalated episode is still open, independent of whether
            anything above is also pending or owed (an author who has gone quiet may owe
            nothing and have nothing under appeal). */}
        {view.kind === 'ready' && view.goneQuietSince && (
          <p role="status">
            {REFEREE_HOME_COPY.goneQuiet(daysSinceQuiet(view.goneQuietSince, new Date()))}
          </p>
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

        {/* The real list (Story 4.7): amount, day, and every commitment missed, each with a
            pre-written copy-to-clipboard message and a Mark Collected control — no per-item
            detail route (Never boundary: unlike an Appeal, a Penalty needs nothing beyond
            what already fits on its list row). */}
        {view.kind === 'ready' && view.owedPenalties.length > 0 && (
          <section aria-label={OWED_PENALTIES_COPY.heading}>
            <h2>{OWED_PENALTIES_COPY.heading}</h2>
            {view.owedPenalties.map((penalty) => {
              // formatOwedDay, not formatDeadline: an owed Penalty persists indefinitely
              // (this story's own "never written off automatically"), so the year has to be
              // part of the label — two rows more than a year apart with formatDeadline's
              // own bare "Aug 18" would be indistinguishable.
              const day = formatOwedDay(new Date(penalty.forDay));
              const missed =
                penalty.missedCommitments.length > 0
                  ? penalty.missedCommitments.join(', ')
                  : 'A commitment';
              const rowMark = markStatus[penalty.id] ?? 'idle';
              const rowCopy = copyStatus[penalty.id] ?? 'idle';

              return (
                <div className="row" key={penalty.id}>
                  <div className="row-main">
                    <div className="row-name">
                      {formatDong(penalty.amountDong)} — {missed}
                    </div>
                    {/* Not aria-hidden: the day is part of what identifies this row, not
                        decoration — a screen-reader user needs it too. */}
                    <div className="row-muted">{day}</div>
                  </div>

                  <button
                    type="button"
                    // The day alone is not enough to distinguish rows — this list is not
                    // scoped to one doer account (RLS grants the referee every account's own
                    // Penalties, Story 4.5), so two different accounts can each owe a
                    // same-day Penalty. Commitment name(s) plus day, mirroring how the
                    // appeals list above disambiguates its own "Open" buttons.
                    aria-label={`Copy collection message for ${missed}, ${day}`}
                    onClick={() => void copyMessage(penalty)}
                  >
                    {OWED_PENALTIES_COPY.copy}
                  </button>
                  {rowCopy === 'copied' && <p role="status">{OWED_PENALTIES_COPY.copied}</p>}
                  {rowCopy === 'failed' && <p role="status">{OWED_PENALTIES_COPY.copyFailed}</p>}

                  <button
                    type="button"
                    aria-label={`Mark collected for ${missed}, ${day}`}
                    disabled={rowMark === 'busy'}
                    aria-busy={rowMark === 'busy'}
                    onClick={() => void markCollected(penalty.id)}
                  >
                    {rowMark === 'busy'
                      ? OWED_PENALTIES_COPY.marking
                      : OWED_PENALTIES_COPY.markCollected}
                  </button>
                  {rowMark === 'failed' && (
                    <p role="status">
                      <strong>{OWED_PENALTIES_COPY.markFailed}</strong> {markErrors[penalty.id]}
                    </p>
                  )}
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
