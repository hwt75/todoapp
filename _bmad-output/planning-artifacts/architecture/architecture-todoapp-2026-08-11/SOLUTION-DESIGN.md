---
title: "Solution Design: todoapp"
status: final
created: 2026-08-11
updated: 2026-08-11
sources:
  - ./ARCHITECTURE-SPINE.md
  - ../../prds/prd-todoapp-2026-08-11/prd.md
  - ../../ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md
---

# Solution Design: todoapp

`ARCHITECTURE-SPINE.md` is the contract — terse by design, decisions only. This document is the
reasoning behind it: what the product demands that ordinary apps do not, which alternatives were
weighed, and what was deliberately left undecided. When the two disagree, the spine wins.

## What makes this architecture unusual

Most task apps can be wrong occasionally and nobody notices. This one moves 500,000 VND per failed
day between two people who know each other, and a friend physically collects it. That single fact
generates every non-obvious decision here.

Three demands follow from it:

**The system must explain itself.** When the author sees a debt he does not remember incurring, he
will not file a bug — he will stop trusting the mechanism and delete the app. Every penalty must be
traceable to the observation that produced it. This is why the data model is an event log rather
than a set of mutable rows: the ledger is not a screen, it is the storage design.

**The clock must run when nobody is looking.** The product's defining requirement (FR-9) is that an
unanswered morning question expires to a miss after 48 hours. That timer exists precisely for periods
when the author has gone quiet — so it cannot live anywhere that depends on him opening anything.

**Two people must see one truth.** The referee decides appeals and collects money. If his screen and
the author's phone can disagree, he will eventually chase money that was already waived, which is the
fastest possible way to lose the referee — the risk the PRD already ranks first.

## The platform decision, and how it went

This was the largest reversal in the project and it is worth recording honestly, because the
reasoning matters more than the outcome.

Both the PRD and the UX specs were written for a native iOS app. The author then revealed he has no
Mac and no Apple Developer account. Investigation separated two things that looked like one problem:

- **No Mac is not a blocker.** Cloud macOS build services compile and sign without owning hardware.
- **No Apple Developer account is a hard blocker.** Apple requires it for code signing, with no
  official path around it.

A sideloading route exists — AltStore with AltServer on Windows, which the author has, signing with
a free Apple ID and refreshing the seven-day certificate automatically. It was investigated and
rejected on a specific finding: **a free Apple ID cannot sign the push notification entitlement.**
The app would install and run, and never notify anyone. For a product whose own PRD states that a
capability requiring the user to open the app unprompted does not exist, that is not a degraded
version — it is a non-functional one.

So the real choice was a 99 USD/year account or a web app. The author chose the web app.

**What made that survivable was a decision taken weeks earlier for entirely different reasons.**
During the UX phase he asked for automatic checks to become optional per commitment rather than a
fixed three-tier model. That change was made to give him control over his own task setup. Its
side effect is that a build with no sensors at all is still a complete product: every commitment
falls back to a declaration, and the money, the referee, and the settlement rules are untouched. Had
the tiered model survived, the platform pivot would have cost the product its spine rather than two
conveniences.

What v1 actually loses: the location and movement Auto-checks, and an alarm-grade morning gate that
breaks through silent mode. What it gains: one codebase instead of two, no App Store review, no
annual fee, and a working system in weeks rather than months.

## Why the server judges, and the client only reports

The alternative — the phone computes verdicts and syncs them — is genuinely simpler for a solo
builder, and it was weighed seriously. It fails on two counts, and the first is fatal.

The 48-hour expiry timer cannot exist on the phone. It only fires when the app runs, and the entire
scenario it was designed for is the author not running the app. A phone-authoritative design would
mean going silent leaves days permanently unresolved, which is precisely the loophole the expiry
rule was introduced to close.

Second, the referee reads a synchronized copy. If the author has not opened the app, the referee sees
stale truth and may collect on a penalty already voided by a grace day.

Making the client a reporting terminal has an unplanned benefit that turned out to matter: because
the client holds no logic, replacing it with a native app later touches no settlement code. The
deferred native client is a client swap, not a rewrite.

## Why an append-only event log rather than CRUD

CRUD was the obvious choice for a two-user application and would be less code. It was rejected for
two reasons that are specific to this product rather than general good practice.

A wrong balance in a CRUD design cannot be explained. There is no record of how it got there, so the
only available answer to "why do I owe this?" is "because the row says so" — which, for a user whose
documented failure mode is retreating from the app, is the answer that ends the project.

And a settlement job that runs twice in a CRUD design charges twice. Guarding that properly means
recording what has already been counted, which is an event log with extra steps.

Full event sourcing — no state tables at all, every read a replay — was also rejected. At two users
and five commitments it buys purity at a real cost in code. The chosen middle keeps settled verdicts
as ordinary rows that happen to be append-only and derived from a log.

## Why settlement lives in Postgres, and why the outbox exists

The author chose plpgsql functions called directly by `pg_cron` over a TypeScript Edge Function, and
the reason is transactional integrity: a settlement pass either completes or rolls back entirely.
There is no HTTP hop where a job can die after writing money but before finishing.

That choice has a limit. Postgres should not be signing VAPID push payloads, parsing an external
API's JSON, or sending email. The transactional outbox resolves this without weakening the guarantee:
the settlement function writes the verdict *and* the work-to-send in one transaction, and a separate
worker drains the queue. A crash mid-settlement rolls back both. There is never a penalty with no
notification, nor a notification for a penalty that did not survive.

The subtlety worth remembering: **the outbox worker runs on its own schedule, not settlement's.** A
queue whose only consumer is triggered by the producer looks exactly like a working system right up
until the producer stops.

## The four collisions found by adversarial review

These were not in the first draft of the spine and are the most likely places a future change breaks
something. Each is a case where two pieces of code, both obeying every stated rule, still disagree.

| Collision | What went wrong | Now fixed by |
|---|---|---|
| Two writers of a chain | Money had one writer; streaks had none. The grace-day path and the daily settlement could both repair a chain, to different values | AD-8, widened to every derived value |
| Check runs after settlement | Schedule the external check ten minutes after day-close and it is `unavailable` every day, forever — silently turning an auto-checked commitment into a manual one | AD-13 |
| A session crossing midnight | Start 23:50, stop 00:20. Three defensible attributions, and under a flat penalty the difference is a failed day | AD-14 |
| Appeal ruling races week close | Both may resolve a held penalty, to opposite outcomes, decided by commit order | AD-15 |

None of these were visible from the requirements. They only appear when you ask what two independent
implementations would do.

## What was deliberately not decided

Real observability is deferred, with one substitute: **the daily summary is the heartbeat.** If
settlement dies — a failed migration, a paused free-tier project — the summary stops arriving. This
matters because every failure mode here is silent *and* favorable: nothing closes, nothing is
charged, and the author has no reason to investigate a system that has stopped asking him for money.

Also deferred: backup beyond the platform default, event log compaction, and anything resembling
multi-user support. Payments are not deferred — they are permanently out of scope, and that is the
decision that keeps this project legally and operationally simple.

## What to build first

The sequence matters more than usual, because one unverified assumption sits underneath everything.

1. ~~**Prove Web Push on the author's own iPhone.**~~ **DONE 2026-08-18 — it works.** Four sends,
   all `201`, all delivered: to a locked phone, after a reboot, through an offline window (queued and
   delivered on reconnect), and after 3h 42m with the app untouched. No subscription was invalidated.
   The riskiest assumption in the document is now a verified fact, and the design token layer and
   Epic 2 — both held back against a negative result — are unblocked. Evidence:
   `_bmad-output/implementation-artifacts/story-1-2-findings.md`.
2. ~~**Confirm TryHackMe completion history is externally readable.**~~ **DONE 2026-08-18 — it is
   not.** Every path on the site answers a sessionless request with a Vercel bot challenge, the
   official API is Enterprise-plan-gated, and the only reachable surface carries no dates and was 45
   days stale. FR-8 has no target: the timer is v1's only Auto-check and every other Commitment is
   settled by Declaration, which FR-8b was already written for. Evidence:
   `_bmad-output/implementation-artifacts/story-1-3-findings.md`.
3. **Schema, RLS, and the event log.** The invariants that are expensive to retrofit.
4. **Settlement functions and the cron schedule**, with the outbox and its worker — the mechanism,
   before any screen exists.
5. **The doer's surfaces**, in the order the day uses them: Today, the morning declaration, the
   ledger.
6. **The referee's surfaces.** Last, because in a good week they show nothing.
