---
id: SPEC-commitments-the-referee-signs-off
companions: []
sources:
  - ../../planning-artifacts/sprint-change-proposal-2026-09-10.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Commitments the referee signs off, per the author's choosing

## Why

**A vision to realize, and a simplification to claim on the way.** For some commitments the author wants his friend's signature on the day, not only his own photograph — and he wants to choose which ones, rather than have the referee looking at everything or nothing.

Today the referee's only power over an ordinary day is an objection filed up to 48 hours *after* it closed (`object_to_day()`, Story 6.7). That timing is the whole cost: the day has already settled and the money has already moved, so an objection must supersede the settlement, write a correction, void a penalty and mint a replacement. It is the most intricate path in the schema, and three of the Epic 6 retrospective's open items exist inside it. It also applies to every proven day, whether the author wanted his friend looking at that commitment or not.

This moves the referee's power to where it costs less and means more: **before midnight, and only where the author asked for it.** The property that made the original design safe is kept deliberately — the referee's silence still holds the day, so a friend who forgets to open the app never costs the author money.

## Capabilities

- **CAP-1**
  - **intent:** The author can mark a commitment as needing his referee's sign-off, and is told what that means before he saves it — including that his friend's silence still holds the day.
  - **success:** A commitment saved with the flag persists it; a commitment saved without it behaves exactly as it does today, with no change to any existing row. The setup surface states the silence rule in the moment the flag is turned on, not in help text.

- **CAP-2**
  - **intent:** A photograph attached to a flagged commitment reaches the referee that account is paired to.
  - **success:** The referee opens the photograph for a flagged commitment-day of his own doer. The same referee cannot open a photograph on an unflagged commitment, and no referee can open either for an account he is not paired to.

- **CAP-3**
  - **intent:** The referee marks the day done, or refuses it with a reason in his own words.
  - **success:** A refusal records who said it, when, which day, which commitment, and the reason verbatim. An approval records the same and changes no outcome. Neither can be edited or withdrawn afterwards.

- **CAP-4**
  - **intent:** With no word from the referee, the day holds on the photograph alone.
  - **success:** A flagged commitment with a photograph and no referee decision settles `held`, and the author's chain, quota and money are identical to the unflagged case. No day is ever held open waiting for a person.

- **CAP-5**
  - **intent:** A refusal fails that commitment's day before the day closes.
  - **success:** The refused commitment freezes as `missed` inside the day's own settlement — no superseding settlement, no voided-and-reminted penalty — and a Grace Day still reaches it. Every other commitment on that day settles as it would have.

- **CAP-6**
  - **intent:** The referee can see what is waiting for him today, and nothing else about the author's history.
  - **success:** The list names only flagged commitments of his paired doer, for the current local day, that have a photograph and no decision yet. It offers no other day, no other account, and no count of anything he has already done.

- **CAP-7**
  - **intent:** The author learns that his day was refused, and reads the reason in the referee's own words.
  - **success:** A refusal produces exactly one message to the author naming the commitment, the day and the reason verbatim; an approval and a silence produce none. The reason is never paraphrased by the app.

- **CAP-8**
  - **intent:** Today tells the author that a flagged row is waiting on his referee.
  - **success:** A flagged row with a photograph and no decision says so; the same row stops saying so once a decision lands or midnight passes. An unflagged row is unchanged.

## Constraints

- **The flag decides money, so it is never read live.** It needs a log and an `_as_of()` reader in the shape `carries_penalty_as_of()` and `due_time_as_of()` already have, and every reader moves through that one door in the same change — Epic 6 retrospective item 50: three defects on 2026-09-07 were that one shape. `requires_photo` needed no such reader because it decides nothing; this flag is the opposite.
- **Silence approves, and no design may weaken that.** Nothing waits on a person: not the settlement, not the penalty, not the chain.
- **A refusal lands before midnight or not at all.** After midnight the day is closed, and `object_to_day()`'s existing 48 hours is what covers an unflagged commitment.
- **A flagged commitment is unreachable by `object_to_day()`,** enforced in the database rather than left to convention. Two mechanisms for one job is how they come to disagree.
- **The refusal is its own table, not `public.objection`,** which is bound to `superseded_settlement` and has no meaning before a settlement exists. It keeps that table's care: `referee_id` with `on delete restrict`, so a statement about someone else's money is never silently anonymised; the reason stored verbatim; the day and the commitment stored rather than derived from a settlement chain that moves on afterwards.
- **The refusal reuses `object_to_day()`'s landing guards.** It refuses wherever it would leave the author a broken chain no Grace Day can reach — a commitment carrying no penalty, a Weekly Quota, a penalty in any state but `owed`. Those reasons did not change because the timing did.
- **The waiting list is a `security definer` function scoped to `paired_doer_id()`,** in the shape `referee_day_lookup()` established, and it names today only.
- **The flag rides only on commitments of kind `do`, and never beside `auto_check_kind`.** A machine already answers for those; `abstain` and `daily_hours_quota` have no moment to photograph.
- **The flag implies proof.** It cannot be set without the photograph requirement — a sign-off with nothing to look at is a referee guessing.
- **The flag cannot be set with no referee paired,** and if the pairing is later revoked, flagged days simply auto-approve.
- **CAP-8's copy reads as information, not as a task.** The reason this was an open question stands: a row that says *waiting* invites the author to go chase his friend, which is the opposite of what silence-approves is for. The words must carry that the day is already safe without a decision. This bends the copy; it does not reopen the decision to show the state.
- **The server is the only judge (AD-1).** Every day boundary resolves in `Asia/Ho_Chi_Minh`, verdict history stays append-only, and the client may refuse a bad draft but never decides an outcome.

## Non-goals

- **Making the referee's inaction cost the author anything.** This is the property the reversal below is affordable because of; any design that spends it is out of scope, not a trade-off to weigh.
- **A nudge to the referee** — email or push. The `email-worker` channel exists if the list proves too quiet in practice; that is a later story, not this one.
- **Any change to appeals, collection, Grace Days, the morning question, or the objection path for unflagged commitments.**
- **Re-judging days already answered.** Turning the flag on reaches forward only.
- **A referee-facing history or browsable archive**, and no withdrawing a refusal once it is made.
- **Editing the photograph after a refusal**, or a second round between author and referee on the same day.

## Success signal

The author marks "Thuốc" as needing his friend's sign-off, photographs the pill at 20:12, and his friend opens it that evening and marks it done. The following week the friend is busy three days running and never opens the app at all — and every one of those days holds anyway, on the photograph alone, with no penalty and no broken chain.

## Assumptions

- One referee per doer (`profile_single_referee`, `profile.referee_of`): the waiting list and the refusal are both scoped by that pairing.
- A flagged commitment carrying a `due_time` proves itself with the claim-parented photograph of Story 6.3; one without proves itself with the commitment-day photograph of Story 6.8. Both must reach the referee when the flag is on — see the open question on the storage policy.
- A photograph attached at 23:58 leaves the referee minutes before auto-approval. Accepted rather than solved: auto-approval fails toward the author, which is the safe direction, and the mechanism being decorative for late proof is the price of having no nudge.

## Open Questions

- ~~**Does Today show the author a "waiting" state on a flagged row?**~~ **Answered 2026-09-10 by hwt75: yes.** It is CAP-8, and the concern that made it a question survives as the constraint on its copy.
- **Does the referee's storage policy widen for a commitment-day photograph on a flagged commitment?** Today it reads only rows where `commitment_id is null`. If it widens, note that this is the *consent* answer to Epic 6 retrospective finding A2 (item 43): a photograph the author marked for sign-off is one he chose to show, which the current copy — "It is private — only you can open it" — would then have to stop saying for flagged commitments.
- **`spec-timed-commitments-with-photo-proof/SPEC.md` owes an amendment.** Its CAP-5 (*"the referee reviews nothing on a schedule"*) and its non-goal (*"A referee approval queue… never given a list of photos to work through"*) both contradict CAP-6 here. Deliberately not edited while writing this kernel; the amendment should record that the queue is now in scope and that silence-approves is what keeps the old CAP-5's property alive.
