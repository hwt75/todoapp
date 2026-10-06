import { beforeEach, describe, expect, it, vi } from 'vitest';
import { writeEvidence } from './evidence-write';
import { EVIDENCE_COPY, evidenceRefusal } from './evidence';

/**
 * Epic 6 retrospective item 45: the write half of the evidence path, once. What each parent
 * inserts, and what each failure is reported as, are the two things the copies had diverged on.
 */

const uploads: string[] = [];
const inserts: Array<Record<string, unknown>> = [];
let uploadError: unknown = null;
let insertError: unknown = null;

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    storage: {
      from: () => ({
        upload: async (path: string) => {
          uploads.push(path);
          return { error: uploadError };
        },
      }),
    },
    from: () => ({
      insert: async (row: Record<string, unknown>) => {
        inserts.push(row);
        return { error: insertError };
      },
    }),
  }),
}));

/** A small photo taken at noon local on `day` — under the compression threshold, so it goes up
 *  as it is. */
function takenOn(day: string): File {
  const at = new Date(`${day}T12:00:00+07:00`).getTime();
  return new File(['x'], 'proof.jpg', { type: 'image/jpeg', lastModified: at });
}

beforeEach(() => {
  uploads.length = 0;
  inserts.length = 0;
  uploadError = null;
  insertError = null;
});

describe('writeEvidence', () => {
  it('refuses a file from another day before anything leaves the device', async () => {
    const onStart = vi.fn();
    const outcome = await writeEvidence(
      takenOn('2026-10-04'),
      { kind: 'declaration', id: 'd1' },
      '2026-10-05',
      onStart,
    );

    expect(outcome).toEqual({ kind: 'wrong-day' });
    expect(onStart).not.toHaveBeenCalled();
    expect(uploads).toEqual([]);
  });

  it('files a claim photo under its declaration, the object path led by that id', async () => {
    const onStart = vi.fn();
    const outcome = await writeEvidence(
      takenOn('2026-10-05'),
      { kind: 'declaration', id: 'd1' },
      '2026-10-05',
      onStart,
    );

    expect(outcome).toEqual({ kind: 'saved' });
    expect(onStart).toHaveBeenCalledOnce();
    expect(uploads[0]).toMatch(/^d1\//);
    expect(inserts[0]).toMatchObject({ declaration_id: 'd1', captured_on: '2026-10-05' });
    expect(inserts[0]).not.toHaveProperty('for_day');
  });

  it('files a kept photo under its commitment, with the day beside it', async () => {
    await writeEvidence(takenOn('2026-10-05'), { kind: 'commitment', id: 'c1' }, '2026-10-05');
    expect(inserts[0]).toMatchObject({ commitment_id: 'c1', for_day: '2026-10-05' });
  });

  it('files an appeal photo under its appeal', async () => {
    await writeEvidence(takenOn('2026-10-03'), { kind: 'appeal', id: 'a1' }, '2026-10-03');
    expect(uploads[0]).toMatch(/^a1\//);
    expect(inserts[0]).toMatchObject({ appeal_id: 'a1', captured_on: '2026-10-03' });
    expect(inserts[0]).not.toHaveProperty('for_day');
  });

  it('writes no row when nothing reached Storage', async () => {
    uploadError = { message: 'storage down' };
    const outcome = await writeEvidence(
      takenOn('2026-10-05'),
      { kind: 'declaration', id: 'd1' },
      '2026-10-05',
    );
    expect(outcome).toEqual({ kind: 'upload-failed' });
    expect(inserts).toEqual([]);
  });

  it('carries the server’s own words when the row is refused', async () => {
    insertError = { message: 'That day has ended.', hint: 'evidence:day-ended' };
    const outcome = await writeEvidence(
      takenOn('2026-10-05'),
      { kind: 'declaration', id: 'd1' },
      '2026-10-05',
    );
    expect(outcome).toEqual({
      kind: 'refused',
      reason: 'That day has ended.',
      hint: 'evidence:day-ended',
    });
  });

  it('reports no hint as null rather than an empty string', async () => {
    insertError = { message: 'new row violates row-level security policy', hint: '' };
    const outcome = await writeEvidence(
      takenOn('2026-10-05'),
      { kind: 'declaration', id: 'd1' },
      '2026-10-05',
    );
    expect(outcome).toMatchObject({ kind: 'refused', hint: null });
  });
});

describe('evidenceRefusal (deferred from epic-6 retro item 42)', () => {
  it('turns every hint the server sends into this product’s own sentence', () => {
    for (const hint of [
      'evidence:day-ended',
      'evidence:not-today',
      'evidence:wrong-capture-date',
      'evidence:no-object',
      'evidence:no-parent',
    ]) {
      const sentence = evidenceRefusal(hint, 'raw database words');
      expect(sentence).toBe(EVIDENCE_COPY.refusals[hint]);
      expect(sentence).not.toContain('raw database words');
    }
  });

  it('keeps the server’s words for a refusal it does not know, never silence', () => {
    expect(evidenceRefusal(null, 'Something new.')).toBe('Something new.');
    expect(evidenceRefusal('evidence:added-later', 'Something new.')).toBe('Something new.');
  });
});
