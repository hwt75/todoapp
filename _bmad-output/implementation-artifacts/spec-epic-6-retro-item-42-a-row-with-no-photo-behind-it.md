---
title: 'Epic 6 retro item 42 — a row with no photo behind it'
type: 'bugfix'
created: '2026-09-10'
status: 'done'
review_loop_iteration: 0
baseline_commit: '6ba64fdad66c9473d2ca6288eb7020ab253b87d8'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-6-retro-2026-09-07.md'
  - '{project-root}/supabase/tests/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A day is held on the bare existence of an `evidence` row. `commitments_owing()`
(`20260829090000:326-328`) and `weekly_held_count()` (`:965`) both ask `exists (select 1 from
public.evidence ...)`, and the only shape check on that row is the string pattern `storage_path like
(parent_id || '/%')` (`20260903120000:100-102`) — never a reference to `storage.objects`. So one
`POST /rest/v1/evidence` carrying a fabricated path, with no upload at all, settles the day `clean`,
keeps the chain and avoids the penalty. The suite certifies this rather than catching it:
`tests/6-4:193,247,542` each insert exactly such a bare row and assert `held`. Retro finding A1
(HIGH) and its verification gap A7.

**Approach:** Refuse the row at insert. A before-insert trigger on `public.evidence` requires an
object of that exact name to exist in the `appeal-evidence` bucket — the same pairing
`orphaned_evidence_objects()` already uses to decide the opposite question. It is its own trigger,
not a line added to `evidence_derive_owner()`, because fixtures disable that trigger to plant rows
and this rule has to survive that. Then the regression the suite is missing, and every fixture row
in the suite gains the object it claims to have.

## Boundaries & Constraints

**Always:**

- **Insert only.** A row whose bytes were later removed by the retention sweep (`swept_at`,
  `20260908180000`) stands untouched. The row is what decides money; deleting or invalidating it
  turns held days into slipped days and mints penalties nobody earned — that migration's own
  reasoning, and it outranks the tidiness of a rule that would hold at all times.
- **Equality on `storage.objects.name`, scoped to `bucket_id = 'appeal-evidence'`** — identical to
  `orphaned_evidence_objects()` (`20260907130000:47-53`), so the gate and the sweeper can never
  disagree about what "the object behind this row" means.
- **All three parents.** An appeal's photo, a claim's photo and a commitment-day photo pass the same
  gate. The defect is the missing reference, not one parent kind.
- The refusal names the rule in its message, like every other refusal `evidence` raises.
- The function is `security definer`, `set search_path = ''`, and revoked from `public`, `anon` and
  `authenticated` — the shape every trigger function in this schema already has.
- **Every fixture `evidence` insert in `supabase/tests` gains a real object**, including the ones
  asserted to be *refused*: without it the refusal under test silently becomes this new refusal, and
  the test would pass for a reason it does not name. Each such file stages the bucket row itself
  (`insert into storage.buckets ... on conflict do nothing`), the pattern `4-6:37-39` established
  because CI starts the database with `-x storage-api`.

**Ask First:**

- Any change to *when* a day counts as held — `commitments_owing()`, `weekly_held_count()`,
  `timed_claim_today` are read-only here.
- What to do about `evidence` rows already in the live project that have no object behind them, if
  any exist. This change cannot refuse them retroactively and does not try.

**Never:**

- **Never a foreign key** from `evidence.storage_path` to `storage.objects.name`. The retention
  sweep deletes objects whose rows must survive; a foreign key would take the row with the bytes and
  cause exactly the penalty-minting this product spent a migration avoiding.
- Never claim to verify the *photograph*. This raises the bar from "no upload at all" to "an object
  in the folder you own", and the spec says so rather than implying more.
- Never touch the client write path, the bucket policies, settlement, the sweeper, or
  `evidence_derive_owner()`'s existing rules.
- Never disable the new trigger in a fixture to keep an old assertion green.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Real upload, then the row | Object at `<parent>/x.jpg` exists in `appeal-evidence` | Insert accepted; the day reads `held` exactly as today | — |
| The attack | One REST insert, fabricated `storage_path`, no object | Insert refused; the day settles as it would with no photo, penalty stands | Trigger raises, naming the rule |
| Same name, wrong bucket | Object of that name exists in another bucket | Refused — the check is scoped to `appeal-evidence` | Same message |
| Bytes swept later | Row inserted with its object; retention pass removes the object and stamps `swept_at` | Row stands; the day still reads `held` | — |
| Fixture with owner-derivation disabled | `alter table ... disable trigger evidence_derive_owner`, then insert | Still refused without an object — this rule is a separate trigger | Same message |
| Appeal-parented row, no object | Insert against an appeal | Refused, same rule, same message | — |
| Path does not lead with the parent id | Object exists, path points elsewhere | Refused by `evidence_storage_path_leads_with_its_parent`, unchanged | Existing constraint |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql:97-102,110-211` —
  the current insert gate: the path constraint (a string pattern) and `evidence_derive_owner()`.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:324-330,949-973` — the two readers
  that turn a bare row into `held`; read-only here.
- `supabase/migrations/20260907130000_a_photo_that_proves_nothing_does_not_stay_forever.sql:36-56` —
  `orphaned_evidence_objects()`; the `bucket_id`-plus-`name` equality this gate mirrors.
- `supabase/migrations/20260908180000_a_photo_does_not_outlive_its_usefulness.sql:33-41` — `swept_at`
  and why the row outlives its bytes. The reason this gate is insert-only.
- `supabase/tests/4-6-the-referee-rules.sql:31-39` and
  `supabase/tests/6-8-a-photo-i-can-keep-against-any-commitment.sql:35-43` — the bucket-staging and
  `storage.objects` insert patterns the other fixtures now need.
- `supabase/tests/6-4-midnight-decides-the-day.sql:193-195,247-248,542-543` — the three bare rows the
  retrospective named.
- Fixtures also inserting `evidence`, all needing objects: `2-1-roles-and-rls.sql`,
  `4-4-contest-a-miss-the-machine-got-wrong.sql`, `4-5-the-referee-has-his-own-way-in.sql`,
  `6-3-evidence-detaches-from-an-appeal.sql`, `6-5-today-shows-where-the-window-stands.sql`,
  `6-7-the-referee-may-object.sql`, `a-photo-does-not-outlive-its-usefulness.sql`,
  `a-referee-belongs-to-one-doer.sql`, `epic-4-retro-2026-08-27-fixes.sql`,
  `evidence-orphan-sweeper.sql`, `the-referee-can-see-what-the-day-was-proved-with.sql`.
- `components/today.tsx:492-527` and `components/appeal-form.tsx:156-172` — the two client writers.
  Read-only evidence that both already upload before inserting, so nothing on the client changes.

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/20260910090000_a_row_with_no_photo_behind_it.sql` — add
      `public.evidence_object_must_exist()` and its before-insert trigger on `public.evidence`;
      revoke execute from client roles; comment both with the insert-only reasoning — the rule that
      closes A1.
- [x] `supabase/tests/a-row-with-no-photo-behind-it.sql` — the missing regression: a fabricated-path
      insert is refused (as a client and with owner-derivation disabled), a real object is accepted
      and its day reads `held`, a swept row keeps its day, and the wrong-bucket case is refused.
- [x] `supabase/tests/6-4-midnight-decides-the-day.sql` — give the three named bare rows their
      objects, so the file proves `held` from a photo rather than from a metadata row.
- [x] The eleven remaining fixture files listed in the Code Map — stage the bucket where absent and
      back every `evidence` insert with an object, refusal cases included.

**Acceptance Criteria:**

- Given a timed commitment claimed today and no object in the bucket, when a client inserts an
  `evidence` row naming a fabricated path, then the insert is refused and `commitments_owing()`
  reports the day unheld.
- Given the same claim with the object actually uploaded, when the row is inserted, then the day
  reads `held` — the behaviour before this change, unchanged.
- Given an `evidence` row whose object was removed by the retention sweep, when its day is read
  again, then it still reads `held` and the row is still there.
- Given the whole SQL suite, when every file is run against a local stack, then all pass — no file
  keeps a row the database would now refuse.

## Verification

**Commands:**

- `docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/a-row-with-no-photo-behind-it.sql`
  — expected: no error, transaction rolls back.
- Every other `supabase/tests/*.sql` through the same command — expected: all pass.
- `npm test` — expected: unchanged pass count; no TypeScript changes in this story.
- `npm run lint`, `npm run format:check` — expected: clean.

**Manual checks (if no CLI):**

- `npm run migrations:check` cannot run here: it compares against the live project, and pushing
  `20260910090000` is the maintainer's call. Record it as pending rather than as passed.

## Results — run on the final state, 2026-09-10

- **The whole SQL suite, every file, against the local stack** — all pass. Twelve fixture files
  needed the photographs their rows claimed; `evidence-orphan-sweeper.sql` already had one, which
  is why it was the only evidence-writing file that never failed.
- `supabase/tests/a-row-with-no-photo-behind-it.sql` — the new regression, six steps, each of the
  matrix rows this story owns. The appeal-parented row is proved in
  `4-4-contest-a-miss-the-machine-got-wrong.sql`, where an appeal already exists.
- `npm test` — 1390 passed, 52 files. No TypeScript changed; this is the evidence that nothing on
  the client depended on the gap.
- `npm run lint`, `npm run format:check` — clean.

**What the fixture work turned up.** Three fixtures were refusing rows for the wrong reason once
the gate existed, and would have gone on passing while proving nothing: `4-4`'s mismatched-path
case, `6-3`'s five malformed shapes, and `6-8`'s nine. Each now stages a real object first, so the
rule each case names is still the rule that turns it away. `4-6` and `6-8` each inserted an object
*after* the row that named it; both were reordered rather than duplicated.

- **`npx supabase db reset --local`, then the whole suite again** — 76 migrations applied in order
  from an empty database, `20260910090000` among them, and every SQL file passes against the result.
  This is the from-scratch run CI's `db-tests` job performs on push.

**The review round (three independent reviewers over the diff).** Nine findings were taken as
patches; none reached the spec, so nothing was re-derived:

- The trigger now returns early on a null `storage_path`, so an omitted path is still the NOT NULL
  constraint's `23502` rather than this trigger's `P0001` — the same rule-stealing the ordering
  comment exists to avoid, found on the one path the comment did not consider.
- `6-3`'s five shape cases and `4-4`'s mismatched-path case now assert *which* rule refused them.
  Staging the objects made those refusals honest today; asserting the rule is what keeps them
  honest if a staged object is ever dropped — which is exactly how `6-4` came to certify A1.
- Step 1 of the new file counted the owed rows as well as reading the answer: `select ... into`
  leaves a null behind for a commitment that returned no row at all, so the assertion could have
  passed for the wrong reason. Step 4 now stamps through `mark_evidence_swept()` rather than by
  hand, so it asserts against the state the sweeper really produces.
- `6-5` staged its object as the doer session, silently depending on the bucket's upload policy in
  a step about a view; it now stages as postgres like every other file. `4-6`'s fixture comment
  contradicted the step-8 comment written beside it, and was corrected.
- `components/appeal-form.test.tsx` now asserts that a failed upload files no row. The client's
  upload-before-insert order became load-bearing with this migration, and that half was unpinned:
  both failure branches print the same sentence, so the copy alone could not tell them apart.
  `today.tsx`'s half was already pinned (`today.test.tsx:1113`).
- `supabase/tests/README.md` gained the rule this change creates: a fixture that writes `evidence`
  stages the bucket and uploads the object, refusal cases included.

Two findings were recorded in `deferred-work.md` rather than fixed here: nothing yet names the
rows in the live project that have no object behind them (the spec's own Ask First, and a
maintainer decision before it is a code one), and a trigger's English message still reaches the
author verbatim on a Vietnamese surface — pre-existing for every refusal this table raises.

**Pushed on the maintainer's instruction, 2026-09-10 — and it turned out to be three migrations,
not one.** `20260908170000` and `20260908180000` had been sitting local-only since 09-08 while the
client code that depends on them shipped on `main`. The deployed `referee-appeal-detail.tsx:162`
selects `evidence.swept_at`, a column only `20260908180000` creates, and its read treats any error
as a failed screen (`:167`) — so the referee's appeal detail, its Approve and Reject controls
included, had been rendering as one error line for two days. `lib/evidence.ts:198` selects the same
column, so the author's kept photos reported a failed read beside it. Found while answering a
question about the referee's reach, by no check in this repository — `migrations:check` is only run
when a story adds a migration, and neither of those stories was still open.

`npx supabase db push --linked` applied all three; `migrations:check` now reports all 76 matching.
**The retention sweep is live from this point**: the hourly worker removes the bytes of
photographs older than thirty days.

**Not run, and not skipped quietly:**

- Nobody has opened the referee's appeal screen since the push. The column it failed on now exists,
  which is what the code needed; that it renders is still a claim rather than an observation.

- `npm run migrations:check` — it compares against the live project. `20260910090000` has not been
  pushed; that is the maintainer's call and nothing here should imply it happened.
- Nothing was exercised in a browser: this story has no surface. The honest client path
  (upload, then row) is unchanged and covered by `npm test`.

## Suggested Review Order

**The rule**

- The gate itself: an object of that exact name, in that exact bucket, or no row.
  [`20260910090000:54`](../../supabase/migrations/20260910090000_a_row_with_no_photo_behind_it.sql#L54)

- Why it is its own trigger and never re-checks an old row — the whole design, in one comment.
  [`20260910090000:27`](../../supabase/migrations/20260910090000_a_row_with_no_photo_behind_it.sql#L27)

- Null path returns early, so NOT NULL keeps its own refusal.
  [`20260910090000:65`](../../supabase/migrations/20260910090000_a_row_with_no_photo_behind_it.sql#L65)

- `before insert`, sorting after `evidence_derive_owner` so older rules still speak first.
  [`20260910090000:98`](../../supabase/migrations/20260910090000_a_row_with_no_photo_behind_it.sql#L98)

**The regression**

- The attack, as a client can perform it: one insert, no upload, and the day stays unheld.
  [`a-row-with-no-photo-behind-it:104`](../../supabase/tests/a-row-with-no-photo-behind-it.sql#L104)

- The counterweight: a swept photo keeps the day it proved, or the sweep would mint penalties.
  [`a-row-with-no-photo-behind-it:219`](../../supabase/tests/a-row-with-no-photo-behind-it.sql#L219)

- The fixture back door, shut: the gate survives `disable trigger evidence_derive_owner`.
  [`a-row-with-no-photo-behind-it:258`](../../supabase/tests/a-row-with-no-photo-behind-it.sql#L258)

- And the older path rule still refuses in its own name.
  [`a-row-with-no-photo-behind-it:321`](../../supabase/tests/a-row-with-no-photo-behind-it.sql#L321)

- The appeal parent, proved where an appeal already exists.
  [`4-4-contest-a-miss:545`](../../supabase/tests/4-4-contest-a-miss-the-machine-got-wrong.sql#L545)

**The fixtures that certified the defect**

- The three rows the retrospective named now carry the photograph they claimed.
  [`6-4-midnight-decides-the-day:207`](../../supabase/tests/6-4-midnight-decides-the-day.sql#L207)

- Every malformed case is refused by its own rule, not by the new one standing in.
  [`6-3-evidence-detaches-from-an-appeal:189`](../../supabase/tests/6-3-evidence-detaches-from-an-appeal.sql#L189)

**Peripherals**

- The client contract this migration made load-bearing: a failed upload files no row.
  [`appeal-form.test.tsx:259`](../../components/appeal-form.test.tsx#L259)

- The rule written down for the next fixture author.
  [`tests/README.md:84`](../../supabase/tests/README.md#L84)

