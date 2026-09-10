---
title: 'The referee can see what the day was proved with'
type: 'feature'
created: '2026-09-08'
status: 'approved'
review_loop_iteration: 0
baseline_commit: 'd046be123da6d24405d8b9f83f5aacc1660be330'
closes_action_item: 'epic-6-retro-item-43-reconcile-the-referee-reach-with-what-th'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-6-retro-2026-09-07.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-8-a-photo-i-can-keep-against-any-commitment.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-9-a-photo-i-can-open-again.md'
  - '{project-root}/supabase/migrations/20260903140000_the_referee_may_object.sql'
  - '{project-root}/supabase/migrations/20260907160000_a_referee_belongs_to_one_doer.sql'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> Written before the work and approved before it started (2026-09-08). **Half of this item is not
> in this spec** — the copy fix landed separately because it carries no migration and closes the
> HIGH defect on its own.

## Intent

**Problem:** The referee rules on days and collects money for them, and the only photograph he can
open is one attached to a formal Appeal (`components/referee-appeal-detail.tsx`). On the one screen
where he goes looking for a day on his own initiative — `Look up a day`, the door Story 6.7 gave him
— he sees the commitment, the outcome and the objection window, and no proof at all. He is asked to
say whether a day held while the thing the day was proved with is invisible to him.

The reach is not the obstacle. `evidence: referee reads his own doer's` (`20260907160000:141`)
already grants him every evidence row of his doer's where `commitment_id is null`, which is exactly
a claim's proof, and `appeal-evidence objects: referee reads his own doer's` (`:183`) already lets
him sign the object behind it. That gap between what he may read and what he is shown is epic 6
retrospective **A2**, rated HIGH and still open.

**The one thing missing is the join.** He has no read on `declaration` at all — no
`declaration: referee ...` policy exists. So he can fetch evidence rows and cannot tell which day or
which commitment any of them belongs to. Without that, the rows are unusable to him.

**Approach:** Widen `referee_day_lookup()` rather than granting a new table read. It is already
`security definer`, already the one door this screen goes through, and already returns exactly the
row the photos would hang from. Adding the evidence paths to its result keeps the referee's raw
reach exactly where it is, and keeps this screen a single query. The client then signs each path
with the ordinary authenticated client, the way `referee-appeal-detail.tsx` already does, reusing
`EVIDENCE_BUCKET` and `EVIDENCE_URL_TTL_SECONDS`.

A new policy on `declaration` is the alternative and is rejected: it would hand him the author's
claim rows wholesale — text, timing, everything — to solve a problem that is only about photographs.

## Boundaries & Constraints

**Always:**

- **The referee's reach does not widen.** He ends this story able to read exactly the objects and
  rows he could read before it. Only the join moves, and it moves inside a `security definer`
  function that already scopes to his own doer.
- One signing path, `lib/evidence.ts`'s own constants, shared with the appeal viewer. Two signing
  loops is how two surfaces start disagreeing about who may see a photo.
- A photo that cannot be signed is reported as a count, never dropped silently — Story 6.9's rule,
  and `referee-appeal-detail.tsx`'s existing `evidenceFailures` is the shape.
- A day with no photo renders exactly what it renders today. No placeholder, no empty frame.
- Signed from the ordinary authenticated client, never a service key.
- The migration is new and numbered. The existing function is replaced by a new migration, never
  edited in place.

**Ask First:**

- Any change to `evidence_object_is_a_commitment_day()` or to either referee evidence policy. Story
  6.8 narrowed both so a commitment-day photo reaches him as neither object nor row; this story
  must not widen either, and if it appears to need to, the design is wrong.
- Granting the referee any read on `declaration`, `focus_session`, or anything else not already his.

**Never:**

- Never show him a **commitment-day** photo (Story 6.8's kept records). Those are the author's own
  archive, answer for no verdict, and are excluded by `commitment_id is null` — which stays.
- Never make this a queue. No count, no badge, no notification, nothing that arrives unasked. Story
  6.7's whole design rests on him never being sent a list of days.
- Never a delete, replace, download or share control. He looks; he does not act on the photo.
- Never change what a photo means to settlement. Nothing here touches a verdict.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Day with a proved claim | Referee names a day; a commitment on it has declaration-parented evidence | That row shows the photo | — |
| Day with no photos | Any looked-up day without evidence | Exactly what the screen shows today | — |
| Several photos on one commitment | Two evidence rows for one declaration | Both shown, in a stable order | — |
| A photo will not sign | `createSignedUrl` fails for one of three | Two shown, plus a count of what could not be opened | Never a silent drop |
| Commitment-day photo exists | Story 6.8 kept photo on the same commitment | Not shown, and not counted as a failure | `commitment_id is null` still filters it out |
| A second referee | Two referee accounts exist | Each sees only his own doer's | The function's existing `referee_of` scoping |
| Signed out | No session | The screen's existing signed-out behaviour | Unchanged |
| Objection flow | Any state of the objection window | Unchanged — photos are shown beside it, never gating it | — |

## Out of scope

- **The doer's copy.** `EVIDENCE_COPY.hint` was the other half of A2 and is already fixed.
- **Appeal detail**, which already shows evidence and is untouched.
- **Commitment-day photos** and any widening of Story 6.8's narrowing.
- **A textual signal on a kept photo** (retro item 46) — a separate item, deliberately not folded in.

</frozen-after-approval>

## Verification

- **SQL**, against a local stack (Docker was started for this; nothing touched the live project):
  `supabase/tests/the-referee-can-see-what-the-day-was-proved-with.sql` — all assertions pass. It
  proves both halves at once: the referee gets the claim's storage path, a commitment with no proof
  comes back as an empty array rather than null, Story 6.8's kept photo does **not** reach him,
  another doer's day returns nothing, a doer calling the function gets zero rows, and — the one the
  design rests on — he still reads **zero** rows from `declaration`, with `select` granted to
  `authenticated` at the top of the file so RLS is the only thing refusing him.
- The SQL test was watched to fail before the migration was applied (`column "evidence_paths" does
  not exist`), so it is not passing vacuously.
- `npm test` — 1381 passed, 52 files. Six new cases in `components/referee-day-lookup.test.tsx`:
  the photo renders, several are numbered, a day with no proof renders nothing and makes no signing
  call at all, every photo on the day is signed in **one** call, a photo that will not sign is
  reported as a count beside the ones that did, and a signing call that fails outright does not
  fail the lookup.
- `npm run lint`, `npm run format:check`, `npm run build` — all clean.

**Both blockers cleared 2026-09-10.**

- **On the remote project.** `20260908170000` was pushed with `npx supabase db push --linked`, on
  the maintainer's instruction, alongside the two other migrations that had been sitting local-only.
  `migrations:check` reports all 76 matching. Note what the delay cost while it lasted: the
  deployed client selected `evidence.swept_at`, a column `20260908180000` creates, and
  `referee-appeal-detail.tsx` treats a failed evidence read as a failed screen — so the referee's
  appeal detail rendered as one error line for two days. Not this story's defect, but its own
  migration was in the same unpushed batch.
- **Browser pass, on production.** hwt75 opened `/referee/day`, looked up 2026-09-09, and saw the
  photograph. That is the claim no test in this repository could make.

Checked read-only against production beforehand, so the browser visit was confirming rather than
discovering: `referee_day_lookup()` returns `evidence_paths` with one real path for that day
(`Gym`, outcome `held`, `already_objected: false`), the referee's own session signs a URL for that
exact object, and `profile.referee_of` pairs him to the account whose day it is.

## Status

`done` on 2026-09-10. Implemented 2026-09-08, on the remote project and seen in a browser
2026-09-10.

## Commits

| Commit | Scope |
| --- | --- |
