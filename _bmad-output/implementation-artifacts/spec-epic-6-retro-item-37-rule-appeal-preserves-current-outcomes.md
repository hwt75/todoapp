---
title: 'Appeal approval changes only the appealed commitment'
type: 'bugfix'
created: '2026-09-07'
status: 'in-progress'
baseline_commit: '4e32bb841db2b4ee4e264a8b23243c535e532b9f'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Approval rebuilds a corrected day from live `commitments_owing()` data.
After an objection changed another commitment from `held` to `missed`, approving an
Appeal can restore it to `held` and silently undo the referee's earlier decision.

**Approach:** Build the Appeal correction from the current settlement's frozen outcomes,
copy every row, and change only the appealed commitment to `held`. Prove the complete
objection → Appeal → approval chain against one account in the SQL suite.

## Boundaries & Constraints

**Always:** Supersede the settlement captured by the Appeal; preserve its commitment set
and every non-appealed outcome; retain the guarded `held → voided` transition. Derive
`missed_count` from the source aggregate, subtracting only an appealed frozen miss that
qualifies under `carries_penalty_as_of()` and the non-weekly rule. Keep every write in one
transaction; never recount other commitments from live state.

**Ask First:** Change the RPC signature, Appeal eligibility, pairing/authorization model,
Penalty state model, or approved-ruling notification copy; add a new lock protocol; apply
the migration remotely.

**Never:** Edit an applied migration; rebuild a correction from `commitments_owing()`;
mutate an existing settlement or frozen outcome; change the rejection branch, UI, Storage,
weekly settlement, or Grace Day behavior; treat the objection and Appeal as competing
records when they target different commitments.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Objection then approval | Correction has objected A=`missed`, machine B=`missed`; B is appealed | Next correction keeps A=`missed`, sets B=`held`, remains `failed/1`, and replaces the voided Penalty | N/A |
| Sole contributing miss | Appealed frozen miss is the source's only day-Penalty contributor | Correction becomes `clean` with `missed_count=0` and no current Penalty | N/A |
| Non-contributing miss | Appealed frozen miss does not contribute to the day Penalty | Other frozen outcomes and source `missed_count` remain unchanged | N/A |
| Lost ruling race | Held Penalty was already resolved | Existing clear refusal; no correction, timestamp, or outbox row | Preserve current refusal |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260826110000_the_long_view_including_whether_this_still_works.sql:136-271` — active function; approval's live recompute at 212-240 is defective; preserve its guards, rejection, timestamp, and outbox.
- `supabase/migrations/20260906080451_collection_follows_the_current_penalty.sql:358-407` — current whole-day freeze precedent: copy source `settlement_commitment` rows and override one commitment only.
- `supabase/migrations/20260825120000_the_same_lock_the_same_day.sql:37-127` — Appeal insert records the current failed settlement/Penalty and holds it under the account lock.
- `supabase/migrations/20260827130000_carries_penalty_freezes_by_day.sql:98-173` — `carries_penalty_as_of()` is the historical money flag; cadence remains live and must be read only for the appealed row's existing non-weekly contribution rule.
- `supabase/tests/6-7-the-referee-may-object.sql:736-920` — extend Account C's failed two-commitment objection through Appeal approval.
- `supabase/tests/4-6-the-referee-rules.sql:426-566,606-714,755-807` — existing approval, remaining-miss, timeout/double-ruling, and weekly-exclusion regressions must remain green.
- `_bmad-output/implementation-artifacts/deferred-work.md:956-960` and `_bmad-output/implementation-artifacts/epic-6-retro-2026-09-06.md:46-54` — original finding and accepted next-work boundary; read-only intent evidence.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/tests/6-7-the-referee-may-object.sql` — make Account C's unaffected miss machine-filed, then add the failing objection → Appeal → approval regression with exact settlement graph, full freeze cardinality/outcomes, Penalty lineage/current projection, Appeal timestamp, and outbox assertions.
- [x] `supabase/migrations/<generated>_appeal_approval_changes_only_its_commitment.sql` — redefine only `rule_appeal()` and its comment/grants; replace live recomputation with source-freeze copying and a one-row contribution delta while preserving every existing guard and side effect.
- [x] `_bmad-output/implementation-artifacts/sprint-status.yaml` — keep item 37 synchronized with implementation/review evidence without closing schema work before remote parity.

**Acceptance Criteria:**
- Given an objection froze one commitment as missed and another machine miss is appealed, when the Appeal is approved, then only the appealed commitment becomes held and the objection's miss remains current.
- Given approval changes the source's remaining day-Penalty contributor count, when the correction commits, then its verdict, `missed_count`, and current Penalty match that preserved snapshot.
- Given the existing rejection and ruling-race scenarios, when their SQL regressions run, then their Penalty, correction, timestamp, refusal, and outbox behavior remains unchanged.

## Spec Change Log

## Design Notes

Use the settled source aggregate plus an appealed-row delta, not a full recount. Copying the
freeze preserves chain/history while the delta confines the money change to one commitment.

The approved-ruling body remains the existing message even when another miss keeps the day
owed. Copy changes are intentionally outside this database-correction fix.

## Verification

**Commands:**
- SQL test-first run of `supabase/tests/6-7-the-referee-may-object.sql` — expected: fails before the migration because the objected outcome returns to `held`, then passes after it.
- `npx supabase db reset` — expected: every migration applies from scratch locally.
- All `supabase/tests/*.sql` through local container `psql -v ON_ERROR_STOP=1` — expected: zero failures, including existing Story 4.6 ruling cases.
- `node scripts/test-current-penalty-race.mjs` — expected: item 36 serialization remains green.
- `npm test`, `npm run lint`, `npm run format:check`, `npm run build` — expected: clean.
- `npm run migrations:check` — expected: local-only migration remains non-zero until an authorized remote push.

**Results (2026-09-07):**

- Test-first proof — with `rule_appeal()` reverted to its
  `20260826110000_the_long_view_including_whether_this_still_works.sql:136-257` definition on the
  local stack, `supabase/tests/6-7-the-referee-may-object.sql` failed exactly at the new Step 6
  assertion: the Appeal correction read `clean` / `missed_count 0` because the live recompute
  restored the referee's objected commitment to `held`. Re-applying
  `20260907090000_appeal_approval_changes_only_its_commitment.sql` turned the same file green
  without touching the test.
- `npx supabase db reset` — passed; every migration, including `20260907090000`, applied from
  scratch.
- All 38 `supabase/tests/*.sql` files — passed, 0 failures, including the Story 4.6 ruling,
  remaining-miss, timeout/double-ruling and weekly-exclusion regressions.
- `node scripts/test-current-penalty-race.mjs` — passed; item 36 serialization remains green
  (both winner orders waited on the account advisory lock and preserved one current Penalty).
- `npm test` — passed, 50 files and 1315 tests.
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero result: `20260906080451` and `20260907090000`
  are local-only until a separately authorized push.
