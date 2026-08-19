'use client';

import { useEffect, useState } from 'react';
import {
  OUTCOME_PRESENTATION,
  chainAgainstRecord,
  type Chain,
  type CommitmentOutcome,
} from '@/lib/chain';
import { createClient } from '@/lib/supabase/client';

interface Day {
  day: string;
  outcome: CommitmentOutcome;
}

type View =
  | { kind: 'loading' }
  | { kind: 'ready'; chain: Chain; days: Day[] }
  | { kind: 'failed'; reason: string };

/**
 * One commitment's history.
 *
 * The current chain and the longest one are drawn together and cannot be separated, because
 * the number that matters on a bad day is the pair. A reset read against zero says *you have
 * nothing*; read against a record it says *you have done better than this, and you did it
 * yourself*. That difference is the reason this surface exists at all — it is reached by
 * tapping a row, and the row most likely to be tapped is the one that just broke.
 *
 * Nothing here is computed. The chain comes from `chain_current` and the days come from the
 * outcomes settlement froze; this screen decides how they read and nothing else.
 */
export function ChainsDetail({
  commitmentId,
  name,
  onClose,
}: {
  commitmentId: string;
  name: string;
  onClose: () => void;
}) {
  const [view, setView] = useState<View>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const supabase = createClient();

      const [{ data: chain, error }, { data: days }] = await Promise.all([
        supabase
          .from('chain_current')
          .select('current_days,longest_days')
          .eq('commitment_id', commitmentId)
          .maybeSingle(),
        supabase
          .from('settlement_commitment')
          .select('outcome,settlement:settlement_id(period)')
          .eq('commitment_id', commitmentId),
      ]);

      if (cancelled) return;
      if (error) {
        setView({ kind: 'failed', reason: error.message });
        return;
      }

      setView({
        kind: 'ready',
        // No history yet is a real state and reads as zero against zero, not as an error.
        chain: {
          currentDays: (chain?.current_days as number | undefined) ?? 0,
          longestDays: (chain?.longest_days as number | undefined) ?? 0,
        },
        days: (days ?? [])
          .map((d) => ({
            day: (d.settlement as unknown as { period: string }).period,
            outcome: d.outcome as CommitmentOutcome,
          }))
          .sort((a, b) => b.day.localeCompare(a.day)),
      });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [commitmentId]);

  return (
    <section>
      <h1>{name}</h1>
      <button type="button" onClick={onClose}>
        Back to today
      </button>

      {view.kind === 'loading' && <p>Working…</p>}

      {view.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {view.reason}
        </p>
      )}

      {view.kind === 'ready' && (
        <>
          {/* Current and longest, in one line, so neither can be shown without the other. */}
          <p
            className="chain-pair"
            aria-label={
              view.chain.currentDays === 0
                ? `Chain broken. Longest ${view.chain.longestDays} days.`
                : `Holding ${view.chain.currentDays} days. Longest ${view.chain.longestDays}.`
            }
          >
            {chainAgainstRecord(view.chain)}
          </p>

          {view.days.length === 0 && (
            <p className="row-muted">No day has been judged for this yet.</p>
          )}

          {view.days.map((d) => (
            <div
              className="row"
              key={d.day}
              role="group"
              aria-label={`${d.day}, ${OUTCOME_PRESENTATION[d.outcome].spoken}`}
            >
              <div className="row-main">
                <div className="row-name">{d.day}</div>
              </div>
              {/* Colour lives in the pill and nowhere else, the same rule the Ledger keeps —
                  this list is structurally a history of failures and must not become a wall
                  of red on the day it is most likely to be opened. */}
              <span
                className={`pill pill-${OUTCOME_PRESENTATION[d.outcome].family}`}
                aria-hidden="true"
              >
                {OUTCOME_PRESENTATION[d.outcome].label}
              </span>
            </div>
          ))}
        </>
      )}
    </section>
  );
}
