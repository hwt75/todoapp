# Epic 8 Context: Commitments the referee signs off, per the author's choosing

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

For some commitments the author wants his friend's signature on the day, not only his own
photograph — and he wants to choose which ones, rather than have the referee looking at everything or
nothing. Today the referee's only power over an ordinary day is an objection filed up to 48 hours
*after* it closed: the day has already settled and the money has already moved, so the objection must
supersede a settlement, write a correction, void a penalty and mint a replacement. That is the most
intricate path in the schema. This epic moves the referee's power to where it costs less and means
more — **before midnight, and only where the author asked for it** — so a decision is read inside the
day's own settlement and nothing is superseded. The property that made the original design safe is
kept deliberately: **the referee's silence still holds the day**, so a friend who forgets to open the
app never costs the author money. Because silence approves, an approval changes no outcome; the
entire force of the mechanism is the refusal.

The planning source for this epic is the spec folder
`_bmad-output/specs/spec-commitments-the-referee-signs-off/` (SPEC.md + stories.yaml + .memlog.md),
not `planning-artifacts/epics.md`, which stops at Epic 5. The approved scope change behind it is
`planning-artifacts/sprint-change-proposal-2026-09-10.md`.

## Stories

- Story 8.1: A commitment can ask for the referee's signature
- Story 8.2: The referee's decision, and what a refusal costs
- Story 8.3: The photograph reaches the referee
- Story 8.4: What is waiting for him today
- Story 8.5: The author is told he was refused
- Story 8.6: Today says the day is waiting on his friend

## Requirements & Constraints

- A commitment may be flagged as needing the referee's sign-off. A commitment saved without the flag
  behaves exactly as it does today, with no change to any existing row.
- **Silence approves, and no design may weaken that.** A flagged commitment with a photograph and no
  referee decision settles `held`, and the author's chain, quota and money are byte-identical to the
  unflagged case. Nothing waits on a person: not the settlement, not the penalty, not the chain. No
  day is ever held open.
- **A refusal lands before midnight or not at all,** and fails that commitment's day inside the day's
  own settlement — freezing as `missed`, with no superseding settlement and no voided-and-reminted
  penalty. A Grace Day still reaches it. Every other commitment on that day settles as it would have.
- A refusal records who said it, when, which day, which commitment, and the reason **verbatim**. An
  approval records the same and changes no outcome. Neither can be edited or withdrawn afterwards,
  and the app never paraphrases the referee's words.
- The refusal reuses the existing objection path's landing guards: it refuses wherever it would leave
  the author a broken chain no Grace Day can reach — a commitment carrying no penalty, a Weekly
  Quota, a penalty in any state but `owed`. Those reasons did not change because the timing did.
- **A flagged commitment must be unreachable by the 48-hour objection path,** enforced in the
  database rather than by convention. Unflagged commitments keep that path unchanged.
- Four refusals of the flag itself, enforced in the database and mirrored client-side so a form can
  refuse a bad draft without a round trip: kind must be `do`; never alongside an auto-check kind; the
  photograph requirement comes with it (a sign-off with nothing to look at is a referee guessing);
  and it cannot be set with no referee paired. A later-revoked pairing simply auto-approves.
- The paired referee can open the photograph behind a flagged commitment-day, and no other: not on an
  unflagged commitment, and never for an account he is not paired to.
- The waiting list names only flagged commitments of his paired doer, for the current local day, with
  a photograph and no decision yet. It offers no other day, no other account, no history, and no
  count of anything he has already done.
- A refusal produces exactly **one** message to the author naming the commitment, the day and the
  reason verbatim; an approval and a silence produce none.
- Today tells the author when a flagged row has its photograph and no decision, and stops saying so
  once a decision lands or midnight passes. An unflagged row is unchanged.
- Non-goals: making the referee's inaction cost the author anything; any nudge (email or push) to the
  referee; any change to appeals, collection, Grace Days, the morning question, or the objection path
  for unflagged commitments; re-judging days already answered (the flag reaches forward only); a
  referee-facing history or archive; withdrawing a refusal; editing the photograph after a refusal or
  a second round between author and referee on the same day.

## Technical Decisions

- **The flag decides money, so it is never read live.** Unlike the photo-requirement flag — which
  decides nothing and so needed no history — this one needs a log and an `_as_of()` reader in the
  shape the existing penalty-carrying and due-time readers already have. Toggling it off after a
  refusal, or on after a clean day, must not re-judge a day already answered. **Every reader moves
  through that one door in the same change** — the standing instruction from the Epic 6
  retrospective, where three defects in one day were exactly that shape (a rule read live by some
  readers and historically by others).
- **The refusal is its own table, not the existing objection table,** which is bound to a superseded
  settlement and has no meaning before a settlement exists. It keeps that table's care: the referee
  reference with `on delete restrict`, so a statement about someone else's money is never silently
  anonymised; the reason stored verbatim; the day and the commitment stored rather than derived from
  a settlement chain that moves on afterwards.
- **The owing query gains one clause, not a state.** A flagged commitment with a photograph is held
  exactly as today unless a refusal exists for that commitment and day. No third answer, and the
  day-close deadline logic is untouched.
- **The waiting list is a `security definer` function scoped to the paired doer**, in the shape the
  existing referee day-lookup established — never an RLS grant on the underlying tables. Granting the
  referee `select` on settlement rows is a prior incident in this repo; do not repeat it.
- **Which photograph the referee reads depends on whether the commitment carries a due time:** a
  claim-parented photo (Story 6.3) if it does, a commitment-day photo (Story 6.8) if it does not.
  Both must reach him when the flag is on, so it is the commitment-day arm of the policy that needs
  widening, and only for flagged commitments. The evidence table and storage objects both carry a
  referee policy — **widen both or neither**, or a photograph becomes listable and unopenable.
- **The privacy copy must change with the policy.** The author's photo control currently promises the
  photo is private and only he can open it. That sentence has to stop being said for a flagged
  commitment. This is the *consent* answer to the open retrospective finding that the app promises a
  privacy the policy does not keep — and it only holds if the sentence changes.
- The author's notification belongs to the refusal's own transaction through the outbox, the way the
  existing objection path does it — a message and its body, not a second write path.
- **Invariants that do not move:** the server is the sole judge (AD-1); external effects go through
  the transactional outbox and are idempotent (AD-3); every day boundary resolves in
  `Asia/Ho_Chi_Minh` and no client derives a date for storage (AD-6); authorization lives in RLS, and
  a table ships with its policies in the same migration (AD-7); settlement is the single writer of
  derived state (AD-8); verdict history is append-only (AD-9).

## UX & Interaction Patterns

- The setup copy is load-bearing, not decoration: it is the only place the author learns that his
  friend forgetting costs him nothing. The silence rule is stated in the moment the flag is turned
  on, not in help text.
- **Nothing on the referee's side may nag, count, or imply a duty.** No badge, no count of what he has
  already done, no empty state that reads as a queue drained. The existing referee day-lookup
  component is the model and explains why at length. The product's referee copy is written so that
  forgetting never hurts anyone — people quit tasks where it does.
- The refuse control asks for the reason before it will submit, and says the refusal is final,
  because it is. Each row's status is keyed by its own id so a refusal on one never bleeds into
  another — the same shape the referee home's collection statuses use.
- The author-facing waiting state reads as **information, not a task**. A row that says *waiting*
  invites him to chase his friend, which is the opposite of what silence-approves exists for; the
  words must carry that the day is already safe without a decision. This bends the copy; it does not
  reopen the decision to show the state.
- The waiting state is derived from what already exists — a photograph, no decision row, before
  midnight — so nothing new is stored for it.
- The referee's channel is the web surface and email; he never gets push.

## Cross-Story Dependencies

- 8.1 is the foundation: nothing reads the flag until 8.2. Its `_as_of()` reader is what every later
  story reads through.
- 8.2 is the highest-risk slice and is deliberately isolated — no UI, no notification, no storage
  policy. Its most important assertion is a negative: a day nobody decided must settle identically to
  the unflagged case, chain and penalty included.
- 8.3 is ordered before 8.4 on purpose: the referee cannot decide on what he cannot see.
- 8.4 depends on 8.2's decision table and 8.3's read policy.
- 8.5 is split out of 8.2 rather than folded in — folding work of that size into one slice is what
  produced the 1,579-line single-block test file the Epic 6 retrospective named. It closes the half
  of the open "days that fail with nobody told" item that this epic can reach.
- 8.6 depends on 8.2 (a decision row to be absent) and on the existing photo-evidence surface.
- The Epic 6 spec (`spec-timed-commitments-with-photo-proof/SPEC.md`) owes an amendment: its CAP-5
  and its "referee approval queue" non-goal both contradict this epic's waiting list. The amendment
  should record that the queue is now in scope and that silence-approves is what keeps the old CAP-5's
  property alive.
