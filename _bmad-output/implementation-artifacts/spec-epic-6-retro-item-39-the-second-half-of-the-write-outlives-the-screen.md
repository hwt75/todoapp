---
title: 'The second half of an evidence write outlives the screen'
type: 'bugfix'
created: '2026-09-07'
status: 'done'
baseline_commit: '3ccf660ee4bcf9c593f54a1f0ef3a471e0007848'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `attachProof()` uploads the photo, then returns on `!mounted.current` before inserting
the `evidence` row. Leaving Today while the upload is in flight — swiping to another tab, or the
browser reclaiming a backgrounded page, which is the ordinary thing to do while a photo uploads
from a gym — therefore leaves the object in Storage with no row. The photo the author took exists
and proves nothing: the timed claim it was meant to prove has no proof, and nothing in the product
can reach the object or clean it up.

**Approach:** Make the metadata write independent of React component lifetime and guard only the
state updates, which are the sole thing an unmounted screen must not do. Prove the window with a
held-open upload and an unmount inside it. Write down what orphan cleanup would have to be, so
the class of defect this belongs to stops being described only as "larger than this story".

## Boundaries & Constraints

**Always:** Finish the `evidence` insert once the object has landed, whatever became of the screen;
guard every `setEvidenceState` and every reload token with `mounted.current`; keep the pre-upload
capture-date refusal, the parent shape, and the absence of `owner_id` exactly as they are.

**Ask First:** Build the orphan sweeper, add a `storage.objects` delete policy, or make the client
delete an object after a refused insert — each changes who may destroy stored data, and this item
asks for the cleanup to be *defined*, not built.

**Never:** Retry the insert on the author's behalf; report a refused insert as a save; change what
`evidence_derive_owner()` enforces; touch the Story 6.9 kept-photo read or the appeal path.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Left mid-upload | Upload in flight, Today unmounts, upload then succeeds | The `evidence` row is inserted anyway, with the same parent and day | N/A |
| Left mid-upload | As above | No state update runs against the unmounted tree | React logs nothing |
| Upload itself failed | Unmounted, upload returns an error | Nothing to finish: no insert, no state update | Silent, nothing stranded |
| Still mounted | The ordinary path | Unchanged — saved, or the refusal in the server's words, then the kept-photo reload | Unchanged |

</frozen-after-approval>

## Code Map

- `components/today.tsx:489-500` — the defect: one `!mounted.current` return standing between a
  completed upload and the row that gives it meaning. The guard belongs to the state updates below
  it, not to the write.
- `components/today.test.tsx` — the upload mock resolves immediately, so the window the defect
  lives in is unreachable from a test until the upload can be held open.
- `_bmad-output/implementation-artifacts/deferred-work.md:932,936` — the orphaned-object entries
  this item's third clause is about; the definition below is what they were missing.
- `supabase/migrations/20260819183000_outbox_schedule.sql:58` — the shape a sweeper's schedule
  would take, if one is ever built.

## Tasks & Acceptance

**Execution:**
- [x] `components/today.tsx` — finish the insert regardless of mount state; guard only the state
      updates, including the upload-error branch.
- [x] `components/today.test.tsx` — hold an upload open, unmount inside it, and assert both halves:
      the row lands, and nothing redraws a screen that is gone.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` — record the orphan-cleanup
      definition against the two existing entries, so building it is a scoping decision rather
      than a design one.

**Acceptance Criteria:**
- Given an upload in flight and Today unmounted before it resolves, when the upload succeeds, then
  the `evidence` row is inserted with the same parent and day it would have carried.
- Given the same, when the insert completes, then no state update runs against the unmounted tree.
- Given an upload that itself fails after the unmount, when it resolves, then nothing is inserted
  and nothing is redrawn.

## Spec Change Log

## Design Notes

The two halves of this write cannot both be conditional on the same thing. The upload is what
creates the durable object; the insert is what makes it mean something. Guarding the second on a
React ref makes the durability of the first depend on whether the author kept looking at the
screen, which is not a property the author can see or control.

### Orphan cleanup, defined

Not built here — the Ask First above is why — but written down completely enough that building it
is a decision about scope rather than about design.

**What an orphan is.** A row in `storage.objects` under the `appeal-evidence` bucket with no
`evidence` row whose `storage_path` equals its `name`, and whose `created_at` is older than a grace
period. The grace period exists solely to protect the gap between the two halves of the write
above; an hour is far longer than any upload and short enough that orphans do not accumulate.

**How they still arise, now that the unmount path is closed.** Every refusal
`evidence_derive_owner()` can raise happens *after* the object is stored: a capture date that does
not match the day, a day that has already ended (AD-1), a parent the caller does not own. The
client cannot clean up after itself, because no `storage.objects` delete policy exists for the
owner or for the service role.

**What it must never delete.** An object whose `evidence` row exists — the row is the only proof
of intent, and a sweeper that reads the two out of order would delete a photo that is currently
proving a day. An object inside the grace period. Anything outside the `appeal-evidence` bucket.

**What it would be.** A `security definer` function owned by `postgres`, deleting from
`storage.objects` by that definition, on its own `pg_cron` schedule — the same shape as
`outbox_schedule` and `settlement_schedule` — plus a test that stages a real orphan, a real
in-grace-period object and a real referenced object, and asserts that only the first is removed.
This is also what `deferred-work.md:936` wants, where a cascade-deleted parent leaves its objects
behind; one mechanism serves both, which is the argument for building it once rather than twice.

## Verification

**Commands:**
- `npx vitest run components/today.test.tsx` with the `!mounted.current` return reinstated —
  expected: the two new cases fail, and only those.
- `npx vitest run components/today.test.tsx` — expected: green, with no test edited between the
  two runs.
- `npm test`, `npm run lint`, `npm run format:check`, `npm run build` — expected: clean.
- No migration, so no `migrations:check` change and nothing to push.

**Results (2026-09-07):**

- Test-first — with the `!mounted.current` return put back in front of the insert, exactly the two
  new cases fail (`finishes the row even when the author leaves Today mid-upload`, `writes the row
  without touching the state of a screen that is gone`) and the other 60 pass. Restoring the fix
  turns all 62 green with no edit to the test.
- `npm test` — passed, 50 files and 1323 tests.
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- All 38 `supabase/tests/*.sql` — passed; unchanged by this item, run because the working tree
  carries item 38's schema.
