---
title: "EXPERIENCE: todoapp"
status: final
created: 2026-08-11
updated: 2026-08-11
sources:
  - ../../prds/prd-todoapp-2026-08-11/prd.md
  - ../../prds/prd-todoapp-2026-08-11/addendum.md
  - ./DESIGN.md
---

# EXPERIENCE: todoapp

Visual identity lives in [DESIGN.md](./DESIGN.md); token references below use `{path.to.token}`
against its frontmatter. Where a mock and this document disagree, this document wins.

## Foundation

Two surfaces, two jobs, two people.

**One installable web app, two roles.** v1 ships as a PWA — installed to the iPhone home screen for
Hoàng the doer, opened in a browser by Nam the referee — from a single codebase, with role resolved
server-side. A native iOS client was the original plan and is deferred, not abandoned; see the PRD
§7.2. No UI system is inherited; DESIGN.md is the identity.

**What the web platform costs, and what it does not.** No background execution on iOS means the
location and movement Auto-checks are unavailable in v1, and the morning gate is a persistent Web
Push rather than an alarm that breaks through silence. What is untouched: the money, the referee, the
settlement rules, and every behavior specified below. That is only true because Auto-checks are
optional rather than a fixed tier — a decision taken for other reasons that happened to make the
product portable.

**The doer's surface needs push; the referee's does not.** Web Push works on iOS 16.4+ only for a
home-screen-installed PWA, so installation is a prerequisite for Hoàng and irrelevant for Nam, whose
channel is email.

Interface language is English on both surfaces. `[ASSUMPTION: both users are Vietnamese speakers and
the emotionally loaded strings — the morning question, the day-two intervention, the collection
message — lose force in a second language. A mixed approach was offered and not taken. Recorded
because it is cheap to revisit and expensive to discover late.]`

## The notification contract

This governs everything below, so it comes first.

The author has stated that he does not open the app unless notified. That makes notifications the
product's primary surface and the app itself a secondary one, and it inverts the usual rule: **a
capability reachable only by opening the app unprompted does not exist.**

| Rule | Consequence |
|---|---|
| Self-sufficient bodies | Every notification is fully legible on the lock screen. Never "You have an update." |
| Persistence | A notification requiring a response re-delivers on a schedule until answered or until its settlement point passes. |
| One exception to persistence | The day-two intervention delivers **once** and waits. Nagging someone who has already withdrawn is how you lose them. |
| One action | A notification offers at most one thing to do. |
| The morning slot is reserved | First interaction after the morning hour belongs to the Declaration. Nothing else may occupy it — with one exception, below. |
| The intervention is the only thing that may take the slot | On the second morning of Silence the intervention replaces the routine notifications, including the outstanding Declaration prompt. It may do so because it arrives *before* the first Declaration expires (FR-9, 48 hours), so it is a final warning rather than a suppression: acting on it still saves the day, and the Declaration remains answerable from inside the app. |
| Referee never gets push | His channel is email. Web push is weak, and he is not the one who needs nagging. |

## Information Architecture

Twelve surfaces. Today is the launch destination and carries chains inline; there is no separate
streak home.

**iOS — the doer**

| Surface | Purpose | Fidelity |
|---|---|---|
| Today | Launch destination. Debt figure, then five commitment rows with chains | mocked |
| Morning Declaration | Blocking question about yesterday. Notification and in-app | mocked (notification) |
| Focus Session | Running timer, banked daily total | mocked |
| Appeal | Contest a machine-recorded miss with evidence | mocked |
| Ledger | Every failed day and its outcome | mocked |
| Task setup | Create or edit a commitment, including optional checks | mocked |
| Chains detail | Per-commitment history | spine-only |
| Week close | Quota settlement and the week's verdict | spine-only |
| Monthly report | The long view, including whether the referee is still active | spine-only |
| Settings | Morning hour, permissions, referee pairing, grace days | spine-only |

**Web — the referee**

| Surface | Purpose | Fidelity |
|---|---|---|
| Appeals and collections | The whole app: one list of things to rule on, one list to collect | mocked |
| Login | Account entry | spine-only |

### Spine-only surfaces

Specified here rather than mocked; each is a list or a table with no layout risk.

| Surface | Contents | Rules |
|---|---|---|
| Chains detail | One commitment's history: current chain, longest chain, calendar of held/missed/waived days | No chain reset is ever the headline. Longest chain is shown adjacent to current so a reset is read against a record, not against zero. |
| Week close | Each Weekly Quota commitment with final position, penalties settled, held penalties resolved per FR-15, and a one-line verdict | Delivered as a notification first; the screen is the detail behind it. Dropped-on-timeout appeals are shown as dropped, not hidden. |
| Monthly report | Chains, penalties incurred **and collected separately**, median days-to-return after a failed day, count of silences over two days | Incurred and collected must never be merged into one figure. Their divergence is the only visible evidence that the referee has stopped participating. |
| Settings | Morning hour, notification permission state, home-screen install state, referee pairing, grace days remaining this month | Permission states are shown with what breaks if they are off, in plain language, not as toggles alone. Install state matters more than any other row: without home-screen installation there is no push at all, and without push there is no product. When a location Auto-check returns, its place and dwell minutes live on its own Commitment and never here — a second location-checked Commitment would otherwise silently inherit the gym's. |
| Login (referee) | Email and password | No signup flow in v1; the account is provisioned when Hoàng pairs him. |
| Morning Declaration, in-app | Same content as the notification, same two neutral controls | Reached by opening the app with a Declaration outstanding. The app cannot be used past it. |

## Voice and Tone

The register is **coach**: second person, short, present tense, no threat. It speaks like someone who
knows the history and is not scandalised by it.

**Never name the money while asking a question.** A stakes-forward register was drafted and rejected:
naming 500,000 VND before the user answers makes the honest answer the expensive one, and since
nothing can detect a lie, that buys lies. The money is stated after the fact, once, plainly. The
debt figure already dominates Today; it does not need reinforcing at the moment of confession.

**Never itemize failures.** State the count and the amount once, then name something that survived.

**The app owns every uncomfortable sentence.** Where a message must be delivered to Hoàng about money,
the product writes it and attributes it to itself, so that Nam is a messenger rather than an author.

| Moment | String | Why |
|---|---|---|
| Morning Declaration | *"Morning. Day 5 is waiting." / "Did last night hold?"* | Names what is at stake to protect — the chain — before asking. No money, no judgment. |
| Declaration controls | *"It held"* / *"I slipped"* | Both neutral, both identical. See DESIGN.md Do's and Don'ts. |
| Day summary, good | *"Four of five today. Gym is still 1 of 3 with two days left. Tomorrow morning is the easy one to take."* | Count, the one open thing, one concrete next step. |
| Day summary, bad | *"One of five today. That's 500,000. Morning exercise held though — day 12. Start there tomorrow."* | Amount once, no itemising, then what survived, then a starting point. |
| Day two of silence | *"Two quiet days. This is the part where it usually ends. It doesn't have to. Do one thing today — TryHackMe, twenty minutes."* | Names the pattern flatly, names his own history, opens the door in the same breath. One small action. No debt figure, no red. |
| Day two, unanswered days pending | *"Two quiet days. This is the part where it usually ends. It doesn't have to. Wednesday and Thursday close tonight — answer them, and do one thing today."* | Same opening, same register. States the deadline once, as a fact rather than a threat, and still asks for one action. It never says what closing costs; the ledger will say that soon enough. |
| Appeal, machine's account | *"Location saw you for 4 minutes. It needed 30."* | Exactly what was observed and exactly what was required. Never "verification failed" — the specific number is what makes it read as a technical fault rather than an arbitrary ruling. |
| Appeal, hold state | *"500,000 is on hold, not charged. It stays on hold until Nam decides, or until Sunday closes — and if he doesn't get to it, it's dropped."* | The most trust-critical sentence in the product. |
| Collection message | *"todoapp says you owe 500,000 for Tuesday. I'm just the one collecting it. When are you free?"* | Seven words do the work: *I'm just the one collecting it*. Nam is demoted from accuser to messenger. The closing question turns confrontation into logistics. |
| Referee empty state | *"Nothing for you this week. Hoàng is at 4 of 5 today. You'll get an email if that changes."* | His default state. The progress crumb is the only retention lever the product has over him. |
| Referee timeout note | *"Ignore this and it's dropped in his favor on Sunday."* | Written for Nam's benefit, not Hoàng's: it tells him he is not a bottleneck. People quit tasks where forgetting hurts someone. |
| Referee escalation (FR-18) | *"Hoàng hasn't opened this in four days. Nothing needs deciding — but he'd probably rather hear from you than from the app."* | The only message that asks Nam to act as a person rather than process a queue, so it names no amount, no missed commitment, and no task for him. It gives him the fact and the opening, and leaves the choice his. Sent by email, once per silence episode. |
| Task setup, abstain kind | *"Nothing can check this one. You'll be asked each morning, and your answer is the record."* | The product's central honesty, stated at configuration time rather than discovered at charge time. |
| Focus Session | *"Keeps running while your phone is locked. Nothing here watches what you're doing."* | Removes the suspicion that would stop him pressing start — and not pressing start is the only real failure here. |

Interface labels use plain language, never glossary terms: **Do it / Avoid it / Put hours in**, not
Do/Abstain/Open-ended. **He did it / He didn't**, not Approve/Reject. **Stop and bank it**, not Stop —
stopping deposits the time, it does not discard it.

The Focus Session's two remaining labels follow the same rule. The control that opens a session reads
**Start the clock**, not Start — the thing being started is a clock and nothing else, which is the
promise the sentence above it makes good on. The day's accumulated minutes read **Banked today**, not
Total or Progress: *banked* is the word the stop control already uses, and it says the minutes are
deposited rather than merely observed.

One session runs at a time, so starting a second says so out loud: *"A clock is already running on
another commitment. Stop that one first."* A start control that silently did nothing would be worse
here than anywhere else in the product — this is the one surface whose entire job is making the tap
feel like something happened.

## Component Patterns

| Component | Behavior |
|---|---|
| Commitment row | Tap opens Chains detail. Machine-verified commitments are not tappable to complete — they complete themselves. Declared commitments show their control only in the morning, not all day. |
| Status pill | Reflects one of: chain count (held), quota position with days remaining (urgent as the margin closes), not-yet (neutral). Never interactive. |
| Debt block | Tap opens the Ledger. Figure is cumulative since first use, never reset by a period boundary. |
| Declaration control pair | Two identical neutral buttons. No default, no pre-selection, no confirmation step on either answer. |
| Optional check row | Toggles a machine check on a commitment. Disabled with an explanation when the commitment's kind makes it meaningless. |
| Focus timer | Starts on tap, survives backgrounding and lock, banks on stop. Never pauses itself, never asks whether the user is still working. |
| Evidence attachment | Camera or library, restricted to items dated the claimed day. Appears only in Appeal, never as a check method — an old photo proves nothing. |
| Account-elsewhere link | Sub-state of its Auto-check row in Task setup. Unlinked shows the service and a link control; linked shows the account identifier and when it was last read. `[ASSUMPTION: v1 takes a public profile URL and needs no authentication. If a service requires OAuth, this row becomes a flow rather than a field.]` |
| Grace day control | Offered wherever a Failed Day is visible and still open: the Day summary, an owed row in the Ledger, and the silence intervention. Always states how many remain. Never applied automatically. |
| Collection card | Pre-written message with a copy control and a Mark collected control. No compose field. |

## State Patterns

| Surface | States |
|---|---|
| Today | Normal · all held · day already failed (rows stay neutral; only the debt block is tinted) · silence intervention replacing routine content · permission broken (a check is configured but its permission is revoked) |
| Commitment row | Not yet · held · missed · held-pending-appeal · waived by grace day |
| Appeal | Draft · submitted and held · ruled in favor · ruled against · dropped on timeout |
| Focus Session | Idle · running · banked · quota met for the day |
| Referee home | Empty (default) · appeals pending · collections outstanding · both · **he has gone quiet** (FR-18) |
| Ledger row | Owed · collected · waived · dropped · **expired** (closed unanswered under FR-9). An owed row carries its pill but is not itself tinted — see DESIGN.md Do's and Don'ts. Any owed or expired row still uncollected offers the grace day control. |

Two states carry rules that outrank layout:

**Day already failed.** Only the debt block is tinted. Rows remain neutral, chains for commitments
that *did* hold remain live and visible, and no notification announces mid-day that the day is lost.
The flat penalty means one miss forfeits the day; withholding that fact until Day Close is what keeps
the rest of the day worth doing.

**Held pending appeal.** Urgent, never failed. Money on hold is money the user might keep, and it must
never be styled as money already gone.

## Interaction Primitives

- **The morning gate blocks the app, never the device.** With a Declaration outstanding, the app opens
  onto it and offers nothing else to do. It is blocking by having no alternative, not by trapping
  focus: the notification is always dismissable at the OS level, the app is always closable, and the
  modal exposes its two controls to VoiceOver as the only focusable elements without capturing the
  rotor. A design intention must never become a locked device.
- **The gate is a persistent Web Push plus a launch modal.** Four mechanisms were once open; the move
  to a PWA closed two of them, since a web app has no Live Activity and no lock-screen widget. What
  remains is a notification that re-delivers on a schedule until answered, and a modal the app opens
  onto and offers nothing past. Neither alone is sufficient: the push is what reaches him at 07:30
  when he is not thinking about the app, and the modal is what remains when the push was swiped away.
- **Machine confirmation is silent.** A check that passes produces no notification and no interaction.
  The happy path costs the user nothing and costs the referee nothing.
- **Nothing destructive is one tap.** Deleting a commitment confirms. Declaring a slip does not —
  it is not destructive, it is honest, and adding friction there would tax the truth.
- **Timeouts always resolve in the user's favor.** Every deadline in the system fails open.

## Accessibility Floor

- Dynamic Type honored throughout; no fixed-height rows that clip at larger sizes. The debt figure and
  timer scale with the rest.
- Color is never the sole carrier of state. Every pill carries a word or number: `12`, `1/3 · 3 days`,
  `Owed`, `Waived`. A user who cannot distinguish the tints loses nothing.
- Contrast floor for any token pair, including ones added later: WCAG AA — 4.5:1 for text, 3:1 for
  non-text state indicators. The current pairs clear it in both modes; the rule exists for the next
  value someone adds.
- All controls reach 44×44pt.
- Under Reduce Motion the focus timer updates without animation and the quota bar snaps rather than
  fills. There is no other motion in the product.
- VoiceOver: commitment rows announce name, state, and chain as one label. The debt block announces
  the amount and the period. The Declaration controls announce as a question with two answers.
- On Today, the accessibility order deliberately differs from the visual order: commitment rows are
  read before the debt block, even though the debt block is drawn first. A sighted user can look past
  the figure; a VoiceOver user cannot skip what is read to them. The visual placement is the author's
  decision and stands — this only spares him hearing it aloud first every single morning.
- The referee's web app is keyboard-navigable and works without JavaScript-dependent focus traps; it
  is used rarely and possibly on an unfamiliar machine.

## Key Flows

**KF-1. Hoàng answers for last night before he answers anything else.**
07:30. He wakes, washes, does his fifteen minutes, and picks up the phone for Facebook and the OKX
prices the way he does every morning. Before either, a Declaration for yesterday's abstinence is
waiting and will not clear without an answer. Two identical gray buttons. **Climax:** he answers
honestly, at the hour he is most capable of it, and the day is judged before he has opened anything
else. **Resolution:** today's commitments appear; the chain continues at 5 or restarts at 1.
**Edge case:** he ignores it. Nothing is charged, nothing is cleared, and the open Declaration begins
counting toward silence.

**KF-2. Hoàng starts the work he has been avoiding since nine.**
10:20, laptop open twice, Facebook both times. A notification: *company work, 0 of 3 hours today.* He
taps, a Focus Session starts, and he works. **Climax:** fifty minutes later it banks and the day reads
0:50 of 3:00 — no money involved, nothing policing where his attention went. **Resolution:** three
more sessions meet the quota.

*The prompt's literal template (Story 3.2, FR-5/FR-12), a configured hour after the fact rather
than at 10:20 sharp: `<name>, <banked> of <target>, as of <time>.` — self-dated the same way
every other push here is, so a copy sitting on the lock screen can be told from a new one.
`Company work, 0:00 of 3:00, as of 10:20.` before the first session; `Company work, 0:50 of
3:00, as of 12:40.` once something is banked. Nothing is sent once the target is met that day —
this is the product's whole answer to a quota that succeeded.*

**KF-3. Hoàng went to the gym and the phone says he did not.**
*(Written against the location Auto-check, which v1 defers; the same flow runs today for the
TryHackMe check. The beats are unchanged.)*
Saturday; the phone was in the locker, so the geofence never accumulated dwell. The app reports the
session missed and states exactly what it saw: four minutes against thirty required. He appeals with a
photo of the check-in screen, taken that day. **Climax:** the 500,000 moves to held, not charged, and
the screen says so in those words. **Resolution:** Nam approves it that evening; the session counts
and the money never moves.

**KF-4. Day two of going quiet.**
He slipped Wednesday, felt terrible, and did not open the app Thursday. Friday morning there is no
Declaration prompt among the usual ones — one message instead, naming two quiet days, stating that
Wednesday and Thursday close tonight, and offering one small thing to do today. Grace days are
mentioned second. **Climax:** the app names the pattern out loud instead of showing him a wall of
red, and the deadline is real rather than rhetorical — silence is not a way out, it is just the
expensive way to answer. **Resolution:** he answers both days and does the one thing.
**Edge case:** he does nothing again. Both days close as misses, appear in the Ledger as expired, and
can still be voided later with a grace day. The mechanism holds without anyone having to chase him.

**KF-5. Nam is told to go and collect.**
Wednesday evening, on the web: Hoàng owes 500,000 for Wednesday, TryHackMe missed, not appealed. The
message is already written and attributes the demand to the app. **Climax:** Nam copies it, sends it,
and collects in person that weekend — never having had to compose the awkward part or decide whether
to raise it. **Resolution:** he marks it collected. **Edge case:** he does nothing; the debt stays
listed and ages, because nothing in this system can charge anyone.

**KF-6. Thursday, and the gym quota is running out of week.**
One session done. A notification: *2 gym sessions left, 3 days remaining* — urgent, not failed,
because a weekly quota cannot fail on a Thursday. **Climax:** by Saturday morning, one left and one
day remaining, it is the loudest thing on the phone. **Resolution:** he goes, or the week closes
against him at Week Close.

*The reminder's literal template (Story 3.5, FR-4) names the commitment the same way
`enqueue_focus_prompts`' body does (Story 3.2), and self-dates with a weekday and clock time —
neither KF-6's own phrasing above self-dates on its own, the same gap `week_summary_body` (3.4)
already hit and fixed: `<name>, <held> of <target>, <days> day(s) left this week, as of
<weekday> <time>.` Once daily while sessions remaining equals days remaining — two left with
exactly two days left, at his morning hour: `Gym, 1 of 3, 2 days left this week, as of Thursday
07:30.` Twice daily once sessions remaining exceeds days remaining — the same two still owed
with only one day left, morning and again twelve hours later: `Gym, 1 of 3, 1 day left this
week, as of Saturday 07:30.` and `Gym, 1 of 3, 1 day left this week, as of Saturday 19:30.`
Silent otherwise — a quota with more days left than sessions owed says nothing.*

**KF-7. Hoàng adds a commitment and decides how much truth it needs.**
He creates *Read 20 pages*, picks Do it and Every day. Money defaults off; he leaves it off. The four
optional checks are all off, so this one runs on his word alone. **Climax:** had he switched money on
*and* a check on, the screen would have told him then and there that the machine's ruling stands and
an appeal is the only way to overturn it — rather than letting him learn that on the day it costs him
500,000. **Resolution:** the commitment appears on Today tomorrow morning.
