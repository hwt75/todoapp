---
title: 'Story 1.1 (tokens) — The design tokens everything else is built from'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: 'db2a9f5'
review_loop_iteration: 0
story_key: '1-1-an-installable-shell-and-the-tokens-everything-else-is-built'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75.** Frozen from here — it does not move without a recorded renegotiation.
>
> _Originally drafted unapproved:_ Epic 1's retrospective found that spec
> 1.2's frozen Intent was rewritten with no recorded renegotiation (F3), so this one starts
> explicitly unapproved and `status: awaiting-approval`. Read it, change what is wrong, then mark it
> approved — after which it does not move without you.

## Intent

**Problem:** The second half of Story 1.1. `DESIGN.md` defines four colour families, a typography
ramp with two rationed roles, three radii and a spacing scale — and none of it exists in code. The
shell shipped deliberately unstyled so that a negative push result would cost no design work. Push is
now proven (`story-1-2-findings.md`), so the insurance has expired and the layer is owed. Epic 2's
every screen is built from these values, and a screen built before them would hard-code what they are
supposed to name.

**Approach:** Land the token layer as CSS custom properties and nothing else — no components, no
screens, no visual redesign of the existing page beyond adopting base text and surface colours. The
values come from `DESIGN.md`'s frontmatter, which stays the single source of truth; a test parses
both and fails when they drift. Structural rules that a stylesheet cannot enforce on its own — every
state family carries a dark counterpart, the button fills carry none, contrast clears AA — are
enforced by tests rather than by review.

## Boundaries & Constraints

**Always:**
- Every colour, radius and spacing value in the product resolves to a named token. A literal hex,
  px radius or ad-hoc spacing value outside the token file is a defect.
- Dark mode is a first-class token set, not a computed inversion, exactly as `DESIGN.md` defines it.
- Any new token pair clears WCAG AA — 4.5:1 for text, 3:1 for non-text state indicators. This is the
  accessibility review's stated fix for its `medium` finding, and it applies to pairs added later,
  not only to today's.

**Ask First:**
- Adding, renaming or re-valuing any token that `DESIGN.md` does not already define. The design
  system is a human-owned artifact; code implements it and does not extend it.
- Introducing a CSS framework or utility library.

**Never:**
- No components, no screens, no layout work. This story ends at the values. `button-action`,
  `status-pill`, `row` and the rest are defined in `DESIGN.md` and built when a screen needs them.
- No new colours, and no shadows. Elevation is 0.5px hairlines and one tonal step.
- Do not spend the rationed roles. `figure` may be claimed by exactly two elements in the finished
  product and `quoted` by exactly one string; neither is one of them here.
- Do not tint anything on the existing page. It is an install instruction, not a state.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Light mode | No `prefers-color-scheme`, or `light` | Base surface, primary text, hairline borders resolve to the light set | — |
| Dark mode | `prefers-color-scheme: dark` | Every surface, text and state token swaps to its `-dark` counterpart | A family missing a dark counterpart fails the suite, not the eye |
| Button fills in either mode | `action-fill`, `destructive-fill` | Identical in both modes — they carry their own background | A dark variant for either is a defect: it would break mode-stability |
| A token drifts from DESIGN.md | Value edited in one place only | Test fails naming the token and both values | — |
| A new pair below AA | Any tint/ink or fill/ink pair | Test fails naming the pair and its measured ratio | — |
| Dynamic Type | iOS text size raised | Type scales; nothing is pinned in px that should scale | — |

</frozen-after-approval>

## Code Map

- `_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md` -- read-only, and the
  source of every value. Frontmatter carries `colors`, `typography`, `rounded`, `spacing`.
- `app/layout.tsx:32` -- holds `INSTALL_HINT_VISIBILITY`, an inline `<style>` already justified as
  mechanism. The token stylesheet is imported here; leave that rule where it is.
- `app/page.tsx` -- adopts base text and surface colour only. Do not restructure; Story 1.2 already
  extended it once and it exists to be replaced by Epic 2's Today screen.
- `lib/install-state.ts`, `lib/push-payload.ts` -- the precedent for this story's shape: a rule
  extracted into a pure module and tested, rather than left where only a device can exercise it.

## Tasks & Acceptance

**Execution:**
- [ ] `app/tokens.css` -- every `DESIGN.md` colour, radius and spacing value as CSS custom properties
  under `:root`, with the dark set under `prefers-color-scheme: dark` -- this file is the token layer;
  everything else in this story exists to keep it honest.
- [ ] `app/globals.css` -- base element styles that consume the tokens and nothing else: page surface,
  body text, the 0.5px hairline rule, and the system font stack -- so the existing page stops being
  browser-default without becoming designed.
- [ ] `app/layout.tsx` -- import the stylesheets -- one line; the existing inline rule stays.
- [ ] `lib/design-tokens.ts` -- parse `app/tokens.css` into a typed map, and expose the contrast
  helper -- gives the tests something to assert against without a browser.
- [ ] `lib/design-tokens.test.ts` -- assert parity with `DESIGN.md`, AA contrast for every pair, a
  dark counterpart for every state family, no dark variant for either fill, and no shadow declaration
  anywhere -- these are the rules a stylesheet cannot state about itself.

**Acceptance Criteria:**
- Given `DESIGN.md` defines a colour, radius or spacing value, when the suite runs, then a token of
  the same name carries the same value, and a mismatch fails naming both.
- Given any tint/ink or fill/ink pair, when contrast is measured, then it is at least 4.5:1.
- Given each of held, urgent, failed and the surface and text families, then a `-dark` counterpart
  exists; and given `action-fill` or `destructive-fill`, then no `-dark` counterpart exists.
- Given the page is rendered in dark mode, then its surface and text come from the dark set with no
  literal colour anywhere in the markup.
- Given the whole stylesheet, then it declares no `box-shadow`.

## Design Notes

**Why the values are not duplicated into TypeScript.** The obvious alternative is a token module in
`lib/` that the CSS is generated from. It was rejected: CSS custom properties are the native form for
this, they cascade into dark mode without a runtime, and generating them would put a build step
between the designer's file and the browser. Instead `DESIGN.md` stays the source, `app/tokens.css`
is the implementation, and a test holds them together. Drift is caught by the suite rather than
prevented by indirection.

**Why the existing page is barely touched.** It is an install instruction that Epic 2 replaces. Making
it look designed would spend effort on a screen with a known expiry, and would tempt component work
this story forbids. It adopts the surface and text colours so the shell stops looking broken, and
stops there.

**What this story deliberately leaves for Epic 2.** Every component in `DESIGN.md` § Components. They
are specified but not built, because a component built without a screen to sit in gets its API from
imagination. The one rule worth restating when they are: **never colour a self-declaration control** —
`DESIGN.md` calls it the load-bearing rule of the whole system, and it outranks consistency.

## Verification

**Commands:**
- `npm test` -- expected: the new token assertions pass alongside the existing 31
- `npm run build` -- expected: clean build, stylesheets emitted
- `npm run lint && npm run format:check` -- expected: clean
- `grep -rnE "#[0-9a-fA-F]{6}" app components lib --include=*.tsx --include=*.ts` -- expected: no
  matches outside `tokens.css`

**Manual checks (if no CLI):**
- The deployed page in light mode: warm base surface, dark text, no browser-default blue
- The same page with the system switched to dark: surface and text swap, nothing unreadable
- Dynamic Type raised on the phone: text scales
