'use client';

import { useEffect, useState } from 'react';
import {
  OUTCOME_PRESENTATION,
  chainAgainstRecord,
  type Chain,
  type CommitmentOutcome,
} from '@/lib/chain';
import { createClient } from '@/lib/supabase/client';
import { readKeptPhotos, type KeptPhotoRead } from '@/lib/evidence';
import { KeptPhotoNote, KeptPhotos, useKeptPhotos } from '@/components/kept-photos';

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
 * Nothing here is computed. The chain comes from `chain_current` and the days come from
 * `settlement_commitment_current` — the same frozen outcomes, through the same supersession
 * join the chain itself uses, so the number and the calendar cannot disagree about a day
 * (AD-9). This screen decides how they read and nothing else.
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

      const [{ data: chain, error }, { data: days, error: daysError }] = await Promise.all([
        supabase
          .from('chain_current')
          .select('current_days,longest_days')
          .eq('commitment_id', commitmentId)
          .maybeSingle(),
        supabase
          .from('settlement_commitment_current')
          .select('outcome,period')
          .eq('commitment_id', commitmentId),
      ]);

      if (cancelled) return;

      // Both parallel reads are checked, not only the first — a failed calendar read used to
      // render silently as an empty history rather than surfacing the failure.
      const failed = error ?? daysError;
      if (failed) {
        setView({ kind: 'failed', reason: failed.message });
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
            day: d.period as string,
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

  /**
   * The photos, in their own pass (Story 6.9).
   *
   * After the history rather than before it: the chain and the calendar are what this screen is
   * for, and they must not wait on a signing round trip to appear. A history that cannot show
   * its photos is still the history — the failure path already said so, and now the slow path
   * says it too.
   *
   * The days come from the calendar above because a photo is only ever drawn against a day
   * already on screen; this creates no route to attach one to a past day, and a day with none
   * renders exactly as it did before. Every `period` here is a *day*: `settle_week` deliberately
   * writes no `settlement_commitment` row (`20260820150000_the_week_closes_and_settles.sql:20`)
   * and never writes an `expired` verdict for `supersede_expiries()` to correct, so no
   * week-start period can reach this list and no photo can be drawn against one.
   */
  const [photos, setPhotos] = useState<{ of: string; read: KeptPhotoRead } | null>(null);
  const dayKey = view.kind === 'ready' ? view.days.map((d) => d.day).join(',') : '';
  // What an answer would have to be an answer *to*. Carried with the answer rather than cleared
  // by a second write, so there is no render at all in which one commitment's photos — or one
  // day's failure count — sits over another's.
  const askedFor = `${commitmentId}\n${dayKey}`;

  useEffect(() => {
    let cancelled = false;
    const days = dayKey === '' ? [] : dayKey.split(',');
    if (days.length === 0) return;

    async function read() {
      const answer = await readKeptPhotos([commitmentId], days, { cancelled: () => cancelled });
      if (cancelled) return;
      setPhotos({ of: `${commitmentId}\n${dayKey}`, read: answer });
    }

    void read();
    return () => {
      cancelled = true;
    };
  }, [commitmentId, dayKey]);

  const keptPhotos = useKeptPhotos(photos?.of === askedFor ? photos.read : null);

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>{name}</h1>
        <button type="button" className="quiet back" onClick={onClose}>
          Back to today
        </button>
      </header>

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

          {view.days.length > 0 && (
            <div className="card">
              {view.days.map((d) => (
                <div
                  className="row"
                  key={d.day}
                  role="group"
                  aria-label={`${d.day}, ${OUTCOME_PRESENTATION[d.outcome].spoken}`}
                >
                  <div className="row-main">
                    <div className="row-name">{d.day}</div>
                    {/* Story 6.9 — the photo he kept that day, where the day itself is. A day
                        with none renders exactly as it always has: no placeholder, no empty
                        frame, nothing said about a photo that was never owed. */}
                    <KeptPhotos
                      photos={keptPhotos.photosOn(commitmentId, d.day)}
                      view={keptPhotos}
                    />
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
            </div>
          )}

          {/* Counted, never dropped. A photo that failed to sign or to load is one he did keep,
              and a list that simply came back shorter would tell him he never kept it. */}
          <KeptPhotoNote view={keptPhotos} />
        </>
      )}
    </section>
  );
}
