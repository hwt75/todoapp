import { describe, expect, it } from 'vitest';
import {
  MIN_REFEREE_PASSWORD_LENGTH,
  REFEREE_INVITE_COPY,
  REFEREE_SIGNUP_COPY,
  canAcceptInvite,
  formatInviteExpiry,
  inviteLink,
  isAcceptablePassword,
  isAcceptedInvite,
  isMintedInvite,
} from './referee-invite';

/**
 * The client's half of the invitation, which is deliberately small: a link, a length, and
 * two narrowings. Everything that decides whether an invitation may exist or may be spent
 * lives in the two Edge Functions, so what is worth testing here is precisely the places a
 * bad server reply or a careless caller could produce something that *looks* like it worked.
 */

describe('the link the doer relays', () => {
  it('points at the signup route with the token in the query string', () => {
    expect(inviteLink('https://example.app', 'tok-abc')).toBe(
      'https://example.app/referee/signup?token=tok-abc',
    );
  });

  it('does not double the slash when the origin carries a trailing one', () => {
    // `window.location.origin` never has one, but a hand-typed base URL in a future caller
    // would, and `https://example.app//referee/signup` is a 404 on some hosts and a redirect
    // on others — neither of which the referee should have to survive.
    expect(inviteLink('https://example.app/', 'tok-abc')).toBe(
      'https://example.app/referee/signup?token=tok-abc',
    );
  });

  it('escapes a token that carries URL-significant characters', () => {
    // The generated token is base64url and cannot contain these. That is exactly why the
    // escaping is asserted rather than assumed: the alphabet is a property of a function in
    // another runtime, and if it ever widens, the link must still be a link.
    expect(inviteLink('https://example.app', 'a+b/c=d&e')).toBe(
      'https://example.app/referee/signup?token=a%2Bb%2Fc%3Dd%26e',
    );
  });
});

describe('narrowing what the server sent', () => {
  it('accepts a complete invitation', () => {
    expect(isMintedInvite({ email: 'r@example.com', token: 't', expiresAt: '2026-08-31' })).toBe(
      true,
    );
  });

  it.each([
    ['no token', { email: 'r@example.com', expiresAt: '2026-08-31' }],
    ['a blank token', { email: 'r@example.com', token: '', expiresAt: '2026-08-31' }],
    ['no expiry', { email: 'r@example.com', token: 't' }],
    ['a blank email', { email: '', token: 't', expiresAt: '2026-08-31' }],
    ['nothing at all', null],
    ['a bare string', 'ok'],
  ])('refuses %s', (_case, body) => {
    expect(isMintedInvite(body)).toBe(false);
  });

  it('narrows an acceptance by its email alone', () => {
    expect(isAcceptedInvite({ email: 'r@example.com' })).toBe(true);
    expect(isAcceptedInvite({ email: '' })).toBe(false);
    expect(isAcceptedInvite({})).toBe(false);
  });
});

describe('the password floor', () => {
  it('is the number the copy promises', () => {
    // The placeholder is the only place the referee learns the rule before typing. If the
    // constant moves and the sentence does not, the form refuses a password it invited.
    expect(REFEREE_SIGNUP_COPY.passwordPlaceholder).toContain(String(MIN_REFEREE_PASSWORD_LENGTH));
  });

  it('rejects one character short and accepts exactly the floor', () => {
    expect(isAcceptablePassword('x'.repeat(MIN_REFEREE_PASSWORD_LENGTH - 1))).toBe(false);
    expect(isAcceptablePassword('x'.repeat(MIN_REFEREE_PASSWORD_LENGTH))).toBe(true);
  });

  it('requires the confirmation to agree, not merely to be long enough', () => {
    expect(canAcceptInvite('longenough', 'longenough')).toBe(true);
    expect(canAcceptInvite('longenough', 'longenaugh')).toBe(false);
    expect(canAcceptInvite('short', 'short')).toBe(false);
  });
});

describe('the expiry a reader acts on', () => {
  it('names a time as well as a date', () => {
    // 2026-08-31T03:00:00Z is 10:00 in Asia/Ho_Chi_Minh. A date-only rendering would say
    // "Aug 31" for an invitation that dies before most of that day has happened.
    const label = formatInviteExpiry('2026-08-31T03:00:00.000Z');
    expect(label).toContain('Aug 31');
    expect(label).toContain('10:00');
  });

  it('is the same string the outstanding notice uses', () => {
    // Two sentences about one instant. They drift the moment one of them formats its own.
    const expiresAt = '2026-08-31T03:00:00.000Z';
    expect(REFEREE_INVITE_COPY.outstanding('r@example.com', expiresAt)).toContain(
      formatInviteExpiry(expiresAt),
    );
    expect(REFEREE_INVITE_COPY.expiresAt(expiresAt)).toContain(formatInviteExpiry(expiresAt));
  });
});

describe('what the copy must keep saying', () => {
  it('warns that the link itself is the credential', () => {
    // The one thing a reader can get catastrophically wrong: treating the link as an
    // address rather than as a password. `pair-referee`'s own copy has the equivalent line.
    expect(REFEREE_INVITE_COPY.shownOnce).toMatch(/anyone holding this link/i);
    expect(REFEREE_INVITE_COPY.shownOnce).toMatch(/never emailed/i);
  });

  it('tells the doer which of the two buttons keeps the password away from him', () => {
    expect(REFEREE_INVITE_COPY.choice).toMatch(/never see/i);
  });

  it('promises the referee the same thing from the other side', () => {
    expect(REFEREE_SIGNUP_COPY.intro).toMatch(/never see it/i);
  });
});
