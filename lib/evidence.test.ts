import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  EVIDENCE_COPY,
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
function row(id: string, day: string, path: string) {
  return { id, commitment_id: 'c1', for_day: day, storage_path: path };
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

describe('readKeptPhotos', () => {
  it('asks nothing at all when no day, or no commitment, was named', async () => {
    expect(await readKeptPhotos(['c1'], [])).toEqual({ photos: [], unsigned: 0, failed: null });
    expect(await readKeptPhotos([], ['2026-09-03'])).toEqual({
      photos: [],
      unsigned: 0,
      failed: null,
    });

    // A commitment with no judged day yet must not cost a round trip per open.
    expect(tables).toHaveLength(0);
    expect(signCalls).toHaveLength(0);
  });

  it('reads no photos as a real state rather than a failure', async () => {
    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    expect(read).toEqual({ photos: [], unsigned: 0, failed: null });
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
    expect(selected).toBe('id,commitment_id,for_day,storage_path');
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

  it('says the row read failed rather than reporting an empty history', async () => {
    evidenceByDays['*'] = { data: null, error: { message: 'permission denied' } };

    const read = await readKeptPhotos(['c1'], ['2026-09-03']);

    // A failed read and a day with no photo look identical on screen unless this is carried
    // separately, and one of them means his own record is unreachable. The server's own words
    // come with it: a refusal and a dead connection are different problems.
    expect(read).toEqual({ photos: [], unsigned: 0, failed: 'permission denied' });
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
    expect(read).toEqual({ photos: [], unsigned: 0, failed: 'permission denied' });
  });

  it('stops signing once its caller has gone', async () => {
    evidenceByDays['*'] = { data: [row('e1', '2026-09-03', 'c1/e1-one.jpg')], error: null };

    const read = await readKeptPhotos(['c1'], ['2026-09-03'], { cancelled: () => true });

    // A screen already left must not go on spending his connection, and its answer is nothing
    // rather than something the caller would apply to a screen that no longer exists.
    expect(read).toEqual({ photos: [], unsigned: 0, failed: null });
    expect(signCalls).toHaveLength(0);
  });
});
