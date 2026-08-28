---
title: 'Story 6.3 — Evidence detaches from an appeal'
type: 'feature'
created: '2026-08-28'
status: 'approved'
review_loop_iteration: 0
baseline_commit: '0114c34'
story_key: '6-3-evidence-detaches-from-an-appeal'
context:
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/brownfield.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-2-a-same-day-claim-lands-on-the-day-it-was-made.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> No spec checkpoint on this story (`stories.yaml`). It carries a **done checkpoint** instead:
> nothing here is provable without a real camera and a real file, so it stops for hwt75.

## Intent

**Problem:** Photo evidence already exists in this product and can only ever appear *downstream of
a loss*. `appeal_evidence.appeal_id` is `not null`, so a photo cannot exist without an appeal, and
an appeal cannot exist without a machine-filed miss to contest. Story 6.2 gave the author a way to
claim a timed commitment at the moment he does it, and that claim currently proves nothing — it is
a tap, which is the same word he could type the next morning.

**Approach:** Detach the evidence store from the appeal it was born attached to. One table, one
bucket, one owner-derivation trigger, now able to hang a photo off either an appeal or a
declaration. Everything that makes the existing store trustworthy is kept exactly: the owner is
derived server-side from the parent row, the capture date must match the day being proven, and the
bucket stays private with access derived from that ownership.

This story stores a photo against a claim. It does not decide whether a day held — that reading is
Story 6.4 — and it does not give the referee a way to see or contest one, which is Story 6.7.

## Boundaries & Constraints

**Always:**
- `owner_id` is derived by the trigger from the parent row and never trusted from the client. It is
  the exact fact the bucket's `storage.objects` policies depend on (NFR4).
- `captured_on` must equal the day being proven. An old photo proves nothing.
- The bucket stays private. Access is derived from ownership, never granted by a URL.
- The storage path leads with the parent row's own id, because that is what
  `storage.foldername(name)` reads to derive access.
- An untimed commitment and every existing appeal behave exactly as they do today.

**Ask First:**
- A second bucket, or a second evidence table. One store, or the rules that make it private have to
  be written twice and will drift.
- Anything that lets the referee read claim evidence. That is Story 6.7 and it arrives with the
  objection, not before — a referee who can see proof but cannot act on it is a surveillance
  feature nobody asked for.

**Never:**
- Do not add an EXIF dependency. `lastModified` is the accepted limitation and is documented as one.
- Do not decide a verdict. Whether a claimed day holds is Story 6.4.
- Do not let a photo reopen a day that has already been settled and frozen.

## The four decisions worth your attention

**1. The table is renamed to `evidence`, because `appeal_evidence` would become a lie.**
A table holding photos that prove ordinary days, named for the dispute mechanism that happened to
need it first, is the kind of name this codebase spends whole comment blocks avoiding. `alter table
rename` carries policies, indexes and foreign keys with it, the function and trigger are renamed to
match, and the 32 database checks run in under a minute — the risk that would once have justified
leaving the name alone no longer exists.

**The bucket keeps its name.** `appeal-evidence` is where the objects already are, and renaming a
bucket means moving every object in it. The mismatch is recorded in `supabase/config.toml` and in
the migration rather than papered over.

**2. Exactly one parent, and the storage path leads with whichever it is.**
`appeal_id` becomes nullable, `declaration_id` is added, and a check enforces that exactly one is
set — the same biconditional shape `commitment_weekly_quota_targets` uses. The `storage_path`
check becomes `coalesce(appeal_id, declaration_id)::text || '/%'`, and both storage policies gain a
declaration branch. Both parents are uuids, so nothing about the folder-name derivation changes.

**3. A claim's photo is refused after midnight; an appeal's is not.**
The rule from `SPEC.md` — no photo by the end of the local day is a failed day — is enforced here,
at the insert, rather than left for settlement to discover. This follows Story 6.2's precedent
exactly: refusing at the moment of the act is legible, and silently accepting something that will
not count is not.

It applies **only** to declaration-parented evidence. An appeal is contesting a day that has
already closed, and its evidence lives on the appeal's own deadline; binding it to the midnight of
the day it proves would break a path that works today.

**4. A queued claim has no photo, and cannot have one until it lands.**
Evidence references a `declaration` row by id, and a claim made without a connection has no row and
no id — it is sitting in the offline queue. So the upload control appears only once the claim has
actually reached the server. `submitDeclaration()` returns that id on the way through, including on
its own duplicate retry, where the id is read back rather than invented.

This is the honest shape of the split `SPEC.md` chose, and it is worth stating plainly: the claim
survives having no signal, the photo does not. A basement claim at 20:14 with no signal until
morning is a claim that stands and a photo that never arrives — which, by "midnight is death", is a
failed day. `SPEC.md` already carries this as an accepted consequence and CAP-8 already says it out
loud on the setup screen.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Photo on an appeal | As today | Unchanged in every respect | — |
| Photo on a claim, same day | Claim exists, photo captured that day | Stored; owner derived from the declaration | — |
| Photo captured on another day | `captured_on` ≠ the declaration's `for_day` | **Refused** | Trigger raises; the form refuses first |
| Photo uploaded after midnight | Claim for day D, insert on D+1 | **Refused** | Trigger raises — the deadline is the end of D |
| Same, but on an appeal | Appeal for day D, insert on D+1 | Accepted | Appeals keep their own deadline |
| Neither parent set | Both null | **Refused** | Exactly-one check |
| Both parents set | Both non-null | **Refused** | Same check |
| Path not under the parent's id | `storage_path` leads elsewhere | **Refused** | Path check, and the object policy refuses too |
| Another account's declaration | `declaration_id` not owned by the caller | **Refused** | Trigger reads the parent and raises |
| Claim still in the offline queue | No connection | No upload control offered | Nothing to reference yet |
| Second photo on the same claim | Another file | Accepted — evidence is a list, not a column | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260824130000_contest_a_miss_the_machine_got_wrong.sql` — the table, its
  RLS, and the two `storage.objects` policies that derive access from `appeal.owner_id`.
- `supabase/migrations/20260827100000_evidence_must_be_dated_the_day_it_proves.sql` — `captured_on`
  and the trigger that refuses a mismatch. The rule is kept; the trigger learns a second parent.
- `supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql`,
  `20260825090000_the_referee_rules.sql` — the referee's read policies, which follow the rename and
  gain nothing else in this story.
- `lib/appeal.ts` — `evidenceObjectPath()`, `fileCapturedOn()`, `isEvidenceDated()`. All three are
  parent-agnostic already and move to a shared module.
- `components/appeal-form.tsx` — the upload flow to copy, and the one that must keep working.
- `lib/declaration-write.ts` — must return the declaration's id so a claim has something to attach
  to.
- `components/today.tsx` — where the upload control goes.
- `supabase/tests/4-4-*.sql`, `4-5-*.sql`, `4-6-*.sql`, `2-1-*.sql`, `epic-4-retro-*.sql` — every
  file naming the old table, all of which must still pass.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_evidence_detaches_from_an_appeal.sql` — rename the table, function
  and trigger; make `appeal_id` nullable; add `declaration_id`; the exactly-one check; the
  storage-path check on whichever parent; the trigger deriving owner and day from either parent and
  refusing a claim's photo after midnight; the declaration branch on both storage policies.
- [x] `lib/evidence.ts` — the path builder and the capture-date rules, moved from `lib/appeal.ts`
  and no longer named for appeals. Its own test file.
- [x] `lib/appeal.ts` — re-export or import rather than keep a second copy.
- [x] `lib/declaration-write.ts` — return the declaration id on a landed write, read back on a
  duplicate retry.
- [x] `components/today.tsx` — an upload control on a landed claim, refusing a wrong-dated file
  before it reaches Storage.
- [x] `components/today.test.tsx` — the control appears only after a claim lands, and not for a
  queued one.
- [x] `supabase/tests/6-3-evidence-detaches-from-an-appeal.sql` — both parents, the exactly-one
  rule, the capture-date rule on each, the midnight rule and its appeal exemption, and the
  cross-account refusal.
- [x] Every existing `supabase/tests/*.sql` naming the old table, updated and still passing.

**Acceptance Criteria:**
- Given a claim filed today, when a photo captured today is attached, then it is stored and its
  owner is the claim's own owner regardless of what the client sent.
- Given the same claim, when a photo captured on another day is attached, then the server refuses
  it and the form had already refused it.
- Given a claim for day D, when a photo is attached on day D+1, then the server refuses it.
- Given an appeal for day D, when a photo is attached on day D+1, then it is accepted — appeals are
  unchanged by the midnight rule.
- Given an evidence row with both parents set, or neither, then the row is refused.
- Given a declaration belonging to another account, then evidence naming it is refused.
- Given a claim still in the offline queue, then no upload control is offered.
- Given every existing appeal path, then it behaves exactly as it did before this story.

## Verification gate

The database side is fully runnable and must be green before this story closes — the local stack
settled in Story 6.2 covers every rule above.

What it cannot cover is the half this story exists for. `captured_on` is read from a real file's
`lastModified`, the upload is a real multipart request into Storage, and the control is a camera
input on a phone. `npm test` mocks all three. That is why this story carries a **done checkpoint**:
it stops here for hwt75 to take a photo on a real device and watch it land.

## Close — 2026-08-28 (stops here for the done checkpoint)

**Everything runnable ran, and passed.** `npm test` — 1148 tests across 48 files.
`supabase/tests/6-3-evidence-detaches-from-an-appeal.sql` passed all four steps on a real
database, and all 33 files under `supabase/tests/` pass against the renamed table: **33 pass, 0
fail**. `tsc --noEmit`, `eslint` and `prettier --check` are clean.

The four existing appeal files passing unchanged in behaviour is the assertion that matters most
here — this story rewrote the table every one of them depends on and changed nothing about how an
appeal's evidence behaves. `epic-4-retro-2026-08-27-fixes.sql` is also what proves the midnight
rule does not reach an appeal: it attaches evidence to an appeal for a day that has already ended,
and that insert is still accepted.

**Three things the work found that the spec did not anticipate:**

1. **The old path check had no name of its own.** It was written inline on the column, so Postgres
   had called it `appeal_evidence_check` rather than the `..._storage_path_check` the migration
   first guessed at. Found by the migration failing on a real database, which is exactly what that
   harness is for.
2. **One test asserted the refusal's wording, and the wording had to change.** The trigger's
   message said "dated the day being appealed", which is wrong once the same trigger serves claims.
   It now says "dated the day it proves", and `epic-4-retro-2026-08-27-fixes.sql` was updated to
   match. The assertion's purpose — that the refusal names its reason — is unchanged.
3. **`submitDeclaration()` had to start returning the declaration's id**, because evidence
   references the row it proves. It is read back after the insert rather than returned by it, so
   the insert keeps the plain shape the morning gate's tests already use, and only for a timed
   claim — the morning answer has nothing to attach and does not pay for the round trip.

**Deliberately not built, and why.** The referee still cannot see a claim's photo. His read policy
was left exactly as it was, covering appeal-parented objects only. A referee who can see proof of
ordinary days but cannot act on it is surveillance nobody asked for; Story 6.7 gives him the
objection and the access together, or neither.

**Still true:** all three of this epic's migrations are applied locally only. The author's own
project has received none of them.

## Done checkpoint — what hwt75 has to check on a real device

Nothing above proves the half this story exists for. `npm test` mocks the file, the camera and the
upload; the database check inserts a metadata row and never an object. What needs a phone:

1. Set a commitment's time to a window that is open now, and claim it.
2. Tap **Proof** and take a photo with the camera. Confirm it saves — `Proof saved.`
3. Confirm a photo picked from the library that was taken on an earlier day is refused with
   "That photo was not taken today", and that nothing is uploaded.
4. Confirm the object is not reachable without being signed in as its owner — the bucket is
   private and that is the whole of NFR4.

Worth knowing before testing: `captured_on` comes from the file's own `lastModified`, not EXIF. A
camera capture sets it to now; a file that has been synced or exported may carry a date that has
nothing to do with when the photo was taken. That limitation is inherited knowingly and documented
in `lib/evidence.ts`.
