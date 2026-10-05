/**
 * The one path a photograph takes to the server (Epic 6 retrospective item 45, finding G3).
 *
 * `components/today.tsx` and `components/appeal-form.tsx` each carried the same seven steps — the
 * date check, the compression, the object path, the upload, the row insert, and what each failure
 * is called — and the copies had already diverged: the item-39 fix made Today's insert run even
 * after the screen unmounted and left the appeal form's copy as it was. `lib/evidence.ts`
 * centralised only the read side. This is the write side, moved here whole, the way
 * `lib/declaration-write.ts` took the declaration path out of the morning gate.
 *
 * It owns the write and nothing about a screen: no state, no copy. Each caller maps the outcome to
 * its own sentences, because Today names the server's refusal and the appeal form deliberately
 * does not.
 */

import { createClient } from '@/lib/supabase/client';
import {
  EVIDENCE_BUCKET,
  compressEvidencePhoto,
  evidenceObjectPath,
  fileCapturedOn,
  isEvidenceDated,
} from '@/lib/evidence';

/**
 * What a photograph hangs off. Exactly one, the shape `evidence_exactly_one_parent` enforces, and
 * `for_day` only ever beside a commitment (`evidence_for_day_belongs_to_a_commitment`).
 */
export type EvidenceParentRef =
  | { kind: 'declaration'; id: string }
  | { kind: 'commitment'; id: string }
  | { kind: 'appeal'; id: string };

export type EvidenceWriteOutcome =
  /** Refused before anything left the device: the file was not taken on the day it proves. */
  | { kind: 'wrong-day' }
  /** Nothing reached Storage. */
  | { kind: 'upload-failed' }
  /** The object is in Storage and the row was refused, with the server's own words. */
  | { kind: 'refused'; reason: string }
  /** Something threw on the way — a network failure, a compression crash. */
  | { kind: 'error'; reason: string }
  | { kind: 'saved' };

/**
 * Write one photograph for `day` against `parent`.
 *
 * `day` is the caller's own day, never a fresh clock read here: Today draws everything against
 * `localDay`, and a second clock would let a file pass the check on one day and be filed under
 * another — the object written to Storage and only then refused by the trigger, which is the one
 * outcome the early check exists to prevent.
 *
 * `onStart` runs once the date check has passed and before anything leaves the device, so a caller
 * can show "Sending…" without first flashing it for a file that is refused on the spot.
 *
 * **The insert is never conditional on the caller still being there.** The object is already in
 * Storage by the time it runs; stopping because a screen unmounted would leave a photo that exists
 * and proves nothing — no `evidence` row, so the claim or appeal has no proof, and the object is an
 * orphan until the sweeper finds it. Callers guard their own state updates, not this.
 */
export async function writeEvidence(
  file: File,
  parent: EvidenceParentRef,
  day: string,
  onStart?: () => void,
): Promise<EvidenceWriteOutcome> {
  // Refused before any upload starts, so an evidently wrong-dated file never reaches Storage.
  // The server refuses it again on the insert (AD-1: a client check alone is never authoritative).
  if (!isEvidenceDated(file, day)) return { kind: 'wrong-day' };

  onStart?.();

  try {
    const supabase = createClient();
    // Shrunk before it goes up, never after: the referee reads this in a box under half his
    // screen, and the full-size original was the whole of why that screen was slow. Declines and
    // hands back the original on any format it cannot decode, so a photo is never lost to this —
    // and carries `lastModified` across, which is what `captured_on` below reads.
    const stored = await compressEvidencePhoto(file);

    // Leads with the parent's own id whichever parent it is — that is what the bucket's policies
    // read via `storage.foldername(name)` to derive access (NFR4).
    const path = evidenceObjectPath(parent.id, crypto.randomUUID(), stored.name);

    const { error: uploadError } = await supabase.storage
      .from(EVIDENCE_BUCKET)
      .upload(path, stored, { contentType: stored.type || undefined });

    if (uploadError) return { kind: 'upload-failed' };

    const { error: insertError } = await supabase.from('evidence').insert({
      ...(parent.kind === 'declaration'
        ? { declaration_id: parent.id }
        : parent.kind === 'appeal'
          ? { appeal_id: parent.id }
          : { commitment_id: parent.id, for_day: day }),
      storage_path: path,
      // The original's date, not the compressed copy's: the two share `lastModified`, and this
      // is the file the author chose.
      captured_on: fileCapturedOn(file),
    });

    return insertError ? { kind: 'refused', reason: insertError.message } : { kind: 'saved' };
  } catch (error) {
    return { kind: 'error', reason: String(error) };
  }
}
