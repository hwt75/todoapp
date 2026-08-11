---
title: "PRD: todoapp (working name)"
status: final
created: 2026-08-11
updated: 2026-08-11
---

# PRD: todoapp (working name)
*Working title — confirm before launch.*

## 0. Document Purpose

This PRD is for the author, who is the product manager, the only engineer, and the only user of
version 1. It builds on `briefs/brief-todoapp-2026-08-11/brief.md` and its addendum and does not
repeat them; where this document contradicts the brief, this document wins and the change is recorded
in `.memlog.md`. Vocabulary is fixed by §3 Glossary and used verbatim throughout. Features are grouped
in §4 with globally numbered functional requirements nested under them, so downstream architecture and
story work has stable references. Inferences the author has not confirmed are tagged `[ASSUMPTION]`
inline and indexed in §10.

## 1. Vision

A commitment carries a real cost, and a real person comes to collect it.

Five commitments, one phone, one friend. Where the phone can confirm the work it confirms it silently
and nobody is bothered. Where it cannot, the author answers for himself the next morning — not at
midnight when he is least honest, but at 07:30 when he is most. A missed day costs 500,000 VND, and
the friend is told to go and collect it. The app never touches the money; it only says who owes what
to whom.

What makes this different from the apps the author has already abandoned is not the penalty. It is
what happens on the second day after a slip. His failure pattern is not dramatic quitting — it is
opening the app, feeling reluctant, closing it, and going quiet for a week. So the product treats
silence as the emergency, not the miss. It notices, it reaches out, and it always shows a way back.

## 2. Target User

The author. One person, one friend acting as **Referee**, verified against his real week. Not a
sample of one because a larger sample was unavailable — a sample of one that is understood completely
beats a thousand that are guessed at.

### 2.1 Jobs To Be Done

- **Stop the abstinence failure that has beaten me alone.** Every honour-system attempt has failed; I
  need a specific person who will know.
- **Make quitting cost something.** By bedtime, doing the work and not doing it currently feel
  identical.
- **Get me started.** My open-ended work does not fail at the finish line, it fails at the first
  minute, when I open the laptop and end up on Facebook instead.
- **Pull me back on day two.** When I slip I do not quit — I go quiet. Something has to notice.
- **Do not make me remember to open an app.** I will not. If it matters, it has to come to me.

### 2.2 Non-Users (v1)

Anyone but the author and his Referee. No second doer, no second Referee, no public signup.

### 2.3 Key User Journeys

- **UJ-1. The author answers for last night before he has answered his email.**
  07:30. He wakes, washes, does his fifteen minutes, and picks up his phone for the first time —
  Facebook and the OKX prices, the way he does every day. Before either of those, the app is holding
  a **Declaration** for yesterday's abstinence Commitment and will not release the phone's
  notification into a dismissable state until he answers: held, or slipped. He answers honestly
  because it is morning and because a lie here has a face attached to it. Held, and yesterday closes
  clean. Slipped, and yesterday closes as a **Failed Day** — 500,000 VND, and the Referee is told.
  **Climax:** the day is judged and the judgment lands before he has opened anything else.
  **Resolution:** today's Commitments appear, the chain either continues or restarts at one.
  **Edge case:** he ignores it. Nothing is charged, nothing is cleared, and the Declaration stays
  open — an unanswered Declaration is the first symptom of the silence the product exists to catch.

- **UJ-2. He starts the work he has been avoiding since nine o'clock.**
  10:20. He has opened the laptop twice and is on Facebook both times. A notification: *company work,
  0 of 3 hours today.* He taps it and starts a **Focus Session**. The timer runs; he works. Fifty
  minutes later the session banks and the day's total reads 0:50 of 3:00. No money rides on this and
  nothing polices where his attention actually went — the timer exists to get him past the first
  minute, which is the only minute that has ever been the problem.
  **Resolution:** three more sessions and the day's quota is met.

- **UJ-3. He went to the gym and the phone says he did not.**
  Saturday, and he left the phone in the locker room so the geofence never registered the dwell. The
  app reports the session missed. He submits an **Appeal** with a photo of the gym's check-in screen,
  taken that day. The 500,000 VND is **Held**, not charged. On the referee's web app the appeal
  appears; his friend, who was there, approves it that evening. The session counts, the money never
  moves.
  **Climax:** he was not charged for the phone's mistake, which is the only reason he still trusts
  the machine tier at all.

- **UJ-4. Day two of going quiet.**
  He slipped on Wednesday, paid, and felt terrible. Thursday he did not open the app. Friday morning
  there is no Declaration prompt among the usual ones — instead a single message that names what is
  happening: two days quiet, one **Grace Day** left this month, and one thing to do today. He uses
  the Grace Day. Thursday closes with no charge and the chain is not reset.
  **Climax:** the app named the pattern out loud instead of showing him a wall of red.
  **Resolution:** he does Friday. This is the moment the product exists for.

- **UJ-5. The friend is told to go and collect.**
  Wednesday evening, on the referee web app: *the author owes 500,000 VND for Wednesday, 11 June —
  missed TryHackMe.* The message is already written; the friend does not have to compose the awkward
  part or decide whether to bring it up. He collects the money in person that weekend and ticks
  **Collected**.
  **Edge case:** he does nothing. The debt stays listed and ages. Nothing auto-charges, because
  nothing in this system can.

- **UJ-6. Thursday, and the gym quota is running out of week.**
  He has been once. A notification: *2 gym sessions left, 3 days remaining.* Nothing has failed —
  a weekly quota cannot fail on a Thursday — but the tone has changed from informational to
  arithmetic. By Saturday morning, one session left and one day remaining, it is the loudest thing on
  his phone.

## 3. Glossary

- **Commitment** — one thing the author has undertaken to do or abstain from, carrying a Kind, a
  Cadence, a Verification Tier, and a flag for whether it carries the Penalty. Five exist in v1.
- **Kind** — *Do* (gym, morning exercise, TryHackMe), *Abstain* (no fap), or *Open-ended* (company
  work). Determines what "done" can even mean.
- **Cadence** — *Daily*, *Weekly Quota* (N times per week), or *Daily Hours Quota* (N hours per day,
  accumulated). Determines when a Commitment can be judged failed.
- **Verification Tier** — *Machine* (phone sensors or an external service confirm it), *Declared*
  (the author states it and no one can check), or *Timer* (a Focus Session was run).
- **Declaration** — the author's own statement about a Declared Commitment for a closed day. Requested
  the following morning, blocking, and not optional.
- **Focus Session** — a timed working block against an Open-ended Commitment. Starts on a tap, banks
  its elapsed minutes when stopped. Carries no Penalty and performs no attention policing.
- **Day Close** — the point at which a calendar day is judged: all its Declared Commitments answered
  and its Machine-tier results final. Until Day Close a day has no verdict.
- **Week Close** — the point at which a week is judged, settling Weekly Quota Commitments and any
  Held Penalties still outstanding.
- **Failed Day** — a calendar day on which at least one Penalty-carrying Commitment was missed.
  A Failed Day costs exactly one Penalty regardless of how many Commitments were missed.
- **Penalty** — 500,000 VND, owed by the author to the Referee, per Failed Day. Never processed by
  the product.
- **Held** — a Penalty that has been incurred but is suspended pending an Appeal. A Held Penalty
  never becomes owed on its own.
- **Appeal** — the author's same-day contest of a Machine-tier miss, with evidence, ruled on by the
  Referee.
- **Referee** — the friend. Holds a separate account on the web surface. Rules on Appeals, receives
  collection instructions, marks Penalties Collected.
- **Collected** — the Referee's confirmation that money physically changed hands. The only way a debt
  is discharged.
- **Grace Day** — a limited monthly allowance that voids one day's Penalty and preserves the Chain.
  Spent deliberately by the author; never granted automatically.
- **Chain** — consecutive days at which a Daily Commitment held, or consecutive weeks at which a
  Weekly Quota was met.
- **Silence** — consecutive days with no Declaration answered and no app interaction. The primary
  signal of abandonment.

## 4. Features

### 4.1 Commitments

**Description:** Five fixed Commitments, configured once. This is not a task manager — there is no
capture, no inbox, no list to curate. Adding a sixth Commitment is a v2 concern.

The v1 set:

| Commitment | Kind | Cadence | Verification Tier | Penalty |
|---|---|---|---|---|
| No fap | Abstain | Daily | Declared | **Yes** |
| Gym | Do | Weekly Quota — 3 | Machine (geofence + dwell) | **Yes** |
| TryHackMe | Do | Daily | Machine (completed-room history) | **Yes** |
| Morning exercise | Do | Daily | Machine (motion) | No |
| Company work | Open-ended | Daily Hours Quota — 3h | Timer | No |

Two Commitments deliberately carry no Penalty. Morning exercise is already an established habit at
07:30; money would add no motivation while adding a real risk — a phone left on the desk produces a
false miss, and because the Penalty is flat per day, one sensor error would swallow the whole day's
500,000 VND even if everything else was done. Company work runs on a timer the author starts himself,
which verifies nothing and therefore cannot fairly carry money.

**Functional Requirements:**

#### FR-1: Commitment configuration
The author can define a Commitment with a Kind, a Cadence, a Verification Tier, and a Penalty flag.

**Consequences (testable):**
- A Commitment whose Verification Tier is Timer cannot have its Penalty flag set.
- A Weekly Quota Commitment stores a target count and a week start day.
- A Daily Hours Quota Commitment stores a target duration in minutes.

**Out of Scope:** creating, editing, or deleting Commitments from the phone during normal use; v1 may
ship them as configuration.

#### FR-2: Judging by Cadence
The system judges each Commitment only at its own settlement point, never earlier.

**Consequences (testable):**
- A Daily Commitment is judged at Day Close.
- A Weekly Quota Commitment is judged only at Week Close; being at 0 of 3 mid-week is never a miss.
- A Daily Hours Quota Commitment is judged at Day Close against accumulated Focus Session minutes.

### 4.2 Notification-First Engagement

**Description:** The author has stated plainly that he forgets to open the app unless notified. This
is a hard design constraint, not a preference: **any capability that requires him to open the app
unprompted does not exist.** Everything that matters is pushed — day summaries, quota arithmetic,
appeal outcomes, silence interventions — and each notification is legible from the lock screen
without opening anything. Realizes UJ-1, UJ-2, UJ-6.

The morning is the highest-value slot in the day, because the first phone pickup at roughly 07:30 is
the one moment he is guaranteed to look. That slot belongs to the Declaration (§4.4), not to
marketing the day ahead.

**Functional Requirements:**

#### FR-3: Push-resident information, delivered persistently
Every state change the author must know about is delivered as a notification whose body is
self-sufficient, and a notification that requires a response persists until it gets one. A reminder
that is dismissed once and never returns is indistinguishable, for this user, from a reminder that
was never sent. Realizes UJ-1, UJ-6.

**Consequences (testable):**
- Day summary, Week Close result, Appeal ruling, and silence intervention each generate a
  notification.
- A notification requiring an action re-delivers on a schedule until the action is taken or its
  settlement point passes.
- No Penalty is ever incurred whose first and only surface is inside the app.
- Persistence never applies to the silence intervention (FR-16), which delivers once and waits.

#### FR-4: Quota-aware reminders
Reminders for a Weekly Quota Commitment escalate as sessions remaining approach days remaining.
Realizes UJ-6.

**Consequences (testable):**
- Reminder frequency and urgency increase when sessions remaining equals days remaining.
- No reminder frames a mid-week quota shortfall as a failure.

#### FR-5: Focus prompt for unstarted quota work
When a Daily Hours Quota Commitment has accumulated no minutes by a configured hour, the system
prompts the author to start a Focus Session. Realizes UJ-2.

### 4.3 Machine Verification

**Description:** Three Commitments confirm themselves with no action from the author. This tier exists
to remove friction from work he already does, not to defeat a determined cheater. It catches false
negatives through the Appeal path (§4.6) and accepts false positives by design — sitting in the gym
doing nothing goes uncaught, consistent throughout: this product protects the author from himself,
not from a fraudster.

**Functional Requirements:**

#### FR-6: Gym verification by geofence and dwell
The system records a gym session when the phone remains inside a configured geofence for a minimum
dwell duration. Realizes UJ-3.

**Consequences (testable):**
- Entering and leaving inside the dwell threshold records nothing.
- A recorded session increments the week's quota progress and generates no notification on the happy
  path.

#### FR-7: Morning exercise verification by motion
The system confirms the morning exercise Commitment from the phone's own motion data within a
configured morning window.

**Consequences (testable):**
- Confirmation requires sustained motion for at least the Commitment's target duration; scattered
  movement totaling that duration does not confirm it.
- Motion outside the configured window does not count.
- A miss here never produces a Penalty, since this Commitment does not carry one.

#### FR-8: TryHackMe verification by completion history
The system confirms the TryHackMe Commitment by reading completed-room history for the author's
account. `[ASSUMPTION: this history is readable from outside TryHackMe. Unconfirmed since the brief;
if it is not, this Commitment drops to the Declared tier and keeps its Penalty.]`

### 4.4 The Morning Declaration

**Description:** The abstinence Commitment cannot be observed by any technical means, and the author
has decided it carries the Penalty regardless — the alternative left money on the tasks he already
succeeds at and nothing on the one that defeats him. That decision puts the entire mechanism on one
button press, so the design's only job here is to make that press unavoidable rather than voluntary.

It is therefore not a confession. He is never asked to volunteer anything at 23:30, when he is least
honest and most ashamed. He is asked the next morning, at the first phone pickup, and the question
blocks. Realizes UJ-1.

Silence is the interesting answer. An unanswered Declaration charges nothing and clears nothing — it
accrues, and it is what §4.7 watches for.

**Functional Requirements:**

#### FR-9: Blocking morning Declaration
For each Declared Commitment, the system requests a Declaration for the previous day at the author's
first phone interaction after a configured morning hour, and the prompt is not dismissable without an
answer. Realizes UJ-1.

**Consequences (testable):**
- Answering *held* closes the previous day clean for that Commitment and extends its Chain.
- Answering *slipped* marks the previous day a Failed Day and resets that Chain to zero.
- Declining to answer leaves the previous day open: no Penalty, no clearance, and the open
  Declaration counts toward Silence.
- A Declaration can be answered late, and answering it late settles the day it belongs to.

#### FR-10: Day Close
A calendar day closes when all its Declared Commitments are answered and its Machine-tier results are
final; at Day Close the system determines whether it is a Failed Day. Realizes UJ-1.

**Consequences (testable):**
- A Failed Day incurs exactly one Penalty regardless of how many Commitments were missed.
- The system does not notify the author mid-day that the day is already lost. `[ASSUMPTION: this is
  a deliberate counter to the flat Penalty's known side effect — once the day is known to be lost,
  the rest of it loses all stakes. Withholding that fact until Day Close keeps the remaining
  Commitments live.]`
- Per-Commitment Chains are tracked independently, so a Failed Day does not reset Chains for
  Commitments that were met.

### 4.5 Focus Sessions

**Description:** Open-ended work has no finish line, so it commits to time instead. The author's
company work runs three hours a day, accumulated across as many sessions as it takes.

The failure this addresses is starting, not finishing — his words: *"lúc bắt đầu làm tôi hay bị sao
nhãng."* So the session is deliberately unpoliced. Pressing start counts. The app does not detect
leaving, does not pause on a switch away, does not ask whether he is still working. That is a real
loophole and it is accepted knowingly: a timer that punishes you for checking a message is a timer
you stop starting, and a session never started is the only outcome that actually costs anything here.
Realizes UJ-2.

**Functional Requirements:**

#### FR-11: Run a Focus Session
The author can start and stop a Focus Session against an Open-ended Commitment; elapsed minutes bank
to that Commitment's daily total. Realizes UJ-2.

**Consequences (testable):**
- The session continues while the app is backgrounded and while the phone is locked.
- Leaving the app never invalidates, pauses, or flags a running session.
- Banked minutes accumulate across multiple sessions within one day.

#### FR-12: Quota progress visibility
The author can see minutes banked against the day's target without opening the app, via the day's
notification surface. Realizes UJ-2.

### 4.6 Penalty, Settlement and Appeal

**Description:** A Failed Day owes 500,000 VND. There is no cap and no stop-loss — the author
considered one and declined it, on the grounds that affordability is not his constraint. The risk this
leaves open is recorded in the §8 counter-metrics and in §9, because the concern was never about
whether he can pay.

One rule is absolute: **a Held Penalty never converts to owed on its own.** If the author is charged
because the Referee was busy, trust in the whole mechanism is gone permanently and immediately.
Realizes UJ-3.

**Functional Requirements:**

#### FR-13: Penalty accrual
Each Failed Day generates one Penalty of 500,000 VND owed by the author to the Referee. Realizes
UJ-5.

**Consequences (testable):**
- Two Penalty-carrying Commitments missed on the same day generate one Penalty, not two.
- Penalties accrue without limit; no cap, decay, or forgiveness exists other than a Grace Day
  (FR-17) or a successful Appeal (FR-20).
- A Penalty is only presented to the Referee once it is owed — never while Held.

#### FR-14: Same-day Appeal
When a Machine-tier Commitment is judged missed, the author can submit an Appeal with evidence on the
day the work was claimed. Realizes UJ-3.

**Consequences (testable):**
- Submitting an Appeal moves the associated Penalty to Held before it is ever presented as owed.
- Evidence submitted after the claimed day is rejected.
- A Held Penalty is invisible on the Referee's collection list until it is ruled on.

#### FR-15: Ruling deadlines by Cadence
A Held Penalty resolves either by the Referee's ruling or by its Cadence's settlement point, whichever
comes first, and always in the author's favor on timeout.

**Consequences (testable):**
- An Appeal against a Weekly Quota Commitment has until Week Close to be ruled on.
- An Appeal against a Daily Commitment has until the end of the following day.
  `[ASSUMPTION: the brief left the daily window open. One day gives the Referee an evening; anything
  shorter puts him on a clock he did not agree to.]`
- An unruled Appeal at its deadline voids the Penalty. It never converts to owed.

### 4.7 Recovery

**Description:** The single most important behavior in the product. The author does not quit — he
goes quiet, and the quiet is what kills the habit. So Silence, not failure, is the emergency, and the
intervention is designed to sound like a person noticing rather than an app reporting. What he must
not meet on the second day is a wall of red. Realizes UJ-4.

**Functional Requirements:**

#### FR-16: Silence detection and intervention
After two consecutive days of Silence, the system replaces routine notifications with a single
intervention naming the pattern, the Grace Days remaining, and one concrete action for today.
Realizes UJ-4.

**Consequences (testable):**
- The intervention suppresses the day's ordinary reminders rather than adding to them.
- It surfaces at most one action.
- `[ASSUMPTION: two days is taken from the brief's stated pattern and has not been tested.]`

#### FR-17: Grace Days
The author can spend a Grace Day to void one day's Penalty and preserve that day's Chains. Realizes
UJ-4.

**Consequences (testable):**
- Grace Days are limited per month, counted, and always visible in the intervention.
  `[ASSUMPTION: two per month. Never confirmed; the brief said only "limited and countable".]`
- A Grace Day cannot be applied to a day already marked Collected.
- Grace Days never accrue automatically and are never spent on the author's behalf.

#### FR-18: Escalation to the Referee
When Silence persists beyond the intervention, the system notifies the Referee that the author has
gone quiet. `[ASSUMPTION: four days. Unconfirmed.]`

**Consequences (testable):**
- The escalation states the number of days and nothing about which Commitments were missed.
- It fires once per Silence episode, not daily.
- Any Declaration answered ends the episode and cancels further escalation.

### 4.8 The Referee Surface

**Description:** A web app with its own account and login, deliberately quiet. In a good week the
Referee does nothing at all — Machine-tier Commitments approve themselves and he is never involved.
He is an appeals court, not a daily approver, because his attention is the scarcest resource in the
system and the brief ranks his burnout as risk number one.

He does two things: rule on Appeals, and collect. On collection he is the active party — the app does
not wait for the author to pay, it tells the friend to come and get it. That asymmetry is where most
of the pressure comes from, and it is also the thing most likely to exhaust him, so the product writes
the uncomfortable message itself and leaves him only the act. Realizes UJ-3, UJ-5.

Because the person who needs nagging is on the phone and not here, this surface does not depend on
push at all.

**Functional Requirements:**

#### FR-19: Referee account and authentication
The Referee holds an account distinct from the author's, and sees only Appeals and Penalties.
Realizes UJ-5.

**Consequences (testable):**
- The Referee cannot see Declarations, Chains, Focus Session activity, or location data.
- The author cannot rule on his own Appeals from any surface.
- The Referee's surface is usable without notification permissions of any kind.

#### FR-20: Rule on an Appeal
The Referee can view an Appeal's evidence and claim and either approve or reject it. Realizes UJ-3.

**Consequences (testable):**
- Approval voids the Held Penalty and credits the Commitment.
- Rejection converts the Held Penalty to owed.
- Every ruling notifies the author with the outcome.

#### FR-21: Collection instruction and confirmation
The Referee sees each owed Penalty with a pre-written collection message, and can mark it Collected.
Realizes UJ-5.

**Consequences (testable):**
- The message names the amount, the date, and the Commitment missed, and requires no composition.
- Marking Collected is the only way a debt is discharged.
- Uncollected debts age visibly and are never written off automatically.

### 4.9 Reviews and Chains

**Description:** Three horizons, all delivered by notification. The daily one is a summary with one
concrete suggestion for tomorrow. The weekly one closes Weekly Quota Commitments, settles the week,
and says whether the week held. The monthly one is the only place the author sees the arrangement as
a whole — trends, Chains, Penalties incurred, and whether this is still working.

**Functional Requirements:**

#### FR-22: Day summary
At Day Close the system delivers a summary of what was met and one suggestion for tomorrow.

**Consequences (testable):**
- The summary is legible in full from the notification, without opening the app.
- It carries exactly one suggestion, naming a specific Commitment.
- On a Failed Day it states the Penalty once and does not itemize the misses.

#### FR-23: Week Close
At Week Close the system judges Weekly Quota Commitments, resolves outstanding Held Penalties per
FR-15, and reports whether the week held. Realizes UJ-6.

#### FR-24: Monthly report
Monthly, the system reports Chains, Penalties incurred and collected, days returned after a slip, and
Silence episodes.

**Consequences (testable):**
- The report covers every measure in §8, including the counter-metrics.
- It states Penalties incurred and Penalties Collected separately, so an inactive Referee is visible
  rather than inferred.

#### FR-25: Chains
The system maintains a Chain per Commitment: consecutive days held for Daily Commitments, consecutive
weeks at quota for Weekly Quota Commitments.

**Consequences (testable):**
- A Grace Day preserves a Chain.
- A Chain reset is never the headline of a notification.

## 5. Cross-Cutting Requirements

- **Notification-first.** Restated because it governs every feature: a capability reachable only by
  opening the app unprompted is not a capability. Everything load-bearing pushes.
- **Two surfaces, two jobs.** iOS for the doer, web for the Referee. The web surface must not be
  designed as though it needs aggressive notification; web push is weak, particularly on iOS Safari
  where it requires home-screen installation.
- **Location privacy.** The gym geofence is the most sensitive data the product holds. Location is
  used solely to evaluate dwell inside one configured geofence; no location history is retained
  beyond the session determination, and none is shown to the Referee.
- **Evidence privacy.** Appeal evidence is visible to the Referee and to no one else.
- **Money is never handled.** No payment integration, no balance the product can move, no stored
  instrument. The product records claims and confirmations between two people.
- **Offline tolerance.** Machine verification and Focus Sessions must survive loss of connectivity
  and reconcile when it returns; a missing network must never produce a Failed Day.

## 6. Non-Goals

- Not a task manager. No capture, no inbox, no projects, no curated list.
- Not an anti-cheat system. False positives are accepted at every tier by design.
- Not a payment product, and not a wallet, escrow, or ledger of transferable value.
- Not a social product. No feed, no leaderboard, no second Referee, no user-to-user feature beyond the
  single doer–Referee pair.
- Not a platform yet. The platform question is referee supply, and v1 does not attempt it.
- Not Android, not a wearable integration, and specifically not the author's Huawei watch.

## 7. MVP Scope

### 7.1 In Scope

- The five Commitments in §4.1, configured once
- Machine verification from the phone alone: geofence with dwell, motion, TryHackMe history
- The blocking morning Declaration and Day Close
- Focus Sessions with a daily hours quota
- Flat 500,000 VND per Failed Day, with Held Penalties and same-day Appeals
- The Referee web app: authentication, appeal rulings, collection instructions, Collected confirmation
- Silence detection with day-two intervention, Grace Days, escalation to the Referee
- Chains per Commitment; daily, weekly and monthly reviews, all pushed

### 7.2 Out of Scope for MVP

- Financial-report research, VHM news tracking, and the horoscope agent build — no stated Cadence, no
  verification path, and no Penalty possible. `[NOTE FOR PM: these come back cheaply once Focus
  Sessions work, since they need nothing but a Commitment row each. Revisit at the first monthly
  report.]`
- A Penalty cap or stop-loss — considered and declined by the author
- Attention policing inside a Focus Session
- In-app Commitment editing
- Public signup, App Store release, second user of any kind

## 8. Success Metrics

The author's own targets come first and are recorded unchanged: **the length of the no-fap Chain**,
and **100% completion on gym and morning exercise**.

They cannot stand alone, for a specific reason: a month at 100% would tell us nothing. Every
distinctive mechanism here — the Penalty, the Referee, the recovery path — only activates on failure.
A clean month means an easy month, not a validated product. This is proven the first time he slips
and comes back fast.

**Primary**

- **SM-1**: No-fap Chain length — longest and current, in days. Validates FR-9, FR-10.
- **SM-2**: Days to return after a Failed Day — median ≤ 1. The exact failure this was built for.
  Validates FR-16, FR-17.

**Secondary**

- **SM-3**: Gym and morning exercise completion — 100% target. Validates FR-6, FR-7.
- **SM-4**: Silence episodes longer than two days — declining, then zero. Validates FR-16.
- **SM-5**: Referee still ruling and collecting in week 8 — still active. Directly tests the
  top-ranked risk; if the Referee has gone quiet, the Penalty is theatre and the author may not have
  noticed. Validates FR-20, FR-21.
- **SM-6**: Declarations answered within the morning window — high and stable. The honesty gate is
  load-bearing and its failure mode is silence, not lying. Validates FR-9.

**Counter-metrics (do not optimize)**

- **SM-C1**: Total Penalties incurred. Driving this to zero by lowering the bar defeats the product;
  driving it up proves nothing either. Counterbalances SM-1 and SM-3.
- **SM-C2**: Days between opening the app and the first Failed Day being acknowledged. If this grows,
  the author is avoiding the app — the precise way the uncapped Penalty is expected to fail.
  Counterbalances SM-1.
- **SM-C3**: Appeals rejected as a share of Appeals filed. A rising share means the Appeal path has
  become a way out rather than a correction. Counterbalances SM-2.

## 9. Open Questions

1. **What does the uncapped Penalty do after three or four consecutive Failed Days?** The author
   declined a cap on affordability grounds, but the concern was motivational: at some run length,
   deleting the app becomes his most rational move. SM-C2 is the tripwire; no mitigation exists.
2. **Is TryHackMe completion history readable from outside?** Unconfirmed since the brief. If not,
   that Commitment moves to the Declared tier and the morning Declaration carries two questions
   instead of one. A few hours of work to settle, and it should be settled before architecture.
3. **How many Grace Days per month, and do they carry over?** Assumed two, non-carrying.
4. **What is the author's iOS/Swift experience?** Deferred to architecture by agreement, but v1 cannot
   be sized without it. Ask it first.
5. **What is the product called?** "todoapp" is a placeholder.
6. **No deadline has been set.**

## 10. Assumptions Index

- **§4.3 / FR-8** — TryHackMe completion history is externally readable. Unconfirmed.
- **§4.4 / FR-10** — Withholding mid-day knowledge that a day is already lost is the right counter to
  the flat Penalty's motivational cliff. Untested.
- **§4.6 / FR-15** — A daily-Cadence Appeal has until the end of the following day to be ruled on.
  The brief left this open.
- **§4.7 / FR-16** — Two days of Silence is the right intervention threshold. Taken from the author's
  described pattern, never tested.
- **§4.7 / FR-17** — Two Grace Days per month. Never confirmed.
- **§4.7 / FR-18** — Escalation to the Referee at four days of Silence. Unconfirmed.
