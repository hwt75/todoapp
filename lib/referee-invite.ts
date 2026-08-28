/**
 * The invitation half of the referee's account: what Settings sends to mint one, what the
 * signup screen sends to spend one, and every string either of them says.
 *
 * The split `lib/referee.ts` draws is drawn again here, for the same reason (AD-1): the
 * server is the sole judge. Whether the caller is the live doer, whether a referee already
 * exists, whether this token is outstanding and unexpired — none of that is decided in this
 * module, and none of it is re-derived from anything the client holds. What lives here is
 * the shape of the two requests, the narrowing of the two replies, and the copy.
 *
 * The one rule this module does own is the password floor, and it owns a *copy* of it:
 * `accept-referee-invite` enforces eight characters and is the authority, this file states
 * the same number so the button can be disabled before a round trip. The number appearing
 * twice is the cost; a form that lets you type six characters, submit, and be told no is the
 * thing being bought.
 */

import { ZONE } from './declaration';

/** The floor `accept-referee-invite` actually enforces. See the module comment: a deliberate
 *  second copy of a server-owned rule, kept for the disabled state of one button. */
export const MIN_REFEREE_PASSWORD_LENGTH = 8;

/** What Settings sends to `invite-referee`. The address, and nothing else — the function
 *  derives eligibility itself, exactly as `PairReferee` does for the direct path. */
export interface InviteReferee {
  email: string;
}

/** What `invite-referee` returns: the address the invitation is bound to, the token in the
 *  clear for the only time it ever exists that way, and when it stops working. */
export interface MintedInvite {
  email: string;
  token: string;
  expiresAt: string;
}

/** What `accept-referee-invite` returns. The address is echoed rather than assumed: the
 *  signup screen never knew it — the token carries no address, by design — so this is where
 *  the referee first learns which account they just created. */
export interface AcceptedInvite {
  email: string;
}

function hasNonEmptyStringField<K extends string>(
  value: unknown,
  key: K,
): value is Record<K, string> {
  return (
    typeof value === 'object' &&
    value !== null &&
    key in value &&
    typeof (value as Record<string, unknown>)[key] === 'string' &&
    (value as Record<string, string>)[key].length > 0
  );
}

/** Whether a reply is a real minted invitation. All three fields non-empty, for the reason
 *  `isPairedReferee` gives: a blank token rendered as a working link is worse than an error,
 *  because it looks like success and fails in someone else's hands. */
export function isMintedInvite(data: unknown): data is MintedInvite {
  return (
    hasNonEmptyStringField(data, 'email') &&
    hasNonEmptyStringField(data, 'token') &&
    hasNonEmptyStringField(data, 'expiresAt')
  );
}

export function isAcceptedInvite(data: unknown): data is AcceptedInvite {
  return hasNonEmptyStringField(data, 'email');
}

/**
 * The link the doer relays.
 *
 * `origin` is passed in rather than read from `window` here so this stays a pure function the
 * tests can call — and so the one caller that has to think about which origin it is on does
 * that thinking in the component, where `window.location.origin` is actually correct.
 *
 * The token goes in the query string, not the path. A path segment would land in the Next
 * router's own route params and, more to the point, in any server access log that records
 * paths — this app has no such log today, but the choice costs nothing and the alternative
 * has to be right forever.
 */
export function inviteLink(origin: string, token: string): string {
  return `${origin.replace(/\/+$/, '')}/referee/signup?token=${encodeURIComponent(token)}`;
}

/** The check that disables the button, and nothing more. Length only: every other property
 *  of a good password is the referee's business, and a client-side complexity rule here would
 *  be a second, drifting copy of a rule the server does not actually have. */
export function isAcceptablePassword(password: string): boolean {
  return password.length >= MIN_REFEREE_PASSWORD_LENGTH;
}

/** Both fields, and that they agree. The confirmation field exists because this password is
 *  typed once and never emailed — a typo would create an account nobody can sign into, and
 *  the invitation that could have created it is spent. */
export function canAcceptInvite(password: string, confirmation: string): boolean {
  return isAcceptablePassword(password) && password === confirmation;
}

/** When the invitation stops working, as something a reader can act on. Date *and* time,
 *  unlike `formatDeadline`'s date-only shape: an appeal deadline is midnight by construction,
 *  while this one is 72 hours after whatever moment the doer pressed the button, so naming
 *  only the date would round a Tuesday-morning expiry to "Tuesday" and be wrong by most of a
 *  day in the direction that matters. */
export function formatInviteExpiry(expiresAt: string): string {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: ZONE,
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(expiresAt));
}

/** Every string the Settings invitation row says. Kept here for the reason `APPEAL_COPY`
 *  and `REFEREE_PAIRING_COPY` give: copy rules, testable independent of a component. */
export const REFEREE_INVITE_COPY = {
  invite: 'Create invite link',
  inviting: 'Creating…',
  failed: 'Not invited.',
  notReadable: 'Outstanding invitations could not be read.',
  noLink: 'The server did not return an invite link.',
  // The two buttons do different things to the same unrepeatable slot, and the difference is
  // who ends up knowing the password. Stated rather than implied by the labels.
  choice:
    'An invite link lets the referee choose their own password, which you never see. ' +
    'Pairing creates the account now and shows you a password to relay.',
  minted: (email: string) => `Invitation for ${email}.`,
  linkLabel: 'Invite link:',
  expiresAt: (expiresAt: string) => `Works until ${formatInviteExpiry(expiresAt)}.`,
  // The same Never boundary `REFEREE_PAIRING_COPY.shownOnce` states, and it has to be stated
  // again rather than referenced: this link is a bearer token, so "relay it" and "anyone who
  // holds it becomes the referee" are one instruction, not two.
  shownOnce:
    'Shown once. Anyone holding this link can become the referee, so relay it the way you ' +
    'would a password — text, call, in person. It is never emailed.',
  copy: 'Copy link',
  copied: 'Copied.',
  outstanding: (email: string, expiresAt: string) =>
    `An invitation for ${email} is outstanding until ${formatInviteExpiry(expiresAt)}. ` +
    'Creating another one replaces it.',
} as const;

/** Every string `components/referee-signup.tsx` says. */
export const REFEREE_SIGNUP_COPY = {
  title: 'Choose your password',
  // Names no address, because this screen genuinely does not know one until the server
  // answers — the token carries no email (20260828120000). Promising "for ref@example.com"
  // here would mean trusting a query parameter to say who you are.
  intro:
    'This link makes you the referee. Choose a password — the person who invited you will ' +
    'never see it.',
  passwordPlaceholder: `Password, at least ${MIN_REFEREE_PASSWORD_LENGTH} characters`,
  confirmationPlaceholder: 'Repeat the password',
  submit: 'Create my account',
  submitting: 'Creating…',
  failed: 'Failed.',
  missingToken:
    'This page needs an invitation link. Ask the person who invited you to send it again.',
  mismatch: 'The two passwords do not match.',
  // The account exists but no session came back. Distinct from a failure, because retrying
  // the link cannot help — the invitation is spent — while signing in normally will.
  noSession: (email: string) =>
    `Account created for ${email}, but no session was issued. Sign in at /referee/login.`,
} as const;
