---
title: "Product Brief: todoapp (working name)"
status: complete
created: 2026-08-11
updated: 2026-08-11
---

# Product Brief: todoapp (working name)

## Executive Summary

Most task apps solve a problem their users do not have. People who abandon todo apps rarely abandon
them because they forgot what to do. They abandon them because they slipped once, the list turned into
a visible record of failure, and opening the app started to feel worse than ignoring it.

This product is built around that specific failure, not around task capture. It puts real money and a
real person behind a small set of daily commitments, verifies only what can honestly be verified, and
— critically — is designed to pull the user back on the second day after a slip, which is the moment
the habit is actually lost.

It runs on two surfaces with two different jobs: an iOS app for the person doing the work, and a web
app for the referee — who is deliberately kept idle. Where a sensor can confirm the work, the task
approves itself. The referee is pulled in only on exception: to rule on a contested miss, and to be
told to go and collect when a penalty stands. The product never touches money. It notifies, and it
records the referee's confirmation that the money was collected. That is the whole payment system.

## The Problem

The author is the first user and the problem is his own, in his own words: he sets up a daily routine,
follows it for a few days, slips, and then quietly stops. Not dramatically — he opens the app again,
feels reluctant, and does not resume for several days. Repeat that a few times and the system is dead.

Three things make conventional todo apps fail him specifically:

1. **The checkbox lies.** His real commitments are not one kind of thing, yet every app presents them
   as identical rows with identical checkboxes. For most of them, ticking the box proves nothing.
2. **Nothing is at stake.** Completion and non-completion feel the same by bedtime. Streaks made of
   in-app points do not survive contact with a bad week.
3. **Slips are unrecoverable.** A broken streak resets to zero and stays visible. The app offers no
   path back, so he takes the only path available: stop looking.

The task he most wants help with — abstaining from a compulsive habit — is also the one he has failed
at repeatedly, and the one no software can observe.

## Three Kinds of Task

This came out of listing his eight real weekly commitments, and it shapes the whole product. Treating
them as one type is a large part of why existing tools fail him.

| Kind | Examples from his week | How it fails | What it needs |
|---|---|---|---|
| **Do** | Gym, morning exercise, one TryHackMe lesson | Simply not done | A finish line and a streak |
| **Abstain** | No fap | Broken in a single moment, often late at night | A chain, a soft landing, and a fast route back |
| **Open-ended** | Company work of unpredictable length, financial-report research, building a horoscope agent | Has no definition of "done" at all | A commitment to time or output, not to completion |

Open-ended work is the quiet problem. A task with no completion criterion cannot be ticked honestly,
cannot be verified, and must never carry money.

**Cadence is a separate dimension from kind**, and the product needs both:

| Cadence | Example | When it can be judged failed |
|---|---|---|
| **Daily** | No fap, morning exercise | At the end of that day |
| **Weekly quota** | Gym, three sessions per week | Only at the end of the week |
| **One-off** | A task that exists for a single day | At the end of that day |

The weekly quota is the awkward one and it changes real behavior. A gym target of three sessions
cannot fail on a Tuesday: nothing is owed until the week closes. That has three consequences —
penalties settle weekly rather than daily; reminders must reason about sessions remaining against days
remaining, escalating as the week runs out; and a streak on such a task counts consecutive *weeks* at
quota, not consecutive days.

## The Solution

**On iOS — for the person doing the work.** A small set of daily commitments, separated by kind.
Reminders with real persistence. Machine-verified tasks confirm themselves with no user action; others
prompt for a tick or a piece of evidence. Money is at stake only where verification holds.

**On web — for the referee.** A dedicated account with its own login, quiet by default. It surfaces
two things only: contested misses to rule on, and penalties to go and collect, ticked off once
collected. On the collection side the referee is the active party — the app does not wait for the user
to pay, it tells someone else to come and get it. That asymmetry is deliberate and is where most of
the pressure comes from. It is also why this surface does not need aggressive push notifications: the
person who needs nagging is on the phone, not here.

**Recovery is a first-class feature, not a courtesy.** Because this user goes quiet for days after a
slip rather than quitting outright, the product's single most important behavior is noticing the
silence and intervening: reaching out after two quiet days, offering a limited and countable grace
allowance, and escalating to the referee when silence persists. Penalties are real and they land — but
there is always a visible way back, because a user who cannot see one stops looking at all.

**Three review horizons.** An end-of-day summary of what was completed with a concrete suggestion for
tomorrow; a weekly review that closes out quota tasks, settles the week's penalties, and shows whether
the week held; and a monthly report giving the longer view — trends, streaks, penalties incurred, and
whether the whole arrangement is still working. A streak protects the single most important task of
each day.

**Claims are same-day; rulings follow the settlement clock.** Evidence must be submitted on the day
the work is claimed — that is what keeps the record honest. But the referee's ruling is not bound to
the same hour: for a weekly quota task, a contested session has until the week closes to be resolved,
which gives the referee days rather than minutes. Whatever the window, one principle is fixed: **a
pending item never converts into a failure on its own.** Charging the user for the referee's silence
would break trust in the mechanism immediately and permanently, so a contested penalty is held, not
applied, until it is ruled on or the period closes.

## Verification Model

"Prove the task was really done" cannot be satisfied in general. Software cannot observe most human
commitments, and it certainly cannot observe a thing that did *not* happen. Rather than build an
anti-cheat system that would only protect the tasks the author already succeeds at, the product states
the limit honestly and tiers on it:

| Tier | How it is confirmed | Carries money? |
|---|---|---|
| **Machine-verified** | Gym via GPS geofence with dwell time; morning exercise via phone motion data; TryHackMe via completed-room history | **Yes** |
| **Referee-approved** | User submits evidence or a claim; the referee approves it from the web app | Optional |
| **Self-reported** | User's word alone | No |

The referee is not a supervisor bolted on for extra pressure. **The referee is the verification layer
for everything a sensor cannot reach.** Cheating remains possible, but its cost stops being technical
and becomes social: you have to lie to a specific person who is looking. For the abstinence task, that
is the only thing that has ever worked.

**The referee is an appeals court, not a daily approver.** Where a sensor confirms the work, the task
approves itself and the referee is never involved. The referee is drawn in only on exception: when the
machine says the commitment was missed, the user may submit evidence contesting it, and the referee
rules. This keeps the happy path free of referee effort entirely, which matters because referee
attention is the scarcest resource in the system.

The asymmetry is deliberate. It catches **false negatives** — the session that happened but the phone
missed, because it was left at home or the GPS drifted — which are the failures that would otherwise
take money from someone who did the work. It does not catch **false positives**, such as sitting in
the gym for forty-five minutes doing nothing. That remains uncaught by design, consistent with the
principle throughout: this system protects the author from himself, not from a determined cheater.

## Who This Serves

**For now, only the author.** One person, verified against his own real week. This is deliberate — the
mechanism depends on knowing exactly how one person fails, and a sample of one that is understood
beats a sample of a thousand that is guessed at.

**Later, if it works for him:** people who have repeatedly bounced off conventional todo and habit
apps, who do not need another place to store tasks but need something that makes stopping expensive
and restarting easy.

## What Makes This Different

- **It admits what cannot be verified** and refuses to attach money to it, rather than pretending an
  anti-cheat system can cover everything.
- **It is designed around the slip, not the streak.** The advantage is what happens on day two after
  failure — the moment every other app loses the user.
- **It separates task kinds** instead of flattening everything into one checkbox.
- **It carries real stakes without touching payments.** Two screens and a notification: no payment
  integration, and none of the regulatory, chargeback, or App Store exposure that sinks solo projects.
  The consequence is real precisely because a person, not a system, comes to collect.

## Scope

Phase 1 is one user and one referee, with real money live from the first day. Deferring the stakes was
considered and rejected: since the payment system amounts to a notification and a checkbox, holding it
back would have bought almost no time.

**In:**

- iOS app for the doer: commitments carrying both a kind (Do / Abstain / Open-ended) and a cadence
  (daily / weekly quota / one-off), persistent reminders, evidence submission, manual ticks
- Weekly quota tracking: progress against the target, reminders that escalate as sessions remaining
  approach days remaining, penalties settled at week close
- Machine verification from the phone alone: motion data for step-based tasks, a GPS geofence with
  dwell time for the gym, TryHackMe completion history
- Web app for the referee: its own account, rule on contested items only, receive collection
  instructions, mark a penalty collected
- Appeals: when machine verification says a commitment was missed, the user may submit same-day
  evidence; the penalty is held until the referee rules or the period closes
- Recovery mechanics: detection of silence after a slip with intervention on day two, a limited and
  countable grace allowance, escalation to the referee when silence persists
- A streak on the single most important task of each day, and on weeks held at quota
- Three review horizons: end-of-day summary with a suggestion for tomorrow, weekly close-out, and a
  monthly report

**Out:**

- Payment processing of any kind — the app never holds or moves money
- Wearable and third-party health integrations, including the author's Huawei watch
- Android, and any surface beyond iOS and the referee web app
- Multiple referees, social feeds, leaderboards, or any user-to-user feature beyond the single
  doer-referee pair
- Public launch

## Success Criteria

The author's own targets: **the length of the no-fap streak**, and **100% completion on gym and
morning exercise**. These are the goals and the reason the product exists, recorded here unchanged.

They cannot be the only measures, for a specific reason: **a month at 100% would tell us nothing about
whether this product works.** Everything distinctive here — the penalty, the referee, the recovery
mechanism — only activates on failure. A clean month means an easy month, not a validated mechanism.
The product is proven the first time the author slips and comes back quickly.

So three more measures sit alongside them:

| Measure | Why it matters | Target |
|---|---|---|
| **Days to return after a slip** | The exact failure this product was built for; his history is several days of silence | Median ≤ 1 day |
| **Silences longer than two days** | The abandonment pattern, caught in the act | Declining, then zero |
| **Referee still approving in week 8** | Directly tests the top-ranked risk. If the referee has gone quiet, the penalty is theatre and the author may not have noticed. | Still active |

## Key Risks

Ranked. Dropping wearable integration retired what had been the largest technical risk; the phone is
now the only sensor.

1. **The referee may quit before the user does — and the mechanism is built to make them quit.** The
   referee has no intrinsic motivation; this is someone else's goal. Worse, the thing that gives the
   product its bite, being told to go and collect money from a friend, is socially unpleasant to *do*,
   not just to receive. Chasing a friend for money is the kind of task people quietly stop doing. Two
   people now need retention, not one, and the mechanism actively erodes the second one.
   *Partly mitigated by design:* the referee rules only on exceptions, never on the happy path, and
   rulings follow the settlement period rather than a same-day clock — so in a good week the referee
   does nothing at all. What remains unmitigated is collection itself, which is unavoidably a person
   asking a friend for money, and which should be made as socially frictionless as the product can
   manage.
2. **Scope is large for one person.** A referee account means multi-user authentication, two roles, a
   backend, evidence upload, and an approval flow on day one. This is not a local todo app.
3. **Penalties may accelerate the abandonment they are meant to prevent.** The author's own history is
   of retreating for days after a failure. The grace and recovery mechanics are the counterweight and
   must be designed with as much care as the penalties.
4. **Phone-based verification is gameable.** Step data misses any session where the phone is left
   behind; a gym geofence can be defeated by walking in and sitting down, and dwell time narrows that
   without closing it. Accepted: this tier exists to remove friction from tasks the author already
   succeeds at, not to defeat a determined cheater — and the person it protects him from is himself.
   *Still to confirm:* that TryHackMe completion history is readable from outside. A few hours of work.

## Vision

If the mechanism holds for one person, it becomes a platform: somewhere anyone can put real stakes on
a commitment and have a real person hold them to it.

One problem must be solved first, and it is worth naming now rather than discovering it in year two.
What makes this work at a scale of one is **a friend who genuinely cares whether you succeed** — and
that is precisely the ingredient the software does not supply. A stranger has no reason to chase you
for money, and a paid referee is a different product with different economics and the regulatory
questions phase 1 was designed to avoid. Referee supply, not features, is the wall between this
version and the platform version.

## Open Questions

- **How long does a contested item wait before the period closes on it?** The principle is fixed and
  the weekly settlement gives most appeals a natural deadline, but daily tasks need their own answer.
- **Cadences for four of the eight commitments were never stated** and must be settled in the PRD.
- The author's iOS/Swift experience is unstated. Technology selection is deliberately deferred to the
  architecture phase, but phase 1 cannot be sized realistically without this answer.
- No deadline has been set.
- The product name is a placeholder.
