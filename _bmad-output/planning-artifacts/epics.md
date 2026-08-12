---
stepsCompleted: [1, 2, 3, 4]
inputDocuments:
  - prds/prd-todoapp-2026-08-11/prd.md
  - prds/prd-todoapp-2026-08-11/addendum.md
  - ux-designs/ux-todoapp-2026-08-11/DESIGN.md
  - ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md
  - architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md
  - architecture/architecture-todoapp-2026-08-11/SOLUTION-DESIGN.md
---

# todoapp - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for todoapp, decomposing the
requirements from the PRD, the UX design contract, and the Architecture spine into implementable
stories.

Requirement IDs are carried over verbatim from their source documents rather than renumbered, so a
story can always be traced back to the FR, AD, or UX decision that produced it.

## Requirements Inventory

### Functional Requirements

Source: `prd.md` §4. Twenty-seven requirements; two are deferred with the native client and are
listed for completeness because their stories return unchanged when it arrives.

**Commitments**

- **FR-1**: The author can create, edit, and delete a Commitment from the phone, setting a Kind, a Cadence, a Penalty flag, and any number of Auto-checks.
- **FR-2a**: Where a Commitment carries a Penalty and has an Auto-check attached, the Auto-check's result stands and an Appeal is the only way to overturn it. Where it carries no Penalty, the author's Declaration overrides any Auto-check result and no Appeal exists.
- **FR-2**: The system judges each Commitment only at its own settlement point, never earlier.

**Notification-first engagement**

- **FR-3**: Every state change the author must know about is delivered as a self-sufficient notification, and a notification requiring a response persists until it gets one.
- **FR-4**: Reminders for a Weekly Quota Commitment escalate as sessions remaining approach days remaining.
- **FR-5**: When a Daily Hours Quota Commitment has accumulated no minutes by a configured hour, the system prompts the author to start a Focus Session.

**Auto-checks**

- **FR-6**: *[DEFERRED — requires a native client]* Location Auto-check: records a session when the phone remains inside a configured geofence for a minimum dwell duration.
- **FR-7**: *[DEFERRED — requires a native client]* Movement Auto-check: confirms a Commitment from the phone's motion data within a configured window.
- **FR-8**: External account Auto-check: confirms a Commitment by reading completion history from a linked external service.
- **FR-8b**: An Auto-check that cannot run reports itself unavailable and falls through to the author's Declaration. It never reports a miss.

**The morning Declaration**

- **FR-9**: For each Commitment whose Declaration was not filed by an Auto-check, the system requests one for the previous day at the author's first interaction after a configured morning hour, blocking, and expiring to a miss after 48 hours.
- **FR-10**: A calendar day closes when every Declaration for it has been filed — by Auto-check, by the author, or by expiry — and at Day Close the system determines whether it is a Failed Day.

**Focus Sessions**

- **FR-11**: The author can start and stop a Focus Session against an Open-ended Commitment; elapsed minutes bank to that Commitment's daily total.
- **FR-12**: The author can see minutes banked against the day's target without opening the app.

**Penalty, settlement and appeal**

- **FR-13**: Each Failed Day generates one Penalty of 500,000 VND owed by the author to the Referee.
- **FR-14**: When an Auto-check on a penalty-carrying Commitment reports a miss, the author can submit an Appeal with evidence on the day the work was claimed.
- **FR-15**: A Held Penalty resolves either by the Referee's ruling or by its Cadence's settlement point, whichever comes first, and always in the author's favor on timeout.

**Recovery**

- **FR-16**: After two consecutive days of Silence, the system replaces routine notifications with a single intervention naming the pattern, the Grace Days remaining, and one concrete action for today.
- **FR-17**: The author can spend a Grace Day to void one day's Penalty and preserve that day's Chains, reachable from the Day summary, the Ledger, and the intervention.
- **FR-18**: When Silence persists, the system emails the Referee that the author has gone quiet and surfaces that state on the Referee's home.

**The Referee surface**

- **FR-19**: The Referee holds an account distinct from the author's, and sees only Appeals and Penalties.
- **FR-20**: The Referee can view an Appeal's evidence and claim and either approve or reject it.
- **FR-21**: The Referee sees each owed Penalty with a pre-written collection message, and can mark it Collected.

**Reviews and chains**

- **FR-22**: At Day Close the system delivers a summary of what was met and one suggestion for tomorrow.
- **FR-23**: At Week Close the system judges Weekly Quota Commitments, resolves outstanding Held Penalties per FR-15, and reports whether the week held.
- **FR-24**: Monthly, the system reports Chains, Penalties incurred and collected separately, days returned after a slip, and Silence episodes.
- **FR-25**: The system maintains a Chain per Commitment: consecutive days held for Daily Commitments, consecutive weeks at quota for Weekly Quota Commitments.

### NonFunctional Requirements

Sources: `prd.md` §5, `EXPERIENCE.md` § Accessibility Floor and § The notification contract.

- **NFR1**: A capability reachable only by opening the app unprompted is not a capability. Everything load-bearing pushes.
- **NFR2**: v1 ships as one PWA installed to the home screen, serving both roles from one codebase, with role resolved server-side.
- **NFR3**: The Referee's surface must work without notification permissions of any kind; his channel is email.
- **NFR4**: Appeal evidence is visible to the Referee and to no one else.
- **NFR5**: The product never holds or moves money — no payment integration, no stored instrument, no transferable balance.
- **NFR6**: Observations submitted while offline — focus sessions, declarations, appeals — queue locally and reconcile when connectivity returns, without duplicating. A network fault must never *invent* a miss that did not happen.
- **NFR6a**: The 48-hour Declaration expiry is measured in wall-clock time and is not extended by loss of connectivity. The server cannot distinguish a phone with no signal from a person choosing not to answer, and any extension it offered would be trivially gamed by airplane mode. A genuinely unreachable phone is remedied afterwards by a Grace Day from the Ledger, per FR-9 — that is the release valve, deliberately chosen over a connectivity exception.
- **NFR7**: Location data, when the location Auto-check returns, is used solely to evaluate dwell inside one configured geofence, is not retained beyond the session determination, and is never shown to the Referee.
- **NFR8**: Dynamic Type is honored throughout, including the debt figure and the running timer; no fixed-height row clips at larger sizes.
- **NFR9**: Color is never the sole carrier of state — every status pill carries a word or number.
- **NFR10**: Contrast floor for any token pair, including ones added later: WCAG AA, 4.5:1 for text and 3:1 for non-text state indicators.
- **NFR11**: All controls reach 44×44pt.
- **NFR12**: VoiceOver support as specified, including the deliberate inversion on Today where commitment rows are read before the debt block.
- **NFR13**: Under Reduce Motion the focus timer updates without animation and the quota bar snaps rather than fills.
- **NFR14**: The morning gate blocks the app, never the device — no focus trap, always closable, notification always dismissable at the OS level.
- **NFR15**: The Referee's web surface is keyboard-navigable with no focus traps and works on an unfamiliar machine.

### Additional Requirements

Source: `ARCHITECTURE-SPINE.md`. These bind every story rather than becoming stories of their own,
except where noted as setup work.

**Greenfield stack — Epic 1 setup work.** No opinionated starter template is prescribed; the stack is
Next.js 16 (App Router, TypeScript) with Serwist for the service worker, Supabase for Postgres, Auth,
Storage and Edge Functions, `pg_cron` and `pg_net` for scheduling, `web-push` for VAPID, deployed on
Vercel. Project initialization is Epic 1 Story 1.

- **AD-1**: The server is the sole judge. No client computes a verdict; clients submit observations only.
- **AD-2**: Every settlement pass runs as a single plpgsql function called directly by `pg_cron`, in one transaction. No settlement logic crosses an HTTP boundary.
- **AD-3**: Everything outbound goes through a transactional outbox, drained by a worker woken on its own `pg_cron` schedule via `pg_net`, independently of any settlement pass.
- **AD-4**: Every submitted event carries a client-generated idempotency key created at action time, not send time.
- **AD-5**: A settled period is never re-settled; settlement is keyed on `(subject, period, settlement_kind)` with a uniqueness constraint.
- **AD-6**: All day, week and 48-hour boundaries are computed in `Asia/Ho_Chi_Minh`. Clients send instants; the server derives days.
- **AD-7**: Authorization lives in RLS, never in application code.
- **AD-8**: Every derived value — penalty, chain, quota progress, ledger balance, every projection — has exactly one writer, and it is settlement.
- **AD-9**: Verdicts are append-only; corrections are new rows referencing the original.
- **AD-10**: An Auto-check resolves to held, missed, or unavailable. Only missed feeds FR-2a. Absence of a result is unavailable, never missed.
- **AD-11**: Notification lifecycle state lives in the database; the client never schedules its own reminders.
- **AD-12**: One codebase, two roles, role resolved server-side and driving both routing and RLS.
- **AD-13**: Every attached Auto-check must reach a terminal result before the day it belongs to is settled; settlement refuses to run for a day whose checks have not been attempted.
- **AD-14**: An event belongs to the day containing its start instant; duration accrues wholly to that day and is never split across a boundary.
- **AD-15**: A penalty's resolution is a single guarded transition — first writer wins, later writers are no-ops.
- **AD-16**: Settlement functions refuse to execute outside their scheduled invocation unless an explicit override is passed, and that override is rejected for the live doer account. All schema and function changes arrive through numbered migrations.
- Naming, id, time, money, error, copy, token, secret, evidence-storage and migration conventions are fixed in the spine's Consistency Conventions table and bind every story.

**Verification work that precedes feature work.** `SOLUTION-DESIGN.md` § What to build first identifies
two unverified assumptions that gate everything downstream: that Web Push works on the author's own
iPhone from a home-screen-installed PWA, and that TryHackMe completion history is externally readable.

### UX Design Requirements

Sources: `DESIGN.md` and `EXPERIENCE.md`, read as one contract.

**Design tokens and visual system**

- **UX-DR1**: Implement the four state color families as tokens — held, urgent, failed, neutral — each with tint, ink, and a dark-mode counterpart. One meaning per family; no color carries two.
- **UX-DR2**: Implement the button fills as tokens one step darker than their tint families (`action-fill`/`action-ink`, `destructive-fill`/`destructive-ink`), mode-stable and requiring no dark variant.
- **UX-DR3**: Implement the typography roles, with `figure` reserved to exactly two elements (the debt total and the running timer) and `quoted` (serif) reserved to exactly one string (the collection message).
- **UX-DR4**: Implement the rounded and spacing scales; nothing pressable is ever pill-shaped, since the pill shape is what distinguishes a state label from a control.
- **UX-DR5**: No literal hex or spacing value in any component — every visual value resolves to a DESIGN.md token.

**Components**

- **UX-DR6**: `button-action` — filled, at most one per card, and on the referee's surface at most one card demanding action above the fold.
- **UX-DR7**: `button-neutral` — outline only, used for every self-declaration control. Never colored; this rule outranks consistency arguments against it.
- **UX-DR8**: `button-destructive` — filled red, deleting a Commitment and nothing else.
- **UX-DR9**: `button-bare` — text only, for leaving without acting.
- **UX-DR10**: `status-pill` — tint plus ink from a single state family, carrying chain count, quota position, or ledger outcome; never interactive, never a button fill.
- **UX-DR11**: `figure-block` — the debt total on Today, the only large colored area in the product.
- **UX-DR12**: `row` — commitment name left, status right, hairline above; the row is never tinted, only its pill.

**Rules that constrain layout**

- **UX-DR13**: No screen ever goes fully red — including the Ledger, where an owed row carries its pill but the row stays neutral and only `Waived` and `Collected` rows take their tint.
- **UX-DR14**: A commitment not yet done today is neutral, never tinted as a failure.
- **UX-DR15**: Flat surfaces only — hairline borders at 0.5px and one tonal step, no shadows anywhere.

**Information architecture — twelve surfaces**

- **UX-DR16**: Doer surfaces: Today (launch destination, debt figure then commitment rows with chains), Morning Declaration, Focus Session, Appeal, Ledger, Task setup.
- **UX-DR17**: Doer surfaces specified by table rather than mockup: Chains detail, Week close, Monthly report, Settings, in-app Morning Declaration.
- **UX-DR18**: Referee surfaces: Appeals and collections (the whole app), Login.
- **UX-DR19**: Monthly report must state Penalties incurred and Penalties Collected as separate figures — their divergence is the only visible evidence the Referee has stopped participating.
- **UX-DR20**: Settings shows home-screen install state with what breaks without it, since without installation there is no push and without push there is no product.

**Voice, tone and microcopy**

- **UX-DR21**: Implement the thirteen specified strings verbatim from `EXPERIENCE.md` § Voice and Tone, including both day-summary variants and both day-two intervention variants.
- **UX-DR22**: Never name the money while asking a question; state it after the fact, once.
- **UX-DR23**: Never itemize failures — state the count and amount once, then name something that survived.
- **UX-DR24**: Interface labels use plain language, never glossary terms: *Do it / Avoid it / Put hours in*, *He did it / He didn't*, *Stop and bank it*.
- **UX-DR25**: The Appeal must state exactly what the machine observed and exactly what was required, never a generic failure message.
- **UX-DR26**: All user-facing copy originates in `EXPERIENCE.md`; new copy is added there before it appears in a component.

**Behavior and state**

- **UX-DR27**: Implement the notification contract — self-sufficient bodies, persistence until answered, one action per notification, the morning slot reserved, the intervention as its single permitted exception, and no push to the Referee.
- **UX-DR28**: Implement the state sets for Today, commitment row, Appeal, Focus Session, Referee home, and Ledger row, including the two states carrying rules that outrank layout (day already failed; held pending appeal).
- **UX-DR29**: Machine confirmation is silent — a passing Auto-check produces no notification and no interaction.
- **UX-DR30**: Nothing destructive is one tap, but declaring a slip is not destructive and must not be given friction.

**Accessibility**

- **UX-DR31**: Deliver the accessibility floor as specified: Dynamic Type, non-color state carriers, AA contrast, 44×44pt targets, VoiceOver labels, Reduce Motion, and the deliberate accessibility-order inversion on Today.

### FR Coverage Map

| FR | Epic | Covered by |
|---|---|---|
| FR-1 | Epic 2 | Task setup — create, edit, delete a Commitment |
| FR-2a | Epic 4 | Precedence once an Auto-check can disagree with the author |
| FR-2 | Epic 2, Epic 3 | Daily judging in Epic 2; quota judging in Epic 3 |
| FR-3 | Epic 2 | Push-resident, persistent notification delivery |
| FR-4 | Epic 3 | Quota-aware escalating reminders |
| FR-5 | Epic 3 | Prompt when quota work has not started |
| FR-6 | *(none — resolved as deferred)* | Location Auto-check. Deliberately uncovered: blocked on an Apple Developer account, specified and waiting. **Not a coverage gap.** |
| FR-7 | *(none — resolved as deferred)* | Movement Auto-check. Same blocker, same status. **Not a coverage gap.** |
| FR-8 | Epic 4 | External account Auto-check |
| FR-8b | Epic 4 | Auto-check availability and fall-through |
| FR-9 | Epic 2 | Blocking morning Declaration and 48-hour expiry |
| FR-10 | Epic 2 | Day Close and Failed Day determination |
| FR-11 | Epic 3 | Run a Focus Session |
| FR-12 | Epic 3 | Quota progress without opening the app |
| FR-13 | Epic 2 | Penalty accrual |
| FR-14 | Epic 4 | Same-day Appeal |
| FR-15 | Epic 4 | Ruling deadlines and timeout in the author's favor |
| FR-16 | Epic 5 | Silence detection and day-two intervention |
| FR-17 | Epic 5 | Grace Days |
| FR-18 | Epic 5 | Escalation to the Referee |
| FR-19 | Epic 4 | Referee account and authentication |
| FR-20 | Epic 4 | Rule on an Appeal |
| FR-21 | Epic 4 | Collection instruction and confirmation |
| FR-22 | Epic 2 | Day summary |
| FR-23 | Epic 3 | Week Close |
| FR-24 | Epic 5 | Monthly report |
| FR-25 | Epic 2 | Chains |

Twenty-five of twenty-seven FRs are covered by a v1 epic. FR-6 and FR-7 are uncovered *by decision*,
not by oversight — they are blocked on an Apple Developer account and return unchanged when one
exists, because the architecture makes the client a thin reporter. A future reviewer should read
these two rows as settled, not as work someone forgot.

## Epic List

### Epic 1: Prove it can reach him

The author learns, on his own iPhone, whether the mechanism is physically possible before anything is
built on the assumption that it is. A bare PWA is installed to the home screen, a push is sent from a
server, and the phone is locked and rebooted to see whether the notification survives. In parallel,
TryHackMe completion history is checked for external readability.

This is the only epic whose valid outcome may be *stop*. Every capability in this product is a
notification; if Web Push is unreliable in his hands, everything downstream is built on sand, and
learning that after a day is cheaper than learning it after two months.

**FRs covered:** none directly — this epic gates FR-3 and FR-8, and validates NFR1 and NFR2.

### Epic 2: A day that judges itself

The author can set up his commitments, is asked each morning to answer for yesterday, and watches
days close and money accrue — running the entire stakes mechanism alone, before a second person is
involved. Penalties sit as owed; nobody collects them yet, which is honest rather than incomplete.

**FRs covered:** FR-1, FR-2 (daily), FR-3, FR-9, FR-10, FR-13, FR-22, FR-25

### Epic 3: Work with no finish line, and weeks that hold

The author can commit to time rather than completion, banking focus sessions against a daily hours
quota, and the two remaining cadences work: a weekly quota that counts down as days run out, and a
week that closes on its own terms.

**FRs covered:** FR-2 (quota), FR-4, FR-5, FR-11, FR-12, FR-23

### Epic 4: The machine answers for him, and the friend rules

Auto-checks file declarations on the author's behalf, and when one is wrong there is a person who can
overturn it. These belong to one epic rather than two because an Appeal only exists when an Auto-check
has reported a miss — split apart, the appeals epic would have nothing to appeal.

**FRs covered:** FR-2a, FR-8, FR-8b, FR-14, FR-15, FR-19, FR-20, FR-21

### Epic 5: The way back

The product notices the author has gone quiet and intervenes on the second day, grace days give him a
countable way to recover without lying, and the monthly report tells him whether the whole
arrangement is still alive — including whether the Referee has quietly stopped participating.

**FRs covered:** FR-16, FR-17, FR-18, FR-24

---

## Epic 1: Prove it can reach him

The author learns, on his own iPhone, whether the mechanism is physically possible before anything is
built on the assumption that it is. The only epic whose valid outcome may be *stop*.

### Story 1.1: An installable shell, and the tokens everything else is built from

As the author,
I want a deployed web app I can install to my iPhone home screen, styled entirely from named tokens,
So that I know the platform can host this product, and no later screen has to invent its own colors.

*Design tokens live here rather than in a design-system epic because the shell already needs color
and type from its first line of CSS — this is the first story that touches them, not a place they
were filed for tidiness. Components come later, with the screens that need them.*

**Acceptance Criteria:**

**Given** a Next.js 16 App Router project with Serwist configured and deployed
**When** I open it in Safari on my iPhone and choose Add to Home Screen
**Then** it launches standalone with no browser chrome
**And** a web app manifest and a registered service worker are both verifiable in Safari's inspector

**Given** the token layer
**Then** the four state color families — held, urgent, failed, neutral — exist as tokens with tint, ink and a dark-mode counterpart each, per UX-DR1
**And** the two button fills sit one step darker than their tint families and carry no dark variant, per UX-DR2
**And** the typography roles exist with `figure` claimable by only two elements and `quoted` by only one string, per UX-DR3
**And** the rounded and spacing scales exist, with the pill radius reserved to non-interactive elements, per UX-DR4
**And** surfaces are flat — 0.5px hairlines and one tonal step, no shadows anywhere, per UX-DR15
**And** the repository contains no literal color or spacing value, per UX-DR5

**Given** the app has not been installed to the home screen
**When** it is opened in a browser tab
**Then** it states plainly that without installation there is no push, and without push there is no product, per UX-DR20

**Given** the deployed app
**When** a Supabase project is connected and a trivial authenticated read succeeds
**Then** the stack named in the spine is proven to hold together end to end
**And** schema changes are applied only through numbered migrations, per AD-16

### Story 1.2: A push arrives on a locked phone and survives a reboot

As the author,
I want a push notification sent from a server to reach my locked iPhone,
So that I know the product's only delivery channel actually works in my hands.

**Acceptance Criteria:**

**Given** the app installed to the home screen and notification permission granted
**When** the server sends a Web Push using VAPID
**Then** the notification appears on the lock screen
**And** its body is fully legible without opening anything, per NFR1

**Given** a delivered subscription
**When** I reboot the phone and wait at least one hour without opening the app
**Then** a newly sent push still arrives
**And** the subscription has not been silently invalidated

**Given** the push proves unreliable in any of the above
**Then** the finding is written up and the project stops here for a decision, rather than continuing on the assumption

### Story 1.3: Settle whether TryHackMe can be read from outside

As the author,
I want to know whether my completed-room history is readable without me,
So that I know whether the only outward-reaching Auto-check in v1 has a target.

**Acceptance Criteria:**

**Given** the author's TryHackMe account
**When** completion history is requested from a server with no browser session
**Then** either a repeatable request returns dated completion data, and the request shape is recorded
**Or** the attempt is documented as not possible, and FR-8 is reduced to the timer Auto-check alone

**Given** either outcome
**Then** the result is recorded in the PRD open questions rather than left in a conversation

---

## Epic 2: A day that judges itself

The author sets up his commitments, is asked each morning to answer for yesterday, and watches days
close and money accrue — running the entire stakes mechanism alone, before a second person exists.

### Story 2.1: Sign in as the doer

As the author,
I want an account that identifies me as the doer,
So that everything I record afterwards belongs to me and is governed by my role.

**Acceptance Criteria:**

**Given** Supabase Auth configured
**When** I sign in
**Then** my account carries a role resolved server-side, per AD-12
**And** the role is never trusted from a client-held claim

**Given** any table created from this story onward
**Then** it carries row-level security expressing its access rule, per AD-7
**And** authorization is never enforced in application code

### Story 2.2: Create and edit a commitment

As the author,
I want to create, edit and delete my own commitments,
So that I can shape what I am held to rather than accept a fixed list. *(FR-1)*

**Acceptance Criteria:**

**Given** the Task setup surface
**When** I create a commitment
**Then** I set a name, a Kind (*Do it / Avoid it / Put hours in*, per UX-DR24), and a Cadence (*Every day / Times a week / Once*)
**And** the money toggle defaults to off

**Given** I choose the Kind *Avoid it*
**When** the Auto-check section renders
**Then** every Auto-check is disabled and greyed
**And** the screen states that nothing can check this one and my morning answer is the record

**Given** a Weekly Quota commitment
**Then** a target count and week start day are stored
**Given** a Daily Hours Quota commitment
**Then** a target duration in minutes is stored

**Given** the five starting commitments from PRD §4.1
**When** they are configured
**Then** gym and morning exercise carry no Auto-check in v1 and are settled by Declaration

**Given** deleting a commitment
**Then** it uses the destructive button — filled red, the only place in the product that colour appears on a control — and confirms before acting, per UX-DR8 and UX-DR30

### Story 2.3: See today, and the row and pill everything else reuses

As the author,
I want a home screen listing today's commitments and where each one stands,
So that opening the app tells me where I stand without reading anything twice.

*Chains are not shown here — they cannot be computed until settlement exists (2.5), so Story 2.9 adds
them to these rows rather than this story promising something it cannot yet display.*

*The row and status-pill components are built here because this is the first screen that needs them,
and every later surface reuses them rather than re-inventing them.*

**Acceptance Criteria:**

**Given** configured commitments
**When** I open the app
**Then** Today is the launch destination and lists each commitment as a row, per UX-DR16
**And** each row shows name left, status right, hairline above, and the row itself is never tinted, per UX-DR12

**Given** a commitment not yet done today
**Then** its row is neutral, never tinted as a failure, per UX-DR14

**Given** any state shown as a colored pill
**Then** the pill also carries a word or number, per NFR9
**And** the pill is not interactive and never uses a button fill, per UX-DR10

**Given** VoiceOver is active
**Then** each row announces its name and state as one label, per NFR12

**Given** the accessibility floor, delivered here and inherited by every later surface
**Then** Dynamic Type is honored with no row clipping at large sizes, per NFR8
**And** every control reaches 44×44pt, per NFR11
**And** any token pair added later clears WCAG AA — 4.5:1 for text, 3:1 for non-text state indicators, per NFR10 and UX-DR31

### Story 2.4: Answer for yesterday

As the author,
I want to be asked each morning whether yesterday held, in a way I cannot scroll past,
So that the one thing no machine can check still gets an honest answer. *(FR-9)*

**Acceptance Criteria:**

**Given** a commitment with no Auto-check and an unfiled Declaration for yesterday
**When** I first interact with the app after the configured morning hour
**Then** the Declaration is presented and the app offers nothing else to do until it is answered
**And** the two controls are visually identical neutral outline buttons, per UX-DR7 — the honest answer is never made to look more expensive than the dishonest one

**Given** the blocking gate
**Then** it blocks the app and never the device, per NFR14 — the notification stays dismissable at the OS level, the app stays closable, and VoiceOver is not trapped

**Given** I answer *It held*
**Then** yesterday closes clean for that commitment
**Given** I answer *I slipped*
**Then** yesterday is marked a miss for that commitment
**Given** I answer neither
**Then** nothing is charged, nothing is cleared, and the open Declaration begins counting toward Silence

**Given** any answer I give
**Then** it is submitted as an observation carrying a client-generated idempotency key created at the moment I tapped, per AD-4
**And** the client sends an instant, never a derived date, per AD-6

**Given** I answer while offline
**Then** the answer queues locally and flushes when connectivity returns, per NFR6
**And** the queued answer carries the instant I tapped, not the instant it was delivered
**And** flushing the queue twice produces one answer, not two

**Given** the gate mechanism
**Then** it is a persistent Web Push plus a launch modal — the two mechanisms a PWA leaves available, per `EXPERIENCE.md` § Interaction Primitives
**And** the push re-delivers on a schedule until answered, per FR-3
**And** neither alone is relied on: the push reaches me when I am not thinking about the app, the modal remains when the push was swiped away

**Given** the notification was swiped away
**When** I open the app with a Declaration still outstanding
**Then** the in-app Declaration surface carries the same content and the same two neutral controls, per UX-DR17 — a dismissed notification must not be the only route to answering

**Given** the morning hour that decides when I am asked
**Then** it is configurable from Settings, alongside notification permission state and referee pairing, per UX-DR17

### Story 2.5: The day closes on its own

As the author,
I want each day to be judged automatically at its own settlement point,
So that a verdict exists whether or not I opened anything. *(FR-10, FR-2 daily)*

**Acceptance Criteria:**

**Given** every Declaration for a day has been filed
**When** the scheduled settlement pass runs
**Then** the day is closed and marked a Failed Day if any penalty-carrying commitment was missed
**And** the pass runs as a single plpgsql function invoked directly by `pg_cron` in one transaction, per AD-2

**Given** a settlement pass that is retried, overlapped, or triggered twice
**When** it runs over an already-settled day
**Then** it is a no-op, guarded by a uniqueness key on `(subject, period, settlement_kind)`, per AD-5

**Given** the day is already known to be lost
**When** I open the app before Day Close
**Then** nothing announces it, per FR-10 — the remaining commitments stay live

**Given** a settlement function invoked outside its schedule
**Then** it refuses to run unless an explicit override is passed, and the override is rejected for the live doer account, per AD-16

**Given** all day and week boundaries
**Then** they are computed in `Asia/Ho_Chi_Minh`, per AD-6

### Story 2.6: A failed day costs money, and I can see every one

As the author,
I want a failed day to accrue 500,000 VND and appear in a ledger I can trace,
So that a debt I do not remember can always be explained. *(FR-13)*

**Acceptance Criteria:**

**Given** a Failed Day
**When** settlement runs
**Then** exactly one Penalty of 500,000 VND is written, regardless of how many commitments were missed
**And** it is written only by a settlement function, per AD-8
**And** it is traceable to the events that produced it, per AD-9

**Given** the Ledger surface
**When** I open it
**Then** each row shows its date, the commitment involved, and its outcome
**And** an owed row carries its pill but the row itself is not tinted, per UX-DR13
**And** the only outcome reachable at this point is `Owed` — `Expired` arrives with 2.7, `Dropped` with 4.4, `Collected` with 4.7, and `Waived` with 5.1, each added by the story that makes it possible

**Given** the Today surface
**Then** the cumulative amount owed since first use appears as the figure block — the only large colored area in the product, per UX-DR11
**And** tapping it opens the Ledger

**Given** the worst possible day, with every commitment missed
**Then** the rows stay neutral and only the debt block is tinted, per UX-DR13 — no screen in this product ever goes fully red

**Given** VoiceOver is active on Today
**Then** commitment rows are read before the debt block, per NFR12, even though the debt block is drawn first

**Given** money is stored anywhere
**Then** it is an integer amount of đồng, never a floating point value

**Given** the product's entire relationship with money, per NFR5
**Then** it records a claim that one person owes another and a confirmation that it was paid, and does nothing else
**And** there is no payment integration, no stored payment instrument, no balance the product can move, and no code path that transfers value
**And** a Penalty is discharged only by the Referee marking it Collected — the product never settles a debt on its own

### Story 2.7: Silence is not a way out

As the author,
I want an unanswered question to close against me after two days,
So that going quiet is never cheaper than telling the truth. *(FR-9 expiry)*

**Acceptance Criteria:**

**Given** a Declaration that has gone unanswered
**When** 48 hours have passed since it was first requested
**Then** it expires and settles as a miss
**And** the day it belongs to closes, per FR-10

**Given** an expired day
**When** I open the Ledger
**Then** it appears with an `Expired` outcome, distinguishable from a day I answered honestly

**Given** a Declaration answered late but before expiry
**Then** answering it settles the day it belongs to, not the day I answered

**Given** I answered while offline and the submission was still queued when 48 hours elapsed
**When** the queue flushes
**Then** my answer settles the day it belongs to, and any expiry already written is superseded — I answered in time; only the delivery was late

**Given** I was genuinely unreachable and answered nothing at all
**Then** the day expires on wall-clock time, per NFR6a
**And** the remedy is a Grace Day applied from the Ledger afterwards, not an extension of the clock

### Story 2.8: The day tells me how it went

As the author,
I want a summary each evening that I can read without opening anything,
So that a bad day ends with somewhere to start tomorrow rather than a list of failures. *(FR-22, FR-3)*

**Acceptance Criteria:**

**Given** Day Close
**When** the summary is delivered
**Then** it arrives as a push whose body is fully legible on the lock screen, per NFR1
**And** it names exactly one suggestion for tomorrow, naming a specific commitment

**Given** a Failed Day
**Then** the summary states the amount once and does not itemize the misses, per UX-DR23
**And** it names something that held, per the specified copy in `EXPERIENCE.md`

**Given** any outbound message
**Then** settlement writes it to the outbox in the same transaction as the verdict, and never calls out directly, per AD-3
**And** a worker woken on its own `pg_cron` schedule via `pg_net` drains the outbox, independently of whether any settlement ran

**Given** the outbox worker executes an effect twice
**Then** the dedupe key makes the second execution harmless

### Story 2.9: Chains that survive a bad day

As the author,
I want a chain per commitment that a failed day does not wipe out wholesale,
So that one miss does not erase the evidence that everything else held. *(FR-25)*

*This story also adds the chain to the Today rows built in 2.3 and to the VoiceOver label, completing
what that story deliberately left out.*

**Acceptance Criteria:**

**Given** a Daily commitment that held
**When** settlement runs
**Then** its chain extends by one day
**And** the chain is written only by settlement, per AD-8 — no other path repairs it

**Given** a Failed Day
**Then** chains for commitments that *did* hold are unaffected
**And** only the chain of the commitment that was missed resets

**Given** any notification mentioning a chain
**Then** a chain reset is never its headline, per `EXPERIENCE.md` § Component Patterns

**Given** the Chains detail surface
**Then** the longest chain is shown adjacent to the current one, so a reset is read against a record rather than against zero

---

## Epic 3: Work with no finish line, and weeks that hold

The author can commit to time rather than completion, and the two remaining cadences work: a weekly
quota that counts down as days run out, and a week that closes on its own terms.

### Story 3.1: Start the work by starting a clock

As the author,
I want to start a timed session against open-ended work and have the minutes bank when I stop,
So that work with no finish line can still be committed to. *(FR-11)*

**Acceptance Criteria:**

**Given** a commitment of Kind *Put hours in*
**When** I tap start
**Then** a session begins and continues while the app is backgrounded and while the phone is locked
**And** the control reads *Stop and bank it*, not *Stop*, per UX-DR24, and is the action button — filled, and the only one on the screen, per UX-DR6

**Given** a running session
**When** I leave the app for any length of time
**Then** nothing invalidates, pauses, or flags the session — the timer performs no attention policing
**And** the screen says so, per the specified copy in `EXPERIENCE.md`

**Given** I stop a session
**Then** its elapsed minutes bank to that commitment's daily total
**And** multiple sessions accumulate within one day

**Given** a session started at 23:50 and stopped at 00:20
**Then** its entire duration is attributed to the day containing the *start* instant, per AD-14
**And** it is never split across the boundary

**Given** a session submitted while offline
**Then** it carries a client-generated idempotency key created when I tapped, per AD-4, and replaying the queue produces one session, not two

### Story 3.2: Know where the hours stand without opening anything

As the author,
I want to see banked minutes against the day's target, and be prompted when I have not started,
So that the work I avoid starting is the work the app pushes me toward. *(FR-12, FR-5)*

**Acceptance Criteria:**

**Given** a Daily Hours Quota commitment with minutes banked
**When** the day's notification surface renders
**Then** progress is legible as banked against target without opening the app, per NFR1
**And** the running session screen shows the day total and a progress bar, not only the current session

**Given** a Daily Hours Quota commitment with no minutes banked
**When** the configured hour passes
**Then** a notification prompts me to start a session
**And** it offers exactly one action, per UX-DR27

**Given** Reduce Motion is enabled
**Then** the timer updates without animation and the progress bar snaps rather than fills, per NFR13

### Story 3.3: A weekly quota that counts down

As the author,
I want a weekly target that reasons about sessions left against days left,
So that a quota gets louder as the week runs out instead of failing silently on Sunday. *(FR-2 quota, FR-4)*

**Acceptance Criteria:**

**Given** a Weekly Quota commitment at 0 of 3 on a Tuesday
**Then** nothing is a miss — a weekly quota cannot fail mid-week, per FR-2
**And** its Today pill reads the quota position and days remaining, in the urgent family, per UX-DR10

**Given** sessions remaining approaches days remaining
**When** reminders are generated
**Then** their frequency and urgency increase, per FR-4
**And** no reminder frames a mid-week shortfall as a failure

**Given** the urgent color family
**Then** it is visually distinguishable from the failed family, per UX-DR1 — *sort this out* must not read as *you lost this*

### Story 3.4: The week closes and settles

As the author,
I want the week to be judged and settled at its own boundary,
So that quota commitments have a real deadline rather than an open question. *(FR-23)*

**Acceptance Criteria:**

**Given** Week Close
**When** the scheduled settlement pass runs
**Then** each Weekly Quota commitment is judged against its target
**And** a shortfall produces a Failed Day penalty under the same rules as FR-13

**Given** Week Close
**Then** it is delivered as a notification first, with the screen as the detail behind it
**And** the week's verdict is stated in one line

**Given** an already-settled week
**When** the pass runs again
**Then** it is a no-op, per AD-5

---

## Epic 4: The machine answers for him, and the friend rules

Auto-checks file declarations on the author's behalf, and when one is wrong there is a person who can
overturn it. These belong together because an Appeal only exists once an Auto-check can report a miss.

### Story 4.1: Attach a check that answers for me

As the author,
I want to attach an external account check to a commitment,
So that work with a public record confirms itself and I am never asked about it. *(FR-8)*

**Acceptance Criteria:**

**Given** the Task setup surface
**When** I enable the *An account elsewhere* Auto-check
**Then** an unlinked state shows the service and a link control; a linked state shows the account identifier and when it was last read, per UX-DR-linked component spec in `EXPERIENCE.md`

**Given** a linked account and a day with completion data
**When** the check resolves
**Then** the Declaration is filed automatically and I am never prompted for that commitment
**And** no notification is generated — machine confirmation is silent, per UX-DR29

**Given** any Auto-check attached to a commitment
**Then** its configuration is stored on that commitment, never as a global setting

### Story 4.2: A check that cannot run never says I missed

As the author,
I want an unreachable check to report itself unavailable rather than failed,
So that a service outage never takes 500,000 VND from me. *(FR-8b)*

**Acceptance Criteria:**

**Given** an external service that cannot be reached, or a check that has not been attempted
**When** the result is recorded
**Then** it resolves to `unavailable`, never `missed`, per AD-10
**And** the day falls through to my Declaration as if no Auto-check were attached

**Given** an `unavailable` result on a penalty-carrying commitment
**Then** FR-2a precedence does not apply — with no machine result to stand on, my Declaration settles the day and no Appeal is needed

**Given** a day whose attached checks have not all reached a terminal result
**When** settlement is invoked for that day
**Then** it refuses to run and reschedules, per AD-13
**And** `unavailable` means *tried and failed*, never *not yet tried*

**Given** a commitment with two Auto-checks where one is unavailable
**Then** availability is evaluated per check, and the working one still counts

### Story 4.3: When money rides on it, the machine's word stands

As the author,
I want the machine's result to be authoritative only where money is at stake,
So that pressure sits where I asked for it and nowhere else. *(FR-2a)*

**Acceptance Criteria:**

**Given** a commitment carrying a Penalty with an Auto-check attached
**When** the check reports a miss
**Then** the result stands and I cannot correct it directly — an Appeal is the only route

**Given** a commitment carrying no Penalty with an Auto-check attached
**When** the check reports a miss
**Then** my Declaration overrides it, with no referee involvement and no hold

**Given** I enable both the money toggle and an Auto-check while creating a commitment
**When** the screen renders
**Then** it states before saving that the machine's result will stand and an Appeal is the only way to overturn it — not on the day it first costs me money

**Given** a commitment with a pending Appeal
**When** I turn its Penalty off
**Then** the Appeal resolves in my favor rather than remaining open

### Story 4.4: Contest a miss the machine got wrong

As the author,
I want to submit evidence against a machine miss and have the money held rather than taken,
So that a technical fault never costs me money before a person has looked at it. *(FR-14, FR-15)*

**Acceptance Criteria:**

**Given** an Auto-check miss on a penalty-carrying commitment
**When** I open the Appeal surface
**Then** it states exactly what the machine observed and exactly what was required, never a generic failure message, per UX-DR25

**Given** I submit an Appeal
**Then** the associated Penalty moves to `Held` before it is ever presented as owed
**And** the screen states in words that the money is held and not charged, and what happens if nobody rules on it

**Given** evidence attached to an Appeal
**Then** only items dated the claimed day are accepted
**And** the evidence is stored in a private bucket whose access rule derives from the Appeal row, per NFR4

**Given** a Held Penalty and its deadline passing with no ruling
**Then** it is voided in my favor, per FR-15
**And** it never converts to owed on its own

**Given** a Held Penalty
**Then** its move to any terminal state is a single guarded transition — first writer wins, later writers are no-ops, per AD-15

### Story 4.5: The referee has his own way in

As the referee,
I want an account that shows me only what concerns me,
So that I can help without being handed someone else's whole life. *(FR-19)*

**Acceptance Criteria:**

**Given** a referee account provisioned when the author pairs him
**When** he signs in through the referee login surface, per UX-DR18
**Then** he sees only Appeals and Penalties
**And** there is no signup flow in v1
**And** he cannot see Declarations, chains, focus session activity, or location data

**Given** any role rule
**Then** it is enforced in row-level security, per AD-7, not in client code
**And** nobody can rule on their own appeal

**Given** the referee's surface
**Then** it works with no notification permission of any kind, per NFR3
**And** it is keyboard-navigable with no focus traps, per NFR15

**Given** a good week with nothing pending
**When** he opens it
**Then** he sees the empty state — the default state — with a short note on how the author is doing, per the specified copy

### Story 4.6: The referee rules

As the referee,
I want to see what the machine saw and what the author says, and decide,
So that a wrong call can be corrected by someone who was actually there. *(FR-20)*

**Acceptance Criteria:**

**Given** a pending Appeal
**When** the referee opens it
**Then** he sees the machine's observation, the author's claim, and the evidence
**And** the controls read *He did it* and *He didn't*, per UX-DR24

**Given** the referee approves
**Then** the Held Penalty is voided and the commitment is credited
**Given** the referee rejects
**Then** the Held Penalty converts to owed
**And** either ruling notifies the author with the outcome

**Given** the pending Appeal
**Then** the screen states that ignoring it drops the penalty in the author's favor at the deadline — written for the referee's benefit, so he knows he is not a bottleneck

### Story 4.7: The app does the asking, the referee does the collecting

As the referee,
I want the uncomfortable message already written for me,
So that collecting money from a friend costs me an action rather than a decision. *(FR-21)*

**Acceptance Criteria:**

**Given** an owed Penalty
**When** it appears on the referee's surface
**Then** it shows the amount, the date, and the commitment missed
**And** a pre-written message is presented that requires no composition, attributing the demand to the app rather than to him, per the specified copy

**Given** the pre-written message
**Then** a copy control places it on the clipboard unchanged

**Given** the referee marks a Penalty Collected
**Then** that is the only way a debt is discharged
**And** uncollected debts age visibly and are never written off automatically

**Given** a Held Penalty
**Then** it is invisible on the collection list until it is ruled on

---

## Epic 5: The way back

The product notices the author has gone quiet and intervenes, grace days give him a countable way to
recover without lying, and the monthly report says whether the arrangement is still alive.

### Story 5.1: A countable way to be forgiven

As the author,
I want a limited allowance that voids a day's penalty and keeps my chain,
So that a bad day has a way out that does not require me to lie about it. *(FR-17)*

**Acceptance Criteria:**

**Given** a Failed Day that is still uncollected
**When** I view it from the Day summary or from its Ledger row
**Then** a grace day control is offered, always stating how many remain
**And** it is never reachable *only* through the silence intervention — using my own allowance must not require going quiet for two days first

**Given** I spend a grace day
**Then** that day's Penalty is voided and its chains are preserved
**And** the Ledger row shows `Waived`, which is the only tinted outcome in that list besides `Collected`, per UX-DR13

**Given** a day already marked Collected
**Then** a grace day cannot be applied to it

**Given** a grace day is spent
**Then** it is recorded as an event and folded in by settlement, per AD-8 — it never repairs derived state directly

### Story 5.2: The app notices I have gone quiet

As the author,
I want the app to name the pattern on the second day instead of showing me a wall of red,
So that the moment I usually disappear has something in it besides my own failures. *(FR-16)*

**Acceptance Criteria:**

**Given** two consecutive days of Silence
**When** the morning arrives
**Then** a single intervention replaces the routine notifications, including the outstanding Declaration prompt
**And** it names the pattern, states grace days remaining, and offers exactly one concrete action

**Given** the intervention
**Then** it carries no debt figure, no itemized list of misses, and no red, per UX-DR23
**And** it delivers once and waits, the single exception to notification persistence, per UX-DR27

**Given** Declarations are outstanding when the intervention fires
**Then** it may take the morning slot because it arrives *before* the first 48-hour expiry
**And** acting on it still saves the day, with the Declaration answerable from inside the app

**Given** any Declaration is answered
**Then** the silence episode ends

### Story 5.3: The friend is told I have disappeared

As the referee,
I want to know when the author has gone quiet, without being given a task,
So that I can reach out as a friend rather than process another item. *(FR-18)*

**Acceptance Criteria:**

**Given** Silence persisting beyond the intervention
**When** the threshold is reached
**Then** the referee is emailed and the state appears on his home surface
**And** the message states the number of days, names no amount, and names no missed commitment

**Given** the escalation
**Then** it asks him for no action and adds nothing to his queues
**And** it fires once per silence episode, not daily

**Given** any Declaration is answered
**Then** the episode ends and further escalation is cancelled

### Story 5.4: The long view, including whether this still works

As the author,
I want a monthly report that shows whether the whole arrangement is still alive,
So that a mechanism that has quietly died cannot keep looking like one that is working. *(FR-24)*

**Acceptance Criteria:**

**Given** the end of a month
**When** the report is generated
**Then** it covers every measure in PRD §8, including the counter-metrics
**And** it states Penalties incurred and Penalties Collected as separate figures, per UX-DR19 — their divergence is the only visible evidence the referee has stopped participating

**Given** the report
**Then** it includes chains, median days to return after a Failed Day, and the count of silences longer than two days

**Given** the daily summary has stopped arriving
**Then** that absence is the heartbeat failure described in the spine's Deferred section — settlement has stopped, and no other alarm exists in v1
