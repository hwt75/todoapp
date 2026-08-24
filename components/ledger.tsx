'use client';

import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { buildLedger, ledgerPillFamily, ledgerPillLabel, type LedgerRow } from '@/lib/ledger';
import { formatDong } from '@/lib/money';

type View =
  { kind: 'loading' } | { kind: 'ready'; rows: LedgerRow[] } | { kind: 'failed'; reason: string };

export interface AppealTarget {
  commitmentId: string;
  commitmentName: string;
  forDay: string;
  amountDong: number;
}

/**
 * Every day that has been judged, newest first.
 *
 * **No row is tinted, on any day.** This screen is structurally a list of failures and is
 * reached in one tap from Today on exactly the worst day — so it is the one most likely to
 * become a wall of red, and a wall of red is the artifact this product exists to avoid.
 * The author's documented failure is retreating from the sight of his own record. Colour
 * lives in the pill and nowhere else.
 */
export function Ledger({
  onClose,
  onOpenAppeal,
}: {
  onClose: () => void;
  /** Story 4.4. Reachable the same way Chains detail and Focus Session are: a callback this
   *  component invokes itself, never a route the caller renders beside it. Optional so every
   *  caller that has not wired the Appeal screen yet keeps compiling — the Contest control
   *  simply does not render without it. */
  onOpenAppeal?: (target: AppealTarget) => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const supabase = createClient();

      const [
        { data: settlements, error },
        { data: penalties, error: penaltiesError },
        { data: misses, error: missesError },
        { data: weekSettlements, error: weekSettlementsError },
        { data: weekPenalties, error: weekPenaltiesError },
      ] = await Promise.all([
        supabase.from('settlement_current').select('period,verdict,missed_count').eq('kind', 'day'),
        supabase.from('penalty_current').select('amount_dong,state,period').eq('kind', 'day'),
        supabase
          .from('declaration')
          .select('for_day,commitment_id,filed_by,commitment:commitment_id(name,carries_penalty)')
          .eq('answer', 'slipped'),
        supabase
          .from('settlement_current')
          .select('period,verdict,missed_count')
          .eq('kind', 'week'),
        supabase.from('penalty_current').select('amount_dong,state,period').eq('kind', 'week'),
      ]);

      if (cancelled) return;

      // Every parallel read is checked, not only the first — a failed penalties/misses/week
      // read used to render silently as an incomplete or wrong ledger rather than a failure.
      const failed =
        error ?? penaltiesError ?? missesError ?? weekSettlementsError ?? weekPenaltiesError;
      if (failed) {
        setView({ kind: 'failed', reason: failed.message });
        return;
      }

      const toPenaltyRecord = (p: { amount_dong: unknown; state: unknown; period: unknown }) => ({
        period: p.period as string,
        amount_dong: p.amount_dong as number,
        state: p.state as 'owed' | 'held' | 'dropped',
      });

      setView({
        kind: 'ready',
        rows: buildLedger(
          settlements ?? [],
          (penalties ?? []).map(toPenaltyRecord),
          (misses ?? [])
            .filter(
              (m) => (m.commitment as unknown as { carries_penalty: boolean })?.carries_penalty,
            )
            .map((m) => ({
              for_day: m.for_day as string,
              commitment_id: m.commitment_id as string,
              commitment_name: (m.commitment as unknown as { name: string }).name,
              filed_by: m.filed_by as 'doer' | 'auto_check',
            })),
          weekSettlements ?? [],
          (weekPenalties ?? []).map(toPenaltyRecord),
        ),
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <section>
      <h1>Ledger</h1>
      <button type="button" onClick={onClose}>
        Back to today
      </button>

      {view.kind === 'loading' && <p>Working…</p>}

      {view.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && view.rows.length === 0 && (
        <p className="row-muted">No day has been judged yet.</p>
      )}

      {view.kind === 'ready' &&
        view.rows.map((row) => (
          <div
            className={row.kind === 'week' ? 'row row-week' : 'row'}
            key={`${row.kind}-${row.day}`}
            role="group"
            aria-label={
              row.kind === 'week'
                ? row.verdict === 'clean'
                  ? `Week of ${row.day}, clean`
                  : `Week of ${row.day}, owed ${formatDong(row.amountDong ?? 0)}`
                : row.verdict === 'clean'
                  ? `${row.day}, clean`
                  : row.verdict === 'expired'
                    ? `${row.day}, expired unanswered, owed ${formatDong(row.amountDong ?? 0)}`
                    : row.state === 'held'
                      ? `${row.day}, ${formatDong(row.amountDong ?? 0)} on hold pending appeal, for ${row.missed.join(' and ')}`
                      : row.state === 'dropped'
                        ? `${row.day}, dropped, for ${row.missed.join(' and ')}`
                        : `${row.day}, owed ${formatDong(row.amountDong ?? 0)}, for ${row.missed.join(' and ')}`
            }
          >
            <div className="row-main">
              <div className="row-name">{row.kind === 'week' ? `Week of ${row.day}` : row.day}</div>
              <div className="row-muted" aria-hidden="true">
                {row.kind === 'week'
                  ? row.verdict === 'clean'
                    ? 'Everything held'
                    : `Fell short${row.amountDong ? ` · ${formatDong(row.amountDong)}` : ''}`
                  : row.verdict === 'expired'
                    ? `Went unanswered${row.amountDong ? ` · ${formatDong(row.amountDong)}` : ''}`
                    : row.verdict === 'clean'
                      ? 'Everything held'
                      : `${row.missed.join(' · ')}${row.amountDong ? ` · ${formatDong(row.amountDong)}` : ''}`}
              </div>

              {/* Contest: only on an eligible owed failed-day row (a machine-filed miss whose
                  Penalty has not already moved to held/dropped/anything else). One control
                  per contestable commitment — a Failed Day can carry more than one. */}
              {row.kind === 'day' &&
                onOpenAppeal &&
                row.appealable.map((miss) => (
                  <button
                    key={miss.commitmentId}
                    type="button"
                    onClick={() =>
                      onOpenAppeal({
                        commitmentId: miss.commitmentId,
                        commitmentName: miss.commitmentName,
                        forDay: row.day,
                        amountDong: row.amountDong ?? 0,
                      })
                    }
                  >
                    Contest {miss.commitmentName}
                  </button>
                ))}
            </div>
            {/* The pill carries the colour. The row never does. */}
            <span className={`pill pill-${ledgerPillFamily(row)}`} aria-hidden="true">
              {ledgerPillLabel(row)}
            </span>
          </div>
        ))}
    </section>
  );
}
