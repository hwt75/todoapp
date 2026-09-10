---
date: 2026-09-10
project: todoapp
trigger: user change request after Epic 6 closed, during Epic 7 execution
scope_classification: Major
status: approved 2026-09-10 by hwt75
inputDocuments:
  - prds/prd-todoapp-2026-08-11/prd.md
  - planning-artifacts/epics.md
  - architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md
  - ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md
  - ../specs/spec-timed-commitments-with-photo-proof/SPEC.md
  - ../implementation-artifacts/epic-6-retro-2026-09-07.md
  - supabase/migrations/20260903140000_the_referee_may_object.sql
  - supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql
---

# Sprint Change Proposal — Commitments the referee signs off, per the author's choosing

## 1. Issue Summary

### What triggered this

The author asked for a change of mechanism, not a fix: some commitments should carry an option
meaning *the referee must approve this*, and for those the referee opens the photograph and marks
the day done.

### The core problem

**Issue type: the stakeholder is reversing a deliberate product decision.**

`SPEC.md` CAP-5 says a submitted photo holds the day by default and *"the referee reviews nothing on
a schedule"*. Its Non-goals name the opposite of what is now being asked for, in these words:

> **A referee approval queue.** The referee is never given a list of photos to work through. Any
> design that requires the referee to act for a day to hold is out of scope.

That boundary was not incidental. It buys one property: **the referee forgetting costs the author
nothing.** Any design where a day waits on a person makes an absent-minded friend into someone who
can lose the author 500,000₫ by not opening an app.

The author's own answers preserve that property while changing the mechanism, which is what makes
this proposal possible rather than a straight contradiction — see the decisions below.

### Decisions already taken by the author (2026-09-10)

1. **The option is per commitment, and the author sets it.** Not a global mode, not the referee's
   choice.
2. **Silence approves.** If midnight arrives with no word from the referee, the day is treated as
   approved. The property above survives intact.
3. **The referee gets a list of what is waiting**, on his own screen. This is the explicit reversal
   of the Non-goal, taken knowingly.
4. **A rejection fails that commitment's day** — the chain breaks, the penalty stands, and a Grace
   Day is still the author's remedy.
5. **Approval replaces objection for flagged commitments.** `object_to_day()` continues to serve
   every commitment without the flag.

### The consequence that shapes the whole design

Because silence approves, **approving changes no outcome**. A day with a photo and no word settles
exactly as a day with a photo and an approval. The entire force of the mechanism is in the
rejection.

So what is being built, in effect, is `object_to_day()` **moved earlier and narrowed**: the
referee's power to fail a day moves from *48 hours after settlement* to *before midnight of the day
itself*, and applies only to commitments the author opted in.

This is a simplification, not an addition. Today an objection arrives after the day has closed, so
it must supersede the settlement, write a correction, void the old penalty and mint a replacement —
the most intricate path in the schema (`20260903140000`, and the reason retro items 36, 37 and 44
exist). A decision that lands *before* the day closes needs none of that: settlement reads it and
freezes once.

## 2. Impact Analysis

### 2.1 Epic impact

Epic 6 is closed and stays closed; this does not reopen it. Epic 7 (in progress) is a surface epic
and this is not a surface change. **Recommendation: a new epic with its own SPEC**, because this
carries schema, settlement, two surfaces and a reversal of a documented product boundary — the
shape the `bmad-spec` kernel exists for.

### 2.2 Artifact conflicts

| Artifact | Conflict | Required action |
| --- | --- | --- |
| `specs/spec-timed-commitments-with-photo-proof/SPEC.md` | CAP-5 and the "referee approval queue" Non-goal both contradict this | Amend — human-owned. The amendment should say *why* the queue is now in scope and record that silence-approves is what keeps CAP-5's property |
| `prd.md` FR-19 – FR-21 | Describe a referee who rules on appeals and collects, never one who signs off a day | New FR for the sign-off, plus a note on the objection's narrowed reach |
| `epics.md` | No epic covers this | New epic entry |
| `EXPERIENCE.md` | Carries the copy for the referee's surfaces and the "It is private — only you can open it" line under the author's photo control | Both need revisiting — see 2.3 |
| `epic-6-retro-2026-09-07.md`, item 43 | Its finding A2 is that the app promises privacy the policy does not keep | This change may resolve A2 by consent: a photo the author *marked for approval* is one he chose to show |

### 2.3 Technical impact

**The flag decides money, so it cannot be read live.** `requires_photo` (`20260903120000`) needed no
history because *"the photo decides nothing"* — settlement never reads it. This flag is the
opposite. Toggling it off after a rejection, or on after a clean day, would re-judge days already
answered. It needs the treatment `carries_penalty_as_of()` and `due_time_as_of()` already have: a
log and an as-of reader, with every reader moved through the one door in the same change (Epic 6
retro item 50, which named three defects of exactly this shape).

**`commitments_owing()` gains one clause, not a state.** Silence approves, so a flagged commitment
with a photo is `held` exactly as today *unless a rejection exists for that commitment and day*. No
third answer, no day held open past midnight, no change to `settle_day()`'s deadline logic.

**A rejection is a new row, not an objection.** `public.objection` is bound to
`superseded_settlement` — it exists to describe a correction of a day that already closed. A
pre-settlement rejection has no settlement to supersede. Recommend a separate table with the same
care `objection` shows: `referee_id` with `on delete restrict` (a statement about someone's money
must not be silently anonymised), the reason stored verbatim, and the day and commitment stored
rather than derived.

**The reject path should reuse `object_to_day()`'s landing guards.** It refuses wherever an
objection would leave the author a broken chain no Grace Day can reach — a commitment carrying no
penalty, a Weekly Quota, a penalty not `owed`. Those reasons do not change because the timing did.

**The queue is a `security definer` function**, scoped to `paired_doer_id()`, in the shape
`referee_day_lookup()` established. It returns today's flagged commitments with a photo and no
decision yet.

**The referee's read of the photograph.** The current policy is `role_from_token() = 'referee' and
commitment_id is null and owner_id = <his paired doer>`. A claim-parented photo is already readable;
a commitment-day photo is deliberately not. Which of the two the sign-off uses decides whether the
policy widens — and if it does, it widens only for flagged commitments, which is the consent
argument that also answers retro finding A2.

### 2.4 Risks

- **A photograph attached at 23:58 gives the referee two minutes.** Auto-approval means this fails
  toward the author, which is the safe direction, but for late proof the mechanism is decorative.
  The list alone will not fix it; a nudge through the existing `email-worker` channel (Story 5.3's)
  would, and is deliberately not proposed here — see Open questions.
- **The list is a queue, and a queue is a duty.** The Non-goal's reasoning was that a referee sent a
  list starts to feel owed work, and a referee who feels owed work stops opening the app. Nothing in
  this proposal prevents that; it accepts the risk on the author's instruction.
- **Two mechanisms for one job during the transition.** Until every reader knows about the flag,
  `object_to_day()` and the rejection path both exist. The guard is that the flag must gate them:
  a flagged commitment must be unreachable by `object_to_day()`, asserted in SQL, not by convention.

## 3. Recommended approach

**Direct adjustment, as a new epic, specified before it is built.** No rollback of Epic 6 is
implied: everything it built stands, and the new path is opt-in and additive.

Suggested capability shape for the SPEC, to be written properly by `bmad-spec`:

- The author may mark a commitment as needing the referee's sign-off, and is told what that means
  before saving — including that his friend's silence still holds the day.
- A photograph on such a commitment reaches the referee, who may mark it done or refuse it with a
  reason in his own words.
- With no word from the referee, midnight holds the day exactly as it does today.
- A refusal fails that commitment's day before it closes: one settlement, no correction.
- The referee sees what is waiting for him today, and nothing else about the author's history.

## 4. Open questions — for the author, before a SPEC is written

> **Approved 2026-09-10 by hwt75.** Approval of this proposal is taken as accepting the
> recommendations on questions 1–4 below. Question 5 carries no recommendation and is not answered
> here — it goes into the SPEC as an Ask First, where it belongs, rather than being decided in code.
> Question 6 stays deferred by its own terms.


1. **Which kinds may carry the flag?** `abstain` has no moment to photograph; `daily_hours_quota` is
   judged by measured minutes; an `auto_check` commitment already has a machine answering for it.
   Recommend: `do` commitments only, and refuse the flag alongside `auto_check_kind`.
2. **Does the flag imply a photograph is required?** A sign-off with nothing to look at is a
   referee guessing. Recommend: the flag implies proof, and the two controls are one.
3. **What happens with no referee paired?** Recommend: the flag cannot be turned on without one, and
   if the pairing is later revoked, flagged days simply auto-approve.
4. **May the referee refuse after midnight?** Recommend no — the day closed, and that is what
   `object_to_day()`'s 48 hours already covers for everything else.
5. **Does the author see "waiting" on Today?** He knows he sent it; whether the row says so is a
   copy decision with a real cost — a row that says *waiting* invites him to chase his friend.
6. **The nudge.** Not proposed here. If the list proves too quiet in practice, the `email-worker`
   channel already exists and is one story, not a redesign.

## 5. Checklist record

- Epic 6 remains closed; nothing here reopens it.
- No code has been written for this proposal.
- The reversal of `SPEC.md`'s Non-goal is recorded as the author's decision of 2026-09-10, with the
  property that made the Non-goal worth having (silence never costs the author) preserved by
  decision 2 rather than abandoned.
