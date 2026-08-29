# Epic 6 Context: A commitment with an hour, and a photo that answers for it

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Every commitment in this product is judged by one question asked the next morning, answerable for
up to three days: the author's own word about a day that has already ended. That works for "did you
go to the gym at all" and fails for anything with a moment in it — take the pill at 20:00, leave the
house by 07:30. This epic lets a commitment carry a local time of day and a late window around it,
lets the author claim it at the moment he does it, and lets a photo taken inside that window stand
in for the morning question entirely. Midnight of the commitment's own day is the deadline: no
accepted photo by then is a Failed Day, with a Grace Day the only remedy. The referee is inverted —
proof holds the day by default and he may object, never approve.

The planning source for this epic is the spec folder `_bmad-output/specs/spec-timed-commitments-with-photo-proof/`
(SPEC.md + brownfield.md + lifecycle.md + stories.yaml), not `planning-artifacts/epics.md`, which
stops at Epic 5.

## Stories

- Story 6.1: A commitment can carry a time and a late window — done
- Story 6.2: A same-day claim lands on the day it was made — done
- Story 6.3: Evidence detaches from an appeal — in review, awaiting its device checkpoint
- Story 6.4: Midnight decides the day — in review, awaiting its device checkpoint
- Story 6.5: Today shows where the window stands
- Story 6.6: The reminder lands inside the window
- Story 6.7: The referee may object — blocked on open questions

## Requirements & Constraints

- A commitment may carry a wall-clock `due_time` and a `late_window_minutes` of 5 to 240, default 30.
  Zero is refused. The window may not cross midnight, enforced by a check constraint comparing
  extracted minutes against 1440 — `time` arithmetic wraps and would accept the case the rule exists
  to refuse.
- A commitment saved without a time behaves exactly as it does today. No existing row changes.
- A claim on a timed commitment is recorded against the current local day, never the previous one,
  and the next morning's question does not ask about it again. Its question died at midnight; there
  is no three-day declaration window and no softer second answer.
- A photo — not a typed answer — is what makes a timed day hold. A claim whose photo has not been
  accepted by the end of its own local day settles as failed. The only remedy is a Grace Day, capped
  at two per calendar month.
- The claim survives having no network; the photo does not. The offline queue is browser storage
  holding JSON and cannot carry a ten-megabyte image. This is an accepted cost, which is why the
  setup surface must state, at the moment a time is turned on, that no photo by midnight is a failed
  day.
- A photo's capture date must equal the day it proves, and is read from the file's own
  `lastModified` — no EXIF dependency exists here and none is added. A frozen day accepts no new
  evidence: settled money never reopens.
- The referee is never given a queue and never has to act for a day to hold. Silence means held.
- Today's surface must distinguish, per timed commitment, a window that is ahead, open now, shut
  unproven, or proven — without opening or refreshing anything.
- A reminder must land inside the window it names, never after it has shut.
- Non-goals: monthly cadence, a referee approval queue, more than one time per commitment per day,
  timing an `abstain` or an hours-quota commitment, editing a filed claim or its photo, and
  migrating existing commitments.

## Technical Decisions

- **Columns, not a new table.** The time and window live on `commitment`; the completion instant and
  the evidence link live on `declaration`. No occurrence or schedule table — two tables narrating one
  event is how data starts contradicting itself.
- **Names carry meaning.** The value is `due_time`, a Postgres `time`, because every `_at` column in
  this schema is a `timestamptz`. The window is never called "grace": Grace Day already names a
  countable forgiveness token.
- **Mirror, don't relocate.** Database constraints are the enforcement point; `lib/commitment.ts`
  mirrors them so a form can refuse a bad draft without a round trip. The cadence-target rules are
  the pattern to copy.
- **Reuse the evidence store.** The private `appeal-evidence` bucket, its owner-derivation policies
  and the referee's viewer all stand. Evidence detaches from `appeal_id` rather than a second store
  being built; the table is now `evidence` with exactly one parent — an appeal or a declaration.
- **The objection is the appeal skeleton reversed.** `appeal` already has a deadline, a ruling
  function and an expiry pass. Story 6.7 points that shape the other way rather than inventing a
  second dispute mechanism.
- **Invariants that do not move:** the server is the sole judge (AD-1); idempotency keys are
  generated at the tap and reused by retries (AD-4); every boundary resolves in `Asia/Ho_Chi_Minh`
  and no client derives a date for storage (AD-6); settlement is the single writer of derived state
  (AD-8).

## UX & Interaction Patterns

- The cost of a time is stated where the time is set, not discovered at month end.
- A window that has shut unproven must read as visibly distinct from one still waiting for its hour;
  the states shown are the ones named in `lifecycle.md`, not a second vocabulary.
- Nothing in this epic gives the referee a task, a queue, or a notification that demands a decision.

## Cross-Story Dependencies

- 6.2 must land before 6.4: the client-side half of the morning-gate exclusion ships in 6.2
  (`lib/declaration.ts` decides what to ask); the server-side half is 6.4
  (`public.commitments_owing()` decides what is true).
- 6.4 depends on 6.1's `due_time` and on 6.3's evidence link: it is the only story in the epic that
  moves money, and it decides what a machine-filed declaration means on a timed commitment — a
  question 6.2 deliberately left open.
- 6.5 renders the state machine 6.1 through 6.4 create, and needs a readable server-side source for a
  window's state, since `components/today.tsx` may not read the declaration table directly.
- 6.6 is a scheduling gap, not a column: `gate_reminder` is enqueued hourly at :05, so a 20:30
  commitment would first be reminded at 21:05. Its new job must collide with neither the settlement
  pass (hourly at :15) nor the outbox worker (every minute).
- 6.7 is blocked until the objection window's length, its output, its reach into a frozen day, and
  who carries the burden are answered. CAP-1 through CAP-4 and CAP-6 through CAP-8 do not depend on
  it.
