---
title: 'Story 2.6 — A failed day costs money, and I can see every one'
type: 'feature'
created: '2026-08-19'
status: 'awaiting-approval'
baseline_commit: '7af4335'
review_loop_iteration: 0
story_key: '2-6-a-failed-day-costs-money-and-i-can-see-every-one'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **NOT YET APPROVED.** This story spends one of the two `figure` roles the whole product is allowed,
> and it is the first to write money. It also decides what a ledger row *is*, which is not obvious
> from the acceptance criteria. Read *What a ledger row is* and *What this product will never do with
> money* before the task list.

## Intent

**Problem:** Days are being settled `failed` and nothing follows. The product's entire claim is that
a missed day costs 500,000 VND and that the author can always find out why he owes what he owes — and
right now a verdict is a row nobody can see and nothing charges against.

**Approach:** One penalty per failed day, written only by settlement, referencing the settlement that
caused it so the chain from money back to the answer he gave is unbroken. A ledger that lists them,
and the debt total on Today.

## What a ledger row is

The acceptance criteria say each row shows "its date, the commitment involved, and its outcome",
which reads as one row per missed commitment. It cannot be: **a Failed Day generates one Penalty
regardless of how many commitments were missed** (FR-13). Two rows for one 500,000 VND would either
double the apparent debt or show two half-penalties that do not exist.

So a **ledger row is a day**, carrying its penalty and naming the commitments that caused it. "The
commitment involved" becomes "the commitments involved", which is the only reading that keeps the
arithmetic honest and still answers the question the row exists to answer: *why do I owe this?*

## What this product will never do with money

NFR5, restated here because this is the story where it stops being abstract. The product records a
**claim** that one person owes another, and a **confirmation** that it was paid. Nothing else.

There is no payment integration, no stored instrument, no balance the product can move, and no code
path that transfers value. A penalty is discharged only by the Referee marking it collected — the
product never settles a debt on its own, and no story after this one may add a way for it to.

Amounts are integers of đồng. Never a float: 500,000 of anything in binary floating point is a
rounding error waiting for a number large enough to show it, and this number only grows.

## Boundaries & Constraints

**Always:**
- Exactly one penalty per failed day. The uniqueness is a constraint, not a check-then-insert.
- Written only by a settlement function (AD-8), in the same transaction as the verdict it follows.
- Append-only (AD-9). A grace day, a won appeal or an expiry produces a **new row referencing this
  one**; the displayed state is the fold of that chain, never a field someone overwrote.
- Traceable: penalty → settlement → the declarations for that period → the commitments. Every step
  of "why do I owe this" has to be answerable from rows, not from memory.

**Ask First:**
- Any state beyond `owed`. `Expired` arrives with 2.7, `Dropped` with 4.4, `Collected` with 4.7,
  `Waived` with 5.1 — each added by the story that makes it reachable, so no screen ever renders a
  state nothing can produce.
- Changing the amount, or making it configurable.

**Never:**
- No payment anything. No integration, no instrument, no transfer, no "mark as paid" the author can
  reach. Collection is the Referee's act and belongs to Epic 4.
- No mutation of a penalty row.
- **No screen goes fully red.** On the worst possible day, with every commitment missed, the rows
  stay neutral and only the debt block is tinted. The Ledger needs this stated separately because it
  is structurally a list of failures, and it is reached in one tap from Today on exactly the worst
  day.

## The two rationed things this story spends

**The `figure` role, one of two.** `DESIGN.md` reserves the large type role for exactly two elements
in the entire product: the debt total and a running focus timer. This story claims the first. Nothing
else on any screen may use it afterwards except Epic 3's timer.

**The only large coloured area.** The debt block is `failed-tint` behind `failed-ink`, and it is the
single place in the product where colour covers an area rather than labelling a state. The author
chose that knowingly, against advice, and the design executes it rather than softening it.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Day settles `failed` | One commitment missed | One penalty, 500000 đồng, state `owed` | — |
| Day settles `failed` | Four commitments missed | Still **one** penalty | FR-13; two would be a lie about the debt |
| Day settles `clean` | Nothing missed | No penalty row at all | — |
| Settlement re-runs | Day already settled | No new penalty | The settlement no-op already covers it; the constraint is the second lock |
| Ledger, no penalties | Never failed | Says so plainly, not an empty screen | — |
| Ledger, worst day | Every commitment missed | Rows neutral, pills only | No screen goes fully red |
| Today, debt is zero | Never failed | No debt block at all — an empty figure is a decoration | — |
| Today, debt accrued | Any | Cumulative since first use, never reset by a period boundary | — |
| VoiceOver on Today | Debt block drawn first | **Commitment rows are read before it** | He can look past a figure; he cannot un-hear one |
| Amount stored | Any | Integer đồng | A float here is a defect, not a rounding preference |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819220000_settlement.sql` -- `settle_day` is where the penalty is written,
  in the same transaction as the verdict. The `on conflict do nothing` pattern is the one to copy.
- `lib/commitment-state.ts` -- the four families and the rule that a row is never tinted. The ledger's
  rows reuse `CommitmentRow`'s shape rather than inventing one.
- `app/tokens.css` -- `--type-figure` and `--type-figure-tracking` exist and have never been used.
  This is their first and one of only two legitimate uses.
- `components/today.tsx` -- gains the debt block, and with it the accessibility-order rule recorded in
  Story 2.3's spec against exactly this moment.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_penalty.sql` -- `penalty_state` enum with `owed` only; the `penalty`
  table with its integer amount, its reference to the settlement that caused it, and uniqueness on
  that reference; RLS so an account reads its own and writes none; `settle_day` extended to write it
  in the same transaction.
- [ ] `lib/money.ts` + test -- integer đồng, formatting for display, and a guard that no float ever
  reaches storage.
- [ ] `lib/ledger.ts` + test -- folding a day's penalty and its missed commitments into one row.
- [ ] `components/debt-block.tsx` -- the figure. The only large coloured area; tapping opens the
  ledger.
- [ ] `components/ledger.tsx` -- one row per day, neutral rows with pills, and the empty case.
- [ ] `components/today.tsx` -- the debt block, drawn first and **read last**.

**Acceptance Criteria:**
- Given a day settled `failed` with any number missed, then exactly one penalty of 500000 exists.
- Given a day settled `clean`, then no penalty exists.
- Given settlement re-running, then no second penalty appears.
- Given the ledger, then each row names its date, the commitments that caused it and its outcome, and
  no row is tinted.
- Given the debt block, then it is the only element using the `figure` role and the only large
  coloured area on the screen.
- Given VoiceOver on Today, then the commitment rows are announced before the debt block.
- Given the schema, then the amount column is an integer type and no float appears anywhere near it.
- Given the whole codebase, then there is no payment integration and no code path that moves value.

## Design Notes

**Why the penalty references the settlement rather than the day.** A day is a date; a settlement is
the decision that closed it, with the subject and the missed count attached. Referencing the decision
means the chain from a number he owes back to the answer he gave is a series of foreign keys rather
than a join on two loose values that could disagree.

**Why the debt block is absent rather than zero.** A large `0` in failed-tint is a decoration that
tells him nothing and costs him the reluctance of opening a screen with a red area on it. The block
appears when there is something to say.

## Verification

**Commands:**
- `npm test` -- expected: money and ledger rules pass alongside the existing 247
- Advisor after applying -- expected: no new lints
- `grep -rniE "stripe|paypal|momo|vnpay|charge|payment" app components lib supabase` -- expected: no
  matches outside comments forbidding them

**Manual checks:**
- Settle a test account's failed day twice; confirm one penalty
- Ledger on a day where everything was missed: rows neutral, only pills coloured
- VoiceOver order on Today: rows before the figure
