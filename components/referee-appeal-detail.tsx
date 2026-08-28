'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { formatDeadline } from '@/lib/appeal';
import { formatDong, PENALTY_DONG } from '@/lib/money';
import type { PenaltyState } from '@/lib/ledger';
import {
  REFEREE_APPEAL_DETAIL_COPY,
  type RefereeAppealDetail as RefereeAppealDetailData,
  type RefereeEvidenceItem,
} from '@/lib/referee';

type View =
  | { kind: 'loading' }
  | { kind: 'not-found' }
  | { kind: 'failed'; reason: string }
  | {
      kind: 'ready';
      appeal: RefereeAppealDetailData;
      evidence: RefereeEvidenceItem[];
      // How many attached evidence items failed to sign a URL for — tracked separately
      // from `evidence` itself so a per-item failure surfaces as a note rather than
      // silently shrinking the list to look like nothing was ever attached.
      evidenceFailures: number;
    };

type Ruling = { kind: 'idle' } | { kind: 'ruling' } | { kind: 'failed'; reason: string };

/**
 * One appeal, ruled (Story 4.6, FR-20): the machine's own call, the evidence the doer
 * attached, and the two controls that resolve it — *He did it* / *He didn't* (UX-DR24).
 *
 * **The server is the sole judge, here as everywhere else (AD-1).** This screen sends one
 * call, `rule_appeal(p_appeal_id, p_approved)`, and reads back whatever the database
 * decided. It never pre-computes eligibility or a verdict itself — a race lost to the
 * timeout job or to a second ruling call comes back as the function's own refusal, shown
 * verbatim, never guessed at client-side.
 *
 * **What guards this screen is RLS and the function's own role check, not this component.**
 * `appeal`/`commitment`/`penalty` already return zero rows to anything but a `role =
 * 'referee'` session, and `rule_appeal()` checks `role_from_table() = 'referee'` as its own
 * first statement before reading anything — the redirects below are UX polish for a doer or
 * a signed-out visitor who lands here directly, never the enforcement boundary (AD-7).
 *
 * **Zero notification permissions, no focus trap (NFR3, NFR15).** Nothing here touches the
 * `Notification` API, and every control is a plain button in document order.
 */
export function RefereeAppealDetail({ appealId }: { appealId: string }) {
  const router = useRouter();
  const [view, setView] = useState<View>({ kind: 'loading' });
  const [ruling, setRuling] = useState<Ruling>({ kind: 'idle' });
  // Bumped after every ruling attempt (won, lost to a race, or refused outright) to
  // re-trigger the effect below and reload — mirrors `components/referee-home.tsx`'s own
  // shape, where the load itself is defined inside the effect rather than a memoized
  // callback the effect invokes directly.
  const [reloadToken, setReloadToken] = useState(0);

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

      // Not this screen's business to enforce (AD-7) — only to avoid showing a doer session
      // a ruling screen it can never populate through RLS anyway.
      if ((profile as { role?: string } | null)?.role !== 'referee') {
        router.replace('/');
        return;
      }

      const { data: appealRow, error: appealError } = await supabase
        .from('appeal')
        .select('id,for_day,deadline,penalty_id,commitment:commitment_id(name)')
        .eq('id', appealId)
        .maybeSingle();
      if (cancelled) return;

      if (appealError) {
        setView({ kind: 'failed', reason: appealError.message });
        return;
      }

      if (!appealRow) {
        setView({ kind: 'not-found' });
        return;
      }

      // The ruling's own outcome, read directly off this appeal's own Penalty row —
      // `penalty`, not `penalty_current` (Story 4.5's own "penalty: referee reads day and
      // week" RLS policy, `20260824160000`, grants the referee that read on the base table
      // directly; this is the one legal exception to the one-door-per-table rule
      // `lib/chain.test.ts` otherwise holds every other screen to).
      //
      // An earlier version of this read compared the day's *current* settlement id against
      // the one this appeal points at — "moved" meant approved. That broke the moment a
      // second, independent thing could also move the same settlement: a later Grace Day
      // (Story 5.1) spent on a *residual*, non-appealed miss that survived a partial
      // approval creates its own fresh settlement and penalty, and grace-daying *that*
      // residual debt supersedes the approval's own correction too — which the settlement-
      // comparison approach could not tell apart from "this ruling itself never counted".
      //
      // This appeal's own `penalty_id` row is immune to that: it is a single, specific row
      // whose `state` is a permanent record of what happened to *this appeal*, regardless of
      // anything that later happens to a *different* penalty row on a *different*
      // settlement.
      //   'voided'    — approved. rule_appeal(true) sets this unconditionally, whether or
      //                 not a residual miss left the corrected day still owing.
      //   'owed'      — rejected, still standing (rejection never moves this row at all).
      //   'waived'    — rejected, and later forgiven by a Grace Day. The only way
      //                 apply_grace_days() ever reaches *this* row is if it was still `owed`
      //                 at fold-in time, which only happens after a rejection — an approval
      //                 already moved it to `voided` first, and grace_day_validate()'s own
      //                 Never boundary excludes a `held` Penalty, so a Grace Day can never
      //                 land on one still under open appeal either.
      //   'held'      — still pending, no ruling yet.
      //   'dropped'   — timed out (void_expired_appeals()).
      //   'collected' — rejected, then later marked paid from the "Owed penalties" list.
      const { data: penaltyRow, error: penaltyError } = await supabase
        .from('penalty')
        .select('state')
        .eq('id', appealRow.penalty_id as string)
        .maybeSingle();
      if (cancelled) return;

      if (penaltyError) {
        setView({ kind: 'failed', reason: penaltyError.message });
        return;
      }

      if (!penaltyRow) {
        setView({ kind: 'failed', reason: "This appeal's own Penalty could not be found." });
        return;
      }

      const penaltyState = penaltyRow.state as PenaltyState;

      const { data: evidenceRows, error: evidenceError } = await supabase
        .from('evidence')
        .select('id,storage_path')
        .eq('appeal_id', appealId);
      if (cancelled) return;

      if (evidenceError) {
        setView({ kind: 'failed', reason: evidenceError.message });
        return;
      }

      const evidence: RefereeEvidenceItem[] = [];
      let evidenceFailures = 0;
      for (const row of evidenceRows ?? []) {
        // One hour, not one minute — long enough for an actual review to happen without
        // the image simply failing partway through with no explanation. Evidence review is
        // exactly the slow, unhurried case this screen exists for (FR-15's own point: the
        // referee is never rushed by a clock only the author feels).
        const { data: signed, error: signError } = await supabase.storage
          .from('appeal-evidence')
          .createSignedUrl(row.storage_path as string, 3600);
        if (cancelled) return;

        if (signError || !signed?.signedUrl) {
          evidenceFailures++;
          continue;
        }

        evidence.push({ id: row.id as string, url: signed.signedUrl });
      }

      setView({
        kind: 'ready',
        appeal: {
          id: appealRow.id as string,
          forDay: appealRow.for_day as string,
          commitmentName:
            (appealRow.commitment as unknown as { name: string } | null)?.name ?? null,
          // Every Penalty costs the same flat amount by construction (FR-13,
          // public.penalty_amount_dong()) — PENALTY_DONG is that constant's own client
          // mirror (lib/money.ts), read here rather than a specific row's amount_dong
          // because a won appeal's own original row is exactly the one no door can read
          // any more.
          amountDong: PENALTY_DONG,
          penaltyState,
          deadline: appealRow.deadline as string,
        },
        evidence,
        evidenceFailures,
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [appealId, router, reloadToken]);

  async function rule(approved: boolean) {
    setRuling({ kind: 'ruling' });

    const supabase = createClient();
    const { error } = await supabase.rpc('rule_appeal', {
      p_appeal_id: appealId,
      p_approved: approved,
    });

    // Either outcome reloads: a raced refusal (the timeout beat this call, or a second
    // ruling attempt lost) is exactly as real an outcome as a success, and the screen
    // should show what rule_appeal()'s own guard actually decided rather than freezing on
    // the stale `held` state that made these buttons render in the first place.
    setRuling(error ? { kind: 'failed', reason: error.message } : { kind: 'idle' });
    setReloadToken((token) => token + 1);
  }

  return (
    <main>
      <section className="screen">
        <header className="screen-head">
          <button type="button" className="quiet back" onClick={() => router.push('/referee')}>
            {REFEREE_APPEAL_DETAIL_COPY.back}
          </button>
        </header>

        {view.kind === 'loading' && <p>{REFEREE_APPEAL_DETAIL_COPY.loading}</p>}

        {view.kind === 'not-found' && <p role="status">{REFEREE_APPEAL_DETAIL_COPY.notFound}</p>}

        {view.kind === 'failed' && (
          <p role="status">
            <strong>{REFEREE_APPEAL_DETAIL_COPY.failed}</strong> {view.reason}
          </p>
        )}

        {view.kind === 'ready' && (
          <>
            <h1>{view.appeal.commitmentName ?? 'A commitment'}</h1>
            <p>
              {REFEREE_APPEAL_DETAIL_COPY.machineCall(
                view.appeal.commitmentName,
                view.appeal.forDay,
              )}
            </p>
            <p>{formatDong(view.appeal.amountDong)}</p>

            <h2>{REFEREE_APPEAL_DETAIL_COPY.evidenceHeading}</h2>
            {view.evidence.length === 0 && view.evidenceFailures === 0 && (
              <p>{REFEREE_APPEAL_DETAIL_COPY.noEvidence}</p>
            )}
            {/* A signed URL into a private bucket, not an asset next/image's own optimiser
                is set up to fetch. */}
            {view.evidence.map((item, index) => (
              // eslint-disable-next-line @next/next/no-img-element
              <img
                key={item.id}
                src={item.url}
                alt={REFEREE_APPEAL_DETAIL_COPY.evidenceAlt(index + 1, view.evidence.length)}
              />
            ))}
            {view.evidenceFailures > 0 && (
              <p role="status">
                {REFEREE_APPEAL_DETAIL_COPY.evidenceLoadFailed(view.evidenceFailures)}
              </p>
            )}

            {view.appeal.penaltyState === 'held' && (
              <>
                <p>
                  {REFEREE_APPEAL_DETAIL_COPY.timeoutNote(
                    formatDeadline(new Date(view.appeal.deadline)),
                  )}
                </p>

                <div className="actions">
                  <button
                    type="button"
                    className="action"
                    disabled={ruling.kind === 'ruling'}
                    aria-busy={ruling.kind === 'ruling'}
                    onClick={() => void rule(true)}
                  >
                    {ruling.kind === 'ruling'
                      ? REFEREE_APPEAL_DETAIL_COPY.ruling
                      : REFEREE_APPEAL_DETAIL_COPY.approve}
                  </button>
                  <button
                    type="button"
                    disabled={ruling.kind === 'ruling'}
                    aria-busy={ruling.kind === 'ruling'}
                    onClick={() => void rule(false)}
                  >
                    {ruling.kind === 'ruling'
                      ? REFEREE_APPEAL_DETAIL_COPY.ruling
                      : REFEREE_APPEAL_DETAIL_COPY.reject}
                  </button>
                </div>

                {ruling.kind === 'failed' && (
                  <p role="status">
                    <strong>{REFEREE_APPEAL_DETAIL_COPY.failed}</strong> {ruling.reason}
                  </p>
                )}
              </>
            )}

            {view.appeal.penaltyState === 'voided' && (
              <p role="status">{REFEREE_APPEAL_DETAIL_COPY.approved}</p>
            )}

            {view.appeal.penaltyState === 'owed' && (
              <p role="status">{REFEREE_APPEAL_DETAIL_COPY.rejected}</p>
            )}

            {view.appeal.penaltyState === 'dropped' && (
              <p role="status">{REFEREE_APPEAL_DETAIL_COPY.timedOut}</p>
            )}

            {/* Story 4.7: this appeal's own Penalty was rejected, then later marked
                Collected from the "Owed penalties" list — reachable by revisiting this
                screen afterward. Without this branch the outcome area silently went blank. */}
            {view.appeal.penaltyState === 'collected' && (
              <p role="status">{REFEREE_APPEAL_DETAIL_COPY.collected}</p>
            )}

            {/* Story 5.1: this appeal was rejected, and the day was later forgiven by a
                Grace Day — unrelated to this appeal's own ruling, and never `approved`. The
                settlement moved off this appeal's own row, the same signal `voided` above
                reads, but the current settlement's own penalty reads `waived` rather than
                `owed`/absent, which is what tells the two causes apart. */}
            {view.appeal.penaltyState === 'waived' && (
              <p role="status">{REFEREE_APPEAL_DETAIL_COPY.gracedAfterRejection}</p>
            )}
          </>
        )}
      </section>
    </main>
  );
}
