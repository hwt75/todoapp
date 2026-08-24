import { describe, expect, it } from 'vitest';
import { evidenceObjectPath, formatDeadline, holdStateCopy, toRow } from './appeal';

describe('toRow', () => {
  it('sends exactly commitment_id, for_day, owner_id and idempotency_key', () => {
    const row = toRow({ commitmentId: 'commitment-1', forDay: '2026-08-18' }, 'owner-1', 'key-1');

    expect(row).toEqual({
      owner_id: 'owner-1',
      commitment_id: 'commitment-1',
      idempotency_key: 'key-1',
      for_day: '2026-08-18',
    });
  });

  it('never sends settlement_id, penalty_id or deadline — the trigger derives all three', () => {
    const row = toRow({ commitmentId: 'c', forDay: '2026-08-18' }, 'o', 'k');
    expect(row).not.toHaveProperty('settlement_id');
    expect(row).not.toHaveProperty('penalty_id');
    expect(row).not.toHaveProperty('deadline');
  });
});

describe('holdStateCopy', () => {
  it('names the real amount and the real deadline, never the template brackets', () => {
    const copy = holdStateCopy(500_000, new Date('2026-08-26T00:00:00+07:00'));

    expect(copy).toContain('500.000₫ is on hold, not charged.');
    expect(copy).toContain('Aug 26');
    expect(copy).not.toContain('[Referee]');
    expect(copy).not.toContain('[deadline]');
  });

  it('says what happens on timeout — the sentence EXPERIENCE.md calls trust-critical', () => {
    const copy = holdStateCopy(500_000, new Date('2026-08-26T00:00:00+07:00'));
    expect(copy).toContain("if he doesn't get to it, it's dropped.");
  });

  it('says the money is not charged, not merely that it is on hold', () => {
    // "On hold" alone could be misread as a softer synonym for "owed". The sentence has to
    // say the negative outright: nothing has been taken.
    const copy = holdStateCopy(500_000, new Date('2026-08-26T00:00:00+07:00'));
    expect(copy).toContain('not charged');
  });
});

describe('formatDeadline', () => {
  it('names the date in the product timezone, not a bare ISO instant', () => {
    // Midnight Asia/Ho_Chi_Minh on the 26th is still the 25th in UTC — the whole reason a
    // fixed-zone formatter is used rather than the device's own locale rendering.
    expect(formatDeadline(new Date('2026-08-26T00:00:00+07:00'))).toBe('Aug 26');
  });

  it('never names a time — the deadline is always midnight, and a time would claim precision it does not have', () => {
    expect(formatDeadline(new Date('2026-08-26T00:00:00+07:00'))).not.toMatch(/\d+:\d+/);
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
