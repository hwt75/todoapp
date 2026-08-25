import { describe, expect, it } from 'vitest';
import {
  collectionMessage,
  formatOwedDay,
  isPairableEmail,
  isPairedReferee,
  refereeFunctionErrorMessage,
  summarizeReferee,
} from './referee';

describe('isPairableEmail', () => {
  it('accepts anything that looks like an address, leaving real validation to the server', () => {
    expect(isPairableEmail('ref@example.com')).toBe(true);
  });

  it('refuses what could not possibly be one', () => {
    expect(isPairableEmail('not an email')).toBe(false);
    expect(isPairableEmail('')).toBe(false);
  });
});

describe('isPairedReferee', () => {
  it('recognises the success shape', () => {
    expect(isPairedReferee({ email: 'ref@example.com', password: 'abc123' })).toBe(true);
  });

  it('refuses anything missing either field, rather than reading undefined as a password', () => {
    expect(isPairedReferee({ email: 'ref@example.com' })).toBe(false);
    expect(isPairedReferee({ password: 'abc123' })).toBe(false);
    expect(isPairedReferee(null)).toBe(false);
    expect(isPairedReferee('a string')).toBe(false);
  });

  it('refuses an empty email or password rather than rendering a blank pairing as real', () => {
    expect(isPairedReferee({ email: '', password: '' })).toBe(false);
    expect(isPairedReferee({ email: '', password: 'abc123' })).toBe(false);
    expect(isPairedReferee({ email: 'ref@example.com', password: '' })).toBe(false);
  });
});

describe('refereeFunctionErrorMessage', () => {
  it('reads the function’s own {error} body off a Response-shaped context', async () => {
    const error = {
      message: 'Edge Function returned a non-2xx status code',
      context: {
        json: () => Promise.resolve({ error: 'Only the doer account may pair a referee.' }),
      },
    };
    expect(await refereeFunctionErrorMessage(error)).toBe(
      'Only the doer account may pair a referee.',
    );
  });

  it('falls back to the generic message when there is no context to read', async () => {
    expect(await refereeFunctionErrorMessage({ message: 'network down' })).toBe('network down');
  });

  it('falls back rather than throwing when the context body is not JSON', async () => {
    const error = {
      message: 'network down',
      context: { json: () => Promise.reject(new Error('not JSON')) },
    };
    expect(await refereeFunctionErrorMessage(error)).toBe('network down');
  });

  it('never throws on a null error', async () => {
    await expect(refereeFunctionErrorMessage(null)).resolves.toEqual(expect.any(String));
  });
});

describe('summarizeReferee', () => {
  it('reads zero appeals pending and zero owed from an empty read', () => {
    expect(summarizeReferee([])).toEqual({
      pendingAppeals: 0,
      owedCount: 0,
      owedTotalDong: 0,
    });
  });

  it('counts held penalties as pending appeals — appeal_hold_penalty is the only writer of held', () => {
    const summary = summarizeReferee([
      { state: 'held', amountDong: 500_000 },
      { state: 'held', amountDong: 500_000 },
    ]);
    expect(summary.pendingAppeals).toBe(2);
    expect(summary.owedCount).toBe(0);
  });

  it('counts and totals owed penalties separately from held ones', () => {
    const summary = summarizeReferee([
      { state: 'owed', amountDong: 500_000 },
      { state: 'owed', amountDong: 500_000 },
      { state: 'held', amountDong: 500_000 },
    ]);
    expect(summary.owedCount).toBe(2);
    expect(summary.owedTotalDong).toBe(1_000_000);
    expect(summary.pendingAppeals).toBe(1);
  });

  it('excludes dropped penalties from both counts — a timeout resolved them in the author’s favour', () => {
    const summary = summarizeReferee([{ state: 'dropped', amountDong: 500_000 }]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 0, owedTotalDong: 0 });
  });

  it('excludes voided penalties from both counts — a won appeal resolved them, too', () => {
    // Unreachable through a real penalty_current read (a voided penalty's own settlement is
    // superseded by the ruling's own correction — 20260825090000), but the switch this
    // function runs is exhaustive on PenaltyState, so this still has to compile and resolve
    // sensibly rather than fall through to the `default` throw.
    const summary = summarizeReferee([{ state: 'voided', amountDong: 500_000 }]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 0, owedTotalDong: 0 });
  });

  it('excludes collected penalties from both counts — the debt has changed hands (Story 4.7)', () => {
    const summary = summarizeReferee([
      { state: 'collected', amountDong: 500_000 },
      { state: 'owed', amountDong: 500_000 },
    ]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 1, owedTotalDong: 500_000 });
  });

  it('excludes waived penalties from both counts — a Grace Day resolved them, never owed (Story 5.1)', () => {
    const summary = summarizeReferee([
      { state: 'waived', amountDong: 500_000 },
      { state: 'owed', amountDong: 500_000 },
    ]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 1, owedTotalDong: 500_000 });
  });
});

describe('formatOwedDay', () => {
  it('includes the year, unlike formatDeadline', () => {
    expect(formatOwedDay(new Date('2026-08-18T00:00:00Z'))).toBe('Aug 18, 2026');
  });

  it('distinguishes two rows more than a year apart that formatDeadline would render identically', () => {
    const thisYear = formatOwedDay(new Date('2026-08-18T00:00:00Z'));
    const lastYear = formatOwedDay(new Date('2025-08-18T00:00:00Z'));
    expect(thisYear).not.toBe(lastYear);
  });
});

describe('collectionMessage', () => {
  it('reuses formatDong/formatOwedDay — the exact money formatting used everywhere else, plus the year', () => {
    // Verbatim from epic-4-context.md, with the planning doc's own literal comma-grouped
    // "500,000" replaced by formatDong's dot-grouped "500.000₫" (confirmed with the human),
    // and the day carrying its year — an owed Penalty persists indefinitely (this story's
    // own "never written off automatically"), so a bare "Aug 18" would be ambiguous for a
    // debt sitting unpaid more than a year.
    expect(collectionMessage(500_000, new Date('2026-08-18T00:00:00Z'))).toBe(
      "todoapp says you owe 500.000₫ for Aug 18, 2026. I'm just the one collecting it. When are you free?",
    );
  });

  it('attributes the demand to the app, never the referee', () => {
    const message = collectionMessage(500_000, new Date('2026-08-18T00:00:00Z'));
    expect(message).toMatch(/^todoapp says you owe/);
    expect(message).toContain("I'm just the one collecting it.");
  });

  it('names every amount distinctly — a different amount reads a different message', () => {
    const a = collectionMessage(500_000, new Date('2026-08-18T00:00:00Z'));
    const b = collectionMessage(1_000_000, new Date('2026-08-18T00:00:00Z'));
    expect(a).not.toBe(b);
  });
});
