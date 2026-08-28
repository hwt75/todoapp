'use client';

import { useEffect, useRef, useState } from 'react';
import { CommitmentRow, type RowCommitment } from '@/components/commitment-row';
import { submitDeclaration, type QueuedClaim } from '@/lib/declaration-write';
import { calendarMoment } from '@/lib/declaration';
import { EVIDENCE_COPY, evidenceObjectPath, fileCapturedOn, isEvidenceDated } from '@/lib/evidence';
import { stateToday } from '@/lib/commitment-state';
import { createClient } from '@/lib/supabase/client';
import { DebtBlock } from '@/components/debt-block';
import { totalOwed } from '@/lib/money';
import type { WeeklyQuotaPosition } from '@/lib/weekly-quota';
import { buildLedger, type LedgerRow } from '@/lib/ledger';
import {
  GRACE_DAY_COPY,
  classifyGraceDaySpend,
  formatGraceAllowance,
  toGraceDayRow,
} from '@/lib/grace';

type View =
  | { kind: 'loading' }
  | {
      kind: 'ready';
      rows: RowCommitment[];
      owedDong: number;
      chains: Record<string, number>;
      quotas: Record<string, WeeklyQuotaPosition>;
      /** Story 5.1: every Failed, still-owed day a Grace Day could void — "the Day summary"
       *  entry point FR-17's own AC names, alongside a Ledger row. Empty far more often than
       *  not (most days are clean), which is why this screen otherwise says nothing about
       *  money at all until there is something to say. */
      graceRows: LedgerRow[];
      // Never `number | null` — a failed or missing `grace_allowance_remaining` read fails
      // the whole view below, the same treatment every other parallel read here already
      // gets, so a real doer session always has a real number by the time this variant is
      // reached (Story 5.1 review finding: never coerce "unknown" to "0 remaining").
      graceRemaining: number;
    }
  | { kind: 'failed'; reason: string };

/** Mirrors `components/ledger.tsx`'s own per-row Grace Day status — see that file's comment
 *  for why this needs to be its own client-local state rather than something read back from
 *  the server: there is no polling surface for whether `apply_grace_days()` has folded a
 *  spend in yet. */
type GraceRowState =
  { kind: 'idle' } | { kind: 'spending' } | { kind: 'spent' } | { kind: 'failed'; reason: string };

/** Story 6.2, per timed commitment. `queued` is a real outcome, not a failure: the claim is on
 *  the device dated when it was tapped, and it goes when there is a connection. */
type ClaimState =
  | { kind: 'idle' }
  | { kind: 'claiming' }
  /** `declarationId` is what a photo attaches to (Story 6.3). Null when the claim landed but
   *  the read that would fetch its id did not — the claim stands, the upload waits. */
  | { kind: 'claimed'; declarationId: string | null }
  | { kind: 'queued' }
  | { kind: 'failed'; reason: string };

/** Story 6.3, keyed by commitment id alongside `claimState`. */
type EvidenceState =
  { kind: 'idle' } | { kind: 'uploading' } | { kind: 'saved' } | { kind: 'failed'; reason: string };

const SELECT =
  'id,name,cadence,carries_penalty,weekly_target,daily_minutes_target,due_time,late_window_minutes';

/**
 * The screen the author opens, and the only one he opens under reluctance.
 *
 * His stated failure mode is opening the app, feeling nothing worth staying for, and not
 * coming back for days. So this answers "where do I stand" before anything is read, and
 * it says nothing it cannot support: until settlement exists, every commitment is
 * honestly `not yet` and no row claims otherwise.
 */
export function Today({
  ownerId,
  onOpenLedger,
  onOpenChain,
  onOpenFocus,
}: {
  ownerId: string;
  onOpenLedger: () => void;
  onOpenChain: (commitment: RowCommitment) => void;
  /** Where a *Put hours in* row goes instead. See the fork below. */
  onOpenFocus: (commitment: RowCommitment) => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });
  // Story 5.1, keyed by `for_day` — mirrors `components/ledger.tsx`'s own identical state.
  const [graceState, setGraceState] = useState<Record<string, GraceRowState>>({});
  // Story 6.2, keyed by commitment id — the same client-local shape `graceState` uses above,
  // and for the same reason: a claim may be sitting in the offline queue, so there is nothing
  // on the server to re-read that would tell this screen what happened.
  const [claimState, setClaimState] = useState<Record<string, ClaimState>>({});
  const [evidenceState, setEvidenceState] = useState<Record<string, EvidenceState>>({});
  // Guards `spendGraceDay`'s own state updates after the insert's await resolves — mirrors
  // `components/settings.tsx`'s identical `mounted` ref, needed for the same reason: a spend
  // fired from a click can still be in flight when this screen unmounts (opening the Ledger,
  // Settings, a Chain, or a Focus Session all swap it out in `app/page.tsx`).
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const supabase = createClient();
      const [
        { data, error },
        { data: penalties, error: penaltiesError },
        { data: chains, error: chainsError },
        { data: quotas, error: quotasError },
        { data: graceSettlements, error: graceSettlementsError },
        { data: gracePenalties, error: gracePenaltiesError },
        { data: grace, error: graceError },
      ] = await Promise.all([
        supabase.from('commitment').select(SELECT).is('archived_at', null).order('created_at'),
        // `penalty_current`, not `penalty`. A penalty attached to a superseded verdict is
        // history rather than debt — it stays in the table so the trace survives and stops
        // counting (AD-9). Reading the base table would charge him for a day he took back.
        supabase.from('penalty_current').select('amount_dong').eq('state', 'owed'),
        // Derived in one place — `chain_current` — rather than counted here. A second
        // implementation of the chain rule would drift, and this one would drift silently
        // because a wrong chain still looks like a number.
        supabase.from('chain_current').select('commitment_id,current_days'),
        // Same pattern, for the other live position this screen shows: `weekly_quota_progress`
        // (spec 3-3) is the one source the pill reads, never a client-side tally of raw
        // `declaration` rows (AD-8).
        supabase.from('weekly_quota_progress').select('commitment_id,held,target,days_remaining'),
        // Story 5.1: two separate reads (never reusing the unfiltered `penalty_current` read
        // above, which deliberately mixes day- and week-kind rows for the aggregate figure) —
        // day-kind only, folded through `buildLedger` the same way `components/ledger.tsx`
        // derives `graceable`, so the two surfaces cannot drift into disagreeing about which
        // day qualifies. Filtered to `verdict = 'failed'` server-side too — unlike the
        // Ledger, which genuinely needs every day ever judged to render its own history,
        // this screen only ever wants the handful that could still be graced, so there is no
        // reason to pull the account's entire settled-day history just to filter it back
        // down client-side.
        supabase
          .from('settlement_current')
          .select('period,verdict,missed_count')
          .eq('kind', 'day')
          .eq('verdict', 'failed'),
        supabase
          .from('penalty_current')
          .select('amount_dong,state,period')
          .eq('kind', 'day')
          .eq('state', 'owed'),
        supabase.from('grace_allowance_remaining').select('remaining').maybeSingle(),
      ]);

      if (cancelled) return;

      // Every parallel read is checked, not only the first — a failed penalties/chains/quotas
      // read used to render silently as if nothing were owed or held, which is a wrong answer
      // dressed as a clean one, not an absence of data.
      const failed =
        error ??
        penaltiesError ??
        chainsError ??
        quotasError ??
        graceSettlementsError ??
        gracePenaltiesError ??
        graceError;
      if (failed) {
        setView({ kind: 'failed', reason: failed.message });
        return;
      }

      // A real doer session always has exactly one row here (`grace_allowance_remaining`'s
      // own `where role = 'doer'`) — no row without an error is itself a failure to
      // surface, never a silent "treat it as 0 remaining" (Story 5.1 review finding).
      if (!grace) {
        setView({ kind: 'failed', reason: 'No Grace Days allowance found for this account.' });
        return;
      }

      setView({
        kind: 'ready',
        rows: (data ?? []) as RowCommitment[],
        owedDong: totalOwed((penalties ?? []).map((p) => p.amount_dong as number)),
        chains: Object.fromEntries(
          (chains ?? []).map((c) => [c.commitment_id as string, c.current_days as number]),
        ),
        quotas: Object.fromEntries(
          (quotas ?? []).map((q) => [
            q.commitment_id as string,
            {
              held: q.held as number,
              target: q.target as number,
              daysRemaining: q.days_remaining as number,
            },
          ]),
        ),
        graceRows: buildLedger(graceSettlements ?? [], gracePenalties ?? [], []).filter(
          (r) => r.graceable,
        ),
        graceRemaining: grace.remaining as number,
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  /** Spends a Grace Day against one Failed, owed day. See `components/ledger.tsx`'s own
   *  identical function for the full reasoning — this is the same control, offered from the
   *  Day summary rather than a Ledger row (FR-17's own two current entry points). */
  /**
   * Claim a timed commitment for today.
   *
   * Every rule about what a claim is — which day it lands on, whether the window was open,
   * that a retry lands once — belongs to `declaration_derive_day()` and to the shared write
   * path. This asks and reports; it decides nothing, and in particular it does not check the
   * window itself. A second copy of that rule in a component is a rule only a browser can
   * exercise, and the server's refusal already names the window in its own words.
   */
  async function claim(commitmentId: string) {
    setClaimState((current) => ({ ...current, [commitmentId]: { kind: 'claiming' } }));

    try {
      const outcome = await submitDeclaration(window.localStorage, {
        idempotencyKey: crypto.randomUUID(),
        ownerId,
        commitmentId,
        answer: 'held',
        answeredAt: new Date().toISOString(),
        // Lands on today, not yesterday — this is the read-side half of that, so a retry
        // arriving twice is recognised as its own duplicate rather than as someone else's row.
        timed: true,
      } satisfies QueuedClaim);

      if (!mounted.current) return;

      setClaimState((current) => ({
        ...current,
        [commitmentId]:
          outcome.kind === 'refused'
            ? { kind: 'failed', reason: outcome.reason }
            : outcome.kind === 'queued'
              ? { kind: 'queued' }
              : { kind: 'claimed', declarationId: outcome.declarationId ?? null },
      }));
    } catch (error) {
      if (!mounted.current) return;
      setClaimState((current) => ({
        ...current,
        [commitmentId]: { kind: 'failed', reason: String(error) },
      }));
    }
  }

  /**
   * Attach one photo to a claim that has landed.
   *
   * Mirrors `components/appeal-form.tsx`'s own upload, deliberately: object first, metadata
   * row second, and a refusal never reported as a save. Every rule it applies is applied again
   * by `evidence_derive_owner()` — the owner is derived from the claim, the capture date must
   * match the day it proves, and a claim cannot be proved once its day has ended (AD-1).
   *
   * `owner_id` is not sent. The trigger sets it before the NOT NULL is checked, and a client
   * that sent one would just have it overwritten — the whole point of NFR4.
   */
  async function attachProof(commitmentId: string, declarationId: string, file: File) {
    const today = calendarMoment(new Date()).day;

    // Refused before any upload starts, so an evidently wrong-dated file never reaches Storage.
    if (!isEvidenceDated(file, today)) {
      setEvidenceState((c) => ({
        ...c,
        [commitmentId]: { kind: 'failed', reason: EVIDENCE_COPY.wrongDay },
      }));
      return;
    }

    setEvidenceState((c) => ({ ...c, [commitmentId]: { kind: 'uploading' } }));

    try {
      const supabase = createClient();
      const path = evidenceObjectPath(declarationId, crypto.randomUUID(), file.name);

      const { error: uploadError } = await supabase.storage
        .from('appeal-evidence')
        .upload(path, file, { contentType: file.type || undefined });

      if (!mounted.current) return;

      if (uploadError) {
        setEvidenceState((c) => ({
          ...c,
          [commitmentId]: { kind: 'failed', reason: EVIDENCE_COPY.failed },
        }));
        return;
      }

      const { error: insertError } = await supabase.from('evidence').insert({
        declaration_id: declarationId,
        storage_path: path,
        captured_on: fileCapturedOn(file),
      });

      if (!mounted.current) return;

      setEvidenceState((c) => ({
        ...c,
        [commitmentId]: insertError
          ? { kind: 'failed', reason: insertError.message }
          : { kind: 'saved' },
      }));
    } catch (error) {
      if (!mounted.current) return;
      setEvidenceState((c) => ({
        ...c,
        [commitmentId]: { kind: 'failed', reason: String(error) },
      }));
    }
  }

  async function spendGraceDay(forDay: string) {
    setGraceState((s) => ({ ...s, [forDay]: { kind: 'spending' } }));

    const { error } = await createClient()
      .from('grace_day')
      .insert(toGraceDayRow({ forDay }, ownerId));

    if (!mounted.current) return;

    const outcome = classifyGraceDaySpend(error);

    if (outcome.kind === 'refused') {
      setGraceState((s) => ({ ...s, [forDay]: { kind: 'failed', reason: outcome.reason } }));
      return;
    }

    // Only 'spent' is a *new* row — 'already-spent' (23505) means nothing was written this
    // time, and the count the last read returned already accounts for that day's own
    // earlier spend. See `components/ledger.tsx`'s identical function for the full reasoning.
    setGraceState((s) => ({ ...s, [forDay]: { kind: 'spent' } }));
    if (outcome.kind === 'spent') {
      setView((v) =>
        v.kind === 'ready' ? { ...v, graceRemaining: Math.max(0, v.graceRemaining - 1) } : v,
      );
    }
  }

  return (
    /* The debt block is drawn first and read last, and that is not a styling accident.
       EXPERIENCE.md requires the commitment rows to be announced before it: a sighted
       reader can look past the figure, a VoiceOver user cannot skip what is read to them,
       and being told your own debt first thing every morning is a cost this product does
       not need to add. So the DOM order is rows-then-figure and CSS `order` puts the
       figure on top. */
    <section className="today">
      {/* No control beside the title. Settings used to be a full-size bordered button standing
          alone under this heading — the most prominent object on the screen, on the one screen
          whose subject is supposed to be prominent instead. It moved to the tab bar in
          `app/page.tsx`, which sits outside this component and therefore keeps the property the
          button was placed here for: Settings stays reachable even when every read below fails,
          and it is the one place that can turn the morning hour back down to something
          sendable. */}
      <header className="screen-head">
        <h1>Today</h1>
      </header>

      {view.kind === 'loading' && <p>Working…</p>}

      {view.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && view.rows.length === 0 && (
        <p className="row-muted">
          Nothing set up yet. Add a commitment below and it will appear here tomorrow morning.
        </p>
      )}

      {view.kind === 'ready' && (
        <>
          <div className="today-rows">
            {view.rows.map((row) => (
              <CommitmentRow
                key={row.id}
                commitment={row}
                state={stateToday(row)}
                chainDays={view.chains[row.id] ?? 0}
                quotaPosition={view.quotas[row.id]}
                /* An hours-quota row opens the Focus Session, and every other row opens the
                   Chains detail as before. Not a preference: `commitments_owing()` excludes
                   that cadence, so it never reaches `settlement_commitment`, so `chain_current`
                   has nothing for it — its Chains detail is empty by construction. The fork
                   lives here because this component already selects `cadence`, which keeps
                   `commitment-row.tsx` a component that opens a thing rather than one that
                   knows which thing. */
                onOpen={row.cadence === 'daily_hours_quota' ? onOpenFocus : onOpenChain}
              />
            ))}
          </div>

          {/* Story 6.2 — the claim, and only the claim.
              Offered for every timed commitment, with no attempt to say whether its window is
              ahead, open or already shut, and no attempt to say whether it has been claimed
              earlier today. Both need reading state this screen deliberately cannot reach:
              this file must never read raw `declaration` rows (AD-8 — one source for a
              position, never a client-side tally), and there is no view yet that answers
              "where does this window stand". Building one is Story 6.5.

              Until then the control is offered a second time after a reload, and the second
              tap is refused by `declaration_one_per_commitment_day` with a sentence saying the
              day is already answered. Legible, and honest about what this screen knows. */}
          {view.rows.some((row) => row.due_time) && (
            <div className="card card-pad stack">
              {view.rows
                .filter((row) => row.due_time)
                .map((row) => {
                  const state: ClaimState = claimState[row.id] ?? { kind: 'idle' };

                  return (
                    <div key={row.id}>
                      <div className="actions">
                        <button
                          type="button"
                          disabled={
                            state.kind === 'claiming' ||
                            state.kind === 'claimed' ||
                            state.kind === 'queued'
                          }
                          onClick={() => void claim(row.id)}
                        >
                          {`Claim ${row.name}`}
                        </button>
                      </div>

                      {state.kind === 'claimed' && (
                        <>
                          <p className="row-muted">Claimed for today.</p>

                          {/* Story 6.3 — the photo, and only once the claim has actually
                              landed. Evidence references the declaration row by id, and a
                              claim sitting in the offline queue has no row and no id. That is
                              the honest shape of the split: the claim survives having no
                              signal, the photo does not. */}
                          {state.declarationId !== null &&
                            (() => {
                              const proof: EvidenceState = evidenceState[row.id] ?? {
                                kind: 'idle',
                              };
                              const inputId = `proof-${row.id}`;

                              return (
                                <>
                                  <label htmlFor={inputId}>{EVIDENCE_COPY.label}</label>
                                  <input
                                    id={inputId}
                                    type="file"
                                    accept="image/png,image/jpeg,image/heic"
                                    // `capture` opens the camera rather than the library where
                                    // the device offers one — a photo taken now is the point.
                                    capture="environment"
                                    disabled={proof.kind === 'uploading'}
                                    onChange={(event) => {
                                      const file = event.target.files?.[0];
                                      if (file) {
                                        void attachProof(row.id, state.declarationId!, file);
                                      }
                                    }}
                                  />
                                  <p className="row-muted">{EVIDENCE_COPY.hint}</p>

                                  {proof.kind === 'uploading' && (
                                    <p role="status">{EVIDENCE_COPY.uploading}</p>
                                  )}
                                  {proof.kind === 'saved' && (
                                    <p role="status">{EVIDENCE_COPY.saved}</p>
                                  )}
                                  {proof.kind === 'failed' && (
                                    <p>
                                      <strong>{EVIDENCE_COPY.failed}</strong> {proof.reason}
                                    </p>
                                  )}
                                </>
                              );
                            })()}
                        </>
                      )}

                      {state.kind === 'queued' && (
                        <p className="row-muted">
                          Saved on this device — there is no connection right now. It will go when
                          there is one, dated when you tapped.
                        </p>
                      )}

                      {state.kind === 'failed' && (
                        <p>
                          <strong>Not claimed.</strong> {state.reason}
                        </p>
                      )}
                    </div>
                  );
                })}
            </div>
          )}

          <DebtBlock totalDong={view.owedDong} onOpen={onOpenLedger} />

          {/* Grace Day (Story 5.1): "the Day summary" entry point FR-17's own AC names,
              alongside a Ledger row — never only inside a future Silence intervention. Says
              nothing at all when nothing is graceable, the same "nothing it cannot support"
              rule the rest of this screen already keeps, and why the frame around them is
              conditional rather than an empty rectangle on the clean days. */}
          {view.graceRows.length > 0 && (
            <div className="card">
              {view.graceRows.map((row) => {
                const rowGrace: GraceRowState = graceState[row.day] ?? { kind: 'idle' };

                return (
                  <div
                    className="row row-grace"
                    key={row.day}
                    role="group"
                    aria-label={`Grace Day, ${row.day}`}
                  >
                    <div className="row-main">
                      <div className="row-name">{row.day}</div>
                      {rowGrace.kind === 'spent' ? (
                        <p role="status">{GRACE_DAY_COPY.spent}</p>
                      ) : (
                        <div className="actions">
                          <button
                            type="button"
                            // Distinguishes one row's control from every other's for a
                            // screen-reader user, the same fix `components/ledger.tsx`'s
                            // identical control needed.
                            aria-label={`Spend a Grace Day for ${row.day}`}
                            onClick={() => void spendGraceDay(row.day)}
                            disabled={rowGrace.kind === 'spending' || view.graceRemaining <= 0}
                          >
                            {rowGrace.kind === 'spending'
                              ? GRACE_DAY_COPY.spending
                              : GRACE_DAY_COPY.spend}
                          </button>
                          <span className="row-muted">
                            {formatGraceAllowance(view.graceRemaining)}
                          </span>
                        </div>
                      )}
                      {rowGrace.kind === 'failed' && (
                        <p role="status">
                          <strong>{GRACE_DAY_COPY.failed}</strong> {rowGrace.reason}
                        </p>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </>
      )}
    </section>
  );
}
