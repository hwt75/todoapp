---
date: 2026-09-03
project: todoapp
trigger: user change request during Epic 6 execution
scope_classification: Moderate
status: approved 2026-09-03 by hwt75
inputDocuments:
  - prds/prd-todoapp-2026-08-11/prd.md
  - planning-artifacts/epics.md
  - architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md
  - ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md
  - ../specs/spec-timed-commitments-with-photo-proof/SPEC.md
  - ../implementation-artifacts/epic-6-context.md
  - supabase/migrations/20260828150000_evidence_detaches_from_an_appeal.sql
---

# Sprint Change Proposal — Opt-in photo evidence on any commitment

## 1. Issue Summary

### What triggered this

The author went looking for a photo-upload control on a commitment and could not find one. The
control exists, but it is reachable only through a chain of conditions he had no reason to expect:

1. the commitment must carry a `due_time` and a `late_window_minutes` (Story 6.1),
2. the current local time must be inside that window (`state === 'open'`),
3. the author must tap **Claim**, and that claim must reach the server (`declarationId !== null`),
4. only then does the `Proof` file input render (`components/today.tsx`, Stories 6.3 / 6.5).

Outside the window the whole control block deliberately renders nothing at all — not a disabled
button, not an explanation. From the author's side this is indistinguishable from the feature not
existing.

### The core problem

**Issue type: new requirement emerged from the stakeholder.**

This is not a defect. Every condition above is a documented, deliberate decision of Epic 6, and the
behaviour matches its spec exactly. What the discovery revealed is that Epic 6 answered a narrower
question than the author actually has: it built *photo as the thing that decides a timed day*, and
the author also wants *photo as a plain record he can keep against any commitment*.

Those two are different capabilities that happen to share a file store. Epic 6 coupled them, because
at the time the only reason to hold a photo was to decide something with it.

### Evidence

- `components/today.tsx` — the `Proof` input renders only inside `state === 'claimed'`, nested inside
  `timed.some(offersSomething)`, where `timed` is `rows.filter((row) => row.due_time)`.
- `lib/commitment.ts` `canBeTimed()` — a time cannot be set on an `abstain` or `daily_hours_quota`
  commitment at all, so those two kinds have no path to a photo under any circumstance.
- `supabase/migrations/20260828150000_evidence_detaches_from_an_appeal.sql` — `evidence` accepts
  exactly one parent, `appeal_id` XOR `declaration_id`. There is no shape in the schema for a photo
  that belongs to a commitment-day without a filed claim.

### Decisions already taken by the author (2026-09-03)

These close the two questions that would otherwise change the size of this work:

- **D1 — The photo decides nothing.** It is evidence only. The morning Declaration remains the sole
  judge of a non-timed commitment's day. **No settlement logic changes.** A missing photo is not a
  miss, does not fail a day, and costs nothing.
- **D2 — Same day only.** The upload control is available for the whole of the commitment's own local
  day and closes at midnight with it. The file must still be dated that day
  (`isEvidenceDated`, unchanged). No back-filling a past day, therefore no question about a photo
  reopening settled money.

---

> **Applied 2026-09-03.** Edits 1-6 below are landed in the repository. Story 6.8 is on the
> sprint board as `backlog`.

## 2. Impact Analysis

### 2.1 Epic impact

| Epic | Status | Impact |
|---|---|---|
| Epic 1–5 | done | **None.** No settlement, penalty, chain, grace or referee behaviour changes. |
| Epic 6 | in-progress | **Additive only.** Every existing story stays true and shipped as written. Story 6.3 (*Evidence detaches from an appeal*) is the direct foundation — it already generalized the store beyond appeals, and this generalizes it one step further. |
| Story 6.6 | review | Unaffected — it schedules reminders inside a due-time window, and this change adds no window. |
| Story 6.7 | backlog, blocked | Unaffected. It concerns the referee objecting to a *timed* day's proof. A commitment carrying only an evidence flag produces no verdict for anyone to object to. |

**Epic 6's goal statement does not cover this work.** Its stated goal is "a commitment with an hour,
and a photo that answers for it". A photo that answers for nothing sits outside that sentence.

Two placements were considered:

- **(a) Story 6.8 inside Epic 6** — recommended. All photo/evidence work stays in one epic, next to
  the Story 6.3 machinery it extends, and Epic 6's goal statement takes one added sentence.
- (b) A new Epic 7 — cleaner on paper, but a single-story epic that touches no verdict, no money and
  no notification is ceremony rather than structure.

### 2.2 Story impact

**New: Story 6.8 — A photo I can keep against any commitment.**

No existing story is modified, rolled back, or reopened.

### 2.3 Artifact conflicts

Three documents currently assert the opposite of what will be true. Two of them were already
partially falsified by Epic 6 and were not caught at the time; this change makes correcting them
unavoidable.

| # | Artifact | Line | Current text | Conflict |
|---|---|---|---|---|
| C1 | `prd.md` §4.3 Auto-checks | 283–284 | "Photographs are deliberately not among them: an old photo taken anywhere proves nothing, so evidence belongs to the **Appeal path and never to verification**." | Half still true, half already false. Photographs remain **not** an Auto-check — D1 preserves that completely. But evidence has not belonged to the Appeal path alone since Story 6.3 shipped. |
| C2 | `prd.md` §7.2 Out of Scope | 655–656 | "Photographs as an Auto-check — … so evidence belongs to the **Appeal path only**" | Same. The Auto-check exclusion stands; "Appeal path only" does not. |
| C3 | `EXPERIENCE.md` § component table | 157 | "Evidence attachment … **Appears only in Appeal**, never as a check method — an old photo proves nothing." | Same. "Never as a check method" stands and is reinforced by D1; "only in Appeal" is now wrong in two ways. |
| C4 | `ARCHITECTURE-SPINE.md` § Consistency Conventions | 228 | "Evidence storage \| **Appeal** evidence goes to a private Storage bucket whose access policy derives from the same rule as the `appeal` row it belongs to (AD-7)… An object outlives its appeal only as long as the appeal is retained." | The convention is written for one parent kind. It must be restated for three, with the retention clause generalized. |

**No conflict with:** AD-1 (server is sole judge — untouched), AD-7 (authorization in RLS — the new
parent kind gets its own policies), AD-8 (one writer per derived value — a photo is not a derived
value), AD-9 (append-only verdicts — no verdict involved), NFR4 (evidence privacy — preserved and
extended unchanged), NFR6 (offline reconcile — see Risk R2).

### 2.4 Technical impact

**Database — one migration.**

`evidence` currently enforces exactly one parent via
`check ((appeal_id is null) <> (declaration_id is null))`, and the storage path must lead with that
parent's id (`storage.foldername(name)` is what the bucket's policies read to derive access).

A third parent kind is needed: a photo whose parent is *(commitment, day)* with no declaration in
existence.

- **Recommended:** add `commitment_id uuid references commitment(id) on delete cascade` and
  `for_day date` to `evidence`. `commitment_id` is a single uuid, so it can lead the storage path
  exactly as the other two parents do, and `evidence_derive_owner()` gains a third branch reading
  `commitment.owner_id`. The exactly-one-parent check widens from a biconditional to a
  "`num_nonnulls(appeal_id, declaration_id, commitment_id) = 1`" form, and `for_day` is required
  when and only when `commitment_id` is set.
- **Rejected:** a new `proof` slot table keyed `(commitment_id, for_day)` — one more table and one
  more owner derivation to keep in agreement, buying nothing the column pair does not already give.
- **Rejected:** auto-creating a `declaration` row on upload — it would file an answer the author did
  not give, and hand the verdict a writer it must not have. Violates D1 and AD-8.

`commitment` gains `requires_photo boolean not null default false`. Existing rows are unaffected by
construction.

**Client.**

- `lib/commitment.ts` — `requiresPhoto` on `CommitmentDraft`, in `EMPTY_DRAFT` as `false`.
  No `canBeTimed()`-style kind restriction: because the photo decides nothing, there is no kind for
  which it is meaningless.
- `components/commitment-form.tsx` — one checkbox. **It carries no warning copy.** The
  `TIMED_COMMITMENT_COPY.warning` sentence exists because a missing photo costs 500,000 VND on a
  timed commitment; here nothing is at stake and a warning would be a lie about the stakes.
- `components/today.tsx` — a per-row upload control for every row with `requires_photo`, rendered
  independently of the `timed` block and its window arithmetic. `attachProof()` is reused with a
  commitment-day parent instead of a declaration parent; `isEvidenceDated` and `EVIDENCE_COPY` are
  unchanged.
- `lib/evidence.ts` — `evidenceObjectPath()` already takes a generic `parentId`. **No change.**

**Untouched:** every settlement function, every `pg_cron` schedule, the outbox and its worker, the
notification pipeline, penalty/grace/chain logic, the referee surface, and the offline queue.

---

## 3. Recommended Approach

### Selected path: Option 1 — Direct Adjustment

| Option | Verdict | Reasoning |
|---|---|---|
| **1. Direct Adjustment** — one new story in Epic 6 plus documentation corrections | **Selected** | The change is purely additive. Because D1 keeps the photo out of every verdict, it touches no settled money and no shipped behaviour. Nothing needs to be undone. |
| 2. Rollback | Not viable | There is nothing to roll back. Stories 6.1–6.5 remain correct and useful; the timed mechanism keeps working exactly as specified. This change removes its *exclusivity*, not the mechanism. |
| 3. MVP review | Not viable | The MVP is unaffected. No goal, metric or scope boundary in the PRD moves, and the one PRD non-goal that looks threatened — photographs as an Auto-check — is explicitly preserved by D1. |

**Effort: Low.** One migration, one checkbox, one render block, and four documentation edits.

**Risk: Low.** Detailed below.

**Timeline impact: none on Epic 6's critical path.** Story 6.8 is independent of Story 6.6 (in review)
and Story 6.7 (blocked), so it can be built in parallel or slotted after 6.6 without waiting on
6.7's open questions.

### Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | The `evidence` exactly-one-parent constraint is load-bearing for both the storage-path check and the owner derivation. A third branch is a place all three can drift apart. | All three are changed in the same migration, and the migration adds a test asserting each parent kind derives the correct owner and refuses a mismatched path — the same shape Story 6.3's own migration used. |
| R2 | A photo upload has no offline queue (`lib/offline-queue.ts` holds JSON, not ten-megabyte images) — the same accepted cost Epic 6 recorded. Without a deadline, though, the cost is smaller here: the author can simply upload later the same day. | Reuse the existing `EVIDENCE_COPY.failed` path. No queue is added. Note explicitly in the story that unlike a timed commitment, a failed upload costs nothing. |
| R3 | Two visually similar upload controls could appear on one screen — the timed `Proof` control and the new evidence control — if a commitment somehow carried both a `due_time` and `requires_photo`. | Story 6.8 must decide this. **Recommendation:** when a commitment carries a `due_time`, the timed photo *is* its photo; suppress the new control and let Epic 6's own flow own it. One control, one meaning. |
| R4 | Storage growth: a photo per commitment per day, with no settlement event to bound retention. Epic 6's photos are bounded by the days they prove. | Out of scope for this story, but flagged: the spine's evidence-retention sentence (C4) should acknowledge that commitment-day evidence has no automatic expiry in v1. |

---

## 4. Detailed Change Proposals

### 4.1 New story

**Story 6.8 — A photo I can keep against any commitment**

> As the author,
> I want to mark any commitment as one I keep a photo against, and attach that photo at any point
> during its day,
> So that I have my own record of the work without having to give the commitment an hour it does not
> have, and without a photo ever deciding whether I owe money.

**Acceptance Criteria**

**Given** the commitment form
**When** the author creates or edits any commitment, of any Kind and any Cadence
**Then** a checkbox offers to require a photo, defaulting to off
**And** no warning about failed days is shown, because none is true

**Given** a commitment with the photo flag on
**When** the author opens Today at any hour of that commitment's local day
**Then** an upload control is present on that commitment's row
**And** it needs no Claim, no due time, and no open window to appear

**Given** a photo taken on that day
**When** the author uploads it
**Then** it is stored privately against that commitment and that day
**And** it is visible to the author, and to the Referee only under the existing Appeal disclosure rule (NFR4)

**Given** a photo not dated that day
**When** the author selects it
**Then** it is refused before it reaches Storage, in the existing wording

**Given** midnight passes
**Then** the control for that day is gone and that day accepts no further evidence

**Given** a day with no photo uploaded
**When** the day settles
**Then** the outcome is exactly what it would have been with the flag off — the morning Declaration
alone decides it, and no penalty, chain or grace is affected *(D1 — this AC is the regression guard
on the whole change)*

**Given** a commitment that carries both a due time and the photo flag
**Then** only Epic 6's own timed proof control is shown *(R3)*

### 4.2 PRD edits

**Edit 1 — `prd.md` §4.3, lines 283–284**

```
OLD:
Four are offered. Photographs are deliberately not among them: an old photo taken anywhere proves
nothing, so evidence belongs to the Appeal path and never to verification.

NEW:
Four are offered. Photographs are deliberately not among them: an old photo taken anywhere proves
nothing, so a photograph never files a Declaration and never decides a day. Photographs are held
elsewhere in the product — as Appeal evidence, as a timed Commitment's proof, and as the optional
record an author may keep against any Commitment — but in none of those does one act as a check.
```

*Rationale: preserves the real non-goal (photo-as-verification) while removing the claim about where
evidence may live, which Story 6.3 already falsified.*

**Edit 2 — `prd.md` §7.2, lines 655–656**

```
OLD:
- Photographs as an Auto-check — an old photo taken anywhere proves nothing, so evidence belongs to
  the Appeal path only

NEW:
- Photographs as an Auto-check — an old photo taken anywhere proves nothing. A photograph is never a
  check method and never files a Declaration; where photographs are held, they are records and
  evidence, never verdicts.
```

### 4.3 UX specification edit

**Edit 3 — `EXPERIENCE.md` line 157**

```
OLD:
| Evidence attachment | Camera or library, restricted to items dated the claimed day. Appears only
in Appeal, never as a check method — an old photo proves nothing. |

NEW:
| Evidence attachment | Camera or library, restricted to items dated the day it belongs to. Appears
in three places — an Appeal, a timed Commitment's proof control, and the all-day control on a
Commitment marked as keeping a photo — and is never a check method in any of them: an old photo
proves nothing, and a missing photo only costs a day where Epic 6 says so. |
```

### 4.4 Architecture edit

**Edit 4 — `ARCHITECTURE-SPINE.md` line 228, Consistency Conventions table**

```
OLD:
| Evidence storage | Appeal evidence goes to a private Storage bucket whose access policy derives
from the same rule as the `appeal` row it belongs to (AD-7): the doer who submitted it and the
referee ruling on it, nobody else. An object outlives its appeal only as long as the appeal is
retained. |

NEW:
| Evidence storage | Evidence goes to a private Storage bucket whose access policy derives from the
row it belongs to (AD-7): the doer who submitted it and, for an Appeal, the referee ruling on it,
nobody else. An evidence row has exactly one parent — an `appeal`, a `declaration`, or a
`(commitment, day)` — and its object path leads with that parent's id, which is what the bucket's
policies read to derive access. An object outlives its parent only as long as the parent is
retained; commitment-day evidence has no automatic expiry in v1. |
```

### 4.5 Epic 6 context edit

**Edit 5 — `epic-6-context.md`, Goal paragraph**

Append one sentence:

```
Story 6.8 later separates the store from the deadline: a Commitment may be marked as one the author
keeps a photo against, with an all-day upload control and no verdict attached. That photo decides
nothing — it is a record, and the morning question still judges the day.
```

Add to the Stories list: `- Story 6.8: A photo I can keep against any commitment — backlog`

*Note: Epic 6's Non-goals list is not edited. "Timing an `abstain` or an hours-quota commitment"
remains a non-goal and is untouched — Story 6.8 gives those kinds a photo, never a time.*

### 4.6 Sprint status edit

Add under `epic-6:` in `_bmad-output/implementation-artifacts/sprint-status.yaml`:

```yaml
  6-8-a-photo-i-can-keep-against-any-commitment: backlog
```

---

## 5. Implementation Handoff

**Scope classification: Moderate.**

Not Minor — it touches the PRD, the UX contract and the architecture spine, and adds a schema shape
that three separate mechanisms (the exactly-one-parent constraint, the storage path check, and the
owner derivation trigger) must agree on. Not Major — no goal, metric, MVP boundary or architectural
decision is overturned, and no shipped work is invalidated.

| Recipient | Responsibility |
|---|---|
| **Product Owner / Analyst** | Apply Edits 1–5. These are documentation corrections; two of them (C1/C3) were already owed from Story 6.3 and should land regardless of whether Story 6.8 is built. |
| **Developer agent** (`bmad-build`) | Build Story 6.8: one numbered migration (AD-16), the form checkbox, the Today control, and tests. |
| **Author (hwt75)** | ~~Confirm R3's recommendation~~ — **settled on approval, 2026-09-03**: a commitment carrying both a due time and the photo flag shows only Epic 6's timed control. |

### Success criteria

1. A commitment of any Kind and Cadence can be marked as keeping a photo, and shows an upload
   control on Today for the whole of its local day with no Claim and no window.
2. A photo not dated that day is refused before reaching Storage.
3. **A day with the flag on and no photo uploaded settles identically to the same day with the flag
   off** — the regression that proves D1 held.
4. `evidence` accepts exactly one parent of three kinds, each deriving the correct owner and
   refusing a path that does not lead with its own id.
5. Stories 6.1–6.6 pass their existing tests unchanged.

---

## 6. Checklist Record

| § | Item | Status |
|---|---|---|
| 1.1 | Triggering story identified — discovery against Stories 6.3/6.5 during Epic 6 execution | [x] Done |
| 1.2 | Core problem defined — new requirement from stakeholder, not a defect | [x] Done |
| 1.3 | Evidence gathered — code paths, schema constraint, form restriction | [x] Done |
| 2.1 | Epic 6 completable as planned | [x] Done — yes, additively |
| 2.2 | Epic-level changes — goal statement extended, one story added | [x] Done |
| 2.3 | Remaining epics reviewed | [x] Done — none affected |
| 2.4 | No epic invalidated; no new epic required | [x] Done |
| 2.5 | Epic order and priority unchanged | [x] Done |
| 3.1 | PRD conflicts — two found (C1, C2) | [!] Action-needed — Edits 1–2 |
| 3.2 | Architecture conflicts — one found (C4); AD-1/7/8/9 clear | [!] Action-needed — Edit 4 |
| 3.3 | UX conflicts — one found (C3) | [!] Action-needed — Edit 3 |
| 3.4 | Other artifacts — epic-6-context, sprint-status | [!] Action-needed — Edits 5–6 |
| 4.1 | Option 1 Direct Adjustment — effort Low, risk Low | [x] Viable — **selected** |
| 4.2 | Option 2 Rollback | [ ] Not viable — nothing to undo |
| 4.3 | Option 3 MVP review | [ ] Not viable — MVP unaffected |
| 4.4 | Path selected with rationale | [x] Done |
| 5.1–5.5 | Proposal components drafted | [x] Done |
| 6.1–6.2 | Checklist reviewed, proposal verified | [x] Done |
| 6.3 | Explicit user approval | [x] Done — hwt75, 2026-09-03 |
| 6.4 | sprint-status.yaml updated | [x] Done — `6-8-a-photo-i-can-keep-against-any-commitment: backlog` |
| 6.5 | Handoff confirmed | [x] Done — Edits 1–6 applied; Story 6.8 handed to `bmad-build` |
