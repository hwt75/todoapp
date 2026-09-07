---
title: 'The reminder and the claim take the same lock'
type: 'bugfix'
created: '2026-09-07'
status: 'done'
baseline_commit: '16ab30adb661d2882c73f0645fb2409a4ed89a2f'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Two writers decide whether a due-time reminder should exist for one commitment on one
day, and neither can see the other mid-flight. `enqueue_due_time_reminder()` checks for a
declaration and then inserts the outbox row; `declaration_cancels_due_time_reminder()` deletes that
row after a claim is filed. A claim committing between the check and the insert satisfies neither
guard — the enqueuer looked before the declaration existed, the canceller looked before the outbox
row did — and the author is reminded, at the moment his window opens, to do a thing he has already
done and told the app about.

**Approach:** Give both paths the same per-commitment-day transaction advisory lock, so the two
possible orderings are the only two outcomes. Prove both with real concurrent sessions, including
that the loser genuinely waits on the lock rather than merely arriving late.

## Boundaries & Constraints

**Always:** Take the identical key on both sides; hold it from before the claimed-day check through
the enqueue; keep every existing refusal, the ninety-minute lookahead, the copy, the dedupe key and
the `new.for_day`-only cancellation exactly as they are; keep the cancellation unable to fail the
claim it runs inside.

**Ask First:** Change the lookahead, the reminder copy, the dedupe key, which days a claim cancels,
or the account-level lock protocol; make the cancellation raise instead of warn.

**Never:** Serialize two different commitments against each other — a doer answering several rows
at once must not wait on himself; let the lock turn a swallowed cancellation failure into a lost
claim; edit an applied migration.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Claim wins | Claim in flight, uncommitted; the pass reaches the same commitment-day | The enqueue waits, then reads the committed declaration and refuses | Returns false, as every refusal does |
| Enqueue wins | Reminder queued, uncommitted; the author files a claim | The claim waits, then its cancellation finds the row and deletes it | Claim commits normally |
| Either order | Both committed | The day carries no queued reminder, and the claim stands | N/A |
| Different commitments | Two claims on the same day, different commitments | Neither waits on the other | N/A |
| Lock unavailable | The cancellation cannot take the lock | Warned and swallowed, as the cancellation already is — a surviving reminder is an annoyance, a lost claim costs money | Existing warning path |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql:226-232,275` — the
  check and the insert the gap sits between.
- `.../20260903090000...sql:629-645` — the cancellation, which looks for a row that may not exist
  yet.
- `.../20260825110000_a_countable_way_to_be_forgiven.sql:156` — the `pg_advisory_xact_lock(hashtext(...))`
  idiom every existing serialization in this codebase uses, at account granularity.
- `scripts/test-current-penalty-race.mjs` — the two-session harness shape, including the
  `pg_stat_activity` wait-event assertion that makes a race test a serialization test.
- `.github/workflows/ci.yml:95` — where a harness of this kind is run on every push.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<generated>_the_reminder_and_the_claim_take_the_same_lock.sql` — take the
      commitment-day lock in both functions, preserving every existing branch, message and comment.
- [x] `scripts/test-due-reminder-race.mjs` — both winner orders with real concurrent sessions, each
      proving the loser waited on the advisory lock, and both ending with no queued reminder.
- [x] `.github/workflows/ci.yml` — run it on every push, beside the collection race.
- [x] `_bmad-output/implementation-artifacts/sprint-status.yaml` — item 40 tracked through
      implementation and remote parity.

**Acceptance Criteria:**
- Given a claim in flight and the pass reaching the same commitment-day, when the claim commits,
  then the enqueue waited on the lock and refuses.
- Given a reminder queued and uncommitted, when the author files a claim, then the claim waited on
  the lock and its cancellation deletes the row.
- Given either order, when both transactions have committed, then no reminder remains for that
  commitment-day.

## Spec Change Log

## Design Notes

The key is the commitment and the day, not the account. It is the narrowest key that covers the
fact being decided, and it deliberately leaves two different commitments' claims free of each other
— an author answering several rows at once has no reason to wait on himself. No path takes both
this lock and the per-account one, so there is no ordering between them to deadlock on; if one ever
does, it must take the account lock first, matching every existing caller.

The lock is taken part-way down `enqueue_due_time_reminder()` rather than at the top. Everything
above it is a cheap refusal no claim can change — gone, archived, untimed, wrong role, outside the
window — and an hourly pass over every commitment should not hold a lock for each one it was never
going to queue.

On the cancellation side the lock sits inside the same swallowing block as the cancel itself, for
the reason that block exists: this runs inside the author's own claim. A lock that cannot be taken
leaves a reminder that should have gone, which is an annoyance; an exception raised here would lose
the claim, which is what costs money.

## Verification

**Commands:**
- `node scripts/test-due-reminder-race.mjs` with both functions reverted to their
  `20260903090000` definitions — expected: fails, naming the writer that never waited.
- `node scripts/test-due-reminder-race.mjs` — expected: both orders pass.
- `npx supabase db reset`, then all `supabase/tests/*.sql` — expected: zero failures.
- `node scripts/test-current-penalty-race.mjs` — expected: the account-level lock is unaffected.
- `npm test`, `npm run lint`, `npm run format:check` — expected: clean.
- `npm run migrations:check` — expected: local-only until a separately authorized push.

**Results (2026-09-07):**

- Test-first — with `enqueue_due_time_reminder()` and `declaration_cancels_due_time_reminder()`
  restored to their `20260903090000` definitions, the harness failed exactly as designed:
  *"due-reminder-race-enqueue-second never waited on the advisory lock."* Its captured output shows
  the enqueue returning `t` — it queued a reminder for a day whose claim was already in flight,
  which is the defect verbatim. Applying the migration turns both orders green with no edit to the
  harness.
- `node scripts/test-due-reminder-race.mjs` — passed both orders: claim-first (the enqueue waits,
  then refuses) and enqueue-first (the claim waits, then its cancellation deletes the row), each
  ending with no queued reminder and the claim intact.
- `npx supabase db reset` — passed; every migration, including `20260907110000`, applies from
  scratch.
- All 38 `supabase/tests/*.sql` — passed, 0 failures, including Story 6.6's own reminder file.
- `node scripts/test-current-penalty-race.mjs` — passed; the account-level lock is untouched.
- `npm test` — passed, 50 files and 1326 tests. The count rose by three without a test being
  written: `lib/roles.test.ts` enumerates `supabase/migrations/` and runs three security
  assertions per migration, so the new file brought its own, and they pass.
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero result: `20260907110000` is local-only until a
  separately authorized push.

**Remote parity (2026-09-07):**

- `npx supabase db push` — `20260907110000` applied to `hxzalpnlrunctbajgtkv`. The migration is
  `create or replace function` plus its comments and one revoke; no DDL touches a table and no
  statement writes a row.
- Local and remote both carry all 66 migrations.
- Checked on the live project rather than assumed: both `enqueue_due_time_reminder` and
  `declaration_cancels_due_time_reminder` now contain `pg_advisory_xact_lock`, and the
  `due-time-reminders` cron job is still present and active — the pass that meets this lock every
  hour is the one that was already running.
- Security advisor — no new finding. Neither function appears on the `security definer` warning
  list, because both remain revoked from `anon` and `authenticated`; the list is unchanged from
  before this push.
