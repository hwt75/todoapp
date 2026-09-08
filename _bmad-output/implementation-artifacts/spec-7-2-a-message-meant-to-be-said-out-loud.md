---
title: 'Story 7.2 — A message meant to be said out loud'
type: 'feature'
created: '2026-09-08'
status: 'approved'
review_loop_iteration: 0
baseline_commit: 'd046be123da6d24405d8b9f83f5aacc1660be330'
story_key: '7-2-a-message-meant-to-be-said-out-loud'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-7-1-a-surface-i-am-less-reluctant-to-open.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md'
  - '{project-root}/design_handoff_todoapp/design/redesign-brief.md'
  - '{project-root}/design_handoff_todoapp/design/Referee surface.dc.html'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> Written before the work, and approved before it started. Story 7.1 was written after its own
> implementation and says so in its first lines; this file exists in the other order on purpose, so
> that the Intent below actually constrains what gets built.
>
> Approved on 2026-09-08 by the maintainer answering both **Ask First** questions below — the amount
> takes an existing token, and neither control takes the primary fill. Both answers are recorded as
> deviations from the handoff frame rather than as silent choices. From here the frozen block does
> not move without the maintainer.

## Intent

**Problem:** The collection message is the most deliberately written sentence in the product —
`EXPERIENCE.md` line 125 records why, word by word: *"I'm just the one collecting it"* demotes the
referee from accuser to messenger, and the closing question turns a confrontation into logistics.
The referee never sees it. Story 4.7 built it clipboard-only: `Copy message` puts
`collectionMessage()` on the clipboard and the first human to read the string is the doer, in a chat
app, after the referee has already pasted it blind. A man about to ask a friend for 500,000 đồng in
person is being asked to send a sentence he has never read.

The type system already reserves a signal for exactly this. `--font-quote` (Lora) and `--type-quote`
exist, `DESIGN.md` names their one job — *"the referee collection message only"* — and
`lib/design-tokens.test.ts:302` currently asserts the face is used **nowhere**, because the screen
that earns it was drawn and never built. Story 7.1 listed it under Out of scope and named this
story as the one that would build it. This is that story.

**Approach:** Turn each owed-penalty row into the collection card the handoff draws — frame 14,
`design/Referee surface.dc.html:127-142`: the amount with the day and commitments it stems from, an
`Owed` state label, a hairline, then the pre-written message rendered in the serif, then the two
controls that already exist. The serif budget in the token test flips from *none yet* to *exactly
one, in exactly this place*, asserted in both directions like every other budget in that file.

No behaviour changes. `collectionMessage()`, `copyMessage()`, `markCollected()`, their per-row
status vocabulary and their idempotency are Story 4.7's and are not touched. Nothing here reaches
the database.

## Boundaries & Constraints

**Always:**

- **What is shown and what is copied are one string from one call to `collectionMessage()`.** A card
  that displays one sentence and copies a different one is worse than the invisible version it
  replaces, because it would be trusted.
- The message is **displayed, never editable** — no compose field, no textarea, no per-row override.
  This is Story 4.7's own Never boundary restated, and it is why the message can be trusted to
  attribute the demand to the app rather than to the referee.
- **`Owed` keeps its word and stays neutral.** No tint. Story 7.1's Never boundary — the debt figure
  on Today is the only large tinted area in the product — outranks the fact that this card is also
  about money.
- Exactly **one** `var(--font-quote)` claimant in the stylesheet, asserted in both directions: a
  second claimant fails, and so does a missing one.
- Every control at least 44×44. No fixed heights — `min-height`, never `height`.
- The state label is not pressable, and neither control takes a label's silhouette.
- Each card's own status messages survive: `Copied.`, the copy-failure sentence, and a refused
  `Mark Collected` with its reason. **A failed `Mark Collected` still never reloads the list away**
  — 4.7's invariant, and the reason `markStatus`/`markErrors` are keyed by penalty id.
- The card is announced as one thing. The amount, the day, the commitments missed and the message
  belong to the same penalty; a screen-reader user must not meet the sentence detached from the sum
  it names.

**Ask First — both were asked before the work and are answered under Deviations below:**

1. **The size of the amount.** The frame draws it at 26px, Figtree 600, tabular-nums. No token is
   that size: `--type-screen-title` tops out at 21px, and `--type-figure` is Caprasimo at 34→44px
   and is rationed to the debt total and the focus timer. Adding a token means editing `DESIGN.md`,
   which is human-owned (7.1's own Ask First, carried from 1-1b). **Answered: use the existing
   token.**

2. **Whether `Mark Collected` takes the primary fill.** The frame fills it. The frame also draws
   exactly one card. `DESIGN.md` says `button-action` is _"One per screen, maximum"_, and three owed
   penalties would put three filled buttons on the referee's home — the rule exists precisely so a
   screen never asks for three things at once. **Answered: neither control is filled.**

Anything else the frame implies but `DESIGN.md` does not define stays an Ask First and is not
decided in code.

**Never:**

- Never a second serif string anywhere in either surface.
- Never a per-penalty detail route. 4.7's Never boundary: unlike an Appeal, a Penalty needs nothing
  beyond what fits on its own card.
- Never change `collectionMessage()`'s text, who a Penalty is attributed to, when it is owed, or
  when it is written off. No migration, no policy, no RPC.
- Never colour the card because money is owed. Owed is neutral; only a resolved outcome takes a tint.
- Never let the message become an announcement — no `role="status"` on text that was on screen
  before anything happened.
- No animation, and nothing to remove under Reduce Motion.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| One owed penalty | `penalty_current`, one `owed` row | One card: amount, day, commitments missed, `Owed` label, hairline, the message in the serif, `Copy message` + `Mark Collected` | — |
| The two strings agree | Any owed penalty | The rendered message is character-identical to what the clipboard receives | A test asserts both against one `collectionMessage()` call |
| Several owed penalties | Three `owed` rows | Three cards, oldest first, each with its own message naming its own amount and day | — |
| No owed penalties | `owedCount === 0` | No cards, and no empty frame for a section that has nothing in it | — |
| Copy succeeds | Clipboard write resolves | `Copied.` under that card only | — |
| Copy unsupported or denied | Clipboard write rejects, or no API | That card's copy-failure sentence; the message stays on screen and can be read aloud or selected by hand | The visible message is the fallback the clipboard-only version never had |
| Mark Collected refused | Double-click, or a race that already resolved it | The card stays exactly where it is, with its reason attached | 4.7's invariant, unchanged |
| Mark Collected succeeds | RPC resolves | That card leaves the list; the others keep their own copy/mark state | — |
| Screen-reader order | Any owed penalty | Amount and day, then the message, then the controls — the sentence never arrives before the sum it names | — |
| A second serif claimant | Any further `var(--font-quote)` in the stylesheet | Token test fails naming the budget | — |
| The serif claimant disappears | The card is refactored away | Token test fails: the budget is one, asserted in both directions | — |
| A literal colour or a new token | Any hex outside `tokens.css`, or a token `DESIGN.md` does not define | Existing token tests fail | — |
| Web font blocked | Lora fails to load | Falls back to Georgia, then a generic serif — the string stays visibly _not_ interface chrome | `next/font` self-hosts, so this is the offline case |
| User raises OS text size | Any Dynamic Type setting | The card grows and nothing clips; the message wraps | rem sizes, `min-height` |

## Deviations from the handoff frame

Both were asked before the work rather than taken during it. Each is a place a `DESIGN.md` rule beat
a drawing.

1. **The amount is `--type-screen-title` (17→21px), not the frame's 26px.** No token is 26px, and
   `DESIGN.md` is human-owned: code implements the design system and does not extend it. It keeps
   the frame's other two properties — 600 weight and tabular numerals, so two amounts of different
   lengths still align down a column of cards.
2. **Neither control is filled; both stay neutral.** The frame fills `Mark Collected`, but draws one
   card. `button-action` is _"One per screen, maximum"_, and the number of cards is the number of
   debts, so following the drawing would put an unbounded number of primary actions on one screen.

## Out of scope

- **The referee home's empty frame and its progress crumb** — `Nothing for you this week. Hoàng is
  at 4 of 5 today.` The brief calls that crumb the only retention lever the product has over the
  referee, and it is not built: `REFEREE_HOME_COPY.empty` says something else and no read of the
  doer's day exists on this screen. It needs a query and a name the `profile` table does not have.
  That is a story, not a paragraph of this one.
- **The appeal-detail screen's own frames**, and any further handoff frame not named above.
- **Any behaviour change** to settlement, penalties, chains, grace, notifications, or the referee's
  authority.

</frozen-after-approval>

## Verification

Run on the final state.

- `npm test` — 1375 passed, 52 files
- `npm test -- components/referee-home` — 37 passed, five of them new to this story: the message
  is shown and is character-identical to what the clipboard receives; it wears the serif class and
  is not an editable field; it survives a rejected clipboard write; each card carries the neutral
  `Owed` label and its own accessible name; and each debt's message names its own amount and day.
- `npm test -- lib/design-tokens` — 44 passed. The serif budget flipped from *zero, nothing has
  earned it* to *exactly one*, asserted in both directions like the display-face and shadow budgets
  beside it.
- `npm run lint` — clean
- `npm run format:check` — clean
- `npm run build` — succeeds
- No migration, so no SQL suite and no `migrations:check` — correctly, not skipped.

Six existing Story 4.7 tests were rewritten rather than deleted: they asserted the old row shape
(`500.000₫ — TryHackMe` on one line, the day on another) and now assert the card's (the amount as
its own figure, `TryHackMe · Aug 18, 2026` as the sub-line). Every behavioural assertion in that
file — copy, refusal, mark-collected, ordering, dedupe, week-kind inclusion, the day-kind-only RPC
filter — is untouched and still passes, which is the evidence that this changed the container and
not the behaviour.

**Browser pass — partial, and by a substitute route.** The live referee account reads
`0 penalties owed`, so the card cannot be reached on the real surface at all; manufacturing one
means faking a failed day on the live account, which AGENTS.md forbids. It was looked at instead on
a throwaway local route rendering three fabricated debts through the real `collectionMessage`,
`formatDong` and `formatOwedDay`, with the real stylesheet and the real `next/font` faces. The route
was deleted after.

Confirmed by eye: three cards stack and read as separate debts; the amount holds its own against
the sub-line at screen-title size, so the deviation from the frame's 26px costs nothing; the
hairline divides the card where the frame divides it; and Lora italic does read as a spoken sentence
beside Figtree, which was the one claim tests could not make.

**Still not verified:** dark mode, 375px, and Dynamic Type. One screenshot at desktop width in light
mode is what was seen.

**Raised by the look, and decided: the `₫` stays as Lora draws it.** In Lora italic the character
is a stroked italic *đ* and reads as a stray letter mid-sentence — `500.000 ₫` rather than the
`500.000₫` the same string gets in Figtree. It was worth checking because every collection message
the product will ever render contains it, and because the first guess was wrong: this is not a font
fallback. All three faces cover `U+20AB`, and the face drawing it is Lora's own preloaded
latin-ext one.

Accepted by the maintainer on 2026-09-08. Recorded here so it is not "fixed" later by someone who
reads it as a bug: nothing is wrong with the glyph, the sentence stays in one face, and
`collectionMessage()` keeps producing exactly the string `formatDong` gives it — which is also the
string the clipboard receives, and that identity is worth more than the shape of one character.

## Status

`review` on 2026-09-08. Implemented; not yet code-reviewed, and the browser pass above is open.

## Commits

| Commit | Scope |
| --- | --- |
