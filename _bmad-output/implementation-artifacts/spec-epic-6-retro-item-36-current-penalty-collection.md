---
title: 'Collection follows the Penalty that still stands'
type: 'bugfix'
created: '2026-09-06'
status: 'done'
baseline_commit: '74c246ac71fb6b3705a7ea5163eb946bfb37bcf0'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A referee can collect an old Penalty id after `object_to_day()` copies
that debt into a correction. The RPC succeeds while the Ledger still shows the
replacement as owed, so one day can be collected twice. Collection can also race
the objection between its unlocked read and copy.

**Approach:** Make every collection operate only on the Penalty whose settlement
still stands, and serialize `object_to_day()` with collection using the existing
per-account transaction advisory lock. Prove both winner orders with real concurrent
database sessions, plus a deterministic stale-id regression in the SQL suite.

## Boundaries & Constraints

**Always:** Keep role checks first. Validate the paired account before
`object_to_day()` locks it. Under the lock, re-read every mutable fact used to move
money. Collection requires no successor to the target settlement, in both its clear
guard and final update. Preserve Grace Day exclusion, one Penalty per day,
atomicity, `security definer`, empty `search_path`, and authenticated-only execution.
Concurrency fixtures run only on local/preview Postgres and clean up afterward.

**Ask First:** Change an RPC signature, schema object, amount/state model, an existing
refusal outside the stale-Penalty case, or apply the migration remotely.

**Never:** Edit an applied migration. Collect a Penalty belonging to a superseded
settlement. Add a row lock before the account advisory lock. Claim concurrency from
a static function-body check or a one-session transaction. Test against the live
doer account.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Current collection | Current day has one owed Penalty | It becomes collected once | Repeat keeps existing resolved refusal |
| Stale screen | Objection copied old owed Penalty to a correction; caller submits old id | No row changes; replacement remains the sole current owed Penalty | Clear refresh/current-Penalty refusal |
| Collection wins | Collector locks first | Objection waits, sees collected state and writes no correction | Existing collected-day refusal |
| Objection wins | Objection holds account lock before collector | Collector waits, then sees its settlement was superseded | Stale/current-Penalty refusal |
| Grace Day | A Grace Day already claims the current day | Collection remains refused | Existing Grace Day message |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260826120000_the_lock_the_collector_never_took.sql:18-86`
  — current collector: lookup, account lock, Grace Day guard and owed update. Do not edit.
- `supabase/migrations/20260903140000_the_referee_may_object.sql:399-721` — current
  `object_to_day()`: paired-account scope at 443-461, currentness check at 467,
  Penalty read at 531 and copy at 668. Read-only precedent; do not edit.
- `supabase/migrations/20260827120000_settlement_current_spells_its_own_columns.sql:18-23`
  — canonical leaf predicate: no row whose `supersedes = s.id`.
- `supabase/tests/6-7-the-referee-may-object.sql:742-847` — Account C retains the
  original owed Penalty id through an objection; reuse it for the sequential stale-id
  failure and postconditions.
- `supabase/tests/epic-5-retro-2026-08-26-fixes.sql:191-208` — documents why the
  single-session SQL suite cannot prove lock behavior.
- `.github/workflows/ci.yml`, `supabase/tests/README.md` — wire and document the
  two-session harness outside the transactional SQL loop.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/tests/6-7-the-referee-may-object.sql` — first add the failing stale
  original-id regression, including unchanged historical and current Penalty state.
- [x] `supabase/migrations/<generated>_collection_follows_the_current_penalty.sql` —
  create with `supabase migration new`; replace only both RPCs/comments. The collector
  rejects superseded targets under its lock and repeats currentness in the update.
  The objection locks after account scope, before currentness and Penalty reads.
- [x] `scripts/test-current-penalty-race.mjs` — drive both winner orders, prove the
  loser waits on an advisory lock, enforce a timeout, assert state, and clean up.
- [x] `.github/workflows/ci.yml`, `supabase/tests/README.md` — run and document the
  race harness separately from rollback-only SQL files.

**Acceptance Criteria:**
- Given an objection has superseded an owed Penalty, when the referee collects its
  old id, then the RPC refuses and exactly one current owed replacement remains.
- Given either RPC holds the account lock, when the other starts for the same day,
  then it waits; after the winner commits, it re-reads state and refuses without a
  second collection or correction.
- Given a current owed Penalty with no Grace Day, when collected, then it becomes the
  only collected current Penalty and a repeat remains idempotently refused.

## Spec Change Log

## Design Notes

Each participant takes at most one account lock; no row lock precedes it. The final
collector update keeps a currentness predicate in case a future correction writer
forgets the shared lock.

## Verification

**Commands:**
- SQL test file through local container `psql -v ON_ERROR_STOP=1` — stale id refused.
- `node scripts/test-current-penalty-race.mjs` — both winner orders pass and cleanup.
- All `supabase/tests/*.sql` against local Supabase — 0 failures.
- `npm test`, `npm run lint`, `npm run format:check`, `npm run build` — clean.
- `npm run migrations:check` — expected local-only migration before any authorized push.

**Results (2026-09-06):**

- `npx supabase db reset` — passed; every migration applied from scratch.
- All 38 `supabase/tests/*.sql` files — passed against the reset local stack.
- `node scripts/test-current-penalty-race.mjs` — passed both winner orders and cleanup.
- `npm test` — passed, 50 files and 1312 tests.
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero result: migration `20260906080451` is
  local-only until a separately authorized push.

**Review rerun (2026-09-07):**

- `node --check scripts/test-current-penalty-race.mjs` and `git diff --check` — passed.
- `npx supabase db reset` — passed; every migration, including `20260906080451`,
  applied from scratch to the local stack.
- All 38 `supabase/tests/*.sql` files — passed.
- `node scripts/test-current-penalty-race.mjs` — passed both winner orders, the
  strengthened correction/objection/outbox and `collected_at` assertions, and cleanup.
- `npm test` — passed, 50 files and 1312 tests.
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero result: migration `20260906080451`
  remains local-only; no remote push was authorized or attempted.

## Suggested Review Order

**Database serialization**

- Collector takes the account lock before re-reading mutable Penalty state.
  [`20260906080451_collection_follows_the_current_penalty.sql:40`](../../supabase/migrations/20260906080451_collection_follows_the_current_penalty.sql#L40)

- Historical Penalty ids receive a clear refresh refusal under the lock.
  [`20260906080451_collection_follows_the_current_penalty.sql:55`](../../supabase/migrations/20260906080451_collection_follows_the_current_penalty.sql#L55)

- Money moves only while the target settlement remains the current leaf.
  [`20260906080451_collection_follows_the_current_penalty.sql:76`](../../supabase/migrations/20260906080451_collection_follows_the_current_penalty.sql#L76)

- Objection joins the same account serialization boundary before deciding money.
  [`20260906080451_collection_follows_the_current_penalty.sql:185`](../../supabase/migrations/20260906080451_collection_follows_the_current_penalty.sql#L185)

**Concurrent proof**

- Objection-first proves waiting, correction shape, notification, and untouched history.
  [`test-current-penalty-race.mjs:271`](../../scripts/test-current-penalty-race.mjs#L271)

- Collection-first proves objection refusal and atomic `collected_at` stamping.
  [`test-current-penalty-race.mjs:330`](../../scripts/test-current-penalty-race.mjs#L330)

- Sequential regression pins stale-screen refusal and the unchanged replacement debt.
  [`6-7-the-referee-may-object.sql:853`](../../supabase/tests/6-7-the-referee-may-object.sql#L853)

- Existing Grace Day refusal remains unchanged and sequentially verified.
  [`4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql:470`](../../supabase/tests/4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql#L470)

**Delivery and follow-up**

- DB CI pins Node 22 before running the two-session harness.
  [`ci.yml:60`](../../.github/workflows/ci.yml#L60)

- CI runs concurrent proof after the rollback-only SQL suite.
  [`ci.yml:95`](../../.github/workflows/ci.yml#L95)

- Test documentation explains isolation, safety guard, and container override.
  [`README.md:36`](../../supabase/tests/README.md#L36)

- Review discoveries outside this fix remain explicit, bounded follow-up work.
  [`deferred-work.md:968`](deferred-work.md#L968)

**Remote parity (2026-09-07):**

- `npx supabase db push` — `20260906080451_collection_follows_the_current_penalty.sql` is on
  the live project `hxzalpnlrunctbajgtkv`, pushed together with item 37's migration.
- `supabase migration list` — local and remote agree on all 64 migrations.
- Security advisor — no new finding; `mark_penalty_collected` and `object_to_day` were already
  on the pre-existing `security definer` warning list before this change.
