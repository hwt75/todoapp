---
title: 'A photo does not outlive its usefulness'
type: 'feature'
created: '2026-09-08'
status: 'approved'
review_loop_iteration: 0
baseline_commit: 'd046be123da6d24405d8b9f83f5aacc1660be330'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-a-photo-that-proves-nothing-does-not-stay-forever.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-8-a-photo-i-can-keep-against-any-commitment.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-9-a-photo-i-can-open-again.md'
  - '{project-root}/supabase/migrations/20260907130000_a_photo_that_proves_nothing_does_not_stay_forever.sql'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> Requested by the maintainer on 2026-09-08 to stop photographs accumulating on the server, and
> approved after the objections below were put to him and overruled. **He asked for every photo to
> go, with no exception by kind**, and chose 30 days over the 7 he first named. Both of those are
> his decisions, recorded here rather than softened.

## Intent

**Problem:** Every photograph ever attached stays in `appeal-evidence` forever. The existing
sweeper (`20260907130000`) removes only *orphans* — objects no `evidence` row points at — and says
in its own Never boundary that it will not touch an object a row points at, whatever its age. So a
photo that has done its job stays for the life of the project.

**Approach:** A second pass in the same hourly sweeper. Any photograph whose `evidence` row is older
than the retention period has its **bytes removed through the Storage API**, and the row is stamped
`swept_at` so it is never named twice and so every surface can tell "cleared" from "broken".

## What this deliberately costs, and what it must not

The maintainer was told the following before approving, and approved anyway. It is recorded because
a later reader will otherwise assume it was an oversight.

- **Story 6.8 is revoked in substance.** "A photo I can keep against any commitment" now keeps it
  for 30 days. Story 6.9's viewer still works and will simply have less to show.
- **An unpaid debt outlives its proof.** A Penalty is never written off automatically, so a debt
  can sit `owed` for more than a year; after 30 days the referee collecting it can no longer see
  what the day was proved with.

**What it must not cost is money, and this is not a judgement call.** `commitments_owing()` and
`weekly_held_count()` both read the `evidence` table:

```
when exists (select 1 from public.evidence e where e.declaration_id = d.id) then d.answer
```

A claim answered `held` counts as held **only while an evidence row exists**; without one, once the
day ends it reads `slipped`. `apply_grace_days()` still rebuilds from live `commitments_owing()`
(epic 6 retrospective A6), so this is not confined to the day being settled — correcting an old day
re-reads it. Deleting `evidence` rows would therefore turn held days into slipped days and mint
500,000₫ penalties that nobody earned, and would drop weekly quota counts below their targets.

So the row stays and the bytes go. The row is about 100 bytes of metadata and is load-bearing for
verdicts; the photograph is the megabyte and is what was asked to be removed.

## Boundaries & Constraints

**Always:**

- Delete through the Storage API, never `delete from storage.objects` — the existing sweeper's rule,
  and the reason `storage.protect_delete()` exists.
- **Every kind of photo expires: appeal, claim, and commitment-day alike.** No exemption by parent.
  That is what was asked for.
- The `evidence` row survives, and `swept_at` is stamped only for objects the Storage API reported
  as actually removed.
- Batched, oldest first, so one pass cannot run unboundedly.
- The decision lives in the database, the effect in the worker (AD-2, AD-3).
- Revoked from `anon` and `authenticated`. Both new functions answer with storage paths or write to
  every account's rows.
- A swept photo is **absent, not broken**: no surface may render it as a failed load.

**Ask First:**

- Changing the retention period, or the schedule.
- Deleting an `evidence` row, or any other database row. This feature deletes bytes only, for the
  reason set out above.
- Sweeping any bucket but `appeal-evidence`.

**Never:**

- Never delete an `evidence` row. It decides whether a day held.
- Never make a verdict, a chain, a quota or a penalty depend on whether the bytes still exist.
- Never sweep an object the orphan pass owns, or vice versa — the two passes must not both name the
  same object in one run.
- Never let a failed removal stamp `swept_at`. A row stamped without its bytes gone is a photo the
  product believes it deleted and is still paying to store.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| A photo past retention | `evidence` row older than 30 days, `swept_at is null` | Bytes removed, `swept_at` stamped | — |
| A photo inside retention | Row younger than 30 days | Untouched | — |
| Already swept | `swept_at` set | Never named again | — |
| A verdict that reads it | Any swept claim photo | `commitments_owing()` still sees the row, so the day still reads `held` | The row is what it reads, and the row stays |
| A grace day on an old corrected day | `apply_grace_days()` re-reads `commitments_owing()` after the sweep | Same answer as before the sweep | — |
| Storage removal fails | `remove()` errors | Nothing is stamped; the next pass names the same rows | Reported loudly, 500 |
| Partial removal | `remove()` returns fewer than asked | Only what it reported removed is stamped | The rest are named again next hour |
| The author's history | A commitment with swept days | Those days show no photo, and a count of how many were cleared | Never "could not be opened" |
| The referee's appeal viewer | An appeal whose photos are swept | Same: absent with a count, never a failed load | — |
| A client calls either function | `anon` or `authenticated` | Refused | Postgres privilege error |
| Orphans | Object with no row, older than the orphan grace | Still the orphan pass's business, unchanged | — |

## Out of scope

- **`referee_day_lookup()`'s `evidence_paths`** (PR #5, unmerged). It will need `and e.swept_at is
  null` once both land. Recorded in Verification as a merge-order task rather than reached across
  branches from here.
- Any change to retention for **orphans**, which keep their own one-hour grace.
- Any way for the author to opt a photo out, or to download one before it goes.

</frozen-after-approval>

## Verification

- **SQL**: `supabase/tests/a-photo-does-not-outlive-its-usefulness.sql` passes. It asserts the two
  halves that pull against each other — a photo past 30 days *is* named for removal, and the
  verdict *does not move* when it is swept. Plus: a fresh photo is not named, an already-swept row
  is never named twice, re-stamping touches nothing, the row survives, and both new functions
  refuse `authenticated`.
- **The danger the design turns on was measured, not assumed.** With the evidence row,
  `commitments_owing()` reads the claim as `held`; with the row deleted it reads null, and the
  next arm of that `CASE` makes it `slipped` once the day ends — a failed day and a 500,000₫
  penalty. That is why the sweep removes bytes and never rows.
- **Every file under `supabase/tests/` was run**, the way CI does it — 43 files, all pass. The new
  column and functions break none of the existing settlement, chain, quota or sweeper tests.
- `npm test` — 1371 passed, 52 files. Three new cases in `lib/evidence.test.ts`: a swept photo is
  left out of the list and counted as cleared rather than failed and is never handed to the signer;
  the count survives the path where *every* photo on a day is swept; and a row arriving with no
  `swept_at` field at all counts as not swept.
- `npm run lint`, `npm run format:check`, `npm run build` — clean.

**Not done, and blocking `done`:**

- `npx supabase db push` — the migration is local only.
- `npx supabase functions deploy evidence-sweeper` — the retention pass does not run until the
  worker is redeployed. **The migration alone changes nothing**: the cron job wakes the old worker,
  which only sweeps orphans. Deploying is the maintainer's call.
- **Nothing was watched actually deleting a photograph.** The SQL proves what is named and what is
  stamped; the Storage `remove()` call itself was not exercised against a real bucket.
- **PR #5's `referee_day_lookup()` needs `and e.swept_at is null`** once both land, or the referee's
  day lookup will report swept photos as "could not be opened". Merge-order task, deliberately not
  reached across branches from here.

## Status

`review` on 2026-09-08. Implemented and verified locally; not pushed, not deployed.

## Commits

| Commit | Scope |
| --- | --- |
