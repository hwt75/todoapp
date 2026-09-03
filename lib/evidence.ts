/**
 * Photo evidence, and where it lives.
 *
 * These three rules were written for an appeal (Story 4.4) and were never about appeals. Story
 * 6.3 detached the evidence store from the dispute mechanism that happened to need it first, so
 * they moved out of `lib/appeal.ts` rather than being copied — a second implementation of "is
 * this file dated the day it claims to prove" would drift, and the drift would decide money.
 *
 * The server enforces every one of them again (`evidence_derive_owner()`,
 * `20260828150000_evidence_detaches_from_an_appeal.sql`). These exist so an evidently wrong file
 * never reaches Storage at all, and so the rules are testable without a browser.
 */

import { ZONE } from './declaration';

/**
 * The calendar date (Asia/Ho_Chi_Minh) a file's own `lastModified` timestamp falls on.
 *
 * Not EXIF `DateTimeOriginal` — parsing binary EXIF client-side has no existing dependency in
 * this codebase, and `lastModified` is the only capture-adjacent signal a plain `<input
 * type="file">` exposes without one. This is a real limitation: a library-picked file's
 * `lastModified` reflects the OS's own file metadata, which a sync or export step can touch
 * independently of when the photo was actually taken. Good enough to refuse an evidently old
 * or unrelated file, not a cryptographic proof of capture time.
 */
export function fileCapturedOn(file: File): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: ZONE }).format(new Date(file.lastModified));
}

/** FR-14: evidence must be dated the day it proves. `forDay` is already `YYYY-MM-DD`
 *  (the same shape `fileCapturedOn` produces via the `en-CA` locale), so a plain string
 *  comparison is exact — no date parsing on either side to disagree about. */
export function isEvidenceDated(file: File, forDay: string): boolean {
  return fileCapturedOn(file) === forDay;
}

/**
 * Where one evidence file lands inside the private `appeal-evidence` bucket.
 *
 * Leads with the parent row's own id — an appeal's, a declaration's, or a commitment's — because
 * that is exactly what the bucket's `storage.objects` policies read via
 * `storage.foldername(name)` to derive access from that parent's `owner_id` (NFR4). A path that
 * did not lead with it would be unreadable by those policies regardless of who owns the parent.
 *
 * The bucket is still called `appeal-evidence` and now holds all three kinds. Renaming a bucket
 * means moving every object in it, so the name stayed and this comment carries the mismatch.
 */
export function evidenceObjectPath(parentId: string, evidenceId: string, filename: string): string {
  // No dot survives, on purpose: allowing `.` and rejecting only `/` would still let
  // `../../etc/passwd` through as `.._.._etc_passwd`, which still reads as a traversal
  // attempt even though `storage.objects` never resolves this as a filesystem path. The
  // extension is not needed for correctness — Supabase Storage keys the object's real
  // content type off the upload's `content-type` header, never off this path.
  const safeName = filename.trim().replace(/[^\w-]/g, '_') || 'evidence';
  return `${parentId}/${evidenceId}-${safeName}`;
}

/**
 * What the claim surface says about a photo.
 *
 * Kept here for the reason `lib/appeal.ts`'s `APPEAL_COPY` gives, and kept separate from it: an
 * appeal's evidence copy talks about the day being contested, and a claim is not a contest.
 */
export const EVIDENCE_COPY = {
  label: 'Proof',
  hint: 'A photo taken today. It is private — only you can open it.',
  uploading: 'Sending…',
  saved: 'Proof saved.',
  failed: 'Proof not saved.',

  /** Refused before the file reaches Storage. The server refuses it again on the insert
   *  (AD-1: a client check alone is never authoritative). */
  wrongDay: 'That photo was not taken today, so it cannot prove today.',
} as const;
