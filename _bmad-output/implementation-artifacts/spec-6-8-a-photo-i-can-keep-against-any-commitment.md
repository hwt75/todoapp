---
title: 'Story 6.8 — A photo I can keep against any commitment'
type: 'feature'
created: '2026-09-03'
status: 'done'
review_loop_iteration: 1
baseline_commit: '155801d0ad609f54540008080ca2eed9119a2908'
story_key: '6-8-a-photo-i-can-keep-against-any-commitment'
context:
  - '{project-root}/_bmad-output/planning-artifacts/sprint-change-proposal-2026-09-03.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-3-evidence-detaches-from-an-appeal.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every path to a photo runs through Epic 6's timed machinery — a `due_time`, an open
window, a landed *Claim* — and outside that window the block draws nothing, so the capability is
indistinguishable from one never built. An `abstain` or `daily_hours_quota` commitment cannot carry
a time at all, so those kinds have no path to a photo under any circumstance.

**Approach:** A commitment may be marked as one the author keeps a photo against, independently of
any hour, putting an upload control on its row for its whole local day. The photo decides nothing —
the morning Declaration stays sole judge — and `evidence` gains a third parent kind: a commitment
and a day.

## Boundaries & Constraints

**Always:**
- The photo is evidence, never a verdict. Settlement, penalty, chain, grace, notification and
  referee outcomes must be unchanged.
- `evidence` carries exactly one parent. The exactly-one-parent check, the storage-path check and
  `evidence_derive_owner()` move **together, in one migration** — load-bearing as a set.
- The object path leads with the parent's own id: `(storage.foldername(name))[1]` is what the bucket
  policies read to derive access.
- The capture-date and midnight rules are the declaration branch's, reused — not rewritten.
- The flag applies to every Kind and Cadence. Unlike `due_time`, nothing makes it meaningless.
- One numbered migration (AD-16); authorization in RLS (AD-7).

**Ask First:**
- Any change to `commitments_owing()`, `weekly_held_count()`, `timed_claim_today` or a `settle_*`
  function. Needing one means the design is wrong.
- Giving `requires_photo` an as-of change log — it does not get one (Design Notes).

**Never:**
- No `declaration` row auto-created on upload: that files an answer the author never gave and hands
  the verdict a second writer (AD-8).
- No new slot table, second bucket, or second owner-derivation.
- No failed-day warning copy on the checkbox — nothing is at stake here.
- No back-filling a past day, no offline queue for the upload, no editing or deleting a filed photo.
- Never two upload controls on one row.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Happy path | Flag on, file dated today | `evidence` row with `commitment_id` + `for_day` = today, owner derived from the commitment | N/A |
| No photo all day | Flag on, nothing uploaded | Day settles identically to the same day with the flag off | N/A |
| Wrong date | File `lastModified` ≠ today | Refused before reaching Storage, existing wording | Client refuses; trigger refuses again |
| After midnight | `for_day` in the past | Control gone; direct insert refused | Trigger raises, declaration-branch message shape |
| Both flags | `due_time` set **and** flag on | Only Epic 6's timed proof control renders | N/A |
| Foreign commitment | Path leads with a commitment the caller does not own | Storage refuses upload; `evidence` insert refuses | RLS + path check, no application check |
| Malformed row | Two parents, zero parents, `for_day` on an appeal, missing `for_day` | Refused | `evidence_exactly_one_parent` + `for_day` biconditional |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260828150000_evidence_detaches_from_an_appeal.sql` — the file this extends.
  `:50` `evidence_exactly_one_parent` (biconditional → three-way count); `:61`
  `evidence_storage_path_leads_with_its_parent` (`coalesce(appeal_id, declaration_id)`, gains a
  third); `:70-126` `evidence_derive_owner()`, `security definer`, `search_path = ''`, branching on
  `appeal_id` else declaration; `:104-109` the midnight guard the new branch reuses; `:116-118` the
  shared capture-date raise. `:155-193` the two `storage.objects` owner policies — **`using`/`with
  check` cannot be altered: drop and recreate both, symmetrically.**
- `supabase/migrations/20260828130000_a_commitment_can_carry_a_time.sql` — naming and
  `comment on column` convention for a new `commitment` column. Real constraint names:
  `commitment_time_and_window_together`, `commitment_late_window_range`,
  `commitment_due_time_whole_minute`, `commitment_window_within_the_day`.
- `20260829090000_midnight_decides_the_day.sql:308` `commitments_owing()`, `:965`
  `weekly_held_count()`, `20260830090000:47` `timed_claim_today` — the only three readers of
  `evidence`, all keyed on `declaration_id`. **Read-only. A `commitment_id` row matches none of
  them; that is why settlement is unchanged.** `:141-170` is the `due_time_as_of()` precedent the
  Design Notes turn on.
- `20260824160000:62` `evidence: referee reads all` — `using (public.role_from_token() = 'referee')`
  — and `20260825090000:263` `appeal-evidence objects: referee reads all` —
  `using (bucket_id = 'appeal-evidence' and public.role_from_token() = 'referee')`. **Neither is
  scoped to a parent kind, so leaving them untouched hands the referee every commitment-day photo,
  object and row alike.** Both must be narrowed so the new kind is excluded. Narrow by excluding the
  commitment-day kind only — never to appeal-only, which would also hide the declaration-parented
  timed proofs Story 6.7 is being built to let him object to.
- `lib/commitment.ts:37` `CommitmentDraft`; `:74` `EMPTY_DRAFT`; `:118` `autoChecksPossible()` and
  `:140` `canBeTimed()` — the two gates the flag deliberately does **not** join; `:326`/`:342`
  `withKind`/`withCadence` clear `dueTime` and must **not** clear this; `:360` `toRow()`.
- `components/commitment-form.tsx:233` — the `carries_penalty` checkbox, the shape to mirror; `:72`
  `set()`.
- `components/commitment-list.tsx:41` `SELECT`, `:51` row type, `:65` `toDraft()`.
- `components/today.tsx:72` `SELECT`, `:219` the `commitment` read, `:381` `attachProof()` (reused
  with a commitment-day parent), `:538` the timed block the new control sits **outside** of, `:572`
  the evidence render to mirror.
- `components/commitment-row.tsx:17` `RowCommitment` — add the optional column.
- `lib/evidence.ts` — `evidenceObjectPath()` takes a generic `parentId`; `EVIDENCE_COPY` and
  `isEvidenceDated` reused. **No change to this file.**
- `supabase/tests/README.md` — tests are hand-written `begin; do $$ … $$; rollback;` blocks with
  `raise exception` assertions, **not pgTAP**. `supabase/tests/6-3-evidence-detaches-from-an-appeal.sql`
  is the model (refusal probes, `foreach v_case in array` constraint matrix);
  `supabase/tests/4-6-the-referee-rules.sql:715-745` models a `storage.objects` path/RLS assertion.
- `components/today.test.tsx:21-45` — the `fromCalls` / `uploaded` mock harness to register in.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql` — add
      `commitment.requires_photo boolean not null default false` with a `comment on column` stating
      settlement never reads it; add `evidence.commitment_id` + `evidence.for_day`; replace
      `evidence_exactly_one_parent` with a three-way count plus a `for_day` biconditional keyed to
      `commitment_id`; extend the storage-path check; add the third branch to
      `evidence_derive_owner()` reusing the midnight guard and capture-date raise; drop and recreate
      both `appeal-evidence` owner policies with a third `exists` against `commitment`; and **narrow
      both referee read policies so a commitment-day photo reaches him as neither object nor row**,
      leaving appeal- and declaration-parented evidence exactly as visible as it is today. Prose
      comments give the reason and the rejected alternative, and assert no property of another
      policy without quoting that policy's own predicate.
- [x] `supabase/tests/6-8-a-photo-i-can-keep-against-any-commitment.sql` — house style: owner
      derivation for the third parent; refusal of every malformed row in the I/O Matrix, **each
      asserted against the constraint it is meant to prove rather than accepting any refusal**; a
      storage probe proving another doer can neither upload into nor read the folder — the read
      asserted under RLS, not as `postgres`; and **a referee step asserting zero rows from both
      `public.evidence` and `storage.objects` for a commitment-day photo**.
- [x] `lib/commitment.ts` — `requiresPhoto` on the draft, `false` in `EMPTY_DRAFT`, carried by
      `toRow()`. Not gated by `autoChecksPossible`/`canBeTimed`, never cleared by
      `withKind`/`withCadence`.
- [x] `components/commitment-form.tsx` — one checkbox mirroring `carries_penalty`, no warning copy.
- [x] `components/commitment-list.tsx` — column in `SELECT`, row type, `toDraft()`.
- [x] `components/today.tsx` + `components/commitment-row.tsx` — column in `SELECT` and
      `RowCommitment`; an all-day per-row upload control for flagged rows, outside the timed block,
      suppressed when `due_time` is set.
- [x] `lib/commitment.test.ts`, `components/commitment-form.test.tsx`, `components/today.test.tsx` —
      every I/O Matrix row with a client half, plus the both-flags suppression and that
      `withKind`/`withCadence` preserve the flag.

**Acceptance Criteria:**
- Given a commitment of any Kind and Cadence with the flag on, when the author opens Today at any
  hour of that day, then an upload control is on its row with no claim, no due time, no open window.
- Given the flag on and no photo uploaded, when the day settles, then verdict, penalty, chain and
  grace allowance are identical to the same day with the flag off.
- Given `supabase/tests/6-4-*.sql` and `6-5-*.sql`, when run against the migrated schema, then they
  pass unmodified.

## Spec Change Log

### 2026-09-03 — iteration 1, `bad_spec`: the referee read the author's private photos

**Triggering finding.** All three review layers, independently, and reproduced against the live
local database: a referee session reads both the `evidence` row and the `storage.objects` object for
a commitment-day photo. `Today`'s own copy says "It is private — only you can open it".

**Root cause, and it was in this spec.** The Code Map asserted that the two referee read policies
were "both untouched, and both are why NFR4 still holds for the new kind". Neither policy is scoped
to a parent kind — the storage one filters on `bucket_id` and role, the table one on role alone —
so leaving them untouched is precisely what opened the hole. The implementation agent trusted the
spec and copied the false claim into the migration's own header comment, where it now records the
opposite of the truth.

**Amended.** The Code Map line now quotes both predicates verbatim and states the narrowing they
require; the migration task carries that narrowing plus a rule against asserting another policy's
behaviour without quoting it; the test task carries a referee step and two strengthenings the same
review found (assert refusals against the named constraint, and assert the storage read under RLS
rather than as `postgres`).

**Known-bad state avoided.** Shipping a feature whose on-screen promise of privacy is false, into a
product whose entire mechanism rests on the author trusting what it tells him, with a migration
comment asserting the safety it does not have.

**KEEP — must survive.** The three-way `::int` parent count and the `for_day` biconditional. The
qualified `objects.name` in every storage-policy branch, and the comment explaining why a bare
`name` binds to `commitment.name` — that was a real bug caught by a positive control and must not
regress. `evidence_derive_owner()`'s third branch reusing the declaration branch's midnight guard
and shared capture-date raise verbatim rather than restating them. The `requires_photo`
no-change-log decision and its written warning. Suppressing the new control when `due_time` is set.
The client-side capture-date refusal before any upload starts.

## Design Notes

**Why `requires_photo` gets no as-of change log.** Every commitment value settlement reads is frozen
per day here — `carries_penalty_as_of()`, `due_time_as_of()` — so a switch flipped today cannot
rewrite what yesterday meant. This column is outside that set for the reason the story exists:
settlement never reads it, so there is no past verdict it could rewrite (`late_window_minutes` is
the precedent). **If a later story makes a missing photo cost anything, this column needs the log
before that story ships** — recorded so the omission reads as a decision, not an oversight.

**The three-way parent, as a count.** A biconditional does not extend to three terms legibly:

```sql
check (
  (appeal_id is not null)::int
  + (declaration_id is not null)::int
  + (commitment_id is not null)::int = 1
)
```

`for_day` belongs to exactly one parent kind, so it gets its own biconditional against
`commitment_id` — the other two derive their day from the parent row, and a stray `for_day` on an
appeal would give a future reader two places to look for one answer.

## Verification

**Commands:**
- `npm test` — expected: all existing tests pass, plus the new client cases.
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check` — expected: clean.
- `npx supabase db reset`, then every file under `supabase/tests/` — expected: 37 pass, 0 fail, with
  `6-4-*` and `6-5-*` passing unmodified.
- `npm run migrations:check` — expected: the new migration reported as not yet pushed.

## Suggested Review Order

**The privacy boundary — read this first**

- The whole story in one line: a commitment-day row is the author's own record, so the referee stops here.
  [`20260903120000…sql:344`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L344)

- The object side of the same narrowing, asked of the path because an object can outlive its row.
  [`20260903120000…sql:359`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L359)

- `security definer` because a referee cannot read `commitment`, so a plain `exists` would be false for everything.
  [`20260903120000…sql:321`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L321)

- The assertion that keeps all three honest: zero for a record, one for a claim's proof.
  [`6-8…sql:423`](../../supabase/tests/6-8-a-photo-i-can-keep-against-any-commitment.sql#L423)

**The third parent kind**

- Two columns rather than a slot table; `for_day` exists only for this kind.
  [`20260903120000…sql:52`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L52)

- The biconditional becomes a count, because three terms do not read as one.
  [`20260903120000…sql:80`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L80)

- `for_day` is refused on the two parents that derive their own day.
  [`20260903120000…sql:91`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L91)

- The path still leads with whichever parent this row has — that prefix is the access rule.
  [`20260903120000…sql:100`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L100)

- A third branch: owner from the commitment, day from the row, refusals reused rather than restated.
  [`20260903120000…sql:110`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L110)

- `objects.name` qualified in every branch — a bare `name` binds to `commitment.name` and silently matches nothing.
  [`20260903120000…sql:264`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L264)

**The flag, and why nothing clears it**

- A plain boolean, defaulted off, read by no settlement path.
  [`20260903120000…sql:33`](../../supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql#L33)

- On the draft with no kind or cadence gate, unlike a due time.
  [`commitment.ts:70`](../../lib/commitment.ts#L70)

- Survives a kind or cadence change, because no kind makes a record meaningless.
  [`commitment.ts:354`](../../lib/commitment.ts#L354)

- Read back so an edit that never touches the checkbox cannot silently turn it off.
  [`commitment-list.tsx:71`](../../components/commitment-list.tsx#L71)

- One checkbox mirroring the money one, and deliberately no warning beside it.
  [`commitment-form.tsx:261`](../../components/commitment-form.tsx#L261)

**The control on Today**

- Outside the timed block entirely; a due time suppresses it so one row never offers two.
  [`today.tsx:685`](../../components/today.tsx#L685)

- One parent union, one clock — the capture guard and `for_day` can no longer disagree across midnight.
  [`today.tsx:404`](../../components/today.tsx#L404)

- The control goes at midnight, and so does yesterday's message about it.
  [`today.tsx:222`](../../components/today.tsx#L222)

- The column that makes the whole feature exist at runtime, now asserted by a test.
  [`today.tsx:73`](../../components/today.tsx#L73)
