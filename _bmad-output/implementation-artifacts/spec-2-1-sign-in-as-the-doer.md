---
title: 'Story 2.1 — Sign in as the doer'
type: 'feature'
created: '2026-08-19'
status: 'awaiting-approval'
baseline_commit: '62c653b'
review_loop_iteration: 0
story_key: '2-1-sign-in-as-the-doer'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **NOT YET APPROVED.** Drafted, not agreed. Read the Role resolution note below before
> approving — it records a decision you made and a tension it creates with this story's own
> acceptance criteria, and that is the part worth your attention rather than the task list.

## Intent

**Problem:** Nothing in this product belongs to anyone yet. Every commitment, declaration, penalty
and verdict that Epic 2 records has to be attributable to an account and governed by that account's
role, and the two roles — doer and referee — read and write disjoint sets of rows. Getting this wrong
is not a bug that shows up as a broken screen; it is a bug that shows up as the referee reading the
doer's private ledger, or the doer writing his own verdict, long after either is cheap to fix.

**Approach:** The first migration, and with it the conventions every later migration inherits: an
account profile carrying a role, row-level security on that table from the moment it exists, and the
two role-resolution helpers that every later policy will call. Email sign-in, because it is the only
provider the project has enabled. No screens beyond what signing in requires.

## Boundaries & Constraints

**Always:**
- Every table carries RLS from the migration that creates it. Not a follow-up migration — the same
  one. A table that exists for one deploy without RLS has been readable by anyone holding the
  publishable key for that deploy.
- Authorization is expressed in policies, never in application code. A client-side role check is
  presentation only.
- Every schema change arrives as a numbered migration. Nothing is applied by hand in the dashboard
  and back-filled into a file afterwards.

**Ask First:**
- Any policy that grants the doer write access to a penalty, verdict or settlement row. AD-8 gives
  those a single writer and it is settlement.
- Enabling a second auth provider, or turning off email confirmation.

**Never:**
- No service-role key in this repository, in the client bundle, or in a Vercel environment variable.
  It bypasses every policy in this story.
- No `using (true)` policy, and no table with RLS enabled but zero policies left as "we will tighten
  it later". Both read as secure and are not.
- No commitment, day, penalty or settlement tables. This story establishes the account and the
  conventions; the domain tables belong to the stories that use them.

## Role resolution — the decision, and the tension it creates

**Decided:** the hybrid. Read paths test the role from the JWT claim; write paths and anything
touching money test it from the profile table.

**The tension, stated rather than buried.** This story's second acceptance criterion says the role
*"is never trusted from a client-held claim"*, and the read paths now do exactly that. The reading
under which the two agree: the JWT is signed by Supabase's auth server and cannot be forged or edited
by the client, so it is not the client *asserting* its own role — which is what AD-12 exists to
prevent. What it can be is **stale**, for as long as the access token lives.

That staleness is the whole reason the write and money paths do not use it. Revoking a referee takes
effect immediately everywhere a decision costs something, and lags only on reads until the next token
refresh.

**If that reading is wrong, this is the place to say so** — changing it later means rewriting every
policy written after this story.

**The risk this creates, and what is done about it.** Two sources of truth for one question means
every future policy has to remember which kind it is, and a write policy that reaches for the fast
one is a silent authorization hole. So the two helpers are named to be impossible to confuse, and a
test fails the build when a `with check` clause references the JWT helper. The rule is not left to
whoever writes the next migration to remember.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| First sign-in | Valid email, no profile yet | Profile row created with role `doer`, owned by the auth user | Profile creation is not the client's job; a failure must not leave an auth user with no profile |
| Sign-in, existing account | Valid email | Session established; role read server-side | — |
| Reading another account's profile | Authenticated as doer, requests another id | Zero rows. Not an error — RLS filters rather than refuses | A `403` would confirm the row exists |
| Client claims a role it does not have | Forged local state saying `referee` | No effect on any read or write; policies never consult it | — |
| Role changed in the table | Doer promoted or referee revoked | Write and money paths honour it immediately; reads follow at token refresh | The lag is the accepted cost of the hybrid |
| Unauthenticated request | Publishable key only, no session | Zero rows from every table | The key alone grants nothing |

</frozen-after-approval>

## Code Map

- `supabase/migrations/` -- does not exist yet. This story creates it, and its first file sets the
  conventions every later migration copies.
- `.env`, `.env.example` -- already carry `NEXT_PUBLIC_SUPABASE_URL` and
  `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, verified against the live project.
- `lib/install-state.ts`, `lib/push-payload.ts` -- the shape to copy: the rule extracted into a pure
  module and tested, with the component left holding nothing but plumbing.
- `app/page.tsx` -- currently the install instruction and the push probe. Sign-in joins it; do not
  restructure, Epic 2's Today screen replaces this page.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/0001_account_and_roles.sql` -- the `app_role` type, the `profile` table
  keyed to `auth.users`, RLS enabled in the same statement block, the owner-only policies, the two
  role helpers, and the trigger that creates a profile on sign-up -- one file because a profile table
  without its policies is a window, however short.
- [ ] `lib/supabase/client.ts`, `lib/supabase/server.ts` -- browser and server clients reading the
  publishable key -- separated because the server client carries the session cookie and the browser
  client must never be handed one built for another request.
- [ ] `lib/roles.ts` -- the two helper names and which path each belongs to, as typed constants the
  policy test asserts against -- so the read/write split is stated in one place rather than
  remembered.
- [ ] `lib/roles.test.ts` -- fails when any `with check` clause in any migration references the JWT
  helper -- this is the guard that makes the hybrid safe to live with.
- [ ] `components/sign-in.tsx`, `app/page.tsx` -- email sign-in, and the session state the page shows
  -- minimal; the real surfaces are later stories.
- [ ] `README.md` -- how to apply migrations, and that the service-role key never leaves Supabase.

**Acceptance Criteria:**
- Given Supabase Auth is configured, when the author signs in, then a profile exists carrying his
  role, and the role was read server-side rather than asserted by the client.
- Given any table this story creates, then RLS is enabled and at least one policy exists, and a test
  fails if a future migration adds a table without both.
- Given a request holding only the publishable key and no session, then every table returns zero rows.
- Given a `with check` clause that reads the role from the JWT, then the suite fails naming the file
  and the policy.
- Given the client's local state claims a role it does not hold, then no read or write changes.

## Design Notes

**Email confirmation is on** (`mailer_autoconfirm: false`, verified against the live project), and
email is the only enabled provider. For one author signing in on his own phone that is a small extra
step, not a problem — but it means the first sign-in needs a reachable inbox, and it is worth knowing
before wondering why nothing happens.

**Applying the migration is the author's step**, the same way deploying and installing were. The CLI
runs through `npx supabase` and needs either a login or a database password, neither of which belongs
in this repository. The migration file is written and verified here; running it is a step in the
README.

**The spine may want updating.** AD-12 says the role is "read from the session server-side" without
choosing a mechanism. The hybrid is a refinement of it, not a contradiction, but `ARCHITECTURE-SPINE.md`
is a human-owned artifact and this spec does not edit it. Consider adding the refinement there once
this is approved.

## Verification

**Commands:**
- `npx supabase db lint` -- expected: the migration parses
- `npm test` -- expected: the RLS-coverage and `with check` guards pass alongside the existing 67
- `npm run build && npm run lint && npm run format:check` -- expected: clean
- `grep -rniE "service_role|secret_key" app components lib .env.example` -- expected: no matches
  outside comments forbidding them

**Manual checks (if no CLI):**
- Sign in on the deployed app; a profile row appears with role `doer`
- With the session cleared, every table returns zero rows rather than an error
- Changing the role in the table takes effect on a write immediately
