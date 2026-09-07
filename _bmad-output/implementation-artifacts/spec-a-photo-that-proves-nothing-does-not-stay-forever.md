---
title: 'A photo that proves nothing does not stay forever'
type: 'feature'
created: '2026-09-07'
status: 'done'
baseline_commit: '2623eb4d979aab3fcd83971f4da2472c54917a34'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Attaching a photo is two writes — the object into Storage, then the `evidence` row that
gives it meaning — and the second one can fail after the first has succeeded. Every refusal
`evidence_derive_owner()` raises happens at that point: a capture date that does not match the day,
a day that has already ended, a parent the caller does not own. The object then exists, proves
nothing, is reachable by nobody, and nothing in the product can remove it. Two entries in
`deferred-work.md` have recorded this since Story 6.8, both waiting on a mechanism that did not
exist.

**Approach:** A sweeper on its own hourly schedule, shaped like the outbox worker: the database owns
the decision of what is an orphan and hands out a batch of names; an Edge Function does the deleting
through the Storage API, because that is the only path that removes the stored bytes as well as the
row. A grace period protects the gap between the two halves of a live upload.

## Boundaries & Constraints

**Always:** Delete through the Storage API, never by removing a `storage.objects` row directly;
require both conditions before naming an object — no `evidence` row points at it, and it is older
than the grace period; batch, so one pass cannot run unboundedly; keep the decision in the database
and the effect in the worker, as AD-2 and AD-3 have it.

**Ask First:** Change the grace period or the schedule; sweep any bucket other than
`appeal-evidence`; delete an `evidence` row, or anything in the database at all; give any client
role execute on the new function.

**Never:** Delete an object an `evidence` row points at, whatever its age; delete an object inside
the grace period; touch a bucket this does not own; use the
`storage.allow_delete_query` escape hatch to bypass `storage.protect_delete()` — that trigger exists
to stop exactly the half-deletion this feature must not perform.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| A real orphan | In `appeal-evidence`, older than the grace period, no `evidence` row | Named, then removed through the Storage API — bytes and row together | N/A |
| Upload in flight | No `evidence` row yet, but younger than the grace period | Not named. The second half of that write has not run yet | N/A |
| A photo doing its job | An `evidence` row points at it | Not named, at any age | N/A |
| Another bucket | Orphaned object outside `appeal-evidence` | Not named. This sweeper owns one bucket | N/A |
| Many orphans | More than one batch | The batch is swept; the rest wait for the next hour | N/A |
| A client asks | `anon` or `authenticated` calls the function | Refused — it is revoked from every client role | Postgres privilege error |
| Secrets missing | Vault has no `outbox_worker_key` or `project_url` | The job raises and says so, as every other waker does | Visible in `cron.job_run_details` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819183000_outbox_schedule.sql:18-64` — the waker shape: Vault for the
  key, `net.http_post`, raise rather than fail quietly, `cron.schedule`.
- `supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql:400-441` — the
  precedent for a *second* worker: it reuses `outbox_worker_key` rather than inventing a secret,
  which is why this adds no new setup step.
- `supabase/functions/outbox-worker/index.ts:35-60` — the service-role client, the batch constant,
  the JSON result shape.
- `supabase/migrations/20260824130000_contest_a_miss_the_machine_got_wrong.sql:253` —
  `evidence.storage_path` is `not null unique`, and holds exactly the object's `name`.
- `storage.protect_delete()` — the trigger that refuses a direct delete, with the hint saying why:
  it prevents orphaning the bytes. This feature agrees with it rather than working around it.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the two entries this closes, and the
  item 39 definition this implements.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<generated>_a_photo_that_proves_nothing_does_not_stay_forever.sql` —
      `orphaned_evidence_objects(grace, batch)`, revoked from every client role; `wake_evidence_sweeper()`;
      the hourly `cron.schedule`.
- [x] `supabase/functions/evidence-sweeper/index.ts` — claim a batch, remove it through the Storage
      API, report counts, fail loudly rather than silently.
- [x] `supabase/tests/evidence-orphan-sweeper.sql` — a real orphan, one inside the grace period, one
      an `evidence` row points at, and one in another bucket; only the first is named. Plus the
      client-role refusal.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` — close the two entries.
- [x] `README.md` — say the job exists and what it removes.

**Acceptance Criteria:**
- Given an object older than the grace period with no `evidence` row, when the function runs, then
  its name is returned and nothing else is.
- Given an object an `evidence` row points at, or one inside the grace period, or one in another
  bucket, when the function runs, then it is not returned at any age.
- Given a client session, when it calls the function, then Postgres refuses on privilege.

## Spec Change Log

- 2026-09-07 — corrects the definition written during item 39, which said the sweeper would be a
  `security definer` function deleting from `storage.objects`. That would remove the row and leave
  the bytes, which is a worse orphan than the one it set out to fix and is exactly what
  `storage.protect_delete()` exists to prevent. The decision stays in the database; the deletion
  moves to an Edge Function using the Storage API.

## Design Notes

The grace period is the whole reason this is safe to run automatically. An object with no `evidence`
row is not necessarily abandoned — it may be a write whose second half has not happened yet — and
the only thing separating the two cases is time. One hour is far longer than any upload and short
enough that orphans do not accumulate. It is deliberately not zero, and deliberately not a day.

The database names orphans; it never deletes them. That split is not ceremony: the Storage API is
the only path that removes the stored bytes, and a database that could delete the row would be able
to half-delete an object without ever being able to finish the job.

## Verification

**Commands:**
- SQL test-first run of `supabase/tests/evidence-orphan-sweeper.sql` — expected: fails before the
  migration, passes after.
- `npx supabase db reset`, then all `supabase/tests/*.sql` — expected: zero failures.
- `deno check` on the new function, or the repo's existing equivalent.
- `npm test`, `npm run lint`, `npm run format:check`, `npm run build` — expected: clean.
- `npm run migrations:check` — expected: local-only until a separately authorized push.

**Results (2026-09-07):**

- Test-first — `supabase/tests/evidence-orphan-sweeper.sql` failed before the migration with
  *"function public.orphaned_evidence_objects() does not exist"*, and passes all four steps after
  it with no edit to the test.
- The four exclusions are asserted against real rows rather than described: an aged unreferenced
  object is named; one two minutes old is not; one an `evidence` row points at is not, at any age;
  one in a second bucket staged alongside is not. Shortening the grace period to a minute exposes
  the young object and still not the referenced one, which is what proves the two guards are
  independent rather than one standing in for the other.
- The PostgREST shape was checked rather than assumed, because it is where this would fail
  silently: called as the service role, `returns setof text` comes back as a plain JSON array of
  strings, which is exactly what the worker's `(data ?? []) as string[]` expects.
- `npx supabase db reset` — passed; every migration, including `20260907130000`, applies from
  scratch, and `cron.job` carries `evidence-sweeper` at `17 * * * *`, active.
- All 39 `supabase/tests/*.sql` — passed, 0 failures.
- Both race harnesses — passed.
- `npm test` — passed, 50 files and 1332 tests (three more, all `lib/roles.test.ts`'s
  per-migration security assertions on the new file).
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero: `20260907130000` is local-only until a
  separately authorized push.

**Still to do, and it is not optional:** `npx supabase functions deploy evidence-sweeper`. The cron
job is created by the migration, so pushing the migration without deploying the function leaves an
hourly POST to a function that is not there — visible in `cron.job_run_details` and
`net._http_response`, costing nothing but the sweep. The two belong in the same change.

**Remote parity and deployment (2026-09-07):**

- `npx supabase functions deploy evidence-sweeper` ran **before** the migration push, deliberately:
  the migration is what creates the cron job, so deploying second would have left an hourly POST to
  a function that was not there.
- `npx supabase db push` — `20260907130000` applied to `hxzalpnlrunctbajgtkv`. Local and remote both
  carry all 68 migrations, and `cron.job` holds `evidence-sweeper` at `17 * * * *`, active.
- Smoke-tested through the path cron itself takes, rather than by invoking the function directly:
  `select public.wake_evidence_sweeper();` on the live project, then reading `net._http_response`.
  The answer was `200 {"ok":true,"named":0,"removed":0}` — Vault secret found, URL right, function
  reachable, bearer accepted, RPC callable, and the result shape the worker returns.
- Safe to run at that moment by inspection, not by hope: the live project holds zero objects in
  `appeal-evidence` and zero `evidence` rows, so the first pass had nothing it could delete.
