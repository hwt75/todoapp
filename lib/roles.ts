/**
 * The two ways a policy may learn an account's role, and which one it is allowed to use.
 *
 * The project resolves role twice on purpose (AD-12, refined in
 * `spec-2-1-sign-in-as-the-doer.md`): a fast reading from the JWT claim for reads, and an
 * authoritative reading from the profile table for writes and anything touching money.
 *
 * Two sources of truth for one question is a real cost. It is paid for by this file plus
 * `roles.test.ts`, which fails the build when a write policy reaches for the fast one —
 * so the rule is enforced rather than remembered by whoever writes the next migration.
 */

export type AppRole = 'doer' | 'referee';

export const APP_ROLES: readonly AppRole[] = ['doer', 'referee'] as const;

export const ROLE_HELPERS = {
  /**
   * `public.role_from_token()` — reads the `app_role` claim the auth hook stamped into
   * the access token. Costs nothing and is **stale** until the token refreshes. Returns
   * null when the claim is absent, so a policy built on it denies rather than grants.
   *
   * Permitted in `using (...)`. Never in `with check (...)`.
   */
  read: 'role_from_token',

  /**
   * `public.role_from_table()` — reads the profile row. Always current, so revoking a
   * referee bites immediately. Costs one indexed primary-key lookup, which at this
   * product's scale is free.
   *
   * Required in `with check (...)`, and in any policy guarding money.
   */
  write: 'role_from_table',
} as const;

/**
 * Clauses a policy can carry, and whether the fast helper is acceptable inside one.
 *
 * `using` filters which existing rows a statement may see or touch; a stale role there
 * costs a read that should have been denied, bounded by the token's lifetime. `with
 * check` decides whether a new or modified row is allowed to exist — a stale role there
 * writes a row that should never have been written, and no later refresh undoes it.
 */
export const CLAUSE_MAY_USE_TOKEN_HELPER = {
  using: true,
  'with check': false,
} as const;
