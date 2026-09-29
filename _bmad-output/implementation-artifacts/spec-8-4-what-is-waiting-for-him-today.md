---
title: 'Story 8.4 — What is waiting for him today'
type: 'feature'
created: '2026-09-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'd685cefe1c51ec3e10a4ffc5c0e615c4f9e09965'
story_key: '8-4-what-is-waiting-for-him-today'
context:
  - '{project-root}/_bmad-output/specs/spec-commitments-the-referee-signs-off/SPEC.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-8-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-8-3-the-photograph-reaches-the-referee.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 8.2 and 8.3 let the referee decide a flagged commitment-day and open the
photograph behind it, but nothing shows him which days those are. `sign_off_day()` has no caller:
the mechanism exists and cannot be reached (CAP-6).

**Approach:** One `security definer` function that names today's flagged commitment-days of his
paired doer that have a photograph and no decision, and a section on his home screen that lists
them with the photograph and two controls — mark it done, or refuse it with a reason. The section
is absent when there is nothing in it.

## Boundaries & Constraints

**Always:** Today only (resolved server-side in `Asia/Ho_Chi_Minh`), his paired doer only, no
history. The list's row gate is `photograph_reaches_the_referee()` — the one door 8.3 built — and
the flag is never read live. The client never derives a date: `for_day` comes back from the
function and is passed to `sign_off_day()` unchanged (AD-6). `sign_off_day()` stays the sole judge;
the screen only mirrors facts to decide whether a control renders, and shows any refusal verbatim.
Each row's status is keyed by its own id. The refuse control requires a reason before it submits
and says the refusal is final. Nothing nags, counts, or implies a duty: no badge, no number, no
"n waiting", no deadline pressure, and no empty state at all.

**Ask First:** Any change to `sign_off_day()`'s decision logic, to settlement, to
`referee_day_lookup()`, or to either referee policy. Any referee notification. Placing the list
anywhere but the referee home.

**Never:** No author notification (8.5 owns it) — so no copy on this side may say the author has
been told. No Today change for the author (8.6). No history, archive, or "done today" tally. No
withdrawal. No RLS grant on `settlement_commitment`, `referee_decision` or
`commitment_requires_referee_approval_change`.

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| Waiting | Flagged as of today, photo (either parentage), no decision | Listed, photos signed in one call |
| Unflagged | Same, flag off as of today | Not listed |
| Flag turned on this morning | Unflagged at today's start | Not listed — forward only |
| Flag turned off this morning | Flagged at today's start | Still listed |
| No photo yet | Flagged, nothing attached | Not listed |
| Decided | Approved or refused | Not listed |
| Yesterday | Flagged, photo, no decision | Not listed |
| Archived | Commitment archived | Not listed |
| Not his doer / not a referee | Other account, or a doer session | Nothing, never an error |
| Nothing waiting | Empty result | Section absent; home's own lines unchanged |
| Refusal not offered | No penalty as of today, or cadence `weekly_quota`/`daily_hours_quota` | Only "done" renders |
| Approve | Tap | Row stays, says it is marked; controls gone |
| Refuse | Reason typed, tap | Row stays, says it is refused; nothing claims the author was told |
| Server refuses | e.g. midnight passed, already decided | Its words, on that row only; nothing reloads |
| A photo will not sign | One path fails | Counted on its row, never dropped |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql:62-118` —
  `photograph_reaches_the_referee(commitment, day)`, the gate this list must call. Its body holds
  the only copy of the parentage union. `:306-535` `sign_off_day()` — refusal guards to mirror
  (`carries_penalty_as_of`, `weekly_quota`, `daily_hours_quota`, archived), untouched.
- `supabase/migrations/20260908180000_a_photo_does_not_outlive_its_usefulness.sql:147-189` —
  `referee_day_lookup()`, the shape to copy (definer, `role_from_table() = 'referee'`,
  `paired_doer_id()`, `swept_at is null` on paths). Not modified.
- `supabase/migrations/20260914140000_referee_day_lookup_lost_its_acl.sql` — why the new function
  needs explicit revoke/grant.
- `supabase/migrations/20260914090000_...refusal_costs.sql:39-133` — `referee_decision`, unique on
  `(subject, for_day, commitment_id)`; `:180-189` why no referee policy exists on it.
- `components/referee-home.tsx` — host screen; `markStatus`/`markErrors` keyed-by-id pattern
  (`:80-81`, `:288-303`); `REFEREE_HOME_COPY.empty` at `:345`.
- `components/referee-day-lookup.tsx:180-201,318-349,365-406` — batched signing, unopenable
  count, reason textarea + final warning. Model for the controls; not modified.
- `lib/referee.ts:490-623` — `RefereeDayRow`, `objectionIsOffered` (facts-not-verdict mirror),
  `REFEREE_DAY_COPY`, `formatWindowClose`.
- `supabase/tests/8-3-the-photograph-reaches-the-referee.sql:660-722` — step 7 asserts one
  expression of the rule and that `referee_day_lookup()` stays narrowed; must pass unmodified.
- `supabase/tests/2-1-roles-and-rls.sql:720-750` — step 9, the referee's doors in both directions.

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql` — (i) move the
      parentage union out of `photograph_reaches_the_referee()` into one definer helper returning
      the commitment-day's evidence rows (path, swept_at, created_at), and `create or replace` the
      predicate onto it, decision unchanged; (ii) `referee_waiting_today()` returning
      `commitment_id, commitment_name, for_day, carries_penalty, cadence, evidence_paths` — gated
      by the predicate, excluding decided and archived, paths from the helper with `swept_at is
      null`; revoke `public, anon`, grant `authenticated`, both helpers' ACLs stated.
- [x] `lib/referee.ts` — `RefereeWaitingRow`, `refusalIsOffered(row)`, `REFEREE_WAITING_COPY`,
      `SIGN_OFF_REASON_MAX = 2000` (mirrors `referee_decision_says_why`).
- [x] `components/referee-home.tsx` — load the list with the rest, sign all paths in one call,
      render the section above "Look up a day" only when non-empty, suppress
      `REFEREE_HOME_COPY.empty` when it renders, per-row `sign_off_day` calls with keyed status.
- [x] `lib/referee.test.ts`, `components/referee-home.test.tsx` — every UI row of the matrix;
      copy asserted by regex in both directions (no digits, no "waiting for you"/"queue"/"pending",
      no "told"/"notified" on the refused line).
- [x] `supabase/tests/8-4-what-is-waiting-for-him-today.sql` — every DB row of the matrix, both
      parentages, both flag-moved-today directions, ACL both ways, and a catalog check that the
      union appears only in the helper.
- [x] `supabase/tests/2-1-roles-and-rls.sql` — add the function to step 9 and the helper to the
      commented exclusions.
- [x] `_bmad-output/specs/spec-timed-commitments-with-photo-proof/SPEC.md` — the owed amendment:
      CAP-5 and the "referee approval queue" non-goal are superseded by Epic 8 CAP-6.
- [x] `sprint-status.yaml` — 8-4 status.

**Acceptance Criteria:**

- Given `sign_off_day()`, both referee policies and the new list, when the parentage union
  changes, then all four change — it is written once.
- Given every pre-existing file in `supabase/tests/`, when run after this migration, then each
  passes unmodified except `2-1-roles-and-rls.sql`.
- Given two waiting rows, when one is refused and the server rejects it, then only that row shows
  the error and the other's controls are untouched.

## Design Notes

**Why the union moves.** 8.3 wrote "which photograph" once, in a boolean. A list needs the *paths*,
and aggregating them here would write the union a fourth time — the Epic 6 item 50 shape 8.3's
step 7 exists to catch. Splitting "which rows" (helper) from "may he see them" (predicate) keeps one
copy. The predicate still does not filter `swept_at`; the list does, as `referee_day_lookup()` does.

**Facts, not a verdict.** Returning `carries_penalty`/`cadence` and mirroring in
`refusalIsOffered` follows `objectionIsOffered`. A `refusable` column would be a second copy of
`sign_off_day()`'s guards.

**Copy direction.** Intro in the shape of `REFEREE_DAY_COPY.intro`: what these are, and that saying
nothing lets each day hold at midnight. Approval says it changes nothing.

## Verification

**Commands:**

- `npx supabase db reset`, then every file in `supabase/tests/` — all pass.
- `npm test`, `npx tsc --noEmit`, `npm run lint`, `npm run format:check`, `npm run build` — clean.
- `npm run migrations:check` — reports only the new file as not on the remote.

**Manual checks:**

- `grep -n "join public.declaration d on d.id = e.declaration_id" supabase/migrations/20260929*` —
  exactly one hit, inside the helper.

**Run 2026-09-29, implementation.**

- `npx supabase db reset`, then all 49 files under `supabase/tests/` — **all pass.** Every
  pre-existing file passed unmodified except `2-1-roles-and-rls.sql`, as the AC allows.
  `8-3-the-photograph-reaches-the-referee.sql` passing unmodified — step 7 included — is what proves
  the predicate decides exactly what it did before its union moved into the helper.
  `node scripts/test-sign-off-race.mjs` and `node scripts/test-current-penalty-race.mjs` — both PASS.
- `npm test` — 1508 passed, 53 files. `npx tsc --noEmit`, `npm run lint`, `npm run format:check`,
  `npm run build` — clean.
- `npm run migrations:check` — **not run: this machine is not `supabase link`ed** to the remote,
  and the script fails hard on that by design. Expected result once linked: `20260929090000` alone
  not on the remote.
- The manual grep — one hit, `:64`, inside `commitment_day_photographs()`. Step 3 of the new SQL
  file asserts the same against the catalog across every `public` function.

**Six mutants watched, each caught.**

| Mutant | Caught by |
| --- | --- |
| Decided rows no longer excluded | `8-4` step 1 — the list names more than the four |
| Swept filter dropped from the paths | `8-4` step 1 — *"Wanted its kept photograph and not the swept one"* |
| Archived no longer excluded | `8-4` step 1 — the list names five |
| `refusalIsOffered` always true | 6 failures — the three `it.each` UI rows and the three lib rows |
| Empty line not suppressed under a list | `referee-home.test.tsx` — *"lists each waiting day…"* |
| Client-derived date sent to `sign_off_day()` | `referee-home.test.tsx` — *"passes back the day the server named…"* |

**Two departures from the task list, both recorded rather than silent.**

- *The helper went into `2-1-roles-and-rls.sql`'s must-be-revoked array, not its commented
  exclusions.* The task assumed a granted helper, as 8.3's were. This one is revoked from every
  client role because both its callers are `security definer`, so the array — which asserts exactly
  that — is where it belongs; the exclusions are for functions granted on purpose. Step 6's notice
  now says thirty-nine.
- *The Epic 6 SPEC amendment was already made*, on 2026-09-10, in that file's CAP-5 and its
  approval-queue non-goal. Nothing was added there. The stale "owes an amendment" line in this
  epic's own SPEC Open Questions is struck through and says so.

## Review — 2026-09-29

Three layers (blind, edge-case, verification-gap), run as subagents on the full diff. **No
`intent_gap` and no `bad_spec`**, so no loopback. Five patches applied, one deferral, the rest
rejected on evidence:

- **Patched.** A test for the AC exactly as written — a *refusal* the server rejects stays on its
  row with his reason still in the box (the first test clicked Mark done). A test that both
  controls are disabled and busy while a decision is in flight and a double tap sends one call —
  watched to fail with `disabled={busy}` removed. A test for a signing call that fails outright.
  `refusalNotOffered` said "this kind of commitment", which is false for a daily one that simply
  carries no penalty today; it now says "today". The struck Open Question in the epic SPEC had left
  its original instruction readable as outstanding; the whole of it is struck now.
- **Deferred** (`deferred-work.md`): a photo that signs and then fails to load, or whose URL
  expires while the screen is open, is uncounted on every referee photo surface — pre-existing
  since Story 6.7.
- **Rejected, with the reason checked rather than assumed.** A row appearing twice through both
  union arms: `evidence_exactly_one_parent` (`20260903120000:79-85`) makes it impossible. `cadence`
  read live while `carries_penalty` is read as of the day: `sign_off_day()` reads cadence live too
  (`v_commitment.cadence`), so the mirror matches its judge. A listed row whose every photo is
  swept: the sweeper takes only photos past retention, never today's. A failed list read failing
  the whole screen: every read on this screen already does, and one section behaving differently
  is its own inconsistency. Digits in `proofLoadFailed`/`proofAlt`: those count photographs on a
  row, not days owed, which is what the no-number rule is about.

After the patches: `npm test` 1511 passed; `tsc`, `lint`, `format:check`, `build` clean; all 49
SQL files pass.

## Suggested Review Order

**The one door, and what moved behind it**

- The parentage union, moved out of the predicate so the list can have paths without a copy.
  [`20260929090000:44`](../../supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql#L44)

- The predicate re-created on it — same decision, grant and policies untouched.
  [`20260929090000:83`](../../supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql#L83)

**The list**

- Today only, his paired doer only, facts not a verdict.
  [`20260929090000:124`](../../supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql#L124)

- The row gate is the same predicate `sign_off_day()` and both policies ask.
  [`20260929090000:162`](../../supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql#L162)

- Swept paths filtered here, as `referee_day_lookup()` does; the predicate does not.
  [`20260929090000:154`](../../supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql#L154)

- Explicit revoke and grant — the ACL `referee_day_lookup()` once lost.
  [`20260929090000:185`](../../supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql#L185)

**The screen**

- Read with the rest; the day comes back from the server.
  [`referee-home.tsx:217`](../../components/referee-home.tsx#L217)

- One RPC per decision, its words on its row, nothing reloads.
  [`referee-home.tsx:390`](../../components/referee-home.tsx#L390)

- The section exists only when non-empty — no drained-queue state.
  [`referee-home.tsx:642`](../../components/referee-home.tsx#L642)

- "Nothing for you right now" steps aside above a list.
  [`referee-home.tsx:454`](../../components/referee-home.tsx#L454)

**What it may say**

- The mirror: two facts `sign_off_day()` checks that a client can see.
  [`referee.ts:661`](../../lib/referee.ts#L661)

- The copy — no count, no duty, and never "he has been told".
  [`referee.ts:683`](../../lib/referee.ts#L683)

**The proofs**

- Exactly four rows listed; every excluded one absent by name.
  [`8-4-…sql:289`](../../supabase/tests/8-4-what-is-waiting-for-him-today.sql#L289)

- The union written once, asserted against the catalog.
  [`8-4-…sql:399`](../../supabase/tests/8-4-what-is-waiting-for-him-today.sql#L399)

- The screen's matrix rows, including in-flight and a rejected refusal.
  [`referee-home.test.tsx:948`](../../components/referee-home.test.tsx#L948)

- Copy rules asserted over every fixed string.
  [`referee.test.ts:403`](../../lib/referee.test.ts#L403)

- The helper in the must-be-revoked array; the list among his doors.
  [`2-1-roles-and-rls.sql:596`](../../supabase/tests/2-1-roles-and-rls.sql#L596)
