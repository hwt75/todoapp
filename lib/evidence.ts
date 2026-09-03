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
 *
 * Story 6.9 adds the read side — `readKeptPhotos()` — for the same reason the write side lives
 * here rather than in a component: three surfaces ask for the same photo (Today, a commitment's
 * history, a Focus Session), and three signing loops would be three places that could start
 * disagreeing about expiry, about what a failure means, and about who may see a photo. One
 * helper, one failure vocabulary, one alt-text rule.
 */

import { createClient } from '@/lib/supabase/client';
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
 * The private bucket every kind of evidence lands in.
 *
 * Named once so the writer and the reader cannot drift onto two different buckets. Still called
 * `appeal-evidence` for the reason `evidenceObjectPath` above gives.
 */
export const EVIDENCE_BUCKET = 'appeal-evidence';

/**
 * How long a signed URL stays good for.
 *
 * One hour, the same figure `components/referee-appeal-detail.tsx` signs with and for the same
 * reason: long enough that an image never simply fails partway through looking at it. Nothing on
 * these surfaces is hurried by a clock.
 */
export const EVIDENCE_URL_TTL_SECONDS = 3600;

/**
 * How many days one `for_day` filter may name.
 *
 * PostgREST puts an `.in()` list in the query string, so an unbounded one is a URL whose length
 * grows with the length of a commitment's history — a year-old daily commitment is ~365 dates,
 * about 4KB of `?for_day=in.(…)` before anything else on the query. The read is chunked at this
 * width instead, which is the same answer with a bounded request.
 */
const DAYS_PER_QUERY = 100;

/** One photo the author filed, resolved to something his own browser can load. The bucket is
 *  private, so `evidence` carries a storage path and never a URL. */
export interface KeptPhoto {
  id: string;
  /** Which commitment's record this is — one read can cover several (Today's flagged rows). */
  commitmentId: string;
  /** The `evidence.for_day` this row was filed under — the day it is a record of. */
  day: string;
  url: string;
  /** Written here, never by a component: identical alt text on several images reads as one
   *  image repeated. */
  alt: string;
}

export interface KeptPhotoRead {
  photos: KeptPhoto[];
  /**
   * How many rows were found but could not be signed.
   *
   * Reported as a count rather than dropped, for the reason `RefereeEvidenceItem`'s own loop
   * already gives: a silently shorter list is indistinguishable from nothing having been filed,
   * which on this surface would tell the author he never kept a record he did keep.
   */
  unsigned: number;
  /** The row read itself failed. Null on success, including the honest success of no rows. */
  failed: string | null;
}

/** Nothing was asked for, or nothing came back. A shape rather than three literals, so an
 *  empty answer is the same object everywhere. */
const NOTHING_KEPT: KeptPhotoRead = { photos: [], unsigned: 0, failed: null };

/** What tells the reader its caller has gone. See `readKeptPhotos`'s own note on it. */
export interface KeptPhotoOptions {
  cancelled?: () => boolean;
}

function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let at = 0; at < items.length; at += size) chunks.push(items.slice(at, at + size));
  return chunks;
}

/**
 * Every photo these commitments carry on the days asked for, signed and ready to render.
 *
 * The days are passed in rather than derived here: each surface already owns the day it is
 * drawn against — Today's `localDay`, a Focus Session's own `day`, the days a commitment's
 * history actually lists — and a second clock in here could disagree with all three.
 *
 * **A list of commitments rather than one**, because Today can have several flagged rows on
 * screen at once and one `.in()` answers for all of them. One read, one signing call, one
 * failure count — the whole reason this helper exists rather than a loop per surface.
 *
 * **`cancelled` is checked between round trips**, the way
 * `components/referee-appeal-detail.tsx`'s own loop checks its effect's flag: a screen the
 * author has already left must not go on issuing requests on his connection.
 *
 * Reads only. Nothing here creates a route to attach a photo to a past day, and nothing here
 * decides anything: access is `evidence: read own` and the owner branch of the bucket's own
 * policies, so another account's rows and objects are simply never returned (AD-7).
 */
export async function readKeptPhotos(
  commitmentIds: readonly string[],
  days: readonly string[],
  options: KeptPhotoOptions = {},
): Promise<KeptPhotoRead> {
  const cancelled = options.cancelled ?? (() => false);
  // Deduplicated before anything is sent. A caller's day list comes from whatever its own
  // surface lists, and asking twice for one day would both lengthen the request and number
  // that day's photos against a doubled total.
  const ids = [...new Set(commitmentIds)];
  const wanted = [...new Set(days)];

  // Nothing to ask about is not a failure and not a read: a commitment whose history is still
  // empty has nothing to look for, and asking anyway would be one round trip per empty screen.
  if (ids.length === 0 || wanted.length === 0) return NOTHING_KEPT;

  const supabase = createClient();

  const pages = await Promise.all(
    chunk(wanted, DAYS_PER_QUERY).map((someDays) =>
      supabase
        .from('evidence')
        .select('id,commitment_id,for_day,storage_path')
        .in('commitment_id', ids)
        .in('for_day', someDays),
    ),
  );

  if (cancelled()) return NOTHING_KEPT;

  // One failed page is a failed read. A partial history presented as the whole of it is the
  // one answer this surface must never give.
  const readError = pages.find((page) => page.error)?.error;
  if (readError) return { photos: [], unsigned: 0, failed: readError.message };

  const rows = pages
    .flatMap(
      (page) =>
        (page.data ?? []) as {
          id: string;
          commitment_id: string;
          for_day: string;
          storage_path: string;
        }[],
    )
    .map((row) => ({
      id: row.id,
      commitmentId: row.commitment_id,
      day: row.for_day,
      path: row.storage_path,
    }))
    // Sorted so two renders of the same day never number the same photo differently.
    .sort((a, b) => a.day.localeCompare(b.day) || a.id.localeCompare(b.id));

  if (rows.length === 0) return NOTHING_KEPT;

  // One call for every path, not one per photo. `createSignedUrls` reports its failures per
  // item — a `path` with no `signedUrl` — which is exactly the per-item failure the sequential
  // loop was written for, without the round trip per photo that made a ten-photo history ten
  // requests deep.
  const { data: signed, error: signError } = await supabase.storage
    .from(EVIDENCE_BUCKET)
    .createSignedUrls(
      rows.map((row) => row.path),
      EVIDENCE_URL_TTL_SECONDS,
    );

  if (cancelled()) return NOTHING_KEPT;

  const urls = new Map<string, string>();
  for (const item of signed ?? []) {
    if (item.path && item.signedUrl && !item.error) urls.set(item.path, item.signedUrl);
  }

  // A whole call that failed is every photo unsigned, never a shorter list and never a screen
  // that says nothing was ever kept.
  const grouped = new Map<
    string,
    { id: string; commitmentId: string; day: string; url: string }[]
  >();
  let unsigned = 0;

  for (const row of rows) {
    const url = signError ? undefined : urls.get(row.path);
    if (!url) {
      unsigned++;
      continue;
    }

    // Grouped by commitment *and* day, because that pair is what a reader is looking at: one
    // row on Today, one day's row in a history.
    const key = `${row.commitmentId}\u0000${row.day}`;
    const group = grouped.get(key) ?? [];
    group.push({ id: row.id, commitmentId: row.commitmentId, day: row.day, url });
    grouped.set(key, group);
  }

  // Alt text is written after signing, not before: "photo 1 of 2" beside a single image is a
  // sentence that contradicts the screen, and the total a reader is told must be the total he
  // can actually see.
  const photos = [...grouped.values()].flatMap((items) =>
    items.map((item, index) => ({
      id: item.id,
      commitmentId: item.commitmentId,
      day: item.day,
      url: item.url,
      alt: EVIDENCE_COPY.photoAlt(index + 1, items.length),
    })),
  );

  return { photos, unsigned, failed: null };
}

/** One commitment's photos for one day — the whole of what a surface has to do to place
 *  them. */
export function photosOn(read: KeptPhotoRead, commitmentId: string, day: string): KeptPhoto[] {
  return read.photos.filter((photo) => photo.commitmentId === commitmentId && photo.day === day);
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

  /**
   * Story 6.9, the read side. One alt-text rule for all three surfaces.
   *
   * Names no day, deliberately. The day is already on screen every time — it is the only day
   * Today draws, and a history states it in its own row's label — and an ISO date inside alt
   * text is read out as a string of digits by the one reader who depends on alt text at all.
   * Nothing about the day either: a photo is a record, and the pill beside it already says what
   * the day was. 1-indexed, the way a count is said out loud.
   */
  photoAlt: (position: number, total: number): string => `Photo ${position} of ${total} you kept.`,

  /** Some photos are on screen and some are not — a count, never a shorter list. Covers a URL
   *  that could not be signed and one that would not load, because to the author looking at
   *  the screen those are one fact. */
  photosFailed: (count: number): string =>
    `${count} photo${count === 1 ? '' : 's'} could not be loaded.`,

  /** The read itself failed, so nothing at all can be shown. Distinct from the count above,
   *  which reports a photo that is known to exist, and shown with the server's own reason —
   *  an RLS refusal and a dead connection are different problems. */
  photosUnreadable: 'Photos could not be loaded.',
} as const;
