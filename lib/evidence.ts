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
 * The longest edge a stored photograph keeps, in pixels.
 *
 * The referee reads these at `max-height: 40vh` (`.kept-photo`) — about 325 CSS pixels on a
 * phone, so roughly 1000 device pixels at 3x. 1600 leaves room to pinch into a corner of the
 * frame and still be looking at real detail, and is still a quarter of the 4032 a phone camera
 * hands over.
 */
export const EVIDENCE_MAX_EDGE = 1600;

/** JPEG quality for a re-encoded photograph. High enough that a compression artefact is not
 *  mistaken for what the photo shows, low enough to be worth doing. */
export const EVIDENCE_JPEG_QUALITY = 0.8;

/** Below this, re-encoding is not worth the risk of making the file bigger or the wait on a
 *  slow phone — a photo this small already loads in about a second on a weak connection. */
export const EVIDENCE_COMPRESS_ABOVE_BYTES = 400 * 1024;

/**
 * The photograph as it should be stored: the same picture, at a size the referee can actually
 * receive.
 *
 * Nothing shrank these before. A phone camera hands over 2-2.5MB (measured on the live bucket,
 * 2026-09-11) and every byte crossed the wire to Sydney so the referee could paint it into a
 * box under 40% of his screen height. That is the whole of why his screen was slow.
 *
 * **It never throws and never returns nothing.** Every failure path returns the original file:
 * a format the browser cannot decode (Chrome on Android still cannot read HEIC), a canvas that
 * refuses, a re-encode that came out no smaller. Losing the author's proof to save bandwidth
 * would be a far worse bug than the one this fixes, so the compression is an optimisation that
 * is allowed to decline.
 *
 * **`lastModified` is carried over deliberately.** `fileCapturedOn` reads it — not EXIF, which
 * a canvas re-encode strips — and `captured_on` is derived from it on both write paths, then
 * checked again by `evidence_derive_owner()`. A `new File(...)` defaults that field to *now*,
 * which would date every photograph the moment it was uploaded and make a same-day claim on a
 * day's last minutes refuse itself. `lib/evidence.test.ts` holds this.
 */
export async function compressEvidencePhoto(file: File): Promise<File> {
  if (file.size <= EVIDENCE_COMPRESS_ABOVE_BYTES) return file;
  if (typeof createImageBitmap !== 'function' || typeof document === 'undefined') return file;

  let bitmap: ImageBitmap | undefined;
  try {
    // `from-image` applies the EXIF orientation the tag would have carried. Without it a photo
    // taken in portrait is stored on its side, because the re-encode drops the tag that told
    // the browser to rotate it.
    bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });

    const scale = Math.min(1, EVIDENCE_MAX_EDGE / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);

    const context = canvas.getContext('2d');
    if (!context) return file;
    context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);

    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/jpeg', EVIDENCE_JPEG_QUALITY),
    );

    // A photo already smaller than what we would write — a tight HEIC, or one that was never
    // large in the first place — is kept as it is.
    if (!blob || blob.size >= file.size) return file;

    return new File([blob], file.name, {
      type: 'image/jpeg',
      lastModified: file.lastModified,
    });
  } catch {
    return file;
  } finally {
    bitmap?.close();
  }
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
 * How long a photograph's bytes are kept.
 *
 * Stated here so the copy the author reads and the sweeper's own default cannot drift into saying
 * two different numbers. The database owns the real decision
 * (`expired_evidence_objects(p_age)`); this is what the product says about it.
 *
 * Every kind expires — an appeal's, a claim's, and the commitment-day records Story 6.8 exists to
 * let him keep. That last one is a deliberate cost the maintainer accepted, not an oversight.
 */
export const EVIDENCE_RETENTION_DAYS = 30;

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
  /**
   * How many rows were found whose bytes have been swept after
   * `EVIDENCE_RETENTION_DAYS`.
   *
   * Counted separately from `unsigned` because they are different facts to the person reading
   * the screen: one is "something went wrong and it may work later", the other is "it is gone
   * and it is not coming back". Collapsing them would tell him to retry a photo that no longer
   * exists.
   */
  cleared: number;
  /** The row read itself failed. Null on success, including the honest success of no rows. */
  failed: string | null;
}

/** Nothing was asked for, or nothing came back. A shape rather than three literals, so an
 *  empty answer is the same object everywhere. */
const NOTHING_KEPT: KeptPhotoRead = { photos: [], unsigned: 0, cleared: 0, failed: null };

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
        .select('id,commitment_id,for_day,storage_path,swept_at')
        .in('commitment_id', ids)
        .in('for_day', someDays),
    ),
  );

  if (cancelled()) return NOTHING_KEPT;

  // One failed page is a failed read. A partial history presented as the whole of it is the
  // one answer this surface must never give.
  const readError = pages.find((page) => page.error)?.error;
  if (readError) return { photos: [], unsigned: 0, cleared: 0, failed: readError.message };

  const allRows = pages.flatMap(
    (page) =>
      (page.data ?? []) as {
        id: string;
        commitment_id: string;
        for_day: string;
        storage_path: string;
        swept_at: string | null;
      }[],
  );

  // A swept row is a photo whose bytes the retention sweep removed. Filtered out here rather than
  // in the query, because the count is worth saying: a day that shows nothing where a photo used
  // to be should say so, not look like a day he never photographed. The row itself stays -- it is
  // what `commitments_owing()` reads to decide the day held.
  // `!= null`, not `!== null`: a row that arrives without the column at all is treated as *not*
  // swept. That is the safe direction — the photo is shown and, if its bytes really are gone,
  // counted as unloadable — where the strict form would silently report every photo as cleared.
  const cleared = allRows.filter((row) => row.swept_at != null).length;

  const rows = allRows
    .filter((row) => row.swept_at == null)
    .map((row) => ({
      id: row.id,
      commitmentId: row.commitment_id,
      day: row.for_day,
      path: row.storage_path,
    }))
    // Sorted so two renders of the same day never number the same photo differently.
    .sort((a, b) => a.day.localeCompare(b.day) || a.id.localeCompare(b.id));

  // Nothing left to sign. Not `NOTHING_KEPT`: a day whose every photo has been swept is not the
  // same answer as a day that never had one, and the count is the only thing that tells them
  // apart on screen.
  if (rows.length === 0) return { photos: [], unsigned: 0, cleared, failed: null };

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

  return { photos, unsigned, cleared, failed: null };
}

/** One commitment's photos for one day — the whole of what a surface has to do to place
 *  them. */
export function photosOn(read: KeptPhotoRead, commitmentId: string, day: string): KeptPhoto[] {
  return read.photos.filter((photo) => photo.commitmentId === commitmentId && photo.day === day);
}

/**
 * The one shared empty answer, and the only `Map` in this module that outlives a single call.
 *
 * `ReadonlyMap` is a compile-time claim and nothing more — it is erased at run time, so one
 * `set()` on this instance, from anywhere, would teach every surface in the app the same wrong
 * answer with the type never saying a word. The three mutators are replaced so the claim is true
 * where it matters. Every non-empty answer is a fresh map built inside `readRefereeReach`, so
 * this is the only instance that needs it.
 */
const EMPTY_REACH = new Map<string, boolean>();

for (const mutator of ['set', 'delete', 'clear'] as const) {
  Object.defineProperty(EMPTY_REACH, mutator, {
    value: () => {
      throw new Error('NO_REFEREE_REACH is shared and immutable. Build your own Map.');
    },
  });
}

/**
 * Nothing known yet about who can open anything.
 *
 * A shared instance rather than a fresh object per call, so an effect comparing the answer it
 * already holds against this one can short-circuit rather than re-render — which is what
 * `components/today.tsx` does when the set of rows empties.
 */
export const NO_REFEREE_REACH: RefereeReach = Object.freeze({
  reach: EMPTY_REACH as ReadonlyMap<string, boolean>,
  failed: null,
});

/**
 * What `readRefereeReach` answers.
 *
 * Two fields rather than one map, for the reason `KeptPhotoRead.failed` above gives: a read that
 * came back empty and a read that never came back are different facts, and only the caller can
 * decide what to do about the second. It matters more than usual here — if the `authenticated`
 * EXECUTE grant on `requires_referee_approval_as_of()` is ever lost, every answer goes missing at
 * once and the only symptom on screen is a helper sentence that quietly stopped appearing.
 * `supabase/tests/8-3-the-photograph-reaches-the-referee.sql` step 0 catches that server-side;
 * this is what lets a client say it rather than go silent.
 */
export interface RefereeReach {
  /**
   * Per commitment id, whether the referee can open the photograph kept against it on the day
   * asked about. **A commitment absent from this map is a third answer, not a `false`.** It is
   * one this read could not answer for: the call failed, or the reader returned NULL for a
   * commitment with no log history at all. A caller must not collapse that into `false` —
   * `false` is the sentence claiming privacy, and claiming a privacy on an answer that never
   * arrived is the one direction that is never safe.
   */
  reach: ReadonlyMap<string, boolean>;
  /** The read itself failed, and this is what it said. Null on success, including the honest
   *  success of nothing having been asked. */
  failed: string | null;
}

/** How many as-of reads go out at once. See `readRefereeReach`'s own note on why there is a
 *  bound at all. */
const REACH_PER_BATCH = 10;

/**
 * Whether the referee can open the photograph kept against each of these commitments **on this
 * day**.
 *
 * Story 8.3. The author's photo control tells him who can open what he is about to take, and
 * after this story that answer is the flag as of the day the photograph belongs to — the same
 * reading `photograph_reaches_the_referee()` makes inside both widened referee policies.
 *
 * **Not the live `commitment.requires_referee_approval` column, and the distinction is the whole
 * point.** `requires_referee_approval_as_of()` returns the value in force at `day_begins_at(day)`
 * (`20260911090000:199-209`), because the flag decides money and a flag moved at 10:00 must not
 * rewrite what the morning meant. The live column and that value differ for the rest of any day
 * the author moves the flag — and in the direction that matters: switched off at 10:00, the
 * referee still reaches today's photograph while the column says he does not. Saying "Only you
 * can open it" then is Epic 6 retrospective A2, the defect this whole story exists to answer.
 * hwt75 granted `authenticated` EXECUTE on that reader on 2026-09-14 so this read could exist.
 *
 * **One call per commitment, in bounded batches.** There is no `.in()` for a function: PostgREST
 * exposes a computed column only for a function taking the table's own row type, and this one
 * takes a uuid and a date. The list is short — Today's untimed, photo-keeping rows, or the single
 * commitment a setup form is editing — but "short" is an assumption about the author's data, not
 * a guarantee, so the calls go out `REACH_PER_BATCH` at a time rather than as one unbounded
 * fan-out. If the list ever stops being short, the fix is a `security_invoker` view, not a second
 * reading of the flag.
 *
 * **No call is allowed to reject.** `Promise.all` fails a whole batch on the first rejection, and
 * a fetch can throw outright — a dropped connection, an aborted navigation — rather than
 * resolving with an `error` field. Each call catches its own, so one commitment that could not be
 * answered for leaves the others answered rather than turning the whole screen silent.
 */
export async function readRefereeReach(
  commitmentIds: readonly string[],
  day: string,
  options: KeptPhotoOptions = {},
): Promise<RefereeReach> {
  const cancelled = options.cancelled ?? (() => false);
  const ids = [...new Set(commitmentIds)];

  if (ids.length === 0) return NO_REFEREE_REACH;

  const supabase = createClient();
  const reach = new Map<string, boolean>();
  let failed: string | null = null;

  for (const batch of chunk(ids, REACH_PER_BATCH)) {
    if (cancelled()) return NO_REFEREE_REACH;

    const answers = await Promise.all(
      batch.map(async (id) => {
        try {
          const { data, error } = await supabase.rpc('requires_referee_approval_as_of', {
            p_commitment_id: id,
            p_day: day,
          });
          return { id, value: error ? null : data, failed: error ? error.message : null };
        } catch (thrown) {
          // A rejected fetch, which never reaches the `error` field at all. Caught per call so
          // one of them cannot take the rest of the batch down with it.
          return { id, value: null, failed: thrown instanceof Error ? thrown.message : 'unknown' };
        }
      }),
    );

    for (const answer of answers) {
      // `=== true` / `=== false` rather than a coercion, and anything else left out of the map
      // entirely. The reader answers NULL for a commitment with no log history, which the Story
      // 8.1 backfill makes unreachable but which a truncated or errored response reproduces — and
      // every server-side reader of this flag compares with `is true` for exactly that reason. A
      // NULL coerced to `false` here would be the copy failing open into the privacy claim.
      if (answer.value === true) reach.set(answer.id, true);
      else if (answer.value === false) reach.set(answer.id, false);
      // The first failure is the one reported. They are overwhelmingly one cause — a lost grant,
      // a dropped connection — and a caller shown the fifth of five identical messages has been
      // told nothing the first did not say.
      failed ??= answer.failed;
    }
  }

  if (cancelled()) return NO_REFEREE_REACH;

  return { reach, failed };
}

/**
 * What the claim surface says about a photo.
 *
 * Kept here for the reason `lib/appeal.ts`'s `APPEAL_COPY` gives, and kept separate from it: an
 * appeal's evidence copy talks about the day being contested, and a claim is not a contest.
 */
export const EVIDENCE_COPY = {
  label: 'Proof',
  /**
   * Who can open this photo — a function of whether the referee can, because there is no
   * longer one answer.
   *
   * Epic 6 retrospective, A2 (HIGH) — this used to read "It is private — only you can open
   * it", and it was false. `evidence: referee reads his own doer's`
   * (`20260907160000:141`) grants the referee every evidence row of his doer's whose
   * `commitment_id is null`, which is exactly a claim's proof: it is parented to the
   * declaration. The retrospective's disposition was that one of the two had to change, the
   * copy or the policy. The policy is what makes him able to rule at all, so the copy is
   * what moved.
   *
   * It names him rather than saying "not private", because the difference the author cares
   * about is *who* — a referee he chose is not the same as an audience.
   *
   * **Story 8.3 made it a branch, and found the old comment's last sentence false.** That
   * sentence claimed this "appears only under a claim's `Proof` control", which
   * `components/today.tsx` disproved: it was rendered at *two* sites, the claim control and
   * Story 6.8's all-day control, and under the second one the referee could not open the
   * photograph at all. A2 inverted — last time the app promised a privacy the policy did not
   * keep, that time it promised a reach the policy did not grant, which fails toward privacy
   * and is why nobody noticed. Story 8.3 widened both referee policies for a commitment-day
   * photograph on a commitment flagged **as of that day** and for no other, so after it the
   * sentence is true for a flagged commitment-day and still false for an unflagged one. One
   * corrected string could not carry that; a branch can.
   *
   * The claim control passes `true` unconditionally and is unchanged by any of this: a
   * declaration-parented proof has reached the referee since Story 4.6 whatever the sign-off
   * flag says, so the argument is "can he open this photograph", not "is this commitment
   * signed off".
   */
  hint: (refereeCanOpen: boolean): string =>
    refereeCanOpen
      ? 'A photo taken today. Only you and your referee can open it.'
      : 'A photo taken today. Only you can open it.',
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

  /**
   * A photo that is gone rather than broken.
   *
   * Said in the past tense and with no suggestion of a retry, because there is nothing to retry:
   * the bytes were removed after `EVIDENCE_RETENTION_DAYS` and the record of them is all that is
   * left. Deliberately distinct from `photosFailed` above -- telling him a deleted photo "could
   * not be loaded" would send him back to check a screen that will never show it again.
   *
   * It names the period rather than saying "removed", so the sentence explains itself the first
   * time he meets it.
   */
  photosCleared: (count: number): string =>
    `${count} photo${count === 1 ? ' was' : 's were'} cleared after ` +
    `${EVIDENCE_RETENTION_DAYS} days.`,

  /** The read itself failed, so nothing at all can be shown. Distinct from the count above,
   *  which reports a photo that is known to exist, and shown with the server's own reason —
   *  an RLS refusal and a dead connection are different problems. */
  photosUnreadable: 'Photos could not be loaded.',
} as const;
