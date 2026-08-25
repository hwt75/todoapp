import { describe, expect, it } from 'vitest';
import {
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
});
