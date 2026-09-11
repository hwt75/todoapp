import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  EVIDENCE_COMPRESS_ABOVE_BYTES,
  EVIDENCE_COPY,
  EVIDENCE_MAX_EDGE,
  compressEvidencePhoto,
  evidenceObjectPath,
  fileCapturedOn,
  isEvidenceDated,
  photosOn,
  readKeptPhotos,
} from './evidence';

/**
 * Moved here whole from `lib/appeal.test.ts` by Story 6.3, unchanged apart from the import.
 * These rules were never about appeals: a path leads with whichever parent owns the object, and
 * a file is dated the day it proves regardless of what it is proving.
 *
 * Story 6.9 adds the read side. Every case below is a row of that story's I/O Matrix that is
 * about the *read* rather than about where a photo is placed — no rows, all signed, one that
 * cannot be signed, and a read that fails outright — asserted here once so the three surfaces
 * that share this helper cannot each answer them differently.
 */

/**
 * One page of the `evidence` read, keyed by the day list that page asked for. `*` answers any
 * page a test has not spoken about, which is every test that does not care about chunking.
 */
let evidenceByDays: Record<string, unknown> = {};
/** Whether the whole `createSignedUrls` call fails, and what each path signs to when it does
 *  not. A path named here signs to whatever it says; anything else signs cleanly. */
let signError: unknown = null;
let signedByPath: Record<string, unknown> = {};
/** Every `.in` filter the read applied, so a dropped or wrong filter cannot pass silently. */
const filters: Array<[string, unknown]> = [];
/** Every batch of paths handed to `createSignedUrls`, with the expiry it asked for. */
const signCalls: Array<{ paths: string[]; ttl: number }> = [];
let selected: string | null = null;
const tables: string[] = [];

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      tables.push(table);
      let days: string[] = [];
      const query = {
        select: (columns: string) => {
          selected = columns;
          return query;
        },
        in: (column: string, value: unknown) => {
          filters.push([column, value]);
          if (column === 'for_day') days = value as string[];
          return query;
        },
        then: (resolve: (value: unknown) => unknown) =>
          Promise.resolve(
            evidenceByDays[days.join(',')] ?? evidenceByDays['*'] ?? { data: [], error: null },
          ).then(resolve),
      };
      return query;
    },
    storage: {
      from: () => ({
        createSignedUrls: (paths: string[], ttl: number) => {
          signCalls.push({ paths, ttl });
          if (signError) return Promise.resolve({ data: null, error: signError });
          return Promise.resolve({
            data: paths.map(
              (path) =>
                signedByPath[path] ?? {
                  path,
                  error: null,
                  signedUrl: `https://signed.test/${path}`,
                },
            ),
            error: null,
          });
        },
      }),
    },
  }),
}));

/** One `evidence` row as the reader asks for it. */
function row(id: string, day: string, path: string, sweptAt: string | null = null) {
  return { id, commitment_id: 'c1', for_day: day, storage_path: path, swept_at: sweptAt };
}

beforeEach(() => {
  evidenceByDays = {};
  signedByPath = {};
  signError = null;
  filters.length = 0;
  signCalls.length = 0;
  selected = null;
  tables.length = 0;
});

describe('EVIDENCE_COPY.hint', () => {
  // Epic 6 retrospective, A2 (HIGH), and the test that item asked for. The sentence used to
  // say "It is private -- only you can open it" while
  // `evidence: referee reads his own doer's` (20260907160000:141) granted the referee every
  // one of these rows. Nothing tested the copy, so nothing noticed. These assertions are
  // about the promise, not the wording: they fail if the exclusivity claim comes back, and
  // they fail if the referee stops being named.
  it('does not claim the author is the only reader', () => {
    // Narrow on purpose: "Only you and your referee" is the true sentence and contains
    // "only you". What must never come back is the exclusivity claim itself.
    expect(EVIDENCE_COPY.hint).not.toMatch(/only you can (open|see|read)/i);
    expect(EVIDENCE_COPY.hint).not.toMatch(/private/i);
  });

  it('names the referee as the other reader', () => {
    expect(EVIDENCE_COPY.hint).toMatch(/referee/i);
  });
});

describe('evidenceObjectPath', () => {
  it('leads with the appeal id — what the storage.objects policy reads', () => {
    const path = evidenceObjectPath('appeal-1', 'evidence-1', 'photo.jpg');
    expect(path.startsWith('appeal-1/')).toBe(true);
  });

  it('sanitises a filename carrying characters a storage path should not', () => {
    const path = evidenceObjectPath('appeal-1', 'evidence-1', '../../etc/passwd');
    expect(path).not.toContain('..');
    expect(path).not.toContain('/etc');
  });

  it('never produces an empty filename segment', () => {
    const path = evidenceObjectPath('appeal-1', 'evidence-1', '   ');
    expect(path).toBe('appeal-1/evidence-1-evidence');
  });
});

describe('fileCapturedOn / isEvidenceDated', () => {
  function fileDatedOn(isoDate: string) {
    return new File(['data'], 'photo.jpg', {
      type: 'image/jpeg',
      lastModified: new Date(`${isoDate}T12:00:00+07:00`).getTime(),
    });
  }

  it('reads the calendar date in Asia/Ho_Chi_Minh off a file’s own lastModified', () => {
    expect(fileCapturedOn(fileDatedOn('2026-08-18'))).toBe('2026-08-18');
  });

  it('is dated once fileCapturedOn matches forDay exactly', () => {
    expect(isEvidenceDated(fileDatedOn('2026-08-18'), '2026-08-18')).toBe(true);
  });

  it('is refused for a day before or after the one being appealed (FR-14)', () => {
    expect(isEvidenceDated(fileDatedOn('2026-08-17'), '2026-08-18')).toBe(false);
    expect(isEvidenceDated(fileDatedOn('2026-08-19'), '2026-08-18')).toBe(false);
  });
});

describe('compressEvidencePhoto', () => {
  /** The capture moment every one of these must survive — `fileCapturedOn` reads it, and
   *  `captured_on` is derived from it on both write paths. */
  const CAPTURED_AT = new Date('2026-08-18T12:00:00+07:00').getTime();

  function photo(bytes: number, name = 'IMG_0001.jpg', type = 'image/jpeg') {
    return new File([new Uint8Array(bytes)], name, { type, lastModified: CAPTURED_AT });
  }

  /**
   * Stands in for the browser pipeline this helper drives: decode, draw, re-encode. The `lib`
   * project runs in Node, which has neither, so each test states what the browser would have
   * done and asserts what the helper makes of it.
   */
  function stubBrowser({
    width = 3024,
    height = 4032,
    outputBytes = 180 * 1024,
    decode,
    toBlobResult,
  }: {
    width?: number;
    height?: number;
    outputBytes?: number;
    decode?: () => never;
    toBlobResult?: 'null';
  } = {}) {
    const closed = { count: 0 };
    const drawn: Array<{ w: number; h: number }> = [];
    const encodedAs: Array<{ type: string; quality: number }> = [];

    vi.stubGlobal(
      'createImageBitmap',
      vi.fn(async (_file: unknown, options?: { imageOrientation?: string }) => {
        if (decode) decode();
        return {
          width,
          height,
          orientation: options?.imageOrientation,
          close: () => {
            closed.count++;
          },
        };
      }),
    );

    const canvas = {
      width: 0,
      height: 0,
      getContext: () => ({
        drawImage: (_bitmap: unknown, _x: number, _y: number, w: number, h: number) =>
          drawn.push({ w, h }),
      }),
      toBlob: (cb: (blob: Blob | null) => void, type: string, quality: number) => {
        encodedAs.push({ type, quality });
        cb(toBlobResult === 'null' ? null : new Blob([new Uint8Array(outputBytes)]));
      },
    };

    vi.stubGlobal('document', { createElement: () => canvas });
    return { closed, drawn, encodedAs, canvas };
  }

  afterEach(() => vi.unstubAllGlobals());

  it('keeps the capture moment, which is the whole of what dates the evidence', async () => {
    stubBrowser();
    const original = photo(2_400_000);
    const stored = await compressEvidencePhoto(original);

    // The bug this guards: `new File(...)` defaults `lastModified` to now, so every photograph
    // would be dated the moment it was uploaded. A same-day claim made near midnight would then
    // refuse itself, and `evidence_derive_owner()` would refuse the rest.
    expect(stored.lastModified).toBe(CAPTURED_AT);
    expect(fileCapturedOn(stored)).toBe(fileCapturedOn(original));
    expect(fileCapturedOn(stored)).toBe('2026-08-18');
    expect(stored.name).toBe('IMG_0001.jpg');
    expect(stored.type).toBe('image/jpeg');
    expect(stored.size).toBeLessThan(original.size);
  });

  it('scales the long edge to the stored maximum and keeps the shape of the picture', async () => {
    const { drawn } = stubBrowser({ width: 3024, height: 4032 });
    await compressEvidencePhoto(photo(2_400_000));

    // 4032 is the long edge, so both fall by the same factor — a portrait photo must not come
    // back square.
    expect(drawn).toEqual([
      { w: Math.round(3024 * (EVIDENCE_MAX_EDGE / 4032)), h: EVIDENCE_MAX_EDGE },
    ]);
  });

  it('reads the EXIF orientation while it still can', async () => {
    stubBrowser();
    await compressEvidencePhoto(photo(2_400_000));
    // The re-encode drops the tag, so a photo decoded without applying it is stored on its side.
    expect(createImageBitmap).toHaveBeenCalledWith(expect.anything(), {
      imageOrientation: 'from-image',
    });
  });

  it('never enlarges a picture that is already smaller than the maximum', async () => {
    const { drawn } = stubBrowser({ width: 800, height: 600 });
    await compressEvidencePhoto(photo(2_400_000));
    expect(drawn).toEqual([{ w: 800, h: 600 }]);
  });

  it('leaves a photo that is already small alone, without touching a canvas', async () => {
    stubBrowser();
    const small = photo(EVIDENCE_COMPRESS_ABOVE_BYTES - 1);
    expect(await compressEvidencePhoto(small)).toBe(small);
    expect(createImageBitmap).not.toHaveBeenCalled();
  });

  it('hands back the original when the browser cannot decode the format', async () => {
    // Chrome on Android still cannot read HEIC, and the bucket accepts it.
    stubBrowser({
      decode: () => {
        throw new Error('unsupported image format');
      },
    });
    const heic = photo(2_400_000, 'IMG_0002.heic', 'image/heic');
    const stored = await compressEvidencePhoto(heic);

    expect(stored).toBe(heic);
    expect(stored.type).toBe('image/heic');
  });

  it('hands back the original when the re-encode comes out no smaller', async () => {
    stubBrowser({ outputBytes: 3_000_000 });
    const original = photo(2_400_000);
    expect(await compressEvidencePhoto(original)).toBe(original);
  });

  it('hands back the original when the canvas gives nothing', async () => {
    stubBrowser({ toBlobResult: 'null' });
    const original = photo(2_400_000);
    expect(await compressEvidencePhoto(original)).toBe(original);
  });

  it('hands back the original where there is no browser at all', async () => {
    // The state this module is imported in on the server, and in the `lib` test project.
    vi.unstubAllGlobals();
    const original = photo(2_400_000);
    expect(await compressEvidencePhoto(original)).toBe(original);
  });

  it('releases the decoded bitmap on both the happy and the failing path', async () => {
    const ok = stubBrowser();
    await compressEvidencePhoto(photo(2_400_000));
    expect(ok.closed.count).toBe(1);

    const refused = stubBrowser({ toBlobResult: 'null' });
    await compressEvidencePhoto(photo(2_400_000));
    expect(refused.closed.count).toBe(1);
  });
});

describe('readKeptPhotos', () => {
  it('asks nothing at all when no day, or no commitment, was named', async () => {
    expect(await readKeptPhotos(['c1'], [])).toEqual({
      photos: [],
      unsigned: 0,
      cleared: 0,
      failed: null,
    });
    expect(await readKeptPhotos([], ['2026-09-03'])).toEqual({
      photos: [],
      unsigned: 0,
      cleared: 0,
      failed: null,
    });

    // A commitment with no judged day yet must not cost a round trip per open.
    expect(tables).toHaveLength(0);
    expect(signCalls).toHaveLength(0);
  });

  it('reads no photos as a real state rather than a failure', async () => {
    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    expect(read).toEqual({ photos: [], unsigned: 0, cleared: 0, failed: null });
    // Nothing to sign is no signing call at all.
    expect(signCalls).toHaveLength(0);
  });

  it('scopes the read to these commitments and only the days asked for', async () => {
    await readKeptPhotos(['c1', 'c2'], ['2026-09-02', '2026-09-03']);

    // Without these asserted, either filter could be deleted and every other test here would
    // still pass while the screen showed another commitment's record, or a day it never asked
    // about, to the person whose whole trust in this product is that it says only what it can
    // support.
    expect(tables).toEqual(['evidence']);
    expect(selected).toBe('id,commitment_id,for_day,storage_path,swept_at');
    expect(filters).toEqual([
      ['commitment_id', ['c1', 'c2']],
      ['for_day', ['2026-09-02', '2026-09-03']],
    ]);
  });

  it('deduplicates the ids and the days before anything is sent', async () => {
    await readKeptPhotos(['c1', 'c1'], ['2026-09-03', '2026-09-03', '2026-09-02']);

    // A day asked for twice would lengthen the request and, worse, number that day's photos
    // against a doubled total.
    expect(filters).toEqual([
      ['commitment_id', ['c1']],
      ['for_day', ['2026-09-03', '2026-09-02']],
    ]);
  });

  it('chunks a long history rather than putting a year of dates in one query string', async () => {
    const year = Array.from({ length: 250 }, (_, i) => `day-${i}`);
    await readKeptPhotos(['c1'], year);

    const dayFilters = filters.filter(([column]) => column === 'for_day');
    expect(dayFilters).toHaveLength(3);
    expect(dayFilters.map(([, value]) => (value as string[]).length)).toEqual([100, 100, 50]);
    // Every day is still asked about — chunking is the same answer, not a shorter one.
    expect(dayFilters.flatMap(([, value]) => value as string[])).toEqual(year);
  });

  it('signs every path in one call, for an hour, numbered within its own day', async () => {
    evidenceByDays['*'] = {
      data: [
        row('e2', '2026-09-03', 'c1/e2-two.jpg'),
        row('e1', '2026-09-03', 'c1/e1-one.jpg'),
        row('e3', '2026-09-02', 'c1/e3-three.jpg'),
      ],
      error: null,
    };

    const read = await readKeptPhotos(['c1'], ['2026-09-02', '2026-09-03']);

    expect(read.unsigned).toBe(0);
    expect(read.failed).toBeNull();
    expect(read.photos).toHaveLength(3);

    // One call, not one per photo — a ten-photo history was ten round trips deep before.
    expect(signCalls).toHaveLength(1);
    // One hour, the same figure the referee's own viewer signs with.
    expect(signCalls[0].ttl).toBe(3600);

    // A day of one is "1 of 1", never "1 of 3": the count a reader is told is the count on that
    // day's own row, not the count in the whole read.
    expect(photosOn(read, 'c1', '2026-09-02').map((p) => p.alt)).toEqual([
      EVIDENCE_COPY.photoAlt(1, 1),
    ]);
    expect(photosOn(read, 'c1', '2026-09-03').map((p) => p.alt)).toEqual([
      EVIDENCE_COPY.photoAlt(1, 2),
      EVIDENCE_COPY.photoAlt(2, 2),
    ]);
    expect(photosOn(read, 'c1', '2026-09-03').map((p) => p.url)).toEqual([
      'https://signed.test/c1/e1-one.jpg',
      'https://signed.test/c1/e2-two.jpg',
    ]);
  });

  it('keeps two commitments’ photos apart within one read', async () => {
    evidenceByDays['*'] = {
      data: [
        { ...row('e1', '2026-09-03', 'c1/e1-one.jpg'), commitment_id: 'c1' },
        { ...row('e2', '2026-09-03', 'c2/e2-two.jpg'), commitment_id: 'c2' },
      ],
      error: null,
    };

    const read = await readKeptPhotos(['c1', 'c2'], ['2026-09-03']);

    // One query answers for every flagged row on Today, and each row still gets only its own.
    expect(photosOn(read, 'c1', '2026-09-03').map((p) => p.id)).toEqual(['e1']);
    expect(photosOn(read, 'c2', '2026-09-03').map((p) => p.id)).toEqual(['e2']);
    // And each is numbered against its own commitment's day, not against the pair.
    expect(photosOn(read, 'c2', '2026-09-03')[0].alt).toBe(EVIDENCE_COPY.photoAlt(1, 1));
  });

  it('counts a photo it could not sign, and still renders the others', async () => {
    evidenceByDays['*'] = {
      data: [row('e1', '2026-09-03', 'c1/e1-one.jpg'), row('e2', '2026-09-03', 'c1/e2-two.jpg')],
      error: null,
    };
    signedByPath = {
      'c1/e2-two.jpg': { path: 'c1/e2-two.jpg', error: 'Object not found', signedUrl: null },
    };

    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    // Never a silently shorter list: one photo, and a note that says one is missing. A list that
    // just came back shorter is indistinguishable from never having kept the record at all.
    expect(read.photos).toHaveLength(1);
    expect(read.unsigned).toBe(1);
    expect(read.failed).toBeNull();
    // And the survivor is numbered against what is actually on screen.
    expect(read.photos[0].alt).toBe(EVIDENCE_COPY.photoAlt(1, 1));
  });

  it('counts every photo when the signing call itself fails', async () => {
    evidenceByDays['*'] = {
      data: [row('e1', '2026-09-03', 'c1/e1-one.jpg'), row('e2', '2026-09-03', 'c1/e2-two.jpg')],
      error: null,
    };
    signError = { message: 'storage unreachable' };

    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    // Two rows exist and neither can be shown. That is two counted, never an empty screen
    // reading as a day he kept nothing on.
    expect(read.photos).toHaveLength(0);
    expect(read.unsigned).toBe(2);
    expect(read.failed).toBeNull();
  });

  it('leaves a swept photo out of the list and counts it as cleared, not as a failure', async () => {
    // Retention (20260908180000). The bytes are gone; the row is still there because
    // `commitments_owing()` reads its existence to decide whether the day held. To the author
    // these are different facts from a photo that would not load, and only one of them is worth
    // a retry.
    evidenceByDays['*'] = {
      data: [
        row('e1', '2026-09-03', 'c1/e1.jpg'),
        row('e2', '2026-09-03', 'c1/e2.jpg', '2026-10-05T00:00:00Z'),
      ],
      error: null,
    };

    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    expect(read.photos).toHaveLength(1);
    expect(read.cleared).toBe(1);
    expect(read.unsigned).toBe(0);
    // Never handed to the signer: signing a path whose object is gone would report it as
    // something that might work later.
    expect(signCalls[0].paths).toEqual(['c1/e1.jpg']);
    // And the one that survives is numbered against the photos actually on screen.
    expect(read.photos[0].alt).toBe(EVIDENCE_COPY.photoAlt(1, 1));
  });

  it('still reports the count when every photo on the day has been swept', async () => {
    // The path that would otherwise return the shared "nothing kept" object and lose the number.
    // A day whose photos were cleared is not the same answer as a day he never photographed.
    evidenceByDays['*'] = {
      data: [row('e1', '2026-09-03', 'c1/e1.jpg', '2026-10-05T00:00:00Z')],
      error: null,
    };

    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    expect(read).toEqual({ photos: [], unsigned: 0, cleared: 1, failed: null });
    expect(signCalls).toHaveLength(0);
  });

  it('treats a row with no swept_at field at all as not swept', async () => {
    // `!= null` rather than `!== null`. If a caller's select ever drops the column, the safe
    // failure is showing the photo and counting a real miss as unloadable — not silently
    // reporting every photo in the product as cleared.
    evidenceByDays['*'] = {
      data: [{ id: 'e1', commitment_id: 'c1', for_day: '2026-09-03', storage_path: 'c1/e1.jpg' }],
      error: null,
    };

    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    expect(read.cleared).toBe(0);
    expect(read.photos).toHaveLength(1);
  });

  it('says the row read failed rather than reporting an empty history', async () => {
    evidenceByDays['*'] = { data: null, error: { message: 'permission denied' } };

    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    // A failed read and a day with no photo look identical on screen unless this is carried
    // separately, and one of them means his own record is unreachable. The server's own words
    // come with it: a refusal and a dead connection are different problems.
    expect(read).toEqual({ photos: [], unsigned: 0, cleared: 0, failed: 'permission denied' });
    expect(signCalls).toHaveLength(0);
  });

  it('fails the whole read when one chunk of a long history fails', async () => {
    const days = Array.from({ length: 150 }, (_, i) => `day-${i}`);
    evidenceByDays[days.slice(0, 100).join(',')] = {
      data: [row('e1', 'day-0', 'c1/e1-one.jpg')],
      error: null,
    };
    evidenceByDays[days.slice(100).join(',')] = {
      data: null,
      error: { message: 'permission denied' },
    };

    const read = await readKeptPhotos(['c1'], days);

    // Half a history presented as the whole of it is the one answer this surface must never
    // give — it would say he kept nothing on days it simply never managed to ask about.
    expect(read).toEqual({ photos: [], unsigned: 0, cleared: 0, failed: 'permission denied' });
  });

  it('stops signing once its caller has gone', async () => {
    evidenceByDays['*'] = { data: [row('e1', '2026-09-03', 'c1/e1-one.jpg')], error: null };

    const read = await readKeptPhotos(['c1'], ['2026-09-03'], { cancelled: () => true });

    // A screen already left must not go on spending his connection, and its answer is nothing
    // rather than something the caller would apply to a screen that no longer exists.
    expect(read).toEqual({ photos: [], unsigned: 0, cleared: 0, failed: null });
    expect(signCalls).toHaveLength(0);
  });
});
