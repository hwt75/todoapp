---
title: 'Story 8.3 — The photograph reaches the referee'
type: 'feature'
created: '2026-09-14'
status: 'in-review'
review_loop_iteration: 0
baseline_commit: 'b0cfa6a065ccf306bd297f474655df852a371df9'
story_key: '8-3-the-photograph-reaches-the-referee'
context:
  - '{project-root}/_bmad-output/specs/spec-commitments-the-referee-signs-off/SPEC.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-8-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-8-2-the-referee-s-decision-and-what-a-refusal-costs.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-epic-6-retro-item-43-the-referee-can-see-what-the-day-was-proved-with.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-09-14 by hwt75** — including all three decisions below, and specifically decision 1:
> `sign_off_day()` is refactored onto the new predicate inside this story rather than left for Story
> 8.4 to consolidate, so that four expressions of one money-deciding rule never coexist. Approved at
> full length above the 1600-token guidance, as Stories 8.1 and 8.2 were and for the same reason — the
> Code Map is what keeps the implementer out of a blind search, and this story's own investigation
> found the brief wrong in three places. Frozen from here.
>
> **ASK FIRST ANSWERED 2026-09-14 by hwt75.** Implementation surfaced that the author's copy has
> nothing to read but the live column while all three server askers read the flag as of the day — so
> for the rest of any day the author moves the flag, copy and policy disagree, and switching it *off*
> makes the app say "only you" while the referee still reaches today's photograph. That is A2 itself,
> inside the story that is A2's consent answer. hwt75 **grants `authenticated` EXECUTE on
> `requires_referee_approval_as_of()`**, answering here the question `20260911090000:240-245` reserved
> for Story 8.6. He was told what it costs and chose it anyway: the function takes an arbitrary
> `p_commitment_id` and performs no ownership check, and an ownership check cannot be added because
> settlement calls it from cron where `auth.uid()` is null. What it exposes is one boolean about a uuid
> the caller must already know. This does **not** reverse decision 2, which is about the policy
> mechanism and stands unchanged.

## Intent

**Problem:** Story 8.2 lets the referee refuse a flagged commitment-day, and `sign_off_day()` already
requires a photograph before he may. But a commitment-day photograph is one he cannot open: both
referee policies exclude it by `commitment_id is null`, narrowed there deliberately by Story 6.8. He
can be asked to judge proof he is forbidden to see.

**Approach:** Widen both referee policies — the `evidence` row and the `storage.objects` byte — for a
commitment-day photograph on a commitment flagged **as of that day**, and no other. Then make the
author's copy say so, because a photograph he marked for sign-off is one he chose to show.

## Boundaries & Constraints

**Always:** The flag is read through `requires_referee_approval_as_of()`, never live. Both policies
widen together and on the same predicate — a photograph that is listable and unopenable, or openable
and unlistable, is the failure this story exists to avoid. The widening reaches a flagged
commitment-day and nothing else: an unflagged commitment-day photograph stays exactly as private as
Story 6.8 made it, and no referee reaches an account he is not paired to. The copy changes with the
policy, in the same commit.

**Ask First:** Granting `authenticated` EXECUTE on `requires_referee_approval_as_of()` (decision 2
says why not). Any change to the author's own policies, to `evidence_derive_owner()`, or to
`evidence_object_must_exist()`. Any referee write path. Widening what the referee reads on an
*unflagged* commitment.

**Never:** No referee surface and no new list — Story 8.4 owns what he is shown, and this story is
deliberately reach without visibility, the way Story 8.1 was a flag nothing read. No change to
`sign_off_day()`'s decision logic, to settlement, or to the objection path. No appeal-evidence
change. No retention or sweep change.

## The three decisions worth your attention

**1. "Which photograph may the referee see" now has three askers, and they must become one.**
`sign_off_day()` already answers it, unioning both parentages at
`20260914090000:384-396`, and its own comment says *"Story 8.4's list must ask this same question; the
two must not be able to disagree."* This story adds the third and fourth askers — the `evidence`
policy and the `storage.objects` policy. Four expressions of one rule is how they come to disagree,
which is the shape all three of Story 8.2's review rounds found and what Epic 6 retrospective item 50
names. One `security definer` predicate is written here, both new policies rest on it, and
`sign_off_day()` is refactored onto it in the same change. Story 8.4 then has one door to walk
through rather than a fourth thing to re-derive.

**2. The inline-the-lookup pattern cannot carry this, and the guard must not be edited to fit.** The
seven policies of `20260907160000:130-192` inline `(select pr.referee_of from public.profile pr where
pr.id = (select auth.uid()))` rather than call `paired_doer_id()`, and `:76-79` says why: granting the
function *"would have meant editing a security guard to fit new code, which is the wrong direction."*
That pattern works only because the inlined read is of the caller's own `profile` row, which
`profile: read own` already permits. It cannot work here: the flag's history lives in
`commitment_requires_referee_approval_change`, which carries `revoke all` **and** an explicit deny-all
policy (`20260911090000:111-117`), so an inlined subquery evaluated as the referee returns nothing —
silently, which is the worst way for an authorization predicate to fail. Nor may the policy reach for
`requires_referee_approval_as_of()` instead: a policy predicate that leans on a client grant is a
policy whose correctness depends on an ACL, and `supabase/tests/2-1-roles-and-rls.sql:535` is the guard
that says so. *(The client grant hwt75 later made — see the Ask First note above — is a different
question with a different answer: it is what the author's **copy** reads, and no policy rests on it.
The two must not be conflated, and the migration comment must say which is which.)* The precedent that
fits is
`evidence_object_is_a_commitment_day()` and `evidence_object_owner()` — narrow `security definer`
helpers called *from* a storage policy and granted to `authenticated`, justified at
`20260903120000:315-320` and `20260907160000:120-123` because each answers one fact about an argument
the caller already named and exposes no column of anything.

**3. The copy is already false today, in the direction nobody checked.** `EVIDENCE_COPY.hint` reads
*"A photo taken today. Only you and your referee can open it."* and is rendered at **two** sites in
`components/today.tsx` — the claim control at `:722`, where it is true, and the Story 6.8 all-day
control at `:809`, where the referee cannot open the photograph at all. The constant's own comment
(`lib/evidence.ts:404-406`) asserts it *"appears only under a claim's Proof control"*, which
`today.tsx` disproves. This is Epic 6 retrospective A2 inverted: last time the app promised privacy
the policy did not keep, this time it promises a reach the policy does not grant. It fails toward
privacy, which is why nobody noticed. After this story the sentence is true for a flagged
commitment-day and still false for an unflagged one, so it has to branch on the flag rather than be
corrected once.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Flagged commitment-day | Referee reads his paired doer's `evidence` row for a commitment flagged as of that day | Row readable, and the object behind it signs a URL | N/A |
| Unflagged commitment-day | Same, flag off as of that day | Neither row nor object reachable — Story 6.8's narrowing stands | Empty result, never an error |
| Flag switched off afterwards | Flagged on the day, unflagged today | Still reachable: the flag is read as of the day the photograph belongs to | N/A |
| Flag switched on afterwards | Unflagged on the day, flagged today | Not reachable — the flag reaches forward only | Empty result |
| Not his account | Referee paired to a different doer, or unpaired | Nothing, by the conjunct every one of the seven policies already carries | Empty result |
| Doer session | The author reads his own | Unchanged by this story | N/A |
| Claim-parented photograph | Declaration-parented, flagged or not | Unchanged — already reachable since Story 4.6 | N/A |
| Object with no `evidence` row | An orphaned upload under a commitment id | Not reachable by the referee: the predicate resolves through the row | Empty result |
| Swept photograph | `evidence.swept_at` set, bytes gone | Row still reachable if flagged; the object is absent, so signing fails as it does for the author | The caller reports it cleared, never as a failure |
| The author's copy | All-day photo control, sign-off on | Says the referee opens this one | N/A |
| The author's copy | All-day photo control, sign-off off | Does **not** say the referee can open it — because he cannot | N/A |
| Copy on a day the flag moved | Flag switched **off** this morning; today's photograph still reaches the referee | Still says the referee opens it — the copy reads the flag as of the day, as the policy does | N/A |
| Copy on a day the flag moved | Flag switched **on** this morning; today's photograph does **not** reach him until tomorrow | Today does **not** say he opens it | N/A |
| The setup form, same day | Sign-off unticked this morning on a commitment flagged when the day began | Still names the referee — it does not say the photograph decides nothing, because today it still does | N/A |
| The read did not come back | The as-of answer is NULL, or the call failed | No sentence at all about who can open it. `false` is the sentence that claims privacy, and claiming privacy on an answer that never arrived is the one direction that is never safe | Silent; the helper line is absent |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260907160000_a_referee_belongs_to_one_doer.sql:140-149` — the live
  `"evidence: referee reads his own doer's"` policy, the one to replace. `:182-192` is its
  `storage.objects` twin, `"appeal-evidence objects: referee reads his own doer's"`. **These two are
  the pair that must move together.** `:76-79` is the inline-rather-than-grant reasoning decision 2
  declines to follow, and `:93-123` is `evidence_object_owner()` — the definer-helper-called-from-a-
  policy shape to copy, grant and all.
- `supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql:315-342` —
  `evidence_object_is_a_commitment_day()`, the closest precedent: a `security definer` boolean about a
  path, granted to `authenticated`, with the argument at `:315-320` for why a policy subquery could
  not do it. `:344-355` is where Story 6.8 added `commitment_id is null` to the evidence policy;
  `:357-372` where it added the object exclusion. `:52-53,79-92` the `commitment_id`/`for_day` pair and
  the parentage CHECKs; `:99-103` `evidence_storage_path_leads_with_its_parent`, which is what lets a
  path be resolved to a parent id at all.
- `supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql:384-396` —
  `sign_off_day()`'s photograph guard, already unioning both parentages, and `:382-383` its comment
  asking for exactly the single door decision 1 builds. **Refactor this onto the new predicate; do not
  leave two copies.** Note it does not filter `swept_at`, and say in the new function which way that
  settles.
- `supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql:184-245` —
  `requires_referee_approval_as_of()`, revoked from every client role at `:240-245`, whose comment
  names Story 8.6 as the first client reader. It stays revoked; the new helper is what calls it.
- `supabase/migrations/20260908180000_a_photo_does_not_outlive_its_usefulness.sql:147-189` —
  `referee_day_lookup()`, which excludes commitment-day photographs by join *and* by
  `e.commitment_id is null`. **Not widened here** — Story 8.4 owns what he is shown. Leave it and say
  so, so the next reader knows it was a decision.
- `supabase/migrations/20260824130000_contest_a_miss_the_machine_got_wrong.sql:299-312` — the author's
  two policies and the deliberate absence of update/delete. `:309`'s `role_from_table() = 'doer'` is
  why no referee write path exists and none is added.
- `lib/evidence.ts:393-407` — `EVIDENCE_COPY.hint` and the A2 rationale comment whose last paragraph
  decision 3 falsifies. `:148` `EVIDENCE_BUCKET`, `:157` the TTL, `:253-333` `readKeptPhotos()` — the
  author's batching helper, not the referee's.
- `components/today.tsx:702-722` the claim control, `:790-809` the all-day control — **both render the
  same hint**, and only the first one is telling the truth. Check whether the row this control sits on
  even carries `requires_referee_approval`; Story 8.1 added the column to `components/commitment-list.tsx`
  and this is a different query.
- `lib/commitment.ts:244-270` `KEPT_PHOTO_COPY` with its three keys, and `components/commitment-form.tsx:319-325`
  the three-way mutually exclusive selection. The doc comment at `:244-256` already states the rule
  this story inherits — the copy moves to match the rule, and it is tested.
- `lib/evidence.test.ts:100-117` — the A2 copy test, asserting the *promise* by regex rather than the
  wording. The new assertions join it in that idiom. `lib/commitment.test.ts:740-770` and
  `components/commitment-form.test.tsx:526-536` are the clause-level and render-level twins.
- `supabase/tests/the-referee-can-see-what-the-day-was-proved-with.sql` — **asserts today that a
  Story 6.8 kept photo does not reach the referee.** That assertion becomes wrong for a flagged
  commitment and must be split, not deleted: unflagged still must not reach him.
- `supabase/tests/2-1-roles-and-rls.sql:460-463,526-560` — the unreachable-functions sweep. The new
  helper is granted and therefore belongs in the *commented exclusions*, beside
  `evidence_object_owner()`, never in the array.
- `supabase/tests/README.md:118-143` — staging `storage.buckets` and `storage.objects` before an
  `evidence` row, including rows expected to be refused. `supabase/config.toml:136-139` is where the
  bucket's `public = false` lives, since no migration can create it.

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/2026<date>_the_photograph_reaches_the_referee.sql` — **(i)** one
      `security definer` predicate answering "is this commitment-day flagged as of its own day",
      reading the flag only through `requires_referee_approval_as_of()`, plus whatever thin path→row
      resolution the storage policy needs; revoked from `public, anon`, granted to `authenticated`,
      with the `evidence_object_owner()` argument for why the grant exposes nothing. **(ii)** drop and
      recreate both referee policies on the same predicate — `public.evidence` and `storage.objects`.
      **(iii)** `create or replace public.sign_off_day()`, its body verbatim but its photograph guard
      reading the new predicate, so decision 1's single door is real rather than intended.
- [x] **The grant, and the guard that records it** — `grant execute on function
      public.requires_referee_approval_as_of(uuid, date) to authenticated` in the same migration, with
      a comment saying it exists for the author's copy and that no policy predicate may rest on it.
      Move its entry in `supabase/tests/2-1-roles-and-rls.sql` out of the must-be-revoked array into
      the commented exclusions beside `has_paired_referee()`, carrying hwt75's reasoning and its cost —
      arbitrary `p_commitment_id`, no ownership check, and why one cannot be added.
- [x] `lib/evidence.ts` — branch `EVIDENCE_COPY.hint` so the referee sentence is said for a flagged
      commitment-day and not for an unflagged one, and correct the constant's own comment, which
      currently claims a render site that does not exist.
- [x] `components/today.tsx` — pass whatever the branch needs to the all-day control, and only there;
      the claim control's sentence is already true and must not change. The value passed must be the
      flag **as of the day the photograph belongs to**, read through the newly granted
      `requires_referee_approval_as_of()`, never the live column.
- [x] `lib/evidence.test.ts`, `lib/commitment.test.ts`, `components/today.test.tsx` — the promise
      asserted by regex in both directions: said when flagged, **absent** when not. The absence is the
      half that catches a branch wired backwards. Add the two matrix rows for a day the flag moved,
      which a live-column read passes and an as-of read does not.
- [x] `supabase/tests/8-3-the-photograph-reaches-the-referee.sql` — a referee session reading the row
      and an author session reading his own; every matrix row; the flag switched off after the day and
      on after it; an orphan object; a swept row. Assert the object arm and the row arm **separately**,
      because widening one and not the other is the specific failure.
- [x] `supabase/tests/the-referee-can-see-what-the-day-was-proved-with.sql` — split its kept-photo
      assertion into flagged (reaches him now) and unflagged (still does not).
- [x] `supabase/tests/2-1-roles-and-rls.sql`, `supabase/tests/README.md`,
      `_bmad-output/implementation-artifacts/sprint-status.yaml` — the exclusion comment, the table row,
      the status.

**Acceptance Criteria:**

- Given a commitment unflagged as of a day, when its paired referee reads that day's kept photograph
  by row and by object, then he gets nothing both times — and the pre-existing SQL files prove the
  rest of his reach is unchanged by passing unmodified.
- Given one flagged commitment-day, when the referee reads it, then the `evidence` row and the
  `storage.objects` row are reachable in the same session; neither alone.
- Given a commitment flagged on the day and unflagged since, when the referee reads that day, then the
  photograph is still reachable.
- Given `sign_off_day()` and the two policies, when the predicate changes, then all three change —
  there is exactly one expression of the rule in the schema.
- Given the all-day photo control with sign-off off, when it renders, then no sentence on screen says
  the referee can open the photograph.

## Spec Change Log

### 2026-09-14 — iteration 0, Ask First answered: the copy read a flag the policy does not

**Triggering finding.** Raised by the implementing agent before any review layer ran. Every server
asker reads the flag through `requires_referee_approval_as_of()`, which returns the value in force at
`day_begins_at(p_day)` (`20260911090000:199-209`). The author's copy had nothing to read but
`commitment.requires_referee_approval`, the live column. So on any day the author moves the flag the
two disagree for the rest of it — and in the dangerous direction: switched **off** at 10:00, the
policy still lets the referee open today's photograph while the copy says *"Only you can open it."*
That is Epic 6 retrospective A2 exactly, re-created inside the story that exists to be its consent
answer.

**What was considered.** Three ways out were put to hwt75: a new narrow `security definer` helper
answering only the flag half, scoped to the caller's own commitment; granting the reader itself; or
recording it and closing in Story 8.6, which `20260911090000:240-245` already names as the first
client reader. **He chose the grant**, with the cost stated: the function takes an arbitrary
`p_commitment_id` and performs no ownership check, and one cannot be added — settlement calls it from
cron, where `auth.uid()` is null. The exposure is a single boolean about a uuid the caller must
already know.

**Amended.** The frozen block records the answered Ask First. Decision 2 gains the distinction it now
needs: the *policy* may not rest on a client-granted ACL, and does not; the *copy* may, and does.
Two matrix rows cover the day the flag moves, in both directions. Tasks gain the grant, the client
read, and the move of the function's entry in `2-1-roles-and-rls.sql` from the must-be-revoked array
to the commented exclusions — the guard is not being edited to fit the code, it is being told a
decision.

**Known-bad state avoided.** Shipping A2 a second time, in the story whose whole premise is that the
app's promise and the policy move together.

**KEEP — must survive.** The three-call-site discipline of decision 1 and the separate row-arm /
object-arm assertions, both of which the implementation already proved by watching each fail alone.
The grant is for the copy only: no policy predicate may call `requires_referee_approval_as_of()`.

### 2026-09-14 — implementation, superseded the same day: what the first pass recorded, and why it did not stand

**Superseded by the entry above.** Kept rather than deleted, because the finding is the same one and
only its disposition changed — and because the correction made to the report is worth keeping too.

The implementation first shipped the copy reading the live
`commitment.requires_referee_approval` column, recorded the disagreement in `deferred-work.md`, and
argued that closing it *had* to mean the frozen Ask First question. **That argument was wrong in
one place.** A third door existed and was not named: a second narrow `security definer` helper
answering only the flag half needs no grant at all, exactly as `photograph_reaches_the_referee()`
needs none. The reason that function could not be reused for the copy is real and worth stating —
it demands a photograph *exist*, and the hint renders before the author has taken one — but that is
an argument for a second helper, not for a grant. hwt75 was shown all three doors and chose the
grant anyway.

What the first pass got right and what stands: the finding itself, its direction of failure, and
that it belongs in this story rather than in 8.6. The `deferred-work.md` entry it wrote has been
removed, because nothing is deferred.

## Design Notes

**The storage policy has only a path; the rule needs a day.** `evidence_storage_path_leads_with_its_parent`
(`20260903120000:99-103`) guarantees the first folder is the parent id, so a commitment-day object's
path yields a commitment — but never its `for_day`, which is the argument
`requires_referee_approval_as_of()` needs. Resolve it through the `evidence` row
(`storage_path = objects.name`), inside the definer function so RLS does not make the lookup
disappear. The consequence is in the matrix and is the right one: an object with no row is not
reachable by the referee. It proves nothing, Story 8.4's list is driven by rows, and an orphan failing
closed is the safe direction.

**`swept_at` has three behaviours already, and this story must not invent a fourth.**
`referee_day_lookup()` filters swept rows server-side (`20260908180000:176-179`); the appeal detail and
`readKeptPhotos()` filter client-side and *count* them as cleared; `sign_off_day()`'s guard does not
filter at all. The policy should not filter either — the row is metadata, the bytes are what is gone,
and a caller signing a URL for a swept object already learns that. State this in the function's comment
rather than leaving the fourth reader to guess.

**Widening a policy is a `drop policy` + `create policy`.** There is no in-place predicate change, and
both referee policies must land in one migration. `20260907160000:140,182` shows the drop-then-create
idiom for exactly these two.

## Verification

**Commands:**

- `npx supabase db reset` then every file under `supabase/tests/` — expected: all pass, and every
  pre-existing file unmodified except `the-referee-can-see-what-the-day-was-proved-with.sql`,
  `2-1-roles-and-rls.sql` and `README.md`, each for the reason named in Tasks.
- `npm test`, `npx tsc --noEmit`, `npm run lint`, `npm run format:check`, `npm run build` — clean.
- `npm run migrations:check` — reports the new file as not yet on the remote.

**Manual checks:**

- The new predicate appears in exactly three places: two policies and `sign_off_day()`. `grep` for it
  and count.
- `git diff` shows no change to `referee_day_lookup()`, to the author's policies, to
  `evidence_derive_owner()`, or to `evidence_object_must_exist()`.

**Run 2026-09-14, after three review layers and the patches they asked for.**

- `npx supabase db reset` then all 48 files under `supabase/tests/` — **all pass.** 44 pre-existing
  files passed **unmodified**; the three named above are the only ones touched, each for its stated
  reason. `8-2-the-referee-s-decision-and-what-a-refusal-costs.sql` passing unmodified is what
  proves the `sign_off_day()` refactor changed no decision it makes.
- **Watched to fail before it could pass, twice, once per arm.** Re-running the new file with only
  the *old* `evidence` policy restored: `Row arm, "flagged as of that day": the referee read 0
  evidence row(s), wanted 1.` With only the old `storage.objects` policy restored: `Object arm,
  "flagged as of that day": the referee read 0 storage.objects row(s), wanted 1. The row arm
  answered 1 …`. Neither arm can pass on the other's work.
- `npm test` — 1481 passed, 53 files. `npx tsc --noEmit`, `npm run lint`, `npm run format:check`,
  `npm run build` — all clean. `node scripts/test-sign-off-race.mjs` and
  `node scripts/test-current-penalty-race.mjs` — both PASS.
- `npm run migrations:check` — `1 local migration(s) not on the remote project: 20260914120000`, as
  expected.

**Six mutants watched, each caught by the assertion written for it and by no other.**

| Mutant | Caught by |
| --- | --- |
| `evidence` policy back to `commitment_id is null` | `8-3` loop, row arm: *"the referee read 0 evidence row(s), wanted 1"* |
| `storage.objects` policy back to the Story 6.8 exclusion | `8-3` loop, object arm — and its message names the row arm's answer of 1, which is the disagreement itself |
| `components/today.tsx` back on the live column | `today.test.tsx` — **4 failed**: both flag-moved-today rows, the plain flagged row, and the failed-read row |
| `components/commitment-form.tsx` back on the live draft flag | `commitment-form.test.tsx` — *"keeps naming the referee after sign-off is unticked on a day it was on"* |
| Either referee policy widened past its flag arm | `the-referee-can-see-what-the-day-was-proved-with.sql` step 2c — separately for the row arm and the object arm, which is what makes the fixture fix real rather than asserted |
| The day stamp dropped from Today's stored reach read | `today.test.tsx` — *"drops yesterday's answer the moment the day turns over"* |
| Unknown falling back to `hint(false)` | `today.test.tsx` — *"says nothing at all when the read does not come back"*, which before the review could not fail for its own defect |

**Manual checks, done.**

- `grep -rn photograph_reaches_the_referee supabase/migrations/` — three call sites and no fourth:
  `:138` inside `commitment_day_object_reaches_the_referee()` (which is what the `storage.objects` policy
  calls), `:186` in the `evidence` policy, `:417` in `sign_off_day()`. Everything else that matches
  is prose. Step 7 of the new SQL file asserts the same thing against the catalog, so a later
  `create or replace` that re-derives the union fails a test rather than passing a grep.
- `git status` — **no migration file other than the new one is touched.** `referee_day_lookup()`,
  the author's two policies, `evidence_derive_owner()` and `evidence_object_must_exist()` all live
  in files that did not change, and the new migration names them only in comments.

## Suggested Review Order

**Start here — the one predicate, and the three places it is allowed to be**

- The rule itself: flag as of the day, unioned with the photograph that proves it.
  [`20260914120000:62`](../../supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql#L62)

- The path→row resolver, named for the one arm it answers and forbidden standalone.
  [`20260914120000:135`](../../supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql#L135)

- Call site three: the guard Story 8.2 shipped, moved onto the shared door in one hunk.
  [`20260914120000:306`](../../supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql#L306)

**Both policies, or neither**

- The row arm. Listable-but-unopenable is the failure this story exists to avoid.
  [`20260914120000:242`](../../supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql#L242)

- The object arm, widened as a disjunct so an orphaned appeal upload stays readable.
  [`20260914120000:270`](../../supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql#L270)

**The grant hwt75 answered for, and its fence**

- For the author's copy only; the comment says which question it is not.
  [`20260914120000:223`](../../supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql#L223)

- The guard file told a decision rather than edited to fit — plus the catalog check that no policy leans on it.
  [`2-1-roles-and-rls.sql:527`](../../supabase/tests/2-1-roles-and-rls.sql#L527)

**The copy, which had to stop reading the live flag**

- The hint became a function of who can open it, not of what the column says today.
  [`evidence.ts:570`](../../lib/evidence.ts#L570)

- The reader, stamped with its own subject so a stale answer cannot be shown.
  [`evidence.ts:478`](../../lib/evidence.ts#L478)

- The fourth surface, found by review: the form named the referee off the draft flag.
  [`commitment-form.tsx:338`](../../components/commitment-form.tsx#L338)

**The proofs**

- Row arm and object arm asserted separately per case — each watched to fail alone.
  [`8-3-…sql:414`](../../supabase/tests/8-3-the-photograph-reaches-the-referee.sql#L414)

- Story 6.8's narrowing, still standing for everything unflagged.
  [`8-3-…sql:550`](../../supabase/tests/8-3-the-photograph-reaches-the-referee.sql#L550)

- The two assertions review found vacuous, now pointed at the right account.
  [`the-referee-can-see…sql:233`](../../supabase/tests/the-referee-can-see-what-the-day-was-proved-with.sql#L233)
