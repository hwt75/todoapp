---
title: 'Story 4.5 — The referee has his own way in'
type: 'feature'
created: '2026-08-24'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'a004d535edca189c9664a92945e075fda28c5711'
story_key: '4-5-the-referee-has-his-own-way-in'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The referee has no account, no way to sign in, and no schema that lets him read
anything at all — Appeal (4.4) writes rows nobody but the author can see. Story 4.6 (rule) and
4.7 (collect) both need a referee who can already sign in and already see only what concerns him.

**Approach:** A one-time-password pairing flow from Settings (an Edge Function holding the
service-role key, the only place this codebase permits one, mirroring `outbox-worker`'s own
shape) creates the referee's account and sets `profile.role = 'referee'`. A separate `/referee`
route pair (login + home) reads that role and shows only Appeals and Penalties, enforced by new
RLS policies — never by the route itself.

## Boundaries & Constraints

**Always:**
- Every access rule lives in RLS (AD-7) — the `/referee` route redirecting a non-referee session
  is UX polish, never the enforcement boundary.
- The service-role key lives only inside the new Edge Function's Supabase-managed environment
  (`Deno.env`), exactly as `lib/supabase/server.ts`'s own header comment requires. It is never
  read, forwarded, or proxied by any Next.js server or client code.
- `handle_new_user()`'s trigger keeps deciding `role` itself — it must never read
  `raw_user_meta_data` (or any other client-suppliable field) to decide a role. A referee account
  is created as an ordinary `role = 'doer'` row by the trigger, then promoted to `'referee'` by a
  second, separate write the Edge Function makes with its own service-role client — never by
  trusting anything the `createUser` call's caller supplied.
- One referee at most (Non-Goal: "no second Referee... beyond the single doer–Referee pair").
  Pairing refuses if a `role = 'referee'` profile already exists.
- Read-only for the referee, throughout: no policy on `appeal`, `appeal_evidence`, `penalty`,
  `settlement`, or `commitment` grants a referee role `insert`/`update`/`delete`. Ruling (4.6) and
  collecting (4.7) are separate, later stories.
- The referee's new read policies use `role_from_token()` (`lib/roles.ts`'s own `read`/`write`
  split) — this story adds no write path for a referee, so `role_from_table()` is never needed
  here.

**Ask First:** None — the pairing UX (Settings row → email input → one-time password shown once)
and the route split (`/referee/login`, `/referee`) both follow directly from existing precedent
(Settings' own "absent, not disabled" comment; AD-12's routing note) with no unresolved fork.

**Never:**
- No email delivery. No SMTP is configured anywhere in this project (`supabase/config.toml`'s own
  commented-out block); the one-time password is displayed once in the author's own UI for him to
  relay however he chooses (text, call, in person) — never emailed, never a Supabase Auth invite
  link.
- No signup flow for the referee, self-service or otherwise. `sign-in.tsx`'s existing "Create
  account" path is the doer's own onboarding and is untouched; the referee route offers sign-in
  only.
- No unpair/re-pair flow. If pairing needs to change, that is a later story's own decision, not
  this one's default.
- No ruling controls (*He did it* / *He didn't*, 4.6) and no collection controls (Mark Collected,
  a copyable message, 4.7) on the referee home surface yet — those stories build them. This
  story's non-empty states show only a count and a total, not per-item detail or actions.
- The empty-state's progress crumb does not attempt EXPERIENCE.md's illustrative "4 of 5 today"
  (today's live commitment count has no existing referee-safe read, and building one is not
  this story's goal) or its "You'll get an email if that changes" (no email channel exists yet
  for anyone, referee or author — 4.6/4.7 will need to build one). Substitute honest copy scoped
  to what `appeal`/`penalty_current` already answer: pending-appeal and owed-penalty counts, both
  zero in the default state.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| First pairing | Doer submits a referee email, no referee profile exists yet | Edge Function creates the account, promotes it to `referee`, returns a one-time password shown once in Settings | N/A |
| Re-pairing attempt | A `role = 'referee'` profile already exists | Edge Function refuses with a clear reason; nothing created | Settings shows the refusal, no account created |
| Non-doer calls the Edge Function | Caller's own `profile.role <> 'doer'` (read live, not from the token) | Refused (403), no account created | N/A |
| Referee signs in | Valid referee email/password at `/referee/login` | Redirected to `/referee`, sees only Appeals/Penalties counts | N/A |
| Referee reads doer-only data | Referee session queries `declaration`/`chain_current`/`focus_session`/`commitment` location fields directly | RLS returns zero rows — no policy grants a referee role read access | N/A |
| Doer lands on `/referee` | A `doer`-role session opens `/referee` directly | Redirected away (client-side); RLS would return nothing referee-scoped for him anyway | N/A |
| Empty state | Referee signed in, zero appeals held, zero penalties owed | The specified empty-state copy (adapted per Boundaries) | N/A |
| Non-empty state | 1+ pending appeal or 1+ owed penalty | A count and total, no per-item detail/actions | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819120000_account_and_roles.sql` -- `app_role` enum (`'referee'`
  already exists), `profile` table (no update policy for any client — role changes only via a
  trusted server path), `handle_new_user()` trigger (unconditionally inserts `role = 'doer'` —
  never touched by this story), `role_from_token()`/`role_from_table()`.
- `lib/roles.ts` -- the `read`/`write` helper split this story's new referee policies must follow
  (`role_from_token()` for every new read-only policy).
- `lib/supabase/server.ts:12-14` -- the explicit, load-bearing rule: no service-role client in
  this Next.js codebase, ever.
- `supabase/functions/outbox-worker/index.ts` -- the exact Edge-Function shape to mirror: reads
  `SUPABASE_SERVICE_ROLE_KEY`/`SUPABASE_URL` from `Deno.env`, builds one service-role client at
  module scope, `Deno.serve` handler. New: `supabase/functions/pair-referee/index.ts`.
- `components/sign-in.tsx` -- the email/password `signInWithPassword` shape to reuse for the
  referee's own login component; its own "Create account" `signUp` path is NOT reused (Never).
- `components/settings.tsx:34-37` -- the exact comment marking referee pairing as "absent rather
  than disabled" — this story fills that row.
- `supabase/tests/2-1-roles-and-rls.sql` -- the RLS-privilege test pattern (two accounts, assert
  one reads/writes what it should and the other reads nothing) to mirror for every new referee
  policy.
- `app/page.tsx` -- current single entry point; add the role check redirecting a referee session
  away to `/referee` (UX only, per Boundaries).
- New: `app/referee/login/page.tsx`, `app/referee/page.tsx`, `components/referee-login.tsx`,
  `components/referee-home.tsx`, `lib/referee.ts` (pairing draft/copy, mirroring `lib/appeal.ts`'s
  own style).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/functions/pair-referee/index.ts` -- new Edge Function: verify caller is a live
  `doer` (read `profile.role` via the caller's own forwarded JWT, never the admin client, for this
  check), refuse if a `referee` profile already exists, else `auth.admin.createUser()` + a
  service-role `update profile set role = 'referee'` on the new row, return `{email, password}`
  once
- [x] `supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql` -- RLS:
  `role_from_token() = 'referee'` read policies on `appeal`, `appeal_evidence`,
  `penalty`(`_current`), `settlement`(`_current`) scoped to `kind = 'day'`/`'week'` as FR-19
  requires (Penalties and Appeals only), and on `commitment` (name only needed for future stories,
  but no column-level RLS exists in Postgres, so this grants full row read — documented in the
  migration); explicit absence of any referee policy on `declaration`, `chain_current`,
  `focus_session`, `push_subscription`, or any location-bearing table. Also adds
  `profile_single_referee`, a partial unique index enforcing "one referee at most" at the database
  level rather than only in the Edge Function's own check-then-act read.
- [x] `lib/referee.ts` -- pairing draft/response shapes, copy strings (mirrors `lib/appeal.ts`)
- [x] `components/settings.tsx` -- fill the referee-pairing row: email input, calls the Edge
  Function via `supabase.functions.invoke('pair-referee', ...)`, shows the one-time password once
- [x] `components/referee-login.tsx` + `app/referee/login/page.tsx` -- email/password sign-in only
- [x] `components/referee-home.tsx` + `app/referee/page.tsx` -- reads appeal/penalty counts,
  renders empty or non-empty state per the I/O Matrix
- [x] `app/page.tsx` -- redirect a `referee`-role session to `/referee`
- [x] `supabase/tests/4-5-the-referee-has-his-own-way-in.sql` -- new RLS test: a referee reads
  appeal/penalty rows and nothing from declaration/chain/focus_session/commitment location data; a
  doer cannot read another account's referee-scoped rows either way; both roles' policies proven
  independently

**Acceptance Criteria:**
- Given a doer with no paired referee, when he submits a referee email from Settings, then a
  referee account exists with `role = 'referee'` and a one-time password is shown once
- Given a referee profile already exists, when pairing is attempted again, then it is refused with
  nothing created
- Given a signed-in referee, when he opens `/referee`, then he sees only appeal/penalty counts —
  never a Declaration, chain, focus session, or location value, by RLS (AD-7)
- Given no pending appeals and no owed penalties, when the referee opens `/referee`, then the
  empty state renders
- Given the referee's surface, then it requires no notification permission (NFR3) and is fully
  keyboard-navigable with no focus traps (NFR15)

## Spec Change Log

## Design Notes

**Why an Edge Function, not a Next.js Server Action.** `lib/supabase/server.ts`'s own comment is
explicit and pre-existing: "There is no service-role client in this codebase and there must not
be... the one place it may ever live is Supabase's own Edge Function environment." Creating
another account's `auth.users` row has no RLS-gated path — it is inherently a service-role
operation — so it must be an Edge Function, invoked directly by the doer's browser via
`supabase.functions.invoke()` (not the `net.http_post`/Vault path `wake_outbox_worker()` uses,
which exists for a cron job with no user session to carry; here a live doer session already
exists and can authenticate the call itself).

**Why promote-after-create, not metadata-driven role.** `auth.admin.createUser()`'s
`user_metadata` lands in `raw_user_meta_data`, which `supabase.auth.signUp()` — the *client's*
own, unprivileged call — can also set. A trigger that trusted that field to pick `role` would let
any self-service signup write `app_role: 'referee'` into its own metadata and promote itself,
recreating exactly the class of forgery Story 4.4 closed for `declaration.filed_by`. Two writes
(create as the trigger's own default `'doer'`, then a second, service-role-only `update`) costs
one extra round trip and closes that hole entirely.

## Verification

**Commands, run 2026-08-24, against the local stack:**
- `npx supabase db reset` -- all 39 migrations, including
  `20260824160000_the_referee_has_his_own_way_in.sql`, applied clean; the `appeal-evidence`
  Storage bucket created on the same reset.
- All 20 files under `supabase/tests/` via `docker exec supabase_db_todoapp psql -v
  ON_ERROR_STOP=1` -- **19/20 pass**; `3-2-focus-prompt.sql` self-refuses outside 07:00-20:00
  Asia/Ho_Chi_Minh wall-clock (pre-existing, unrelated to this story -- it was outside that window
  when this ran). `4-5-the-referee-has-his-own-way-in.sql`'s 5 steps all pass: `profile_single_
  referee` refuses a second referee profile; a referee session reads every appeal, every piece of
  evidence, and every day/week settlement and penalty across two separate doer accounts (proving
  the new policies are not owner-scoped); it reads every commitment column including
  `auto_check_account_ref`; it reads zero rows of `declaration`, `chain_current`, `focus_session`
  and `push_subscription`, proven against real rows that exist for the fixture account (not an
  empty table); and a plain `doer`-token session reads none of that referee-only width either.
  Every other pre-existing test file continues to pass unchanged.
- `npm test` -- **781/781 pass** across 38 files, including new `lib/referee.test.ts`,
  `components/referee-login.test.tsx`, `components/referee-home.test.tsx`, plus new cases added to
  `app/page.test.tsx` (referee redirect) and `components/settings.test.tsx` (the pairing row,
  replacing the old "referee is absent" assertion).
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.

**Manual checks, run 2026-08-24, against the local stack (no live project available in this
environment -- see below):**
- `npx supabase start` (a full stop/start, not merely a container restart, was needed for the
  local edge-runtime to discover the newly added `pair-referee` function at all).
- Signed up a real doer account via `/auth/v1/signup`, then called `pair-referee` with its access
  token as `Authorization`: created the referee, returned `{email, password}` once. Confirmed
  `profile.role = 'referee'` on the new row directly in the database. **Correction (2026-08-25
  independent review):** as written, this step cannot be accurate on its own. `pair-referee`
  refuses any caller whose `profile.is_live_doer` is not `true`
  (`supabase/functions/pair-referee/index.ts`, the `role !== 'doer' || !is_live_doer` check), and
  `is_live_doer` defaults `false` with nothing in this codebase setting it automatically
  (`20260819220000_settlement.sql:20`) — every other place this flag needs to be `true` sets it by
  hand. A fresh `/auth/v1/signup` account's profile would read `is_live_doer = false` and should
  have been refused at that check, not paired. Whether an `update profile set is_live_doer = true`
  was run by hand before this step — the same kind of ad-hoc, not-migrated workaround the database
  bullet below already discloses for a different local-stack gap — was not recorded at the time and
  cannot be reconstructed with confidence now, so this bullet is flagged rather than left standing
  as an unqualified success claim. It does not cast doubt on the refusal paths below, which were
  exercised independently of whatever made this first call succeed.
- Immediately re-paired with the same doer session: refused with `"A referee is already paired.
  There is no re-pairing yet."` (409), and no second `auth.users`/`profile` row was created.
- Called `pair-referee` as the newly paired referee's own session (a `doer`-only action attempted
  by a non-doer): refused with `"Only the live doer account may pair a referee."` (403).
- Called `pair-referee` with no `Authorization` header at all: refused with `"Sign in as the doer
  before pairing a referee."` (403).
- Signed in as the referee via `/auth/v1/token?grant_type=password` with the one-time password:
  succeeded, and the referee's own session reads `profile.role = 'referee'` back through RLS.
- The referee's session read `/rest/v1/declaration` and `/rest/v1/appeal` through PostgREST
  directly (not through the SQL test harness): both returned `200 []` -- filtered by RLS rather
  than refused, matching AD-7's own "filters rather than refuses" convention.
- Database reset afterward (`npx supabase db reset`) to leave the local environment clean; the
  ad-hoc `grant select`/`grant select, update` statements run by hand during this exercise (to
  work around the local stack's own missing default table grants for `authenticated`/`service_
  role` -- the same documented gap `2-1-roles-and-rls.sql`'s own header explains) were never
  written to any migration and did not survive the reset.
- **Not run in this environment:** `npx supabase functions deploy pair-referee` against the real
  live project, and the `/referee/login` -> `/referee` UI flow in an actual browser. This
  environment has no authenticated `supabase` CLI session and no browser tooling for this repo;
  deploying and clicking through the pairing/sign-in flow on the live project is the one piece of
  this story's own Verification section that still needs a human (or an environment with live
  project credentials) to run and record.

## Suggested Review Order

**Server-side authorization for pairing (the entry point)**

- The one place a service-role client may live in this codebase; verify the caller is a live doer before creating anything.
  [`pair-referee/index.ts:79`](../../supabase/functions/pair-referee/index.ts#L79)

- The gate this story exists to get right: not just `role = 'doer'`, but `is_live_doer` — closes the self-registered-stranger takeover this story's own Design Notes describe.
  [`pair-referee/index.ts:99`](../../supabase/functions/pair-referee/index.ts#L99)

- Two separate writes, deliberately: create through the ordinary trigger, promote only with a second service-role update — never trusting client-supplied metadata for role.
  [`pair-referee/index.ts:122`](../../supabase/functions/pair-referee/index.ts#L122)

- Password generation using base64url's own substitution, corrected during review from a skewed `x`/`z` mapping.
  [`pair-referee/index.ts:161`](../../supabase/functions/pair-referee/index.ts#L161)

**RLS: the actual enforcement boundary (AD-7)**

- `profile_single_referee` — the database-level guarantee of "one referee at most," independent of the Edge Function's own check-then-act read.
  [`20260824160000_the_referee_has_his_own_way_in.sql:23`](../../supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql#L23)

- The referee's read-only widening on `appeal`/`appeal_evidence` — not owner-scoped, by design, since there is at most one referee.
  [`20260824160000_the_referee_has_his_own_way_in.sql:56`](../../supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql#L56)

- Same shape on `settlement`/`penalty`, scoped to `kind in ('day','week')` per FR-19.
  [`20260824160000_the_referee_has_his_own_way_in.sql:90`](../../supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql#L90)

- `commitment` reads its full row width for the referee — a documented, accepted trade-off (no column-level RLS in Postgres), recorded in `deferred-work.md`.
  [`20260824160000_the_referee_has_his_own_way_in.sql:125`](../../supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql#L125)

- Proves the read-only boundary from the other side: the referee session attempting insert/update/delete against all five tables and being refused.
  [`4-5-the-referee-has-his-own-way-in.sql:388`](../../supabase/tests/4-5-the-referee-has-his-own-way-in.sql#L388)

**Doer-side redirect (UX polish, never the boundary)**

- The render-time reset that keeps a referee session from ever rendering one frame of the previous account's stale role — adjusted during render per React's own guidance, not inside the Effect.
  [`page.tsx:68`](../../app/page.tsx#L68)

- Where that role is actually read, and why an error resolves to `null` rather than closing the screen forever.
  [`page.tsx:78`](../../app/page.tsx#L78)

- The blocking guard: nothing doer-shaped renders while the role read is in flight or a redirect is about to fire.
  [`page.tsx:104`](../../app/page.tsx#L104)

**Client pairing UX (Settings)**

- The row this story fills in — one call to the Edge Function, nothing decided client-side.
  [`settings.tsx:182`](../../components/settings.tsx#L182)

- The success/failure shapes the pairing row renders from — password shown once, refusal shown verbatim.
  [`referee.ts:76`](../../lib/referee.ts#L76)

- Narrowed during review to reject an empty-string email/password rather than rendering it as a successful pairing.
  [`referee.ts:55`](../../lib/referee.ts#L55)

**Referee's own surfaces (sign-in and home)**

- Sign-in only, deliberately not reusing `sign-in.tsx`'s "Create account" path.
  [`referee-login.tsx:1016`](../../components/referee-login.tsx#L1016)

- The home surface's own guard: a count and a total, and the two redirects (signed-out, non-referee) that keep the wrong session off it.
  [`referee-home.tsx:30`](../../components/referee-home.tsx#L30)

- Uses the imported `PenaltyState` union (corrected during review from a hand-rolled cast) so a future penalty state fails the build here rather than silently miscounting.
  [`referee-home.tsx:79`](../../components/referee-home.tsx#L79)

**Tests and peripherals**

- The write-refusal proof added during review — the one I/O boundary the original test suite asserted only by omission.
  [`4-5-the-referee-has-his-own-way-in.sql:591`](../../supabase/tests/4-5-the-referee-has-his-own-way-in.sql#L591)

- Proves the account-switch role reset actually does something, rather than only ever firing as a no-op on first mount.
  [`page.test.tsx`](../../app/page.test.tsx)

- The pairing row's own tests: success, verbatim refusal, disabled/enabled button states.
  [`settings.test.tsx`](../../components/settings.test.tsx)

- Referee home and login component tests: empty/non-empty states, both redirects, no notification permission, no focus trap.
  [`referee-home.test.tsx`](../../components/referee-home.test.tsx)

- Copy/shape unit tests, including the new empty-string rejection case.
  [`referee.test.ts`](../../lib/referee.test.ts)

- Where the deferred findings from this story's own review are recorded.
  [`deferred-work.md`](../../_bmad-output/implementation-artifacts/deferred-work.md)
