import { describe, expect, it } from 'vitest';
import { bodyStatesItsTime, buildPayload, payloadProblems, type PushPayload } from './outbox';

const AT = new Date(2026, 7, 19, 7, 30, 0);

function payload(overrides: Partial<PushPayload> = {}): PushPayload {
  return { ...buildPayload('todoapp', 'Yesterday is still unanswered.', AT), ...overrides };
}

describe('a payload the outbox would accept', () => {
  it('has a title, a body and an instant', () => {
    expect(payloadProblems(payload())).toEqual([]);
  });

  it('stamps the send time into the body, not only the metadata', () => {
    // The metadata is invisible on a lock screen. The body is the only part the author
    // can read without opening anything, which is where the time has to be.
    expect(buildPayload('todoapp', 'Yesterday is still unanswered.', AT).body).toContain('07:30');
  });

  it('records the instant as ISO-8601', () => {
    expect(() => new Date(payload().sent_at).toISOString()).not.toThrow();
  });
});

describe('a payload that would lie by the time it is read', () => {
  // Story 1.2 watched a push arrive minutes after it was sent, once the phone rejoined
  // Wi-Fi. Anything describing the present is a claim about a moment the sender cannot
  // know.
  it.each([['right now'], ['just now'], ['currently'], ['at the moment']])(
    'is refused for saying "%s"',
    (trap) => {
      const bad = payload({ body: `You are ${trap} behind. (07:30)` });
      expect(payloadProblems(bad).join(' ')).toContain(trap);
    },
  );

  it('is refused when the body carries no time at all', () => {
    const bad = payload({ body: 'Yesterday is still unanswered.' });
    expect(payloadProblems(bad).join(' ')).toContain('cannot be told from a new one');
  });

  it('is refused for a body that carries the wrong time', () => {
    // A stale template that hard-codes an hour would pass a naive "contains a colon" check.
    const bad = payload({ body: 'Yesterday is still unanswered. (09:15)' });
    expect(payloadProblems(bad).length).toBeGreaterThan(0);
  });

  it.each([
    ['an empty title', { title: '   ' }],
    ['an empty body', { body: '   ' }],
    ['a nonsense instant', { sent_at: 'yesterday-ish' }],
  ])('is refused for %s', (_label, overrides) => {
    expect(payloadProblems(payload(overrides)).length).toBeGreaterThan(0);
  });
});

describe('bodyStatesItsTime', () => {
  it('matches the hour and minute of the instant', () => {
    expect(bodyStatesItsTime(payload())).toBe(true);
  });

  it('pads a single-digit hour, so 07:05 is not written 7:5', () => {
    const early = buildPayload('todoapp', 'Morning.', new Date(2026, 7, 19, 7, 5, 0));
    expect(early.body).toContain('07:05');
    expect(bodyStatesItsTime(early)).toBe(true);
  });

  it('is false for an unparseable instant rather than throwing', () => {
    expect(bodyStatesItsTime(payload({ sent_at: 'not a date' }))).toBe(false);
  });
});
