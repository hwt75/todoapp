---
title: 'Story 2.3 — See today, and the row and pill everything else reuses'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '1a8aee1'
review_loop_iteration: 0
story_key: '2-3-see-today-and-the-row-and-pill-everything-else-reuses'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75** — including *What is honest to show today*: neutral `Not yet`
> only, the five-state model built and tested, and no code that produces the other four. Frozen.

## Intent

**Problem:** Opening the app currently shows an install instruction, a push probe and a settings
list. None of that is the product. The author's stated failure mode is opening the app, feeling
reluctant, and not returning — so the first screen has to answer "where do I stand" before he has
read anything, or it becomes another thing not worth opening.

**Approach:** Today, as the launch destination: one row per commitment, name left, status right,
hairline above, and the row itself never tinted. The row and status pill are built here as the
components every later surface reuses, so no later story re-invents what a state looks like. The
accessibility floor is delivered here too and inherited by everything after it.

## What is honest to show today

Settlement does not exist until Story 2.5 and declarations until 2.4, so **the only state a
commitment can truthfully be in today is "not yet"**. This story does not invent the others.

The story itself already applies this reasoning to chains — it defers them to 2.9 rather than
"promising something it cannot yet display" — and the same restraint governs quota position. A
weekly commitment showing `0/3` would be claiming the author has done zero sessions this week, when
the truth is that nothing has been recorded either way. Those are different statements and the second
one is the true one.

**So:** every row today carries a neutral `Not yet` pill, and the row's second line states the
commitment's target as configuration rather than progress. Quota position arrives with settlement.

**What is built beyond that, and why.** The row's *state model* covers all five states
`EXPERIENCE.md` names — not yet, held, missed, held pending appeal, waived — with each one's tint
family and label shape, tested. That is not speculative construction: it is the contract the story
was written to establish, and the mapping from state to colour family is exactly the thing that goes
wrong when three later screens each decide it separately. What is *not* built is any code that
produces those states. Today emits `not yet` and nothing else, and a test asserts that.

## Boundaries & Constraints

**Always:**
- The row is never tinted. Colour lives in the pill and nowhere else, so a list of commitments never
  reads as an alert panel.
- Every pill carries a word or a number. A user who cannot distinguish the four tint families must
  lose no information at all.
- The pill is never interactive and never uses a button fill. Pill radius is reserved to it, which is
  what lets a state label be told from a control before either is read.
- Rows have no fixed height. Dynamic Type must be able to grow them without clipping.

**Ask First:**
- Showing any number derived from events — a chain, a quota position, a total. Those belong to
  settlement, which owns every derived value (AD-8).
- Removing the push probe or the install hint from the app. They are Epic 1 apparatus and still the
  only way to subscribe, but they are no longer what the screen is about.

**Never:**
- No declaration control, no morning gate, no debt block, no chain. Each has its own story.
- No tint on a commitment that simply has not happened yet. It is ten in the morning.
- Do not spend the `figure` or `quoted` type roles. The debt total and the focus timer are the only
  two elements that may ever claim `figure`, and neither is on this screen.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Signed in, commitments exist | Any set | Today is the first thing shown: one row each, name left, pill right | — |
| Nothing configured yet | Zero commitments | A line saying so and a way to add one — never an empty screen | — |
| Not done yet today | Every commitment, today | Neutral `Not yet` pill; row untinted | — |
| A state that cannot occur yet | `held`, `missed`, `waived`, `appealing` | The component renders each correctly, and Today never produces one | A test fails if Today emits anything but `not yet` |
| Money-carrying commitment | `carries_penalty` true | Said in words on the row, not by colour | — |
| VoiceOver | Row focused | Name and state announced as **one** label, not two | — |
| Dynamic Type at largest size | Long commitment name | Row grows; nothing clips or truncates to nothing | — |
| Signed out | No session | Today is not shown at all; sign-in is | — |

</frozen-after-approval>

## Code Map

- `components/commitment-list.tsx` -- currently a settings list doing double duty as a home screen.
  Today takes over the reading surface; that file keeps create, edit and archive.
- `lib/commitment.ts` -- `CADENCE_LABELS`, `KIND_LABELS` and the draft rules already live here; the
  row's description line should reuse them rather than re-spelling a cadence.
- `app/globals.css` -- `.row`, `.pill`, `.pill-held` and `.pill-neutral` were added by Story 2.2 as
  a first pass. This story is where they become the real thing, with a class per state family.
- `app/tokens.css` -- the four state families already exist with dark counterparts and AA-clearing
  contrast, enforced by `lib/design-tokens.test.ts`. No new colour is needed or permitted.
- `app/page.tsx` -- ordering changes: Today first for a signed-in account, Epic 1 apparatus below it.

## Tasks & Acceptance

**Execution:**
- [ ] `lib/commitment-state.ts` -- the five row states, each mapped to its tint family and the shape
  of its label, plus the pure function that decides a commitment's state today -- which returns
  `not yet` for everything until settlement exists, and is the single place that changes when it does.
- [ ] `lib/commitment-state.test.ts` -- every state maps to a family and a non-empty label; the
  today-function returns only `not yet`; no state maps to a button fill.
- [ ] `components/commitment-row.tsx`, `components/status-pill.tsx` -- the two components every later
  surface reuses. The row carries one accessibility label combining name and state.
- [ ] `components/today.tsx` -- the screen: heading, rows, and the empty case.
- [ ] `app/globals.css` -- a pill class per state family, and row rules that grow with type.
- [ ] `app/page.tsx` -- Today first when signed in.

**Acceptance Criteria:**
- Given configured commitments, when the app opens signed in, then Today is the first content and
  each commitment is one row with name left, pill right, hairline above, and no tint on the row.
- Given a commitment not yet done today, then its pill is neutral and says `Not yet`.
- Given any pill, then it carries a word or number, is not interactive, and uses no button fill.
- Given VoiceOver, then each row announces name and state as a single label.
- Given the largest Dynamic Type setting, then no row clips and every control still reaches 44×44.
- Given the component library, then all five states render, and Today produces only `not yet`.

## Design Notes

**Verified in a real browser on 2026-08-19**, signed in as a throwaway account with three
commitments, deleted afterwards with all three tables back to zero. Today is the first heading and
the first content. Each row announces one label — "No fap, not yet done today, missing this costs
money" — rather than making a listener assemble it. Pills read `Not yet`, are `aria-hidden` so the
state is not heard twice, carry the pill radius, and have no pointer cursor. The row's computed
background is transparent in both modes.

At an emulated largest Dynamic Type the rows grew from 66px to 146px and from 89px to 287px with
**nothing clipped, nothing overflowing the viewport, and no control under 44px**. In dark mode all
four families render distinctly with their declared dark tint and ink.

**One misuse found and fixed while verifying.** Story 2.2's settings list was spending a pill on
`costs money`. A pill carries *state* — a chain count, a quota position, a ledger outcome — and that
is configuration. Spending the pill vocabulary on a setting blunts it exactly where it has to be read
at a glance, so the settings list now says it in plain muted text.

**Why the accessibility-order rule is noted but not yet actionable.** `EXPERIENCE.md` requires that on
Today the commitment rows be read before the debt block, deliberately differing from the visual order,
so a VoiceOver user is not made to hear his own debt figure first every morning. There is no debt
block yet. The rule is recorded here so the story that adds it does not have to rediscover it — and
because it is the kind of thing that is trivial to build in and expensive to retrofit.

**Two surfaces, one list.** Today reads; the existing commitment list writes. They are kept apart
because the reading surface is opened every day under reluctance and the writing surface is opened
rarely and deliberately, and a screen that does both well does neither.

## Verification

**Commands:**
- `npm test` -- expected: the state-model tests pass alongside the existing 121
- `npm run build && npm run lint && npm run format:check` -- expected: clean
- Browser: computed styles confirm the row carries no background and the pill carries a tint

**Manual checks (if no CLI):**
- Open signed in: Today first, one row per commitment, all neutral
- Raise the system text size to its largest: rows grow, nothing clips
- Dark mode: pills swap tint families, nothing becomes unreadable
