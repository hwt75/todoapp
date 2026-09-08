---
title: 'Story 7.1 — A surface I am less reluctant to open'
type: 'feature'
created: '2026-09-08'
status: 'awaiting-approval'
review_loop_iteration: 0
baseline_commit: 'c9361a0bc358e99583c84115e97a0f45a09432f2'
story_key: '7-1-a-surface-i-am-less-reluctant-to-open'
context:
  - '{project-root}/design_handoff_todoapp/README.md'
  - '{project-root}/design_handoff_todoapp/RULES.md'
  - '{project-root}/design_handoff_todoapp/design/redesign-brief.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-1b-design-tokens.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **NOT APPROVED, AND WRITTEN AFTER THE FACT.** This is the one thing about this file a reader
> must know before anything else in it.
>
> Every other spec in this directory was written before its work and approved before it started.
> This one was written on 2026-09-08 to record work that was already implemented, on branch
> `apply-redesign-handoff` and open as PR #2. It was produced by reading the handoff and the diff,
> not by deciding what to build.
>
> That ordering is a real defect and is recorded as such rather than disguised. What it costs: the
> Intent below cannot have constrained the implementation, because the implementation already
> existed when it was written — so it describes rather than governs, and any place where the two
> agree proves nothing. The Boundaries are the handoff's rules restated, which *are* independent of
> the code; the I/O matrix is what the tests assert, which is not.
>
> The reason it exists at all: `sprint-status.yaml` is the work queue and the attribution source,
> and a design change touching the visual layer of every screen in the product was about to be
> invisible in it. A dangling status entry with no artifact behind it would be worse than this.
>
> Read it, change what is wrong, then mark it approved — after which it does not move without you.
> Until then `status: awaiting-approval` and the story sits at `review`, not `done`.

## Intent

**Problem:** The author's documented failure mode is not "fails a commitment" — it is opening the
app, feeling reluctant, and not coming back for days. The design shipped in Story 1.1 (tokens) took
that seriously in every respect but one: it put the whole product on a white ground with 0.5px black
hairlines, which is the visual language of a form to be filled in. A ledger of one's own failures,
rendered as a spreadsheet, is a screen that costs something to open.

A second problem is functional rather than atmospheric. `urgent` and `failed` were separated by hue
alone. They demand opposite responses — "sort this out" versus "you lost this" — and hue alone does
not carry that distinction at a glance, to anyone, and carries nothing at all to a user who cannot
separate those two hues.

**Approach:** Apply the 2026-09-08 handoff (`design_handoff_todoapp/`) to the token layer and the
stylesheet. The ground becomes a warm cream, hairlines 1px and warm, the radius 16 with a 28px outer
frame, and the type three named faces with one rationed job each. `urgent` gains a silhouette of its
own — outlined, 6px corners, the one label in the product that is not a pill — so it differs from
`failed` in hue *and* shape.

Token **names** do not change; only their values. The handoff sheet uses its own short names
(`--pg`, `--cd`, `--ink2`), and renaming to match would touch every component in the product to say
exactly what it already says. `DESIGN.md` remains the source of truth and moves in the same commit
as the stylesheet, because the parity test parses both.

## Boundaries & Constraints

These are `design_handoff_todoapp/RULES.md` restated. They are behavioural, not aesthetic, and they
outrank consistency and taste both.

**Always:**
- Four state meanings, one meaning each: **held** (the chain is alive), **urgent** (running out of
  room, nothing lost yet), **failed** (missed, or money owed), **neutral** (everything else,
  including not done yet).
- Urgent must be separable from failed *before the words are read* — a different hue **and** a
  different silhouette.
- Colour is never the only carrier of state. Every label also carries a word or a number.
- Every control is at least 44×44. Where a design measurement and this rule disagree, this rule
  wins and the deviation is recorded.
- No row has a fixed height, including the two large figures. `min-height`, never `height`.
- On Today, the commitment rows are announced *before* the debt figure, though the figure is drawn
  first. A sighted reader may skip the number; a screen-reader user may not.

**Ask First:**
- Adding, renaming or re-valuing any token that `DESIGN.md` does not define. The design system is a
  human-owned artifact; code implements it and does not extend it. (Carried unchanged from 1-1b.)
- Any deviation from a handoff frame. Three were taken here and are listed under Deviations below.

**Never:**
- Never colour the two self-declaration controls. `It held` and `I slipped` are identical: same
  neutral, no default selection, no confirmation step. Nothing in this system can detect a lie, so
  the cheap answer must never also be the attractive one. This outranks every consistency argument
  that will be made against it.
- Never let a screen go fully red, the Ledger included. An `Owed` row keeps its label and stays
  neutral; only `Collected` and `Waived` take a tint. The debt figure is the only large tinted area
  in the product.
- Never colour a commitment for merely not having happened yet.
- Never use red for emphasis, urgency or attention. Red means missed or owed.
- Never make a status label pressable, and never give a control a label's silhouette.
- At most one primary action per screen.
- No animation. The timer updates as text; the quota track is a static fill. Under Reduce Motion
  nothing changes, because there was nothing to remove.

## Three rules the previous design stated that are now false

Each was enforced by a test. The tests were rewritten to enforce the new rule rather than deleted,
which is the only reason this is a design change and not a loosening.

| Was | Is | Why |
|---|---|---|
| No shadow anywhere | Exactly one shadow, in exactly two places | The tab bar and the blocking declaration are literally a layer above the page. The shadow says that, not "this matters more". A third claimant fails the suite; so does a missing one. |
| The button fills are mode-stable and carry no dark variant | The one fill is declared and measured in both modes | A single fill holding contrast on cream *and* on a warm near-black does not exist. Pretending otherwise loses contrast in whichever mode it was not chosen for. 6.46:1 light, 8.94:1 dark. |
| `destructive-fill` / `destructive-ink` exist | There is no destructive fill at all | The one destructive action in the product should read as a warning, not as a second primary action wearing red. Deleting a commitment is now outlined in the failed family. |

The referee's verdict pair changed with them: **both** controls are now coloured. Rule 4 of the
handoff permits it — he is ruling on someone else, not confessing — and previously only one of the
two was filled, which read as a recommendation on a screen that must not make one.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Light mode | No `prefers-color-scheme`, or `light` | Cream page, card one shade lighter, 1px warm hairlines | — |
| Dark mode | `prefers-color-scheme: dark` | A declared warm near-black set, not an inversion; every family has its own dark tint | A token with no dark counterpart fails the suite, not the eye |
| Urgent beside failed | Both labels on one screen | Different hue and different shape: urgent outlined at 6px, failed a filled pill | A `.pill-urgent` that resolves to `--radius-pill` fails the suite |
| A token drifts from DESIGN.md | Value edited in one place only | Test fails naming the token and both values | — |
| A new pair below AA | Any tint/ink or fill/ink pair, either mode | Test fails naming the pair and its measured ratio | — |
| A third shadow appears | Any `box-shadow` outside `.tabbar` / `.declaration` | Test fails: the budget is two, asserted in both directions | — |
| A third display-face claimant | Any `var(--font-display)` beyond wordmark, debt figure, timer | Test fails: the budget is three, asserted in both directions | — |
| A second serif string | Any `var(--font-quote)` in the stylesheet | Test fails. The referee's collection message is designed but not built; nothing has earned the serif yet | — |
| A literal colour in the stylesheet | Any hex outside `tokens.css` | Test fails | — |
| A web font fails to load | No network, or Google Fonts blocked | Each face falls back to a real stack; the screen stays readable | `next/font` self-hosts at build time, so this is the offline case, not the third-party one |
| User raises OS text size | Any Dynamic Type setting | Rows and both large figures grow; nothing clips | Sizes are rem and heights are `min-height` |

## Deviations from the handoff frames

Recorded rather than silently taken. Each is a place a rule beat a drawing.

1. **The brand bar shows the account's email, not a first name.** The frames write *Nam*. `profile`
   has no name column, and adding one is a migration — out of scope for a change to the visual
   layer. A real email beats a placeholder that is right about nobody.
2. **The brand bar is 45px, not 44px.** `Sign out` is a real control, so the 44×44 touch-target
   floor sets the content height and the hairline adds the 45th pixel. The Always rule above beats
   the measurement.
3. **The quota track fills with `--text-secondary`, not ochre.** The Today and Focus frames use
   secondary ink; only the style page's isolated example uses the urgent colour. Following the
   screens also avoids spending a state colour on a running total that settlement has not ruled on.

## Out of scope

- **The referee's collection message.** The one Lora-italic string in the product. That screen does
  not exist in the code — only in the frames — so the face is tokenised and the "no second serif"
  test still holds until the story that builds it.
- **The referee brand bar itself**, which is attributed to `4-5-the-referee-has-his-own-way-in`:
  it is that story's missing way back out, not part of the visual system.
- **Any behaviour change to settlement, penalties, chains, grace, notifications or the referee's
  authority.** Nothing in this story reaches the database.

</frozen-after-approval>

## Verification

Run on the final state, and each commit was run against the full suite independently so the history
bisects.

- `npm test` — 1365 passed, 52 files
- `npm run lint` — clean
- `npm run format:check` — clean
- `npm run build` — succeeds
- Browser, both surfaces, at 375px and 1280px, light and dark. Layout claims were measured in the
  DOM rather than eyeballed: the brand bar spans the viewport with no horizontal overflow, and the
  content column stays 544px and centred beneath it.

CI on PR #2, all green: `check` (lint, suite, build), `db-tests`, and the Vercel build. The
Supabase preview branch was skipped, correctly — this story carries no migration.

**Not verified, and not claimable from here:** PWA installation, the new app icon as iOS renders it
on a home screen, and push delivery. All three need the deployed HTTPS app on a real device
(AGENTS.md, Verification). The icon is the one worth attention — it changed from a flat placeholder
fill to the supplied mark, and the handoff itself notes that at 30pt the mark's inner wording stops
resolving.

The Vercel preview deployment was reachable but sits behind Vercel Deployment Protection, so even
the browser-level checks could not be repeated against the deployed build — only against the local
dev server. **This story was marked `done` without those three device checks having been run.**
Story 6.6 closed the other way round (`c9361a0`, "the device checks pass"), so this is a departure
from how the previous epic closed, and it is written here rather than left to be discovered.

## Status

`done` on 2026-09-08, on the maintainer's instruction, after PR #2 merged as `97394c3` — a merge
commit, so all four commits survive and the history still bisects.

The spec above remains `awaiting-approval`. A merged story with an unapproved spec is not a
contradiction so much as an accurate record: the maintainer accepted the code, and has not yet
read the intent that was written after it. Marking the frontmatter `approved` would be forging an
approval nobody gave, which is the one thing that would make this file worse than useless.

## Commits

| Commit | Scope |
|---|---|
| `5d02067` | `chore:` — vendors the handoff. `prebuild` reads its logo, so the icons cannot be regenerated from a clean clone without it. |
| `9269b51` | `style:` — the token layer, the stylesheet, the icon generator, DESIGN.md. |
| `d9c8072` | `feat(4-5-…)` — the referee's brand bar and its way out. Attributed to 4-5, not here. |

The first two carry no scope because this story did not exist when they were written. Adding it
retroactively does not license rewriting their subjects: they are pushed and under review, and a
force-push to make history claim a story key invented afterwards would be worse than the gap.
