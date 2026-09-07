---
title: 'A time switched off stays off'
type: 'bugfix'
created: '2026-09-07'
status: 'in-progress'
baseline_commit: 'cbd6c0183cf3f6a5ab13d6a8e7217bb54130b972'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `due_time_as_of()` documents its fallback as the value in effect when the day began,
falling back to the creation value only for a day at or before the commitment's own creation. It was
written as a `coalesce` of those two subqueries, and a coalesce cannot tell "no entry applies" from
"the entry that applies says null". So when the entry in force at day start was the one that
switched the time *off*, the correct null answer fell through to the creation value: a commitment
switched back to untimed went on being judged timed on every later day, demanding a photo the app no
longer offers to take and settling the day `failed` with a penalty and a broken chain.

**Approach:** Replace the coalesce with three explicit branches — changed mid-day, an entry in force
at day start, or no entry yet — so a recorded null is an answer rather than an absence. This is the
shape `late_window_at()` already uses, and for the identical reason.

## Boundaries & Constraints

**Always:** Keep the mid-day rule exactly as item 38 left it, counting only entries where `due_time`
itself moved; keep the creation-value extrapolation for a day at or before creation; keep the
signature, volatility, `security definer`, `search_path` and grants unchanged, so every existing
caller is untouched.

**Ask First:** Change what governs a day, the mid-day rule, the creation-value fallback, or any
caller of `due_time_as_of()`; re-settle or correct any day whose verdict this changes.

**Never:** Change `carries_penalty_as_of()`, the log, or `late_window_at()`; edit an applied
migration; let a day already settled be re-judged silently.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Days after a switch-off | Created timed, switched off on day S | Every day after S reads untimed | N/A |
| The switch-off day itself | As above, `p_day` = S | Untimed — changed part-way through, the existing rule | N/A |
| Days before the switch-off | As above, `p_day` < S | Still the time that governed them | N/A |
| Before creation | `p_day` at or before the first entry | Still the creation value, extrapolated backward | N/A |
| Switched off then on again | Off on S, on again on T > S | Days in (S, T) untimed; days after T carry the new time | N/A |
| Never timed | One entry, `due_time` null | Untimed, exactly as before | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260907100000_a_queued_claim_keeps_the_meaning_it_had.sql:92-133` — the
  active definition, carrying item 38's mid-day refinement and the coalesce this replaces.
- `.../20260829090000_midnight_decides_the_day.sql:140-152` — the prose the implementation
  disagrees with: the creation value is a fallback "for any day at or before its own creation".
- `.../20260907100000...sql:196-230` — `late_window_at()`, already written as an existence test,
  with a comment saying why. This makes the two readers consistent as well as correct.
- `supabase/tests/6-4-midnight-decides-the-day.sql` — Step 12 proves the switch-*on* direction;
  Step 17 is the switch-off one, which nothing covered.
- `_bmad-output/implementation-artifacts/deferred-work.md` — where this was recorded during item 38
  rather than fixed, because item 38's frozen boundary was that no settled day may be re-judged.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/tests/6-4-midnight-decides-the-day.sql` — Step 17: a commitment created timed and
      switched off later reads untimed on every day after the switch, keeps its time on the days it
      governed, and is untimed on the switch day itself; and `commitments_owing()` agrees.
- [x] `supabase/migrations/<generated>_a_time_switched_off_stays_off.sql` — three explicit branches
      in place of the coalesce, everything else unchanged.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` — close the entry that recorded this.

**Acceptance Criteria:**
- Given a commitment created with a time and switched back to untimed on day S, when any day after
  S is asked about, then it reads untimed and `commitments_owing()` carries no `due_time` for it.
- Given the same commitment, when a day before S is asked about, then it still reads the time that
  governed it.
- Given every existing regression in the suite, when it runs, then nothing else moves.

## Spec Change Log

## Design Notes

The defect is the same class `due_time_as_of()` was created to fix — a past day judged by a rule
that was not in force then — reintroduced by the shape of the fallback rather than by the rule
itself. That is worth noticing: the function's prose was right the whole time, and only the
implementation disagreed with it, which is exactly the kind of gap prose cannot close on its own.

**Nothing already settled changes.** Verified against the live project before the migration was
written: every commitment there carries exactly one `commitment_due_time_change` entry, its own
creation, so no `due_time` has ever been switched off and this branch has never been reached by real
data. It is fixed now precisely because that is still true — the first person to switch a time off
would otherwise have paid for it.

## Verification

**Commands:**
- SQL test-first run of `supabase/tests/6-4-midnight-decides-the-day.sql` — expected: Step 17 fails
  before the migration, passes after, with no edit to the test between the two runs.
- `npx supabase db reset`, then all `supabase/tests/*.sql` — expected: zero failures.
- Both race harnesses, `npm test`, `npm run lint`, `npm run format:check`, `npm run build` —
  expected: clean.
- `npm run migrations:check` — expected: local-only until a separately authorized push.

**Results (2026-09-07):**

- Live-data check before writing the migration — all seven commitments on
  `hxzalpnlrunctbajgtkv` carry exactly one due-time entry, so no day that has ever been settled is
  judged differently by this change.
- Test-first — Step 17 failed against the previous definition with the case stated plainly:
  *"On 'the day after' (2026-09-06) a commitment whose time was switched off still reads a due_time
  of 20:00:00 — the value it was created with, months earlier."* Applying the migration turns all
  17 steps green; putting the coalesce back reproduces the same failure.
- `npx supabase db reset` — passed; every migration, including `20260907120000`, applies from
  scratch.
- All 38 `supabase/tests/*.sql` — passed, 0 failures. Step 12, which proves the switch-*on*
  direction, is untouched.
- Both race harnesses — passed.
- `npm test` — passed, 50 files and 1329 tests (three more than before, all of them
  `lib/roles.test.ts`'s per-migration security assertions on the new file).
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
