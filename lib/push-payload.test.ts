import { describe, expect, it } from 'vitest';
import { PUSH_FALLBACK, resolvePushContent } from './push-payload';

describe('resolvePushContent', () => {
  it('reads title and body from a well-formed payload', () => {
    const raw = JSON.stringify({ title: 'todoapp', body: 'Test push, 14:32.' });
    expect(resolvePushContent(raw)).toEqual({ title: 'todoapp', body: 'Test push, 14:32.' });
  });

  // The send script puts the time in the body precisely so a fresh delivery can be
  // told from one left over on the lock screen. It has to survive intact.
  it('does not alter the body it is given', () => {
    const body = 'Test push, 09:41:07. Reading this on the lock screen means the channel works.';
    expect(resolvePushContent(JSON.stringify({ title: 't', body })).body).toBe(body);
  });

  describe('falls back rather than showing nothing', () => {
    it.each([
      ['malformed JSON', 'not json at all'],
      ['an empty string', ''],
      ['whitespace only', '   '],
      ['null', null],
      ['undefined', undefined],
      ['a JSON null', 'null'],
      ['a JSON array', '[1,2,3]'],
      ['a JSON string', '"just a string"'],
      ['a JSON number', '42'],
    ])('%s', (_label, raw) => {
      expect(resolvePushContent(raw)).toEqual(PUSH_FALLBACK);
    });
  });

  // Per-field, not all-or-nothing: the body is the half that has to be legible
  // on a lock screen, so a missing title must never cost us a present body.
  describe('falls back per field', () => {
    it('keeps a good body when the title is missing', () => {
      const result = resolvePushContent(JSON.stringify({ body: 'The day closed. You missed one.' }));
      expect(result).toEqual({ title: PUSH_FALLBACK.title, body: 'The day closed. You missed one.' });
    });

    it('keeps a good title when the body is missing', () => {
      const result = resolvePushContent(JSON.stringify({ title: 'Yesterday' }));
      expect(result).toEqual({ title: 'Yesterday', body: PUSH_FALLBACK.body });
    });

    it.each([
      ['empty', ''],
      ['whitespace', '  '],
      ['a number', 7],
      ['null', null],
      ['an object', { nested: true }],
    ])('replaces a body that is %s', (_label, body) => {
      expect(resolvePushContent(JSON.stringify({ title: 'todoapp', body })).body).toBe(
        PUSH_FALLBACK.body,
      );
    });
  });

  it('never returns an empty title or body, whatever it is given', () => {
    const inputs = ['', '{}', 'garbage', JSON.stringify({ title: '', body: '' }), null];
    for (const raw of inputs) {
      const { title, body } = resolvePushContent(raw);
      expect(title.trim()).not.toBe('');
      expect(body.trim()).not.toBe('');
    }
  });
});
