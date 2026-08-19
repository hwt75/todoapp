---
title: 'Story 2.7 — Silence is not a way out'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '428110d'
review_loop_iteration: 0
story_key: '2-7-silence-is-not-a-way-out'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75** — the supersession reading below, not the simpler
> expiry-is-final alternative. Frozen from here.

## Intent

**Problem:** Story 2.5 left a day nobody answered open forever, deliberately, because deciding
against him for not answering is a serious thing to build casually. But a question that can be
ignored indefinitely is a question with no cost, and the whole mechanism depends on his word being
the thing that settles a day. Going quiet must never be cheaper than telling the truth.

**Approach:** A declaration unanswered 48 hours after it was first requested expires, settles as a
miss, and closes its day like any other. The ledger shows it as `Expired` rather than as something he
said, because those are different facts about him and collapsing them would make the record lie.

## AD-5 and the fifth acceptance criterion

**The collision.** AD-5 says a settled period is never re-settled, and that *"late-arriving events for
a settled period are recorded and ignored for that period's verdict."* The fifth acceptance criterion
says the opposite for one case:

> Given I answered while offline and the submission was still queued when 48 hours elapsed, when the
> queue flushes, then my answer settles the day it belongs to, and any expiry already written is
> superseded — I answered in time; only the delivery was late.

**The resolution, and why it is not a fudge.** AD-5's phrase is *late-arriving events*. A declaration
carries `answered_at` — the instant he tapped, which the offline queue preserves precisely so this
distinction can be made. An answer given at 07:31 on day two and delivered on day four is **not a
late event**. It is a timely event delivered late, and the two are different facts.

So the rule this story adds: **an expiry is superseded by a declaration whose `answered_at` precedes
the deadline, and by nothing else.** An answer genuinely given after the deadline is a late event and
AD-5 governs it — recorded, ignored for that period's verdict, and the remedy is a Grace Day.

**And it is a new row, never a mutation** (AD-9). The expiry settlement stays. The supersession is a
row referencing it, and the ledger shows the fold. Losing the trace of why a penalty appeared and
then vanished is precisely what makes a ledger untrustworthy, and this is the first thing in the
product that could make one vanish.

**If this reading is wrong, say so now.** The alternative — that an expiry is final regardless of when
he answered — is defensible and simpler, and it means a man who answered honestly from a tunnel pays
500,000 VND for his carrier's coverage. Changing it later means rewriting every ledger fold.

## When the clock starts and stops

A declaration for day `D` is requested at his morning hour on `D+1`. It expires at that same hour on
`D+3`. Wall-clock, in `Asia/Ho_Chi_Minh` (AD-6), and **not extended for being unreachable** — the
remedy for a genuinely impossible two days is a Grace Day applied from the ledger afterwards (5.1),
which is a recorded act with a count, rather than a clock that quietly stretches.

## Boundaries & Constraints

**Always:**
- An expiry settles the day as a miss and closes it, exactly as an answered day closes.
- The ledger distinguishes `Expired` from `Owed`. What he did and what he failed to do are different
  facts and the record must not merge them.
- Everything is written by a settlement function in one transaction (AD-2, AD-8).

**Ask First:**
- Any notification about an expiry. FR-16's intervention is its own concern with its own rules, and
  a "you have been quiet" push sent by this story would be the second mechanism nagging him.
- Extending the deadline for any reason.

**Never:**
- No mutation of a settlement or a penalty. Corrections are new rows (AD-9).
- No expiry written for a day whose declarations are complete.
- No supersession by an answer genuinely given after the deadline.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Unanswered 48h | Nothing filed | Expires, settles as a miss, day closes | — |
| Answered on day two | Before the deadline | Settles the day it belongs to, no expiry | The day it belongs to, never the day he answered |
| Answered offline day two, flushed day four | `answered_at` before the deadline | The answer supersedes the expiry, as a new row | He answered in time; only delivery was late |
| Answered day four for a day-one question | `answered_at` after the deadline | Recorded, ignored for the verdict (AD-5) | The remedy is a Grace Day, not a rewrite |
| Expiry runs twice | Already expired | No-op | Same `(subject, period, kind)` key |
| Partially answered day | One of two filed | The unanswered one expires; the day closes on both | A day cannot half-close |
| Genuinely unreachable two days | Nothing filed | Expires on wall-clock time | NFR6a; the clock is not the place for mercy |
| Ledger | An expired day | Says `Expired`, not `Owed` and not a slip | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819220000_settlement.sql` -- `settle_day` closes a day only when
  `answered = total`. The expiry is what makes that condition reachable for a silent day.
- `supabase/migrations/20260819230000_penalty.sql` -- one penalty per failed day, whatever made it
  fail. An expired day is a failed day and costs the same.
- `lib/ledger.ts` -- `ledgerPillLabel` returns `Owed` or `Clean` today. `Expired` is the third, and
  the first state added by the story that makes it reachable, as the pattern requires.
- `lib/offline-queue.ts` -- preserves `answered_at` as the tap instant, which is the only reason the
  supersession rule can tell a timely answer from a late one.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_expiry.sql` -- `expired` added to `day_verdict` and `penalty_state`;
  a `superseded_by` reference on `settlement` for the fold; `expire_due_declarations()` writing an
  expiry per silent day; `settle_day` teaching itself that an expired declaration counts as answered.
- [ ] `supabase/migrations/<ts>_supersede.sql` -- the rule that a declaration whose `answered_at`
  precedes the deadline supersedes an expiry, as a new row.
- [ ] `lib/expiry.ts` + test -- the deadline from a day and a morning hour, and whether an
  `answered_at` beats it. Pure, both sides of the boundary.
- [ ] `lib/ledger.ts` -- `Expired` as an outcome, folded so a superseded expiry shows the answer.
- [ ] `components/ledger.tsx` -- the `Expired` pill, in the `failed` family but worded differently.

**Acceptance Criteria:**
- Given nothing filed 48 hours after the request, then the day settles as a miss and closes.
- Given an answer before the deadline, then no expiry is written.
- Given an answer whose `answered_at` precedes the deadline but arrives after it, then the expiry is
  superseded by a new row and the ledger shows the answer.
- Given an answer genuinely given after the deadline, then the expiry stands.
- Given the ledger, then an expired day reads `Expired` and never `Owed`.
- Given any of this, then no settlement or penalty row is ever updated in place.

## Design Notes

**Verified against the live project on 2026-08-19.** A day left entirely unanswered settled
`expired` with one penalty. An answer tapped inside the deadline and inserted days later superseded
it: two settlement rows in history and one that counts, one penalty in history and none that counts,
and the current verdict `clean`. The trace of why a penalty appeared and then vanished survives
exactly as AD-9 requires.

**A branch of the rule we agreed turns out to be unreachable, and that is worth knowing.** The
supersession test is "answered before the deadline", with the intent that an answer genuinely given
after it leaves the expiry standing. It cannot happen. The `for_day` trigger derives the day as
`answered_at - 1 day`, so a tap always lands on `D+1` while the deadline is on `D+3` — a margin of at
least 24 hours, whatever the morning hour, measured rather than reasoned. Structurally, **a day older
than yesterday cannot be answered at all**, which means silence past two days can only end in an
expiry.

That is the intended shape of FR-9 rather than a defect, but it makes the discriminator
correct-by-construction rather than discriminating. The check stays: it is the rule, not the current
arithmetic, and a catch-up surface would make it live overnight. It is pinned by a test so the
property is noticed if it ever stops holding.

**One thing nearly shipped wrong.** The client was still reading `penalty` and `settlement` rather
than the folded views, so a superseded expiry would have kept charging him for a day he had taken
back. Both surfaces now read `penalty_current` and `settlement_current`, and a check confirms no
component touches a base table.

**Why an expired day costs the same as an admitted one.** It is tempting to charge less for silence
than for an admitted slip, or more. Both are wrong: less makes silence cheaper than honesty, which is
the exact failure this story is named after, and more makes the product punish unreachability. Same
price, different label.

## Verification

**Commands:**
- `npm test` -- expected: deadline arithmetic passes alongside the existing 316
- Advisor after applying -- expected: no new lints

**Manual checks:**
- A silent day expires and appears as `Expired` in the ledger
- An answer dated before the deadline, inserted after it, supersedes the expiry and the ledger folds
  to the answer
- An answer dated after the deadline leaves the expiry standing
