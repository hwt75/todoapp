'use client';

import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import type { PenaltyState } from '@/lib/ledger';
import {
  MONTHLY_REPORT_COPY,
  appealRejectShare,
  countSilenceEpisodes,
  foldAppealOutcomes,
  foldChains,
  foldCommitmentCompletion,
  foldDeclarationAnswerRate,
  foldPenaltyFigure,
  formatDays,
  formatMonthLabel,
  formatRate,
  isRefereeStillActive,
  lookaheadEndDay,
  medianDaysToAcknowledge,
  medianDaysToReturn,
  monthDayBounds,
  monthInstantBounds,
  mostRecentCompletedMonth,
  originalPenaltyRows,
  type AppealOutcomeRow,
  type AppealOutcomeTotals,
  type ChainRow,
  type ChainSummary,
  type CommitmentAnswerRateRow,
  type CommitmentCompletion,
  type OriginalPenaltyRow,
} from '@/lib/monthly-report';

interface ReportData {
  monthLabel: string;
  chains: ChainSummary[];
  medianDaysToReturn: number | null;
  commitmentCompletion: CommitmentCompletion[];
  silenceEpisodeCount: number;
  refereeStillActive: boolean;
  askedTotal: number;
  answeredTotal: number;
  answerRate: number | null;
  penaltiesIncurred: { count: number; totalDong: number };
  penaltiesCollected: { count: number; totalDong: number };
  medianDaysToAcknowledge: number | null;
  appealOutcomes: AppealOutcomeTotals;
  appealShare: number | null;
}

type View =
  { kind: 'loading' } | { kind: 'ready'; data: ReportData } | { kind: 'failed'; reason: string };

/**
 * One account-wide measure: its name, and its figure out at the row's right edge.
 *
 * The whole screen used to be nine `h2` + `p` pairs stacked down the page, so every measure
 * put its name and its number on two separate lines and a reader had nothing to run an eye
 * down. The figures line up on one edge instead — which is the only reason a report of this
 * shape is quicker to read than the same sentences in prose.
 *
 * `note` rather than `value` for a measure whose answer is a sentence: a sentence dragged out
 * to the right edge is not a column, it is a ragged paragraph pretending to be one. Those sit
 * under the name, the same shape a Settings row uses for its consequence line.
 *
 * One `aria-label` on the group and `aria-hidden` on the parts, so the row is announced as a
 * single fact — the convention every other row in this product already follows.
 */
function Measure({ name, value, note }: { name: string; value?: string; note?: string }) {
  return (
    <div className="row" role="group" aria-label={`${name}, ${value ?? note ?? ''}`}>
      <div className="row-main">
        <div className="row-name">{name}</div>
        {note !== undefined && (
          <div className="row-muted" aria-hidden="true">
            {note}
          </div>
        )}
      </div>
      {value !== undefined && (
        <span className="row-muted" aria-hidden="true">
          {value}
        </span>
      )}
    </div>
  );
}

/** `Incurred: 1 · 500.000₫`, or `Incurred: None.` — one string, so neither half can be read
 *  without the other. */
function penaltyFigure(label: string, entry: { count: number; totalDong: number }): string {
  const figure =
    entry.count === 0
      ? MONTHLY_REPORT_COPY.noPenalties
      : MONTHLY_REPORT_COPY.penaltyLine(entry.count, entry.totalDong);
  return `${label}: ${figure}`;
}

/**
 * SM-C1's counter-metric: what the month cost, and what was actually collected of it.
 *
 * **Two figures, never merged.** They stay on separate lines under one name rather than out
 * at the row's right edge, because a single edge with two numbers on it is exactly the
 * merge this measure exists to refuse.
 */
function Penalties({ incurred, collected }: { incurred: string; collected: string }) {
  return (
    <div
      className="row"
      role="group"
      aria-label={`${MONTHLY_REPORT_COPY.penaltiesHeading}, ${incurred}, ${collected}`}
    >
      <div className="row-main">
        <div className="row-name">{MONTHLY_REPORT_COPY.penaltiesHeading}</div>
        <div className="row-muted" aria-hidden="true">
          {incurred}
        </div>
        <div className="row-muted" aria-hidden="true">
          {collected}
        </div>
      </div>
    </div>
  );
}

/**
 * The Monthly report (Story 5.4, FR-24) — the only screen in this app that states every PRD
 * §8 measure together, at the altitude where a month can look fine on Today while the
 * mechanism underneath (the Referee's own ruling and collecting, or Silence quietly becoming
 * routine) has stopped. Author-only, read-only, no month picker: it always names the most
 * recently completed calendar month and computes it live, never a stored report row.
 *
 * **Nothing here decides anything.** Every figure is a plain read of an existing table/view
 * (`chain_current`, `settlement_current`, `penalty_current`, `silence_episode`, `appeal`) or
 * the one new server-side aggregation this story adds
 * (`commitment_answer_rate_for_month()`), folded by `lib/monthly-report.ts`'s own pure
 * functions — mirroring `components/ledger.tsx`'s identical split between "what the server
 * decided" and "how this screen reads it".
 *
 * **AC #3 (the daily summary's own absence is the heartbeat failure) needs no code here.**
 * The existing daily-summary mechanism is already the product's only alarm
 * (`ARCHITECTURE-SPINE.md`'s own Deferred section) — this screen adds no second one.
 */
export function MonthlyReport({ onClose }: { onClose: () => void }) {
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      try {
        await loadReport();
      } catch (err) {
        // Any thrown error mid-load — a network failure `await` itself rejects on, or
        // `foldAppealOutcomes`'s own exhaustiveness-check throw on an unrecognized
        // `penalty_state` — must still land on the same `failed` view the explicit
        // query-error checks below already produce, rather than leaving `view` stuck on
        // `loading` forever.
        if (!cancelled) setView({ kind: 'failed', reason: String(err) });
      }
    }

    async function loadReport() {
      const supabase = createClient();
      const { year, month } = mostRecentCompletedMonth(new Date());
      const dayBounds = monthDayBounds(year, month);
      const instantBounds = monthInstantBounds(year, month);
      const lookaheadEndDate = lookaheadEndDay(year, month);
      const lookaheadEndInstant = `${lookaheadEndDate}T00:00:00+07:00`;

      const [
        { data: chainRows, error: chainError },
        { data: commitmentRows, error: commitmentError },
        { data: failedRows, error: failedError },
        { data: cleanRows, error: cleanError },
        { data: declarationRows, error: declarationError },
        { data: incurredRows, error: incurredError },
        { data: collectedRows, error: collectedError },
        { data: appealRows, error: appealError },
        { data: ruledRows, error: ruledError },
        { data: silenceRows, error: silenceError },
        { data: rateRows, error: rateError },
      ] = await Promise.all([
        supabase.from('chain_current').select('commitment_id,current_days,longest_days'),
        supabase.from('commitment').select('id,name'),
        // SM-2, corrected (Epic 5 retrospective, 2026-08-27, finding A3): the base
        // `settlement` table with `supersedes` is null, not `settlement_current` — a Grace
        // Day or an approved Appeal can recompute a Failed Day's own corrective settlement to
        // `clean`, which would otherwise vanish the day from its own month's Failed-day set
        // (and this report's own median) the moment it was later forgiven or overturned.
        // "Was this day originally Failed" ignores supersession on purpose (direction agreed
        // 2026-08-27): the median describes what happened operationally, not what a later
        // correction reclassified it as.
        supabase
          .from('settlement')
          .select('period')
          .eq('kind', 'day')
          .eq('verdict', 'failed')
          .is('supersedes', null)
          .gte('period', dayBounds.gte)
          .lt('period', dayBounds.lt),
        // SM-2's own lookahead: a Failed day near month end may return past the month
        // boundary, so clean-day candidates are fetched through the lookahead window, not
        // only the report month itself. Same `supersedes is null` fix, for the identical
        // reason: an original clean day must not be double-counted or displaced by whatever
        // a later correction of some *other* day happens to also read `clean`.
        supabase
          .from('settlement')
          .select('period')
          .eq('kind', 'day')
          .eq('verdict', 'clean')
          .is('supersedes', null)
          .gte('period', dayBounds.gte)
          .lt('period', lookaheadEndDate),
        // SM-C2: any Declaration, any commitment (declaration_satisfies_silence()'s own
        // established framing), through the same lookahead window.
        supabase
          .from('declaration')
          .select('answered_at')
          .gte('answered_at', instantBounds.gte)
          .lt('answered_at', lookaheadEndInstant),
        // SM-C1, incurred, corrected (Epic 5 retrospective, 2026-08-27, finding A3): the base
        // `penalty` table, any kind, with each row's own settlement embedded so
        // `originalPenaltyRows` can keep only the ones never superseded — `penalty_current`
        // would otherwise lose the original month's own figure once a Grace Day or an
        // approved Appeal folds it into a corrective row stamped with fold-in time, and gain
        // a spurious one in whatever month that fold-in happened to land in instead.
        supabase
          .from('penalty')
          .select('amount_dong,settlement:settlement_id(supersedes)')
          .gte('created_at', instantBounds.gte)
          .lt('created_at', instantBounds.lt),
        // SM-C1, collected: penalty_current rows collected in-month, any kind. Doubles as
        // SM-5's own "any penalty.collected_at in-month" signal — the identical rows.
        supabase
          .from('penalty_current')
          .select('amount_dong')
          .gte('collected_at', instantBounds.gte)
          .lt('collected_at', instantBounds.lt),
        // SM-C3: appeals filed this month, joined to their own penalty's current state —
        // the same signal referee-appeal-detail.tsx already reads to infer an outcome.
        supabase
          .from('appeal')
          .select('created_at,penalty:penalty_id(state)')
          .gte('created_at', instantBounds.gte)
          .lt('created_at', instantBounds.lt),
        // SM-5's other half: any appeal.ruled_at in-month.
        supabase
          .from('appeal')
          .select('id')
          .gte('ruled_at', instantBounds.gte)
          .lt('ruled_at', instantBounds.lt),
        supabase
          .from('silence_episode')
          .select('started_day')
          .gte('started_day', dayBounds.gte)
          .lt('started_day', dayBounds.lt),
        // SM-6/SM-3: the one new RPC this story needs (commitments_owing() itself is
        // revoked from authenticated) — p_month is any date inside the report month.
        supabase.rpc('commitment_answer_rate_for_month', { p_month: dayBounds.gte }),
      ]);

      if (cancelled) return;

      const failed =
        chainError ??
        commitmentError ??
        failedError ??
        cleanError ??
        declarationError ??
        incurredError ??
        collectedError ??
        appealError ??
        ruledError ??
        silenceError ??
        rateError;
      if (failed) {
        setView({ kind: 'failed', reason: failed.message });
        return;
      }

      const names = new Map<string, string>(
        (commitmentRows ?? []).map((c) => [c.id as string, c.name as string]),
      );

      const failedPeriods = (failedRows ?? []).map((r) => r.period as string);
      const cleanPeriods = (cleanRows ?? []).map((r) => r.period as string);
      const answeredAtInstants = (declarationRows ?? []).map((r) => r.answered_at as string);

      const appealOutcomeRows: AppealOutcomeRow[] = (appealRows ?? []).map((r) => ({
        penalty_state:
          ((r.penalty as unknown as { state?: PenaltyState } | null)?.state as
            PenaltyState | undefined) ?? null,
      }));
      const appealOutcomes = foldAppealOutcomes(appealOutcomeRows);

      const rateRowsTyped = (rateRows ?? []) as CommitmentAnswerRateRow[];
      const answerRateTotal = foldDeclarationAnswerRate(rateRowsTyped);

      setView({
        kind: 'ready',
        data: {
          monthLabel: formatMonthLabel(year, month),
          chains: foldChains((chainRows ?? []) as ChainRow[], names),
          medianDaysToReturn: medianDaysToReturn(failedPeriods, cleanPeriods),
          commitmentCompletion: foldCommitmentCompletion(rateRowsTyped, names),
          silenceEpisodeCount: countSilenceEpisodes(silenceRows ?? []),
          refereeStillActive: isRefereeStillActive(
            (ruledRows ?? []).length,
            (collectedRows ?? []).length,
          ),
          askedTotal: answerRateTotal.asked,
          answeredTotal: answerRateTotal.answered,
          answerRate: answerRateTotal.rate,
          penaltiesIncurred: foldPenaltyFigure(
            originalPenaltyRows((incurredRows ?? []) as unknown as OriginalPenaltyRow[]),
          ),
          penaltiesCollected: foldPenaltyFigure((collectedRows ?? []) as { amount_dong: number }[]),
          medianDaysToAcknowledge: medianDaysToAcknowledge(failedPeriods, answeredAtInstants),
          appealOutcomes,
          appealShare: appealRejectShare(appealOutcomes),
        },
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>{MONTHLY_REPORT_COPY.title}</h1>
        <button type="button" className="quiet back" onClick={onClose}>
          Back to today
        </button>
      </header>

      {view.kind === 'loading' && <p>{MONTHLY_REPORT_COPY.loading}</p>}

      {view.kind === 'failed' && (
        <p role="status">
          <strong>{MONTHLY_REPORT_COPY.failed}</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && (
        <>
          <p className="row-muted">{MONTHLY_REPORT_COPY.subtitle(view.data.monthLabel)}</p>

          {/* Per-commitment, so it keeps its own heading and its own frame — the measures
              below are account-wide and share one. */}
          <section>
            <h2>{MONTHLY_REPORT_COPY.chainsHeading}</h2>
            {view.data.chains.length === 0 ? (
              <p>{MONTHLY_REPORT_COPY.noChains}</p>
            ) : (
              <div className="card">
                {view.data.chains.map((c) => {
                  const value = MONTHLY_REPORT_COPY.chainLine(c.currentDays, c.longestDays);
                  return (
                    <div
                      className="row"
                      key={c.commitmentId}
                      role="group"
                      aria-label={`${c.commitmentName}, ${value}`}
                    >
                      <div className="row-main">
                        <div className="row-name">{c.commitmentName}</div>
                      </div>
                      <span className="row-muted" aria-hidden="true">
                        {value}
                      </span>
                    </div>
                  );
                })}
              </div>
            )}
          </section>

          <section>
            <h2>{MONTHLY_REPORT_COPY.completionHeading}</h2>
            {view.data.commitmentCompletion.length === 0 ? (
              <p>{MONTHLY_REPORT_COPY.noCompletionData}</p>
            ) : (
              <div className="card">
                {view.data.commitmentCompletion.map((c) => {
                  const value = `${MONTHLY_REPORT_COPY.completionLine(c.answered, c.asked)} (${formatRate(c.rate)})`;
                  return (
                    <div
                      className="row"
                      key={c.commitmentId}
                      role="group"
                      aria-label={`${c.commitmentName}, ${value}`}
                    >
                      <div className="row-main">
                        <div className="row-name">{c.commitmentName}</div>
                      </div>
                      <span className="row-muted" aria-hidden="true">
                        {value}
                      </span>
                    </div>
                  );
                })}
              </div>
            )}
          </section>

          {/* Every account-wide measure, one row each, in one frame. This screen used to be
              nine `h2` + `p` pairs stacked down the page, which put the name of a measure and
              its number on separate lines nine times over and gave a reader nothing to scan
              down. A report is read by running an eye along one edge, so the figures line up
              on that edge. */}
          <div className="card">
            <Measure
              name={MONTHLY_REPORT_COPY.returnHeading}
              value={formatDays(view.data.medianDaysToReturn)}
            />
            <Measure
              name={MONTHLY_REPORT_COPY.silenceHeading}
              value={MONTHLY_REPORT_COPY.silenceCount(view.data.silenceEpisodeCount)}
            />
            {/* A sentence, not a figure, so it sits under its name rather than out at the
                edge — the same shape Settings uses for a row's consequence line. */}
            <Measure
              name={MONTHLY_REPORT_COPY.refereeHeading}
              note={
                view.data.refereeStillActive
                  ? MONTHLY_REPORT_COPY.refereeActive
                  : MONTHLY_REPORT_COPY.refereeInactive
              }
            />
            <Measure
              name={MONTHLY_REPORT_COPY.answerRateHeading}
              value={
                view.data.askedTotal === 0
                  ? MONTHLY_REPORT_COPY.noAnswerRateData
                  : `${MONTHLY_REPORT_COPY.completionLine(view.data.answeredTotal, view.data.askedTotal)} (${formatRate(view.data.answerRate)})`
              }
            />

            <Penalties
              incurred={penaltyFigure(
                MONTHLY_REPORT_COPY.incurredLabel,
                view.data.penaltiesIncurred,
              )}
              collected={penaltyFigure(
                MONTHLY_REPORT_COPY.collectedLabel,
                view.data.penaltiesCollected,
              )}
            />

            <Measure
              name={MONTHLY_REPORT_COPY.acknowledgeHeading}
              value={formatDays(view.data.medianDaysToAcknowledge)}
            />
            <Measure
              name={MONTHLY_REPORT_COPY.appealsHeading}
              value={
                view.data.appealShare === null
                  ? MONTHLY_REPORT_COPY.noAppealsData
                  : `${MONTHLY_REPORT_COPY.appealShareLine(view.data.appealOutcomes)} (${formatRate(view.data.appealShare)})`
              }
            />
          </div>
        </>
      )}
    </section>
  );
}
