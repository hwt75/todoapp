---
name: todoapp
description: The visual identity for a commitment app where real money and a real friend are at stake — quiet by default, colored only where something is true.
status: final
created: 2026-08-11
updated: 2026-09-08
sources:
  - ../../prds/prd-todoapp-2026-08-11/prd.md
  - ../../prds/prd-todoapp-2026-08-11/addendum.md
  - ../../../../design_handoff_todoapp/README.md
  - ../../../../design_handoff_todoapp/RULES.md
colors:
  surface-base: '#F5EAD8'
  surface-base-dark: '#17140F'
  surface-card: '#F9F4ED'
  surface-card-dark: '#211C16'
  surface-sunken: '#EEE7DB'
  surface-sunken-dark: '#262019'
  text-primary: '#201E1D'
  text-primary-dark: '#F2ECE1'
  text-secondary: '#645C50'
  text-secondary-dark: '#B6AB9B'
  text-muted: '#736A5C'
  text-muted-dark: '#8A8072'
  border: '#DCD3C4'
  border-dark: '#37302A'
  border-strong: '#C0B6A5'
  border-strong-dark: '#4C4339'
  held-tint: '#E1EECC'
  held-tint-dark: '#272E1B'
  held-ink: '#3D472B'
  held-ink-dark: '#CCDBB2'
  urgent-tint: '#FBEACD'
  urgent-tint-dark: '#33260F'
  urgent-ink: '#8A5A0A'
  urgent-ink-dark: '#EDC47A'
  failed-tint: '#F7DCDA'
  failed-tint-dark: '#3A1A17'
  failed-ink: '#8E2F2B'
  failed-ink-dark: '#EFABA4'
  neutral-tint: '#EEE7DB'
  neutral-tint-dark: '#262019'
  neutral-ink: '#645C50'
  neutral-ink-dark: '#B6AB9B'
  action-fill: '#8C491A'
  action-fill-dark: '#F6A06B'
  action-ink: '#FFF8EF'
  action-ink-dark: '#1B1207'
typography:
  note: 'Three faces, one job each. Fluid: every size below is the phone floor and never shrinks; the ceiling is reached on a desktop window and no wider composition exists past it'
  display:
    fontFamily: 'Caprasimo'
    note: 'The debt total and the running focus timer, and nothing else in the app. Never a title'
  screen-title:
    fontFamily: 'Figtree'
    note: 'Figtree 600 · web 17px, growing to 21px'
    letterSpacing: '-0.01em'
  figure:
    fontFamily: 'Caprasimo'
    note: 'Used only for the debt total and the running timer · web 34px, growing to 44px'
    letterSpacing: '-0.02em'
  body:
    fontFamily: 'Figtree'
    note: 'Figtree 400 · web 15px, growing to 16px'
  label:
    fontFamily: 'Figtree'
    note: 'Figtree 500 · web 13px, growing to 14px'
  caption:
    fontFamily: 'Figtree'
    note: 'Figtree 400 · web 11px, fixed — growing it would close the gap that makes it read as a caption'
  quoted:
    fontFamily: 'Lora'
    note: 'Lora italic. The referee collection message only — nothing else in either surface is serif'
rounded:
  DEFAULT: '16px'
  card: '16px'
  frame: '28px'
  pill: '9999px'
  urgent: '6px'
spacing:
  '1': '4px'
  '2': '9px'
  '3': '13px'
  '4': '18px'
  '6': '26px'
  '8': '35px'
  card-pad: '18px'
  row-pad-y: '11px'
  row-pad-x: '16px'
components:
  button-action:
    background: '{colors.action-fill}'
    color: '{colors.action-ink}'
    radius: '{rounded.DEFAULT}'
    note: 'One per screen, maximum'
  button-neutral:
    background: '{colors.surface-card}'
    border: '1px solid {colors.border-strong}'
    color: '{colors.text-primary}'
    note: 'Every self-declaration control. Never colored — see Do´s and Don´ts'
  button-destructive:
    background: 'transparent'
    border: '1px solid {colors.failed-ink}'
    color: '{colors.failed-ink}'
    note: 'Outlined, not filled. Deleting a commitment and nothing else'
  button-verdict:
    note: 'The referee only. Uphold is {colors.held-ink} behind {colors.held-tint}; deny is {colors.failed-ink} behind {colors.failed-tint}. No default, no confirmation'
  button-bare:
    background: 'transparent'
    color: '{colors.text-secondary}'
  status-label:
    radius: '{rounded.pill}'
    padding: '5px 11px'
    border: '1px solid the family ink'
    note: 'Tint + ink pair from one state family; never a button fill. Urgent is the exception — see status-label-urgent'
  status-label-urgent:
    radius: '{rounded.urgent}'
    background: 'transparent'
    border: '1.5px solid {colors.urgent-ink}'
    note: 'Outlined, square-ish. A different silhouette so urgent is told from failed before the words are read'
  figure-block:
    background: '{colors.failed-tint}'
    color: '{colors.failed-ink}'
    radius: '{rounded.card}'
    note: 'The debt total on Today. The only large colored area in the app'
  list-frame:
    background: '{colors.surface-card}'
    border: '1px solid {colors.border}'
    radius: '{rounded.card}'
    note: 'One hairline boundary around a whole list. Rows stay hairline-separated inside it'
  screen-head:
    note: 'Screen title and its one navigation control on a single 44px row. Every screen'
  button-quiet:
    background: 'transparent'
    color: '{colors.text-secondary}'
    note: 'Navigation only — back, and the screen switch. Never an action, never a declaration'
  tabbar:
    background: '{colors.surface-card}'
    radius: '{rounded.card}'
    shadow: 'the product´s one shadow'
    note: 'Today / Ledger / Settings. Absent on the Morning Gate and every sub-screen'
---

# DESIGN: todoapp

## Brand & Style

This is a ledger, not a coach's whiteboard. The product takes real money from its user and asks a
friend to come and collect it, so the visual posture is that of something that keeps records
accurately and does not perform enthusiasm about it. No confetti, no medals, no progress rings
filling up. When the user succeeds the app says so once and moves on; when the user fails it says
that once too.

The restraint is not aesthetic preference. The user's established failure mode is opening the app,
feeling reluctant, and not returning for days. Every decorative flourish is a small additional cost
to opening it. So the default state of every surface is quiet, and color is spent only where it
carries information.

One deliberate exception dominates the home screen: the accumulated debt figure is the largest and
most saturated thing in the product. The author chose that knowingly, against advice, and the design
executes it rather than softening it.

The 2026-09-08 revision (handed off in `design_handoff_todoapp/`) changed the ground and the voice
without changing any of that. The page went from white to a warm cream, the hairlines from 0.5px
black to 1px warm, the radius from 8/12 to 16 with a 28px outer frame, and the type from the system
face to three named faces with one job each. The reasoning is the same reasoning: the ground is the
one thing present on every screen, and warmth is the cheapest available reduction in the cost of
opening it. What did not move is the part that carries information — the four state meanings, the
rule against coloring a self-declaration, and the debt figure's dominance.

## Colors

Four families, each with exactly one meaning. A color that means two things means nothing.

**Held** (`{colors.held-tint}` / `{colors.held-ink}`) — the commitment held, the chain is alive, the
action moves you forward. This is the only family that reads as *good*, so it must stay scarce.
It marks completed rows, live chain counts, and the referee's *he did it* verdict.

**Urgent** (`{colors.urgent-tint}` / `{colors.urgent-ink}`) — running out of room, but nothing has
failed yet. A weekly quota with fewer days left than sessions owed. A penalty on hold pending the
referee. Urgent is explicitly *not* a failure color: the user must be able to tell "sort this out"
from "you lost this" at a glance, because those two demand opposite emotional responses. Hue alone
was not carrying that separation, so the urgent label also has its own silhouette — see
**status-label-urgent** below.

**Failed** (`{colors.failed-tint}` / `{colors.failed-ink}`) — a commitment was missed, or money is
owed. Nothing else. The moment red starts appearing on ordinary states it stops being a signal.

**Neutral** (`{colors.neutral-tint}` / `{colors.neutral-ink}`) — everything else, including
commitments not yet done today. A task untouched at ten in the morning is not a failure and must
never be tinted as one.

There is one button fill (`{colors.action-fill}`), and it is not mode-stable. A single fill that
holds its contrast both on cream and on a warm near-black does not exist, and pretending otherwise
costs contrast in whichever mode loses; so the fill and its ink are declared twice, and both pairs
are measured (6.46:1 light, 8.94:1 dark). There is no destructive fill at all — see
**button-destructive**.

## Typography

Three faces, each with exactly one job, self-hosted at build time by `next/font` so nothing is
fetched at runtime and nothing reflows when it arrives.

**Caprasimo** is the display voice and is rationed to two elements in the finished product: the debt
total and a running focus timer. Both are numbers the user is meant to feel rather than read.
Granting the display face to anything else — a title, a chain count, a screen head — would flatten
the hierarchy that makes those two land, and would make a ledger read as a poster.

**Figtree** carries everything else: 600 for screen titles, 500 for labels, 400 for body and
caption. Nothing is bold, nothing is uppercase, and every label is sentence case.

`{typography.quoted}` — Lora italic — appears once in the entire product, on the pre-written
collection message in the referee's web app. It marks that text as *something to be said out loud by
a person* rather than interface chrome, which is the whole point of that component.

The ramp is fluid and stated in rem, so the user's own text-size setting still moves it. No row in
either surface has a fixed height, including the two large figures: `min-height`, never `height`.

## Layout & Spacing

Single column, full width, on both surfaces. The iOS app is a list of rows and the referee's web app
is a short stack of cards; neither has enough content to justify a grid, and the referee's surface
is deliberately too sparse for one.

Commitment rows are separated by hairline rules, not cards. Nine tinted rectangles stacked vertically
would read as an alert panel; hairlines let the row's status label carry the color and keep the page
calm. Cards are reserved for objects that are genuinely separate — an appeal, a collection item, the
debt block.

A list of rows does sit inside one **list-frame**: a single hairline rectangle around the whole
list, with the rows still hairline-separated inside it. This is not a card per row and does not
reintroduce the stack of rectangles the rule above forbids — it is one boundary saying where the
ledger begins and ends, which is the thing the rows were previously floating without.

The spacing scale is the system's 1.10x ramp — 4 · 9 · 13 · 18 · 26 · 35 — with card padding at 18
and rows at 11 / 16. There is no `5` and no `7`: a step invented between two members of a scale is
how a rhythm stops being one.

## Elevation & Depth

Nearly flat. Hairline borders at 1px in the warm border tone, plus a single tonal step
(`{colors.surface-sunken}`), do almost all the layering work.

Exactly one shadow exists, and it is spent in exactly two places: under the tab bar, and under the
blocking morning declaration. Both mark *a layer above the page*, which is literally true of both —
not importance, which is the other reason to raise something and is not a reason this product
accepts. Nothing else in either surface has depth; depth would be decoration, and decoration is a
cost on a screen the user is already reluctant to open.

`{colors.surface-base}` and `{colors.surface-card}` are no longer the same value: a card sits one
shade lighter than the cream page, and the hairline between them is warm rather than grey. That is
what stops a list of rows reading as a spreadsheet. `{colors.surface-sunken}` remains the one tonal
step, spent on the quota track, a row under the cursor, a disabled control, the current tab, and the
utility band at the foot of Today.

## Layout

One column, `max-width: 34rem`, centred, on every screen. The product is a phone app that happens
to be reachable in a desktop browser; a commitment row stretched across a 1440px window puts the
name at one edge and its status at the other and makes the reader's eye do work that the phone
never asked of it. The column is the same column at every width — there is no second, wider
composition to maintain, and no screen gains a sidebar at some breakpoint, including the referee's
1280px desktop.

## Shapes

`{rounded.DEFAULT}` for controls and inset blocks, `{rounded.card}` for cards, `{rounded.frame}` for
the one outer frame (the blocking declaration), `{rounded.pill}` for status labels only. The pill
shape is what distinguishes a state label from a pressable control at a glance, so nothing pressable
is ever pill-shaped — and status labels are now the only fully round thing in the product.

`{rounded.urgent}` is the deliberate exception in the other direction: the urgent label is not a
pill. See **status-label-urgent**.

## Components

**button-action** — filled `{colors.action-fill}`, full width where it is the screen's purpose. At
most one per screen. If a screen appears to need two, one of them is not an action.

**button-neutral** — outline only, on the card surface. Used for every control by which the user
reports on themselves. See Do's and Don'ts; this is the load-bearing rule of the whole system.

**button-destructive** — *outlined* in `{colors.failed-ink}`, filling with `{colors.failed-tint}` on
hover. Deleting a commitment, and nothing else. It is outlined rather than filled because there is
exactly one destructive action in the product and it should read as a warning, not as a second
primary action that happens to be red. Rarity is what preserves its force.

**button-verdict** — the referee's two rulings, and the only pair of controls in the product colored
against each other. *He did it* is `{colors.held-tint}` on `{colors.held-ink}`; *he didn't* is
`{colors.failed-tint}` on `{colors.failed-ink}`. Neither is preselected and neither is confirmed.

**status-label** — tint background, ink text and a 1px ink border, from a single state family.
Carries the chain count, the quota position (`1/3 · 3 days`), or the ledger outcome. Never uses a
button fill, never has an `onClick`, and never takes a pointer cursor.

**status-label-urgent** — the one label that is not a pill: transparent, a 1.5px
`{colors.urgent-ink}` outline, `{rounded.urgent}` corners. Urgent and failed have to be
distinguishable *before* the words are read, and a hue difference alone was not doing it. Now they
differ in hue and in silhouette.

**figure-block** — the debt total on Today, `{colors.failed-tint}` behind `{colors.failed-ink}`, set
in the display face. The only large colored area in the product.

**row** — commitment name left, status right, hairline above, 44px minimum. The row is not tinted;
only its label is.

**list-frame** — one hairline rectangle, `{rounded.card}`, around a whole list of rows. Rows carry
the horizontal padding rather than the frame, so a pressable row's hover reaches both edges instead
of stopping short inside a gutter.

**screen-head** — the screen title and its one navigation control on a single row, 44px tall. The
control is a **button-quiet**, never a bordered button: a screen that opens with a bordered
rectangle standing alone under its title makes navigation the most prominent object on a surface
whose subject is meant to be prominent instead. A head that carries a control also carries a
hairline beneath it, marking where the screen you came into begins; Today has neither.

**button-quiet** — no border, no fill, `{colors.text-secondary}`, label-sized. Navigation only:
_Back to today_, and the tab bar's items. It is never an action and never a self-declaration —
those keep **button-neutral**, whose outline is the whole point of the rule below.

**tabbar** — _Today_ / _Ledger_ / _Settings_, a hairline-framed card on `{colors.surface-card}`
carrying the product's one shadow, the current screen marked with `aria-current` and
`{colors.surface-sunken}` rather than a color. It exists because the Ledger had no entry point on a
day with nothing owed: it was reachable only through the debt block, which renders nothing at zero.
It appears on those three screens only — never on the Morning Gate, the Silence intervention, or any
sub-screen reached from Today.

## Do's and Don'ts

**Never color a self-declaration control.** The morning question's two answers must be visually
identical outline buttons. Tinting the honest answer green and the costly one red taxes telling the
truth — and nothing in the system can detect a lie, so the cheap answer must not also be the
attractive one. A single false declaration destroys the mechanism in a way that losing 500,000 VND
does not. This rule outranks every consistency argument that will be made against it.

**Do color the referee's judgment controls.** He is ruling on someone else, not confessing, so there
is no shame to tax and speed is worth more than symmetry.

**Never let a screen go fully red — including the Ledger.** On the worst possible day, Today keeps its
rows neutral and tints only the debt block. The Ledger needs the rule stated separately because it is
structurally a list of failures and would otherwise be the reddest screen in the product, reached in
one tap from the home screen on exactly the worst day. There, an owed row carries its label but the row
itself stays neutral; only `Waived` and `Collected` rows are allowed their tint, so the color in that
list belongs to the days that resolved rather than the days that did not. A wall of red is the exact
artifact the product exists to avoid, since the user's documented failure is retreating from the sight
of his own record.

**Never tint a commitment that simply has not happened yet.** Not-yet-done is neutral. It is ten in
the morning.

**Do not use red for emphasis, urgency, or attention.** Red means missed or owed. That is all it may
ever mean.

**Do not add a second serif.** The one serif string is a signal, and a second one deletes it. The
same rule now applies to the display face: it is spent on two figures, and a third claimant takes it
from meaning "this is the number" to meaning "this is a number".

**Color is never the only thing carrying state.** Every status label also carries a word or a number
— `12`, `1/3 · 3 days`, `Owed`, `Waived` — so a user who cannot separate the four families loses no
information at all.
