---
name: todoapp
description: The visual identity for a commitment app where real money and a real friend are at stake — quiet by default, colored only where something is true.
status: final
created: 2026-08-11
updated: 2026-08-11
sources:
  - ../../prds/prd-todoapp-2026-08-11/prd.md
  - ../../prds/prd-todoapp-2026-08-11/addendum.md
colors:
  surface-base: '#FFFFFF'
  surface-base-dark: '#1C1C1E'
  surface-card: '#FFFFFF'
  surface-card-dark: '#2C2C2E'
  surface-sunken: '#F7F6F2'
  surface-sunken-dark: '#242426'
  text-primary: '#2C2C2A'
  text-primary-dark: '#F2F2F0'
  text-secondary: '#5F5E5A'
  text-secondary-dark: '#A0A09A'
  text-muted: '#888780'
  text-muted-dark: '#6E6E68'
  border: '#DCDAD2'
  border-dark: '#3A3A3C'
  border-strong: '#B4B2A9'
  border-strong-dark: '#545456'
  held-tint: '#EAF3DE'
  held-tint-dark: '#173404'
  held-ink: '#3B6D11'
  held-ink-dark: '#C0DD97'
  urgent-tint: '#FAEEDA'
  urgent-tint-dark: '#412402'
  urgent-ink: '#854F0B'
  urgent-ink-dark: '#FAC775'
  failed-tint: '#FCEBEB'
  failed-tint-dark: '#501313'
  failed-ink: '#A32D2D'
  failed-ink-dark: '#F7C1C1'
  action-fill: '#97C459'
  action-ink: '#173404'
  destructive-fill: '#F09595'
  destructive-ink: '#501313'
typography:
  note: 'Fluid. Every size below is the phone floor and never shrinks; the ceiling is reached on a desktop window and no wider composition exists past it'
  screen-title:
    note: 'iOS Title 3, semibold · web 17px/500, growing to 21px'
  figure:
    note: 'iOS Large Title, medium · used only for the debt total and the running timer · web 34px, growing to 44px'
    letterSpacing: '-0.5px'
  body:
    note: 'iOS Body · web 15px/400, growing to 16px'
  label:
    note: 'iOS Subheadline · web 13px/400, growing to 14px'
  caption:
    note: 'iOS Caption 1 · web 11px/400, fixed — growing it would close the gap that makes it read as a caption'
  quoted:
    fontFamily: 'serif'
    note: 'The referee collection message only — nothing else in either surface is serif'
rounded:
  DEFAULT: '8px'
  card: '12px'
  pill: '9999px'
spacing:
  '1': '4px'
  '2': '8px'
  '3': '12px'
  '4': '16px'
  '5': '20px'
  '6': '24px'
  card-pad: '16px'
  row-pad: '11px'
components:
  button-action:
    background: '{colors.action-fill}'
    color: '{colors.action-ink}'
    radius: '{rounded.DEFAULT}'
    note: 'One per card, maximum'
  button-neutral:
    background: 'transparent'
    border: '0.5px solid {colors.border-strong}'
    color: '{colors.text-primary}'
    note: 'Every self-declaration control. Never colored — see Do´s and Don´ts'
  button-destructive:
    background: '{colors.destructive-fill}'
    color: '{colors.destructive-ink}'
  button-bare:
    background: 'transparent'
    color: '{colors.text-secondary}'
  status-pill:
    radius: '{rounded.pill}'
    padding: '2px 8px'
    note: 'Tint + ink pair from one state family; never the button fills'
  figure-block:
    background: '{colors.failed-tint}'
    color: '{colors.failed-ink}'
    radius: '{rounded.card}'
    note: 'The debt total on Today. The only large colored area in the app'
  list-frame:
    background: '{colors.surface-card}'
    border: '0.5px solid {colors.border}'
    radius: '{rounded.card}'
    note: 'One hairline boundary around a whole list. Rows stay hairline-separated inside it'
  screen-head:
    note: 'Screen title and its one navigation control on a single 44px row. Every screen'
  button-quiet:
    background: 'transparent'
    color: '{colors.text-secondary}'
    note: 'Navigation only — back, and the screen switch. Never an action, never a declaration'
  tabbar:
    background: 'transparent'
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

## Colors

Four families, each with exactly one meaning. A color that means two things means nothing.

**Held** (`{colors.held-tint}` / `{colors.held-ink}`) — the commitment held, the chain is alive, the
action moves you forward. This is the only family that reads as *good*, so it must stay scarce.
It marks completed rows, live chain counts, and the single forward action on a screen.

**Urgent** (`{colors.urgent-tint}` / `{colors.urgent-ink}`) — running out of room, but nothing has
failed yet. A weekly quota with fewer days left than sessions owed. A penalty on hold pending the
referee. Urgent is explicitly *not* a failure color: the user must be able to tell "sort this out"
from "you lost this" at a glance, because those two demand opposite emotional responses.

**Failed** (`{colors.failed-tint}` / `{colors.failed-ink}`) — a commitment was missed, or money is
owed. Nothing else. The moment red starts appearing on ordinary states it stops being a signal.

**Neutral** — everything else, including commitments not yet done today. A task untouched at ten in
the morning is not a failure and must never be tinted as one.

The two button fills (`{colors.action-fill}`, `{colors.destructive-fill}`) sit one step darker than
their tint families on purpose. Tints label state; fills invite a press. If they shared a tone the
user would have to read the text to learn whether a green area was a chain badge or a button, which
is the one question an interface should answer before it is read. This also makes the fills
mode-stable — they carry their own background, so they need no dark-mode variant.

## Typography

The platform owns the ramp. iOS uses the system face and Dynamic Type; the referee's web app uses
the system stack. Only two weights exist: regular and medium. Nothing is bold, nothing is uppercase,
and every label is sentence case.

`{typography.figure}` is reserved for exactly two things: the debt total and a running focus timer.
Both are numbers the user is meant to feel rather than read. Granting large type to anything else
would flatten the hierarchy that makes those two land.

`{typography.quoted}` — serif — appears once in the entire product, on the pre-written collection
message in the referee's web app. It marks that text as *something to be said out loud by a person*
rather than interface chrome, which is the whole point of that component.

## Layout & Spacing

Single column, full width, on both surfaces. The iOS app is a list of rows and the referee's web app
is a short stack of cards; neither has enough content to justify a grid, and the referee's surface
is deliberately too sparse for one.

Commitment rows are separated by hairline rules, not cards. Nine tinted rectangles stacked vertically
would read as an alert panel; hairlines let the row's status pill carry the color and keep the page
calm. Cards are reserved for objects that are genuinely separate — an appeal, a collection item, the
debt block.

A list of rows does sit inside one **list-frame**: a single hairline rectangle around the whole
list, with the rows still hairline-separated inside it. This is not a card per row and does not
reintroduce the stack of rectangles the rule above forbids — it is one boundary saying where the
ledger begins and ends, which is the thing the rows were previously floating without.

## Elevation & Depth

Flat. Hairline borders at 0.5px and a single tonal step (`{colors.surface-sunken}`) do all the
layering work. No shadows anywhere. Depth would be decoration here, and decoration is a cost on a
screen the user is already reluctant to open.

`{colors.surface-base}` and `{colors.surface-card}` are the same white in light mode: a card is
told from the page it sits on by its hairline, not by a tone. That leaves exactly one tonal step in
the light palette, and it is spent on `{colors.surface-sunken}` — the quota track, a row under the
cursor, a disabled control, and the utility band at the foot of Today. In dark mode the two stay
apart, because a 0.5px hairline separates far less against `{colors.surface-base-dark}` than it
does against white.

## Layout

One column, `max-width: 34rem`, centred, on every screen. The product is a phone app that happens
to be reachable in a desktop browser; a commitment row stretched across a 1440px window puts the
name at one edge and its status at the other and makes the reader's eye do work that the phone
never asked of it. The column is the same column at every width — there is no second, wider
composition to maintain, and no screen gains a sidebar at some breakpoint.

## Shapes

`{rounded.DEFAULT}` for controls and inset blocks, `{rounded.card}` for cards, `{rounded.pill}` for
status pills only. The pill shape is what distinguishes a state label from a pressable control at a
glance, so nothing pressable is ever pill-shaped.

## Components

**button-action** — filled `{colors.action-fill}`, full width where it is the screen's purpose. At
most one per card, and on the referee's surface at most one card demanding action above the fold.
On the doer's single-purpose screens this reduces to one per screen. If a card appears to need two,
one of them is not an action.

**button-neutral** — outline only. Used for every control by which the user reports on themselves.
See Do's and Don'ts; this is the load-bearing rule of the whole system.

**button-destructive** — filled `{colors.destructive-fill}`. Deleting a commitment, and nothing else.
Rarity is what preserves its force.

**status-pill** — tint background, ink text, from a single state family. Carries the chain count, the
quota position (`1/3 · 3 days`), or the ledger outcome. Never uses a button fill.

**figure-block** — the debt total on Today, `{colors.failed-tint}` behind `{colors.failed-ink}`.
The only large colored area in the product.

**row** — commitment name left, status right, hairline above. The row is not tinted; only its pill is.

**list-frame** — one hairline rectangle, `{rounded.card}`, around a whole list of rows. Rows carry
the horizontal padding rather than the frame, so a pressable row's hover reaches both edges instead
of stopping short inside a gutter.

**screen-head** — the screen title and its one navigation control on a single row, 44px tall. The
control is a **button-quiet**, never a bordered button: a screen that opens with a bordered
rectangle standing alone under its title makes navigation the most prominent object on a surface
whose subject is meant to be prominent instead.

**button-quiet** — no border, no fill, `{colors.text-secondary}`, label-sized. Navigation only:
_Back to today_, and the tab bar's items. It is never an action and never a self-declaration —
those keep **button-neutral**, whose outline is the whole point of the rule below.

**tabbar** — _Today_ / _Ledger_ / _Settings_, hairline above, the current screen marked with
`aria-current` and `{colors.surface-sunken}` rather than a color. It exists because the Ledger had
no entry point on a day with nothing owed: it was reachable only through the debt block, which
renders nothing at zero. It appears on those three screens only — never on the Morning Gate, the
Silence intervention, or any sub-screen reached from Today.

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
one tap from the home screen on exactly the worst day. There, an owed row carries its pill but the row
itself stays neutral; only `Waived` and `Collected` rows are allowed their tint, so the color in that
list belongs to the days that resolved rather than the days that did not. A wall of red is the exact
artifact the product exists to avoid, since the user's documented failure is retreating from the sight
of his own record.

**Never tint a commitment that simply has not happened yet.** Not-yet-done is neutral. It is ten in
the morning.

**Do not use red for emphasis, urgency, or attention.** Red means missed or owed. That is all it may
ever mean.

**Do not add a second serif.** The one serif string is a signal, and a second one deletes it.
