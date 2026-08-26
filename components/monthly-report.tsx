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
  type AppealOutcomeRow,
  type AppealOutcomeTotals,
  type ChainRow,
  type ChainSummary,
  type CommitmentAnswerRateRow,
  type CommitmentCompletion,
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
        supabase
          .from('settlement_current')
          .select('period')
          .eq('kind', 'day')
          .eq('verdict', 'failed')
          .gte('period', dayBounds.gte)
          .lt('period', dayBounds.lt),
        // SM-2's own lookahead: a Failed day near month end may return past the month
        // boundary, so clean-day candidates are fetched through the lookahead window, not
        // only the report month itself.
        supabase
          .from('settlement_current')
          .select('period')
          .eq('kind', 'day')
          .eq('verdict', 'clean')
          .gte('period', dayBounds.gte)
          .lt('period', lookaheadEndDate),
        // SM-C2: any Declaration, any commitment (declaration_satisfies_silence()'s own
        // established framing), through the same lookahead window.
        supabase
          .from('declaration')
          .select('answered_at')
          .gte('answered_at', instantBounds.gte)
          .lt('answered_at', lookaheadEndInstant),
        // SM-C1, incurred: penalty_current rows created in-month, any kind.
        supabase
          .from('penalty_current')
          .select('amount_dong')
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
          penaltiesIncurred: foldPenaltyFigure((incurredRows ?? []) as { amount_dong: number }[]),
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
    <section>
      <h1>{MONTHLY_REPORT_COPY.title}</h1>
      <button type="button" onClick={onClose}>
        Back to today
      </button>

      {view.kind === 'loading' && <p>{MONTHLY_REPORT_COPY.loading}</p>}

      {view.kind === 'failed' && (
        <p role="status">
          <strong>{MONTHLY_REPORT_COPY.failed}</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && (
        <>
          <p className="row-muted">{MONTHLY_REPORT_COPY.subtitle(view.data.monthLabel)}</p>

          <h2>{MONTHLY_REPORT_COPY.chainsHeading}</h2>
          {view.data.chains.length === 0 ? (
            <p>{MONTHLY_REPORT_COPY.noChains}</p>
          ) : (
            <ul>
              {view.data.chains.map((c) => (
                <li key={c.commitmentId}>
                  {c.commitmentName}: {MONTHLY_REPORT_COPY.chainLine(c.currentDays, c.longestDays)}
                </li>
              ))}
            </ul>
          )}

          <h2>{MONTHLY_REPORT_COPY.returnHeading}</h2>
          <p>{formatDays(view.data.medianDaysToReturn)}</p>

          <h2>{MONTHLY_REPORT_COPY.completionHeading}</h2>
          {view.data.commitmentCompletion.length === 0 ? (
            <p>{MONTHLY_REPORT_COPY.noCompletionData}</p>
          ) : (
            <ul>
              {view.data.commitmentCompletion.map((c) => (
                <li key={c.commitmentId}>
                  {c.commitmentName}: {MONTHLY_REPORT_COPY.completionLine(c.answered, c.asked)} (
                  {formatRate(c.rate)})
                </li>
              ))}
            </ul>
          )}

          <h2>{MONTHLY_REPORT_COPY.silenceHeading}</h2>
          <p>{MONTHLY_REPORT_COPY.silenceCount(view.data.silenceEpisodeCount)}</p>

          <h2>{MONTHLY_REPORT_COPY.refereeHeading}</h2>
          <p>
            {view.data.refereeStillActive
              ? MONTHLY_REPORT_COPY.refereeActive
              : MONTHLY_REPORT_COPY.refereeInactive}
          </p>

          <h2>{MONTHLY_REPORT_COPY.answerRateHeading}</h2>
          <p>
            {view.data.askedTotal === 0
              ? MONTHLY_REPORT_COPY.noAnswerRateData
              : `${MONTHLY_REPORT_COPY.completionLine(view.data.answeredTotal, view.data.askedTotal)} (${formatRate(view.data.answerRate)})`}
          </p>

          <h2>{MONTHLY_REPORT_COPY.penaltiesHeading}</h2>
          <p>
            {MONTHLY_REPORT_COPY.incurredLabel}:{' '}
            {view.data.penaltiesIncurred.count === 0
              ? MONTHLY_REPORT_COPY.noPenalties
              : MONTHLY_REPORT_COPY.penaltyLine(
                  view.data.penaltiesIncurred.count,
                  view.data.penaltiesIncurred.totalDong,
                )}
          </p>
          <p>
            {MONTHLY_REPORT_COPY.collectedLabel}:{' '}
            {view.data.penaltiesCollected.count === 0
              ? MONTHLY_REPORT_COPY.noPenalties
              : MONTHLY_REPORT_COPY.penaltyLine(
                  view.data.penaltiesCollected.count,
                  view.data.penaltiesCollected.totalDong,
                )}
          </p>

          <h2>{MONTHLY_REPORT_COPY.acknowledgeHeading}</h2>
          <p>{formatDays(view.data.medianDaysToAcknowledge)}</p>

          <h2>{MONTHLY_REPORT_COPY.appealsHeading}</h2>
          <p>
            {view.data.appealShare === null
              ? MONTHLY_REPORT_COPY.noAppealsData
              : `${MONTHLY_REPORT_COPY.appealShareLine(view.data.appealOutcomes)} (${formatRate(view.data.appealShare)})`}
          </p>
        </>
      )}
    </section>
  );
}
