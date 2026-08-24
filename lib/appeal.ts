/**
 * Appeal: the author's claim that a machine-filed miss was wrong (Story 4.4, FR-14/FR-15).
 *
 * The server is the sole judge (AD-1). Every eligibility rule — ownership, that the
 * commitment carries a Penalty, that the day's current settlement outcome is `missed`,
 * that the day's own declaration was machine-filed rather than the author's own honest
 * `slipped`, that the linked Penalty is still `owed` — lives in `appeal_hold_penalty()`'s
 * trigger (`20260824130000_contest_a_miss_the_machine_got_wrong.sql`), not here. This
 * module carries only what the client actually owns: the shape of what it sends
 * (`lib/commitment.ts`'s own style — a plain function mapping a draft to a row, database
 * columns spelled in exactly one place), and the copy.
 */

import { formatDong } from './money';

export interface AppealDraft {
  commitmentId: string;
  /** `YYYY-MM-DD`. The already-settled day being contested, read off a Ledger row — unlike
   *  `declaration`/`focus_session`, an appeal names a day that already happened rather than
   *  deriving one from an instant the client just experienced, so the client sends it
   *  directly and the server checks it against `settlement_commitment` itself. */
  forDay: string;
}

/** The column names `appeal` uses. Kept here so no component spells them. `settlement_id`,
 *  `penalty_id` and `deadline` are never sent — `appeal_hold_penalty()` derives all three
 *  before the row is written (AD-1), and a client that sent them would just have them
 *  overwritten by the same trigger that fills them when they are absent. */
export function toRow(draft: AppealDraft, ownerId: string, idempotencyKey: string) {
  return {
    owner_id: ownerId,
    commitment_id: draft.commitmentId,
    idempotency_key: idempotencyKey,
    for_day: draft.forDay,
  };
}

/**
 * Every string this surface says.
 *
 * Kept here for the reason `lib/focus-session.ts`'s own `FOCUS_COPY` gives: these are copy
 * rules, testable independent of a component, and the source `components/appeal-form.tsx`
 * reads from rather than one it invents inline and this file merely documents afterward.
 */
export const APPEAL_COPY = {
  contest: 'Contest this',
  submitting: 'Submitting…',
  failed: 'Not submitted.',
  serverRefused: 'The server refused this appeal.',

  /** A 23505 on `appeal_one_per_commitment_day` from a *different* idempotency key — a
   *  second appeal attempt, not this attempt's own retry arriving twice. */
  alreadyAppealed: 'This day has already been appealed. Reopen the Ledger to see where it stands.',

  /** The claim itself. Generic and honest rather than UX-DR25's measured-quantity example
   *  (`"Location saw you for 4 minutes. It needed 30."`) — `account_elsewhere`, the only
   *  Auto-check kind that exists, has no observed/required numbers to show, and inventing a
   *  data model for a resolver shape that does not exist yet was scoped out before this
   *  file was written (see the story's Spec Change Log). */
  claim: 'Account elsewhere reported a miss.',

  evidenceHint:
    'Optional, and never required to submit. Camera or library, from the day being ' +
    'appealed — attaching it never blocks or delays the hold above.',
  evidenceUploading: 'Uploading…',
  evidenceSaved: 'Evidence attached.',
  evidenceFailed:
    'The evidence could not be saved. The appeal itself still stands — you can try again.',
} as const;

/**
 * The hold-state sentence, verbatim from EXPERIENCE.md (quoted in the story's own Design
 * Notes) — "the single most trust-critical sentence in the product" — with the real amount
 * and the real deadline filled in rather than left as the template's own bracketed
 * placeholders.
 *
 * `[Referee]` resolves to the plain word "the referee": no account exists yet to name one
 * (Story 4.5 has not shipped, and `public.profile` carries no name column at all), and a
 * placeholder token left in production copy would be a worse failure than a generic noun.
 */
export function holdStateCopy(amountDong: number, deadline: Date): string {
  return (
    `${formatDong(amountDong)} is on hold, not charged. It stays on hold until the referee ` +
    `decides, or until ${formatDeadline(deadline)} closes — and if he doesn't get to it, ` +
    `it's dropped.`
  );
}

/** The deadline, as a date a reader recognises rather than an ISO instant. `deadline` is
 *  always midnight Asia/Ho_Chi_Minh (`appeal_deadline()`'s own shape), so naming only the
 *  date — never a time — never drops information the boundary actually carries. */
export function formatDeadline(deadline: Date): string {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Ho_Chi_Minh',
    month: 'short',
    day: 'numeric',
  }).format(deadline);
}

/**
 * Where one evidence file lands inside the private `appeal-evidence` bucket.
 *
 * Leads with the appeal's own id because that is exactly what the bucket's
 * `storage.objects` policy reads via `storage.foldername(name)` to derive access from
 * `appeal.owner_id` (NFR4) — a path that did not lead with it would be unreadable by that
 * policy regardless of who owns the appeal.
 */
export function evidenceObjectPath(appealId: string, evidenceId: string, filename: string): string {
  // No dot survives, on purpose: allowing `.` and rejecting only `/` would still let
  // `../../etc/passwd` through as `.._.._etc_passwd`, which still reads as a traversal
  // attempt even though `storage.objects` never resolves this as a filesystem path. The
  // extension is not needed for correctness — Supabase Storage keys the object's real
  // content type off the upload's `content-type` header, never off this path.
  const safeName = filename.trim().replace(/[^\w-]/g, '_') || 'evidence';
  return `${appealId}/${evidenceId}-${safeName}`;
}
