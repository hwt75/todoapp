---
title: 'Story 2.8 — The day tells me how it went'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '24ac9a3'
review_loop_iteration: 0
story_key: '2-8-the-day-tells-me-how-it-went'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75** — all three: the copy minus the chain and quota clauses, the
> widened self-dating rule, and no summary for an expired day. Frozen from here.

## Intent

**Problem:** A day closes, a penalty is written, and nothing tells him. The whole product is a
notification, and the one at the end of the day is the one that decides whether tomorrow starts from
somewhere or from a list of failures. The author's documented pattern is a bad day becoming a bad
week; this message is the intervention against that, and it has to work without the app being opened.

**Approach:** Settlement writes the summary to the outbox in the same transaction as the verdict
(AD-3). The worker delivers it. The body is legible in full on the lock screen, states the count
once, never itemises, names something that held, and offers exactly one thing to do tomorrow.

## What the specified copy asks for that is not built

`EXPERIENCE.md` gives the exact strings, and both reference things later stories add:

> *"One of five today. That's 500,000. Morning exercise held though — **day 12**. Start there
> tomorrow."*

`day 12` is a chain count. Chains are Story 2.9.

> *"Four of five today. **Gym is still 1 of 3 with two days left.** Tomorrow morning is the easy one
> to take."*

Quota position needs Week Close, which is not built either.

**Proposed:** send the message the copy specifies minus those clauses, and add them in the stories
that make them true. This is the same restraint Story 2.3 applied to chains and 2.5 applied to the
Today verdict — a notification that says `day 12` when nothing counts chains is worse than one that
does not mention it, because he has no way to know it is fiction.

So today: *"One of five today. That's 500,000₫. Morning exercise held though. Start there tomorrow."*
Every element of the specified shape survives except the chain: amount once, no itemising, something
that held, one starting point.

## The self-dating collision

Story 2.4a's payload rule requires a body to carry the time it was sent, because a push can arrive
minutes late and a notification sitting on the lock screen must be distinguishable from a new one.
`lib/outbox.ts` enforces it by checking the body contains `HH:MM`.

A day summary in the coach register cannot carry a clock time without sounding like a machine —
*"Four of five today. (21:00)"* is not the voice this product uses, and voice here is load-bearing.

**Proposed:** the rule becomes *carry enough of your own timestamp to be told from a stale copy*, and
the unit is whatever the message is about. A reminder is about a moment and carries `HH:MM`. A day
summary is about a day and carries the day: *"Four of five on Tuesday."* Read a day later it is
unambiguous, which is the whole point of the original rule.

That is a real change to a rule written two stories ago, so it is proposed here rather than made
quietly, and `payloadProblems` will accept either form.

## Boundaries & Constraints

**Always:**
- Written to the outbox by settlement, in the same transaction as the verdict (AD-3). Settlement
  never calls out.
- Legible in full on a lock screen with no interaction, and no longer than that allows.
- Exactly one suggestion, naming a specific commitment.
- The coach register: second person, short, present tense, no threat. It speaks like someone who
  knows the history and is not scandalised by it.

**Ask First:**
- Any second suggestion, or a suggestion that names no commitment.
- Sending a summary for a day with no commitments at all.

**Never:**
- **Never itemise the misses.** State the count and the amount once, then name something that
  survived. A list of failures is the thing this message exists to replace.
- Never name the money in a message that asks a question. This one states it after the fact, which
  is allowed; the morning gate may not.
- No summary for a day that settled `expired`. He was not there. A cheerful count of what held on a
  day he never answered is the product being glib about its own silence, and the ledger will tell him
  soon enough.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Clean day | Everything held | Count, one suggestion naming a commitment | — |
| Failed day, one miss | Penalty written | Count, amount once, something that held, one starting point | Never a list of what was missed |
| Failed day, everything missed | Nothing held | Count and amount, one suggestion, and no false comfort | It must not claim something held when nothing did |
| Expired day | Closed on the clock | **No summary at all** | He was not there to be summarised |
| Day with no commitments | Nothing configured | No summary | — |
| Settlement rolls back | Transaction aborts | No verdict and no summary | The point of the outbox |
| Worker runs the effect twice | Same dedupe key | One notification | — |
| Read the next morning | Delivered late | The body names the day it is about | The self-dating rule, at the right unit |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819241000_expiry_and_supersession.sql` -- `settle_day` is where the
  verdict is written and therefore where the summary is enqueued, in the same transaction.
- `lib/outbox.ts` -- `payloadProblems` and `bodyStatesItsTime`. The self-dating rule lives here and
  is what this story proposes to widen.
- `supabase/migrations/20260819210000_gate_reminder.sql` -- the enqueue shape to copy, including the
  dedupe key carrying the subject and the period.

## Tasks & Acceptance

**Execution:**
- [ ] `lib/summary.ts` + test -- the sentence, built from a count, an amount and the name of
  something that held. Pure, so the copy rules are testable: no itemising, one suggestion, one
  amount, and the day named.
- [ ] `lib/outbox.ts` -- self-dating widened to accept a named day as well as a clock time, with the
  reason recorded.
- [ ] `supabase/migrations/<ts>_day_summary.sql` -- `settle_day` enqueues the summary alongside the
  penalty, skipping expired days, with a dedupe key of subject and period.
- [ ] `app/sw.ts` -- unchanged; the worker and the service worker already carry whatever the payload
  says.

**Acceptance Criteria:**
- Given a clean day, then one summary is enqueued naming the count and exactly one commitment to
  start with tomorrow.
- Given a failed day, then the summary states the amount once, names something that held, and lists
  nothing.
- Given a day where nothing held, then the summary offers a starting point without claiming anything
  survived.
- Given an expired day, then no summary is enqueued.
- Given settlement running twice, then one summary exists.
- Given the body, then it names the day it is about and passes `payloadProblems`.

## Design Notes

**Verified against the live project on 2026-08-19.** A failed day produced exactly one summary:
*"Two of three on Monday. That's 500.000₫. No fap held though. Start with TryHackMe tomorrow."* —
91 characters, under the lock-screen ceiling, count once, amount once, something that held named,
one commitment to start with, and nothing itemised. The clean and nothing-held shapes were checked
too; the second offers a starting point without claiming anything survived. An expired day settled
`expired` and enqueued **zero** rows.

**The two copies drifted within minutes.** The copy rules live in `lib/summary.ts` as tested
functions and in `public.day_summary_body` as the thing settlement actually calls, because settlement
runs in Postgres. `to_char`'s group separator follows the database's `lc_numeric`, so the SQL rendered
`500,000₫` while `formatDong` renders the Vietnamese `500.000₫` — and the one the author would have
read on his lock screen was the wrong one. Fixed by making the separator explicit; the seam itself is
recorded in `deferred-work.md`, because a rule in two languages will drift again.

**A test disagreed with its own checker, and the checker was wrong.** `summaryProblems` flagged the
suggestion as an itemised miss. But *"Start with Gym tomorrow"* when Gym was missed today is the
correct sentence — the rule is never to *list* the misses, not never to name one as a place to begin.
The suggestion is now exempt, which is the rule stated properly rather than a loophole.

**Why nothing is sent for an expired day.** It is tempting to summarise anyway — the data is there.
But a message that says "one of five today, start with X tomorrow" about a day he never answered is
the product pretending it knows how his day went. It does not. It knows he did not say.

## Verification

**Commands:**
- `npm test` -- expected: copy rules pass alongside the existing 343
- Advisor after applying -- expected: no new lints

**Manual checks:**
- Settle a failed day for a test account; confirm exactly one outbox row, an amount stated once, and
  no list of misses
- Settle an expired day; confirm no outbox row
