# Redesign brief — "todoapp": a commitment app with real money and a real friend at stake

You are redesigning the visual interface of an existing, shipped product. Produce high-fidelity
screen designs for **two surfaces of one product**: an installed phone web app (PWA) for the person
making the commitments, and a plain browser app for the friend who holds him to them.

**What you may change:** the entire visual language — palette values, type scale and pairing,
density, shape language, iconography, illustration, subtle depth, how a row or a card is drawn.
**What you may not change:** the screen inventory, what each screen contains, the wording of the
interface copy given below, and the behavioural rules in §3. Those rules exist for documented
psychological reasons, not aesthetic ones — a design that breaks them is wrong even if it is
beautiful.

---

## 1. The product in one paragraph

A man commits to a handful of daily things — exercise, study, company work, no gambling. Each
commitment can carry money: miss it, and a flat penalty (500,000 VND) is owed for that whole day.
The money is not charged by any payment system; a friend acts as **referee**, is told who owes what,
and collects it in person. A few commitments are machine-checked; most run on the user's own word,
declared each morning. The user's established failure mode is: fail once, feel bad, stop opening the
app for days. Every design decision is measured against whether it makes opening the app cheaper or
more expensive.

**This is a ledger, not a coach's whiteboard.** No confetti, no medals, no progress rings filling
up, no streak celebrations, no motivational copy. It keeps records accurately and does not perform
enthusiasm about it. When the user succeeds it says so once and moves on; when he fails it says that
once too.

## 2. The two people, the two surfaces

|                | The doer                                   | The referee                              |
| -------------- | ------------------------------------------ | ---------------------------------------- |
| Device         | iPhone, PWA installed to the home screen   | Any browser, often an unfamiliar desktop |
| Frequency      | Every morning, several times a day         | Rarely — a few minutes a week            |
| Reached by     | Push notification (the primary surface)    | Email                                    |
| Job            | Declare, do, appeal, see what he owes      | Rule on appeals, collect money, look up a day |

**Notifications are the primary surface and the app is the secondary one.** The user does not open
the app unprompted. Every notification body must be fully legible on a locked lock screen and offer
at most one action. Design the lock-screen notifications as first-class screens, not as an
afterthought.

## 3. Non-negotiable rules

These outrank any consistency or beauty argument.

1. **Four state meanings, one meaning each.** _Held_ (it held; the chain is alive) · _Urgent_
   (running out of room, nothing lost yet) · _Failed_ (missed, or money owed) · _Neutral_
   (everything else, including a commitment simply not done yet). Pick new hues if you like, but a
   colour that means two things means nothing.
2. **Urgent must be unmistakable from Failed.** "Sort this out" and "you lost this" demand opposite
   responses and must be told apart at a glance, before being read.
3. **Never colour a self-declaration control.** The morning question's two answers — _It held_ and
   _I slipped_ — must be visually **identical** neutral controls. No green on the honest answer, no
   red on the costly one, no default selection, no confirmation step. Nothing in the system can
   detect a lie, so the cheap answer must not also be the attractive one.
4. **Do colour the referee's judgment controls.** He is ruling on someone else, not confessing.
   Speed beats symmetry there.
5. **No screen ever goes fully red — including the Ledger,** which is structurally a list of
   failures. On the worst day, commitment rows stay neutral and only the debt figure is tinted. In
   the Ledger, an _owed_ row carries its status label but the row itself stays neutral; only
   resolved outcomes (_Waived_, _Collected_) may take a tint. A wall of red is the exact thing that
   makes this user stop opening the app.
6. **Never tint a commitment that simply has not happened yet.** It is ten in the morning; that is
   not a failure.
7. **Red means missed or owed. Never emphasis, never urgency, never attention.**
8. **The debt figure is deliberately the largest, most saturated thing in the product.** The author
   chose this knowingly, against advice. Execute it; do not soften it.
9. **A state label is never pressable, and a control is never shaped like a state label.** Whatever
   silhouette you give status labels, nothing tappable may share it.
10. **Nothing destructive is one tap** (deleting a commitment confirms), **but declaring a slip is
    one tap** — it is honest, not destructive, and friction there taxes the truth.
11. **One primary action per screen, at most.** If a card appears to need two, one of them is not an
    action.
12. **Colour is never the sole carrier of state.** Every status label carries a word or a number:
    `12`, `1/3 · 3 days`, `Owed`, `Waived`.

## 4. Visual direction

The current design is intentionally austere: white page, hairline borders, no shadows, one tonal
step, system typeface, two weights, nothing bold, nothing uppercase, sentence case everywhere. It
holds together but reads plain and unresolved — that is why you are here.

Give it a considered, calm, adult identity: something that looks like a well-made instrument for
keeping an honest record — closer to a financial statement or a field notebook than to a habit
tracker. Warmth is welcome; cheerfulness is not. Restraint is the point: every decorative flourish
is a small extra cost to opening a screen the user is already reluctant to open.

You may introduce a refined palette (light **and** dark, both first-class), a real type pairing,
a considered spacing rhythm, a shape language, restrained iconography, subtle depth where it earns
its place, and one distinctive signature element. Keep exactly one string in a serif — the referee's
pre-written collection message — as a signal that it is meant to be said out loud by a person; a
second serif deletes that signal.

The product has **no logo and no app icon yet**. Propose both: a wordmark, and an iOS home-screen
icon that survives at 60×60 pt. The name is lowercase: `todoapp`.

Layout: a single column, roughly 34rem / 544px maximum, centred at every width, on both surfaces. It
is a phone app that happens to be reachable on a desktop; no screen gains a sidebar or a second,
wider composition at any breakpoint.

## 5. Screen inventory

Design every screen below, in light and dark, at **390×844** (phone) for the doer's surface and
**1280×900** (browser, content still in the centred column) for the referee's. Where states are
listed, draw each state as its own frame.

### Doer — the phone app

| #   | Screen                        | Contents                                                             | States to draw                                                                                          |
| --- | ----------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 1   | Sign in                       | App name, email, password, one action                                 | default · error                                                                                           |
| 2   | Morning Declaration (blocking) | The question about yesterday, two identical neutral answers          | one day pending · several days pending                                                                    |
| 3   | Today (home)                  | The whole day — see §6                                                | normal · everything held · day already failed · a claim window open · a check's permission revoked · empty |
| 4   | Chains detail                 | One commitment's history: current chain, longest chain, a calendar of held / missed / waived days | live chain · just reset                                                              |
| 5   | Focus Session                 | Running timer and banked total                                        | idle · running · banked · quota met for the day                                                           |
| 6   | Appeal                        | Contest a machine-recorded miss, attach a photo                       | draft · submitted and held · ruled in favour · ruled against · dropped on timeout                         |
| 7   | Ledger                        | Every failed day and how it ended                                     | populated · empty                                                                                         |
| 8   | Task setup                    | Create or edit a commitment, including optional checks                | new · money and a machine check both switched on (warning state)                                          |
| 9   | Week close                    | Each weekly-quota commitment's final position and a one-line verdict  | —                                                                                                         |
| 10  | Monthly report                | The long view                                                         | —                                                                                                         |
| 11  | Settings                      | Hour, permissions, install state, referee pairing, grace days         | healthy · notifications denied · not installed to the home screen · referee just paired (one-time password shown once) |
| 12  | Silence intervention          | Replaces everything else on the second quiet morning                  | —                                                                                                         |
| 13  | Lock-screen notifications     | Five templates — see §7                                               | —                                                                                                         |

### Referee — the browser app

| #   | Screen                  | Contents                                              | States to draw                                                            |
| --- | ----------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------- |
| 14  | Sign in / accept invite | Email, password                                       | sign in · choose your password (first visit)                              |
| 15  | Referee home            | Everything he ever sees by default                    | empty (his normal state) · appeals pending · penalties owed · both · the doer has gone quiet |
| 16  | Appeal detail           | The machine's account, the evidence photos, the ruling | pending ruling · already resolved                                         |
| 17  | Day lookup              | Type a date, see what that day held                    | form · result · objection recorded                                        |

## 6. Screen detail, with the real interface copy

Use this copy verbatim. It is load-bearing — each line was written against a specific failure mode.

**Today (the home screen).** Screen title `Today`. In this visual order:

- Up to five or six commitment rows inside a single hairline frame: commitment name on the left, a
  status label on the right. The row itself is never tinted — only its label is. The label carries a
  chain count (`12`), a weekly-quota position (`1/3 · 3 days`), or nothing yet. Machine-checked rows
  are not tappable to complete; they complete themselves. A declared row shows its control only in
  the morning, not all day.
- Where a commitment has a time window, a control block: `Claim Evening study` while the window is
  open, then `Evening study — claimed for today.` with a photo attachment labelled `Proof` and the
  hint `A photo taken today. It is private — only you can open it.`, then `Proof saved.` Offline:
  `Saved on this device — there is no connection right now. It will go when there is one, dated when
  you tapped.`
- **The debt block** — the accumulated amount owed, as a large figure on the only large tinted area
  in the product. Tapping it opens the Ledger. It renders nothing at all when nothing is owed.
- Grace-day rows, when a failed day is still open: `Spend a Grace Day`, with how many remain, then
  `Grace Day spent. This day clears within the hour.`
- A bar switching between `Today` / `Ledger` / `Settings`. The current screen is marked without
  colour — "you are here" is not one of the four state meanings.
- Empty state: `Nothing set up yet. Add a commitment below and it will appear here tomorrow morning.`
- **Reading order note:** commitment rows are announced before the debt figure even though the
  figure is drawn first. A sighted user can look past the figure; a screen-reader user cannot skip
  what is read to them.

**Morning Declaration.** `Morning. Day 5 is waiting.` / `Did last night hold?` and two identical
neutral buttons: `It held` · `I slipped`. The app opens onto this and offers nothing else to do
while a declaration is outstanding — blocking by having no alternative, never by trapping the
device. Never name the money while asking.

**Focus Session.** A running timer, the second and only other large figure in the product.
`Start the clock` · `Stop and bank it` · `Banked today`, showing e.g. `0:50 of 3:00` over a quiet
progress track. Supporting line: `Keeps running while your phone is locked. Nothing here watches
what you're doing.` Starting a second session: `A clock is already running on another commitment.
Stop that one first.`

**Appeal.** The machine's account is stated exactly: `Location saw you for 4 minutes. It needed 30.`
— never "verification failed"; the specific number is what makes it read as a technical fault rather
than an arbitrary ruling. The hold state is the most trust-critical sentence in the product and
deserves real typographic weight: `500,000 is on hold, not charged. It stays on hold until Nam
decides, or until Sunday closes — and if he doesn't get to it, it's dropped.` Money on hold is
_urgent_, never _failed_ — it may still be kept.

**Ledger.** One row per failed day, each with an outcome label: `Owed` · `Collected` · `Waived` ·
`Dropped` · `Expired`. Empty: `No day has been judged yet.` See rule 5 — this screen must not become
the reddest thing in the app.

**Task setup.** Plain language, never glossary terms: the kind reads `Do it` / `Avoid it` /
`Put hours in`. Money defaults **off**. Optional machine checks, each toggleable, disabled with an
explanation where the commitment's kind makes it meaningless. For an unverifiable kind: `Nothing can
check this one. You'll be asked each morning, and your answer is the record.` When money **and** a
machine check are both switched on, the screen says so there and then — that the machine's ruling
stands and an appeal is the only way to overturn it — rather than letting him discover it on the day
it costs him 500,000.

**Monthly report.** Chains; penalties **incurred** and **collected** as two separate figures that
must never be merged (their divergence is the only visible evidence that the referee has stopped
participating); median days to return after a failed day; count of silences longer than two days.

**Settings.** Morning hour; notification permission with its consequence in plain language rather
than a bare toggle — `The morning question and the evening summary arrive on your lock screen.`;
home-screen install state — `Launched from the home screen, which is the only way iOS delivers push
at all.` (this row matters more than any other: no install, no push, no product); referee pairing,
including a one-time password shown exactly once; grace days remaining this month.

**Silence intervention.** Title `Two quiet days`. Body: `Two quiet days. This is the part where it
usually ends. It doesn't have to. Do one thing today — TryHackMe, twenty minutes.` No debt figure.
No red. One small action. It replaces the routine content entirely and delivers **once** — nagging
someone who has already withdrawn is how you lose them.

**Referee home.** His default is empty, and that empty frame is the most important one on this
surface: `Nothing for you this week. Hoàng is at 4 of 5 today. You'll get an email if that changes.`
— the progress crumb is the only retention lever the product has over him. When there is work:
`Pending appeals` (rows: commitment name, day, `Open`) and `Owed penalties` (rows: amount — the
commitments missed, day, `Copy message`, `Mark Collected`). A collection card carries the
pre-written message in the one serif, with a copy control and no compose field: `todoapp says you
owe 500,000 for Tuesday. I'm just the one collecting it. When are you free?` When the doer has gone
quiet: `Hoàng hasn't opened this in four days. Nothing needs deciding — but he'd probably rather
hear from you than from the app.` — informational, no action control, never a queue item. Plus a
plain `Look up a day` door and `Sign out`.

**Appeal detail (referee).** The machine's account, the attached photos, and two coloured judgment
controls in plain language: `He did it` / `He didn't` — never Approve/Reject. Plus the note written
for his benefit rather than the doer's: `Ignore this and it's dropped in his favor on Sunday.`

## 7. Lock-screen notification templates

Design these as iOS lock-screen frames. Every body is self-dated, so a copy still sitting on the
lock screen can be told from a new one.

1. Morning Declaration — `Morning. Day 5 is waiting.` / `Did last night hold?` (re-delivers until answered)
2. Focus prompt — `Company work, 0:50 of 3:00, as of 12:40.`
3. Weekly quota running out — `Gym, 1 of 3, 1 day left this week, as of Saturday 07:30.`
4. Day summary, bad — `One of five today. That's 500,000. Morning exercise held though — day 12. Start there tomorrow.`
5. Day summary, good — `Four of five today. Gym is still 1 of 3 with two days left. Tomorrow morning is the easy one to take.`

## 8. Component inventory to design

Row (name + status label) · list frame · status label · debt figure block · primary action · neutral
self-declaration control · destructive control (deleting a commitment, and nothing else) · quiet
navigation control · screen head (title and its one navigation control on a 44px row) · card · tab
bar · quota track · photo attachment control and thumbnail · toggle row with consequence text ·
collection card · empty states · inline error (`Failed.` plus a reason sentence) · loading
(`Working…`).

## 9. Accessibility floor

- Contrast: WCAG AA — 4.5:1 for text, 3:1 for non-text state indicators — for **every** pair you
  introduce, in both light and dark. State the measured ratio for each tint/ink pair you propose.
- All controls reach 44×44 pt.
- The type ramp must survive the user's own text-size setting growing it; no fixed-height rows that
  clip, the two large figures included.
- Motion: essentially none. Under Reduce Motion the timer updates without animation and the quota
  track snaps rather than fills. Nothing else in this product animates — keep it that way.
- Dark mode is a declared palette, not an inversion. A warm palette inverted goes muddy, and each
  state meaning has to survive the change intact.

## 10. What to deliver

1. Every screen in §5, light and dark, each listed state as its own frame.
2. The five notification frames from §7.
3. A style page: the palette with its four state meanings named and their contrast ratios, the type
   ramp, the spacing scale, the shape and border language, and the components from §8.
4. A wordmark and an app icon.
5. A short written rationale — ten lines at most — for anything you changed that the current system
   had a stated reason for, especially if you added depth, colour, or motion.

## 11. Appendix — the current system, as a starting point (not a constraint)

Palette in use today, light / dark:

- Surface `#FFFFFF` / base `#1C1C1E`, card `#2C2C2E`; one tonal step `#F7F6F2` / `#242426`
- Text `#2C2C2A` / `#F2F2F0`, secondary `#5F5E5A` / `#A0A09A`, muted `#888780` / `#6E6E68`
- Hairline `#DCDAD2` / `#3A3A3C`, strong `#B4B2A9` / `#545456`
- Held tint `#EAF3DE` with ink `#3B6D11` / `#173404` with `#C0DD97`
- Urgent tint `#FAEEDA` with ink `#854F0B` / `#412402` with `#FAC775`
- Failed tint `#FCEBEB` with ink `#A32D2D` / `#501313` with `#F7C1C1`
- Action fill `#97C459` with ink `#173404`; destructive fill `#F09595` with ink `#501313` — both
  mode-stable, and one step darker than their tint families so that a coloured area reads as
  pressable before its text is read

Type: the system stack, two weights (400 / 500), nothing bold, nothing uppercase, sentence case.
Screen title 17→21px · body 15→16px · label 13→14px · caption 11px fixed · figure 34→44px at −0.5px
tracking, reserved for exactly two things: the debt total and the running timer.

Shape: 8px controls, 12px cards, fully rounded status labels only. Spacing: 4 / 8 / 12 / 16 / 20 /
24, card padding 16, row padding 11. Hairlines are 0.5px, not 1px — at 1px a list of rows starts to
read as a table. No shadows anywhere.

The interface language is English on both surfaces, though both users are Vietnamese speakers;
amounts are Vietnamese đồng, written `500,000`.
