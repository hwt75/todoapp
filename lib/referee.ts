/**
 * The Referee: his own account, his own way in, and the two numbers his home surface may
 * say (Story 4.5, FR-19).
 *
 * The server is the sole judge (AD-1). Every eligibility rule around pairing — that the
 * caller is a live doer, that no second referee exists — lives in `pair-referee`'s own Edge
 * Function, mirroring the split `lib/appeal.ts` already draws: this module carries only
 * what the client actually owns, the shape of what it sends, and the copy.
 */

import type { PenaltyState } from './ledger';

/** What Settings sends to the `pair-referee` Edge Function. Nothing else — the function
 *  derives everything about eligibility itself, never trusting a client-sent role or flag. */
export interface PairReferee {
  email: string;
}

/** The loosest check worth running before spending a round trip — the server is the real
 *  authority on whether an address is usable at all (mirrors `sign-in.tsx`'s own `canSubmit`). */
export function isPairableEmail(email: string): boolean {
  return email.includes('@');
}

/** What the Edge Function returns on success: an account and a password shown exactly once. */
export interface PairedReferee {
  email: string;
  password: string;
}

function hasStringField<K extends string>(value: unknown, key: K): value is Record<K, string> {
  return (
    typeof value === 'object' &&
    value !== null &&
    key in value &&
    typeof (value as Record<string, unknown>)[key] === 'string'
  );
}

/** `hasStringField`, plus refusing an empty string — a field present but blank is not a
 *  usable value, and treating it as one is how `{email: '', password: ''}` would have been
 *  rendered as a real, successful pairing. Only used by `isPairedReferee` below: the error
 *  path's own `{error: string}` body has no equivalent "empty means absent" reading — an
 *  empty error message is still a message the server chose to send. */
function hasNonEmptyStringField<K extends string>(
  value: unknown,
  key: K,
): value is Record<K, string> {
  return hasStringField(value, key) && value[key].length > 0;
}

/** Whether an Edge Function response body is the success shape, narrowed rather than cast.
 *  Requires both fields to be non-empty — a blank email or password is not a real pairing,
 *  and falls through to `REFEREE_PAIRING_COPY.noPassword` the same as a missing field would. */
export function isPairedReferee(data: unknown): data is PairedReferee {
  return hasNonEmptyStringField(data, 'email') && hasNonEmptyStringField(data, 'password');
}

/**
 * What one call to `supabase.functions.invoke('pair-referee', ...)` failed with, as a
 * sentence rather than a thrown class name.
 *
 * `functions.invoke` never rejects on a non-2xx response — it resolves with `error` set,
 * and the response body (the function's own `{ error: string }`) is reachable only through
 * `error.context`, a `Response` the caller has to read itself. Reading a `Response` body is
 * the one place this needs to be async; everything else in this module is pure.
 */
export async function refereeFunctionErrorMessage(
  error: { message?: string; context?: unknown } | null,
): Promise<string> {
  const fallback = error?.message ?? REFEREE_PAIRING_COPY.unreachable;
  const context = error?.context;

  if (!context || typeof (context as { json?: unknown }).json !== 'function') {
    return fallback;
  }

  try {
    const body: unknown = await (context as { json: () => Promise<unknown> }).json();
    if (hasStringField(body, 'error')) return body.error;
    return fallback;
  } catch {
    // The body was not JSON, or was already consumed. The generic message stands in.
    return fallback;
  }
}

/** Every string the Settings pairing row says. Kept here for the reason `APPEAL_COPY` gives:
 *  copy rules, testable independent of a component. */
export const REFEREE_PAIRING_COPY = {
  rowName: 'Referee',
  consequence:
    'The person who rules on a contested miss and collects what you owe. Paired once — ' +
    'there is no unpair or re-pair yet.',
  emailPlaceholder: 'referee@example.com',
  pair: 'Pair referee',
  pairing: 'Pairing…',
  failed: 'Not paired.',
  unreachable: 'The server could not be reached.',
  noPassword: 'The server did not return a password.',
  shownOnce:
    'Shown once. Relay it however you choose — text, call, in person. It is never emailed.',
  passwordLabel: 'One-time password:',
  paired: (email: string) => `Paired as ${email}.`,
} as const;

/** Every string the Referee's own login screen says (`components/referee-login.tsx`). No
 *  "Create account" path here — pairing is the only way a Referee account is ever made
 *  (Never boundary), so this screen offers sign-in and nothing else. */
export const REFEREE_LOGIN_COPY = {
  title: 'Referee sign-in',
  submit: 'Sign in',
  submitting: 'Signing in…',
  failed: 'Failed.',
  noSession:
    'Account found, but no session was issued. Ask the doer to re-pair if this keeps happening.',
} as const;

/** One row of `penalty_current`, the only shape `components/referee-home.tsx` reads.
 *  `state` is `lib/ledger.ts`'s own `PenaltyState`, not a redefined copy — a future state
 *  that type gains (`collected`, 4.7; `waived`, 5.1) becomes a compile error in the switch
 *  below rather than a row that silently counts toward neither total. */
export interface RefereePenaltyRow {
  state: PenaltyState;
  amountDong: number;
}

export interface RefereeSummary {
  pendingAppeals: number;
  owedCount: number;
  owedTotalDong: number;
}

/**
 * The two counts FR-19's home surface may show, and nothing else.
 *
 * `held` is exactly "pending appeal": `appeal_hold_penalty()` (Story 4.4) is the only writer
 * that ever moves a penalty to `held`, and it does so in the same transaction as the appeal
 * row, so counting held penalties counts open appeals without a second query joining
 * `appeal` at all. `dropped` (a timed-out appeal, resolved in the author's favour) is read
 * but deliberately excluded from both counts — it is neither pending nor owed.
 *
 * The `switch` is exhaustive on `PenaltyState` on purpose: a state this function does not
 * yet know what to do with fails the build rather than silently vanishing from both counts,
 * understating what the referee is shown.
 */
export function summarizeReferee(rows: readonly RefereePenaltyRow[]): RefereeSummary {
  let pendingAppeals = 0;
  let owedCount = 0;
  let owedTotalDong = 0;

  for (const row of rows) {
    switch (row.state) {
      case 'held':
        pendingAppeals++;
        break;
      case 'owed':
        owedCount++;
        owedTotalDong += row.amountDong;
        break;
      case 'dropped':
        break;
      default: {
        const exhaustive: never = row.state;
        throw new Error(`summarizeReferee: unhandled penalty state ${String(exhaustive)}`);
      }
    }
  }

  return { pendingAppeals, owedCount, owedTotalDong };
}

/** Every string `components/referee-home.tsx` says. Scoped to what `appeal`/`penalty_current`
 *  already answer (Boundaries): no live commitment count, no email-channel promise — neither
 *  exists yet for anyone, referee or author. */
export const REFEREE_HOME_COPY = {
  title: 'Referee',
  loading: 'Working…',
  failed: 'Failed.',
  signOut: 'Sign out',
  empty: 'Nothing for you right now. 0 appeals pending, 0 penalties owed.',
  pendingAppeals: (count: number): string => `${count} appeal${count === 1 ? '' : 's'} pending.`,
  owedPenalties: (count: number, totalLabel: string): string =>
    `${count} penalt${count === 1 ? 'y' : 'ies'} owed, ${totalLabel} total.`,
} as const;
