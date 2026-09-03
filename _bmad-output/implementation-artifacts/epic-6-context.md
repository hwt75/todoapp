# Epic 6 Context: A commitment with an hour, and a photo that answers for it

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Every commitment in this product is judged by one question asked the next morning, answerable for up
to three days: the author's own word about a day that has already ended. That works for "did you go
to the gym at all" and fails for anything with a moment in it — take the pill at 20:00, leave the
house by 07:30. This epic lets a commitment carry a local time of day and a late window around it,
lets the author claim it at the moment he does it, and lets a photo taken inside that window stand in
for the morning question entirely. Midnight of the commitment's own day is the deadline: no accepted
photo by then is a Failed Day, with a Grace Day the only remedy. The referee is inverted — proof
holds the day by default and he may object, never approve. Story 6.8 then separates the store from
the deadline: any commitment may be marked as one the author keeps a photo against, with an all-day
upload control and no verdict attached. That photo decides nothing — it is a record, and the morning
question still judges the day.

The planning source for this epic is the spec folder
`_bmad-output/specs/spec-timed-commitments-with-photo-proof/` (SPEC.md + brownfield.md +
lifecycle.md + stories.yaml), not `planning-artifacts/epics.md`, which stops at Epic 5.

## Stories

- Story 6.1: A commitment can carry a time and a late window — done
- Story 6.2: A same-day claim lands on the day it was made — done
- Story 6.3: Evidence detaches from an appeal — done
- Story 6.4: Midnight decides the day — done
- Story 6.5: Today shows where the window stands — done
- Story 6.6: The reminder lands inside the window — review
- Story 6.7: The referee may object — backlog, blocked on open questions
- Story 6.8: A photo I can keep against any commitment — done
- Story 6.9: A photo I can open again — backlog

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
- **Story 6.8 — photo as record, not verdict.** A commitment may be flagged as one the author keeps
  a photo against. The photo is evidence only and never decides anything: the morning Declaration
  remains sole judge, and settlement, penalty, chain, grace, notification and referee behaviour are
  all unchanged. A day with the flag on and no photo settles identically to the same day with the
  flag off — that regression is the guard on the whole change. The upload control is available for
  the whole of the commitment's own local day and closes at midnight; the file must still be dated
  that day, and no past day can be back-filled. The flag applies to any Kind and any Cadence with no
  restriction — unlike a `due_time`, which cannot be set on an `abstain` or `daily_hours_quota`
  commitment. Because nothing is at stake, the flag carries no failed-day warning copy. When a
  commitment carries both a `due_time` and the photo flag, only the timed proof control is shown.
- **Story 6.9 — the photo must be openable by the one person it is for.** Evidence has been
  write-only to the author since 6.3: the only signed-URL read in the product belongs to the
  referee's appeal viewer. A kept record he cannot open is worth less than a proof that merely has
  to exist, and the upload copy already promises "only you can open it". Reading is a read: no
  schema change, and the referee narrowing 6.8 established must not be weakened to achieve it.
- Non-goals (unchanged by 6.8): monthly cadence, a referee approval queue, more than one time per
  commitment per day, timing an `abstain` or an hours-quota commitment, editing a filed claim or its
  photo, and migrating existing commitments. Story 6.8 gives those kinds a photo, never a time.

## Technical Decisions

- **Columns, not a new table.** The time and window live on `commitment`; the completion instant and
  the evidence link live on `declaration`. No occurrence or schedule table — two tables narrating one
  event is how data starts contradicting itself. The same choice repeats in 6.8: the commitment-day
  parent is a column pair on `evidence`, not a new slot table, and no `declaration` row is
  auto-created on upload — that would file an answer the author never gave.
- **Names carry meaning.** The value is `due_time`, a Postgres `time`, because every `_at` column in
  this schema is a `timestamptz`. The window is never called "grace": Grace Day already names a
  countable forgiveness token.
- **Mirror, don't relocate.** Database constraints are the enforcement point; `lib/commitment.ts`
  mirrors them so a form can refuse a bad draft without a round trip. The cadence-target rules are
  the pattern to copy.
- **Reuse the evidence store.** The private `appeal-evidence` bucket, its owner-derivation policies
  and the referee's viewer all stand. Evidence detaches from `appeal_id` rather than a second store
  being built.
- **One parent, now three kinds.** `evidence` carries exactly one parent. That invariant widens from
  a two-way biconditional (appeal XOR declaration) to a three-way count: an appeal, a declaration, or
  a commitment-plus-day. The storage object path must lead with that parent's own id, because the
  path prefix is what the bucket policies read to derive access, and the owner-derivation trigger
  gains a matching third branch. The constraint, the path check and the trigger are load-bearing
  together and must move in the same migration or they drift.
- **The objection is the appeal skeleton reversed.** `appeal` already has a deadline, a ruling
  function and an expiry pass. Story 6.7 points that shape the other way rather than inventing a
  second dispute mechanism.
- **Invariants that do not move:** the server is the sole judge (AD-1); idempotency keys are
  generated at the tap and reused by retries (AD-4); every boundary resolves in `Asia/Ho_Chi_Minh`
  and no client derives a date for storage (AD-6); settlement is the single writer of derived state
  (AD-8); a photo is never a derived value and never a verdict.

## UX & Interaction Patterns

- The cost of a time is stated where the time is set, not discovered at month end. Conversely, the
  photo flag shows no such warning — a warning where nothing is at stake would misstate the stakes.
- A window that has shut unproven must read as visibly distinct from one still waiting for its hour;
  the states shown are the ones named in `lifecycle.md`, not a second vocabulary.
- The 6.8 upload control renders per row, independently of the timed block and its window
  arithmetic: no claim, no due time, no open window needed for it to appear. Never two similar upload
  controls on one row — a due time wins.
- Evidence attachment now appears in three places — an appeal, a timed commitment's proof control,
  and the all-day control on a commitment marked as keeping a photo — and is never a check method in
  any of them. Photos stay private, visible to the author, and to the referee only under the existing
  appeal disclosure rule.
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
- 6.8 builds directly on 6.3's generalized evidence store and depends on nothing else in the epic. It
  is independent of 6.6 and of 6.7's open questions, so it can run in parallel or slot in after 6.6.
  Its only coupling to shipped work is the display rule that a due time suppresses its control.
