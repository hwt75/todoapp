import { describe, expect, it } from 'vitest';
import { evidenceObjectPath, fileCapturedOn, isEvidenceDated } from './evidence';

/**
 * Moved here whole from `lib/appeal.test.ts` by Story 6.3, unchanged apart from the import.
 * These rules were never about appeals: a path leads with whichever parent owns the object, and
 * a file is dated the day it proves regardless of what it is proving.
 */

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
