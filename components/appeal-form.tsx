'use client';

import { useRef, useState } from 'react';
import { classifyConflict, classifyWriteError } from '@/lib/declaration-submit';
import { APPEAL_COPY, holdStateCopy, toRow, type AppealDraft } from '@/lib/appeal';
import {
  EVIDENCE_BUCKET,
  evidenceObjectPath,
  fileCapturedOn,
  isEvidenceDated,
} from '@/lib/evidence';
import { formatDong } from '@/lib/money';
import { createClient } from '@/lib/supabase/client';

type Submission =
  | { kind: 'idle' }
  | { kind: 'submitting' }
  | { kind: 'held'; appealId: string; deadline: string }
  | { kind: 'failed'; reason: string };

type Evidence =
  { kind: 'idle' } | { kind: 'uploading' } | { kind: 'saved' } | { kind: 'failed'; reason: string };

/**
 * Contest a machine-filed miss (Story 4.4, FR-14/FR-15).
 *
 * **The server is the sole judge.** Every eligibility rule this screen's Contest button can
 * run into — ownership, that the commitment carries a Penalty, that the day's own
 * declaration was machine-filed rather than the author's own honest slip, that its Penalty
 * is still owed — lives entirely in `appeal_hold_penalty()`'s trigger. This component sends
 * one insert and reads back whatever the database decided; it never pre-checks eligibility
 * itself, because a client-side re-derivation of the same rule is exactly the second copy
 * that drifts (AD-1).
 *
 * **No offline queue.** Every other observation in this product (`declaration`,
 * `focus_session`) is queued through `lib/offline-queue.ts` so a tap made without signal is
 * never lost. An appeal is not: it is reached from the Ledger, a screen that already needed
 * a live read to show the row being contested, and the deadline `appeal_hold_penalty()`
 * stamps has to measure from an instant the server actually recorded — a locally-stamped
 * "submitted" that turns out never to have reached the server would start a clock that was
 * never real. A failed submission says so and offers nothing but the same button to try
 * again, reusing the one idempotency key this component ever mints.
 *
 * **The claim is generic, not fabricated.** `account_elsewhere` — the only Auto-check kind
 * that exists — has no observed/required numbers the way a measured check would
 * (UX-DR25's own example), so the copy says only what is true: that Account elsewhere
 * reported a miss.
 */
export function AppealForm({
  ownerId,
  commitmentId,
  commitmentName,
  forDay,
  amountDong,
  onClose,
}: {
  ownerId: string;
  commitmentId: string;
  commitmentName: string;
  forDay: string;
  amountDong: number;
  onClose: () => void;
}) {
  const [submission, setSubmission] = useState<Submission>({ kind: 'idle' });
  const [evidence, setEvidence] = useState<Evidence>({ kind: 'idle' });

  // Minted on the first tap and reused by every retry (AD-4) — never regenerated on a
  // second click, or a submission that actually reached the server the first time would
  // read as a fresh, second appeal attempt and be refused by `appeal_one_per_commitment_day`
  // rather than recognised as its own earlier success.
  const idempotencyKeyRef = useRef<string | null>(null);

  async function submit() {
    setSubmission({ kind: 'submitting' });

    try {
      if (!idempotencyKeyRef.current) {
        idempotencyKeyRef.current = crypto.randomUUID();
      }
      const idempotencyKey = idempotencyKeyRef.current;

      const draft: AppealDraft = { commitmentId, forDay };
      const supabase = createClient();

      const { data, error } = await supabase
        .from('appeal')
        .insert(toRow(draft, ownerId, idempotencyKey))
        .select('id,deadline')
        .single();

      if (!error && data) {
        setSubmission({
          kind: 'held',
          appealId: data.id as string,
          deadline: data.deadline as string,
        });
        return;
      }

      const result = classifyWriteError(error);

      if (result === 'duplicate') {
        // A 23505 alone doesn't say whether the row that won is this attempt's own retry
        // (the network dropped the response, not the request) or a different, earlier
        // appeal for the same day — Postgres's error carries the violated constraint, not
        // the winning row's key. Read back what actually stands and compare, the same way
        // `morning-gate.tsx` tells its own retry apart from a conflicting Auto-check row.
        const { data: existing, error: readError } = await supabase
          .from('appeal')
          .select('id,idempotency_key,deadline')
          .eq('commitment_id', commitmentId)
          .eq('for_day', forDay)
          .maybeSingle();

        if (readError || !existing) {
          setSubmission({ kind: 'failed', reason: APPEAL_COPY.serverRefused });
          return;
        }

        const conflict = classifyConflict(existing.idempotency_key as string, idempotencyKey);

        if (conflict === 'duplicate') {
          setSubmission({
            kind: 'held',
            appealId: existing.id as string,
            deadline: existing.deadline as string,
          });
        } else {
          setSubmission({ kind: 'failed', reason: APPEAL_COPY.alreadyAppealed });
        }
        return;
      }

      // `rejected` carries the trigger's own raised message (e.g. "Only a machine-filed
      // miss can be appealed.") or a constraint's; `unreachable` carries none of the
      // server's own words, so the generic sentence stands in for it.
      setSubmission({ kind: 'failed', reason: error?.message ?? APPEAL_COPY.serverRefused });
    } catch (err) {
      setSubmission({ kind: 'failed', reason: String(err) });
    }
  }

  async function uploadEvidence(file: File) {
    if (submission.kind !== 'held') return;

    // FR-14: refused before any upload starts — an evidently wrong-dated file never reaches
    // Storage at all. The server enforces the same rule again on the `evidence` insert
    // below (AD-1: a client check alone is never authoritative).
    if (!isEvidenceDated(file, forDay)) {
      setEvidence({ kind: 'failed', reason: APPEAL_COPY.evidenceWrongDay });
      return;
    }

    setEvidence({ kind: 'uploading' });

    try {
      const supabase = createClient();
      const path = evidenceObjectPath(submission.appealId, crypto.randomUUID(), file.name);

      const { error: uploadError } = await supabase.storage
        .from(EVIDENCE_BUCKET)
        .upload(path, file, { contentType: file.type || undefined });

      if (uploadError) {
        setEvidence({ kind: 'failed', reason: APPEAL_COPY.evidenceFailed });
        return;
      }

      const { error: insertError } = await supabase.from('evidence').insert({
        appeal_id: submission.appealId,
        storage_path: path,
        captured_on: fileCapturedOn(file),
      });

      if (insertError) {
        setEvidence({ kind: 'failed', reason: APPEAL_COPY.evidenceFailed });
        return;
      }

      setEvidence({ kind: 'saved' });
    } catch {
      setEvidence({ kind: 'failed', reason: APPEAL_COPY.evidenceFailed });
    }
  }

  return (
    <section className="screen">
      <header className="screen-head">
        <h1>{commitmentName}</h1>
        <button type="button" className="quiet back" onClick={onClose}>
          Back to the ledger
        </button>
      </header>

      <div className="card card-pad stack">
        <p>
          {forDay} · {formatDong(amountDong)}
        </p>
        <p>{APPEAL_COPY.claim}</p>

        {(submission.kind === 'idle' || submission.kind === 'submitting') && (
          <div className="actions">
            <button
              type="button"
              className="action"
              disabled={submission.kind === 'submitting'}
              aria-busy={submission.kind === 'submitting'}
              onClick={() => void submit()}
            >
              {submission.kind === 'submitting' ? APPEAL_COPY.submitting : APPEAL_COPY.contest}
            </button>
          </div>
        )}

        {submission.kind === 'failed' && (
          <>
            <p role="status">
              <strong>{APPEAL_COPY.failed}</strong> {submission.reason}
            </p>
            <div className="actions">
              <button type="button" className="action" onClick={() => void submit()}>
                {APPEAL_COPY.contest}
              </button>
            </div>
          </>
        )}

        {submission.kind === 'held' && (
          <>
            {/* The single most trust-critical sentence in the product (EXPERIENCE.md) —
              the amount and the real, server-stamped deadline, never the template's own
              bracketed placeholders. */}
            <p role="status">{holdStateCopy(amountDong, new Date(submission.deadline))}</p>

            <label htmlFor="appeal-evidence">Evidence</label>
            <input
              id="appeal-evidence"
              type="file"
              accept="image/*"
              disabled={evidence.kind === 'uploading'}
              onChange={(event) => {
                const file = event.target.files?.[0];
                if (file) void uploadEvidence(file);
              }}
            />
            <p className="row-muted">{APPEAL_COPY.evidenceHint}</p>

            {evidence.kind === 'uploading' && <p role="status">{APPEAL_COPY.evidenceUploading}</p>}
            {evidence.kind === 'saved' && <p role="status">{APPEAL_COPY.evidenceSaved}</p>}
            {evidence.kind === 'failed' && (
              <p role="status">
                <strong>{APPEAL_COPY.failed}</strong> {evidence.reason}
              </p>
            )}
          </>
        )}
      </div>
    </section>
  );
}
