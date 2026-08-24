import { describe, expect, it } from 'vitest';
import {
  classifyConflict,
  classifyWriteError,
  dayRolledOver,
  shouldRetry,
} from './declaration-submit';

/** Ho Chi Minh City is UTC+7 all year. */
function hcm(day: string, hour: number, minute = 0): Date {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d, hour - 7, minute));
}

describe('what a failed write means', () => {
  it('no error is a send', () => {
    expect(classifyWriteError(null)).toBe('sent');
  });

  it('a unique violation is the answer already being recorded', () => {
    // A previous attempt got through and its acknowledgement did not. Success arriving out
    // of order — retrying it forever would be retrying something that already worked.
    expect(classifyWriteError({ code: '23505', message: 'duplicate key' })).toBe('duplicate');
  });

  describe('the server decided, so retrying changes nothing', () => {
    it.each([
      ['42501', 'insufficient privilege — an RLS policy refused it'],
      ['23502', 'not-null violation'],
      ['23503', 'foreign key violation'],
      ['23514', 'check constraint violation'],
      ['22P02', 'invalid text representation'],
    ])('%s is rejected (%s)', (code) => {
      expect(classifyWriteError({ code })).toBe('rejected');
    });

    it('is never retried', () => {
      expect(shouldRetry('rejected')).toBe(false);
    });
  });

  describe('the request never reached a decision, so it is worth keeping', () => {
    it.each([
      ['a dead network', { message: 'Failed to fetch' }],
      ['a timeout', { message: 'network timeout' }],
      ['no code at all', { message: 'something went wrong' }],
      ['a non-SQLSTATE code', { code: 'PGRST301', message: 'JWT expired' }],
      ['a lowercase code', { code: 'abcde' }],
      ['a short code', { code: '2350' }],
    ])('%s is unreachable', (_label, error) => {
      expect(classifyWriteError(error)).toBe('unreachable');
    });

    it('is the only outcome that stays queued', () => {
      expect(shouldRetry('unreachable')).toBe(true);
      expect(shouldRetry('sent')).toBe(false);
      expect(shouldRetry('duplicate')).toBe(false);
    });
  });

  it('never calls a policy refusal a connection problem', () => {
    // The finding this exists for. Telling the author his answer is saved when a policy
    // refused it is a lie he cannot detect: the question is gone and nothing was recorded.
    expect(classifyWriteError({ code: '42501' })).not.toBe('unreachable');
    expect(shouldRetry(classifyWriteError({ code: '42501' }))).toBe(false);
  });
});

describe('the day turning over between question and answer', () => {
  it('is false within the same local day', () => {
    // Shown at 07:30 on the 19th, tapped at 07:31. Both refer to the 18th.
    expect(dayRolledOver('2026-08-18', hcm('2026-08-19', 7, 31))).toBe(false);
  });

  it('is false right up to local midnight', () => {
    expect(dayRolledOver('2026-08-18', hcm('2026-08-19', 23, 59))).toBe(false);
  });

  it('is true one minute after it', () => {
    // The finding. Drawn at 23:58 asking about the 18th, tapped at 00:01 — the trigger
    // would derive the 19th, filing an answer against a day never asked about and leaving
    // the 18th open forever.
    expect(dayRolledOver('2026-08-18', hcm('2026-08-20', 0, 1))).toBe(true);
  });

  it('is true for a screen left open all day', () => {
    expect(dayRolledOver('2026-08-18', hcm('2026-08-21', 9))).toBe(true);
  });

  it('uses the local boundary, not UTC', () => {
    // 00:30 local on the 20th is 17:30 UTC on the 19th. A UTC comparison would say the day
    // had not turned over, and the answer would be filed a day out.
    const justAfterLocalMidnight = hcm('2026-08-20', 0, 30);
    expect(justAfterLocalMidnight.toISOString().slice(0, 10)).toBe('2026-08-19');
    expect(dayRolledOver('2026-08-18', justAfterLocalMidnight)).toBe(true);
  });
});

describe('what a 23505 on declaration actually means (FR-2a)', () => {
  it('is my own retry when the existing row carries the same idempotency key', () => {
    expect(classifyConflict('key-1', 'key-1')).toBe('duplicate');
  });

  it('is a conflict when the existing row carries a different key', () => {
    // Not my own answer arriving late — something else, on this day, already decided it.
    // Story 4.3's own shape: a Penalty-carrying commitment's Auto-check filed `slipped`
    // first, and this attempt is the author's own, honest, contradicting tap.
    expect(classifyConflict('machine-key', 'my-key')).toBe('conflict');
  });

  it('reads a null existing key as a conflict, the safe default', () => {
    // Not reachable today — declaration has no delete policy, so a row that won a unique
    // violation cannot vanish before the follow-up select reads it back. If that ever
    // changed, treating "can't tell" as "assume the worst" is the direction that cannot
    // silently let a wrong answer through.
    expect(classifyConflict(null, 'my-key')).toBe('conflict');
  });
});
