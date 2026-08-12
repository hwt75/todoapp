# Accessibility review — todoapp UX spines

Against `EXPERIENCE.md` § Accessibility Floor and the `DESIGN.md` color tokens. Verdict: **a real
floor, above the usual standard for a solo project, with one serious hole.**

## Findings

**high — The blocking morning gate has no assistive-technology escape.**
`EXPERIENCE.md` § Interaction Primitives: with a Declaration outstanding, "the app opens onto it and
cannot be used past it", and the notification "persists". An interface that cannot be dismissed and
cannot be navigated past is the classic assistive-technology trap: a VoiceOver rotor that cannot
leave the modal, or a Guided Access / Switch Control session with no exit, turns a design intention
into a locked device.
*Fix:* state that the gate blocks *the app's content*, never the system — the notification is always
dismissable at the OS level, the modal always exposes both controls to VoiceOver as the only two
focusable elements, and the app is always closable. Blocking must be achieved by having nothing else
to do, not by trapping focus.

**medium — No contrast target is stated.**
The floor says "color is never the sole carrier of state" — correct and well applied — but never
names a ratio. Spot-checking the tokens, the pairs hold up: `{colors.action-fill}` #97C459 against
`{colors.action-ink}` #173404 and `{colors.destructive-fill}` #F09595 against
`{colors.destructive-ink}` #501313 both clear AA comfortably, as do the tint/ink pairs in both modes.
The risk is not today's values, it is the next value added without a rule.
*Fix:* state WCAG AA 4.5:1 for text and 3:1 for non-text state indicators as the floor for any new
token pair.

**low — Reduce Motion is unaddressed.**
The product has almost no motion, which is why this is low. The running focus timer and the quota
progress bar are the only animated elements.
*Fix:* one line — the timer updates without animation under Reduce Motion; the progress bar snaps
rather than fills.

**low — The debt figure's VoiceOver label is specified; its emotional weight is not considered.**
The floor states the debt block announces amount and period. On a screen a user opens reluctantly,
the first thing VoiceOver reads aloud is the largest debt figure. Sighted users can look away; a
VoiceOver user cannot skip past it without hearing it.
*Fix:* consider ordering the accessibility elements so today's commitments are read before the debt
block, even though the debt block is visually first. This is a rare case where the accessibility
order should deliberately differ from the visual order — and it happens to be the ordering the design
argued for and the author overruled.

## Checked and sound

- Dynamic Type honoured throughout, including the two large figures — an easy thing to exempt and
  correctly not exempted.
- Every status pill carries a word or number alongside its tint (`12`, `1/3 · 3 days`, `Owed`,
  `Waived`). A user who cannot distinguish the four tint families loses no information at all. This
  is the single best accessibility decision in the spines.
- 44×44pt minimum stated for all controls.
- The referee's web surface is specified as keyboard-navigable with no focus traps, and explicitly
  usable on an unfamiliar machine.
- Dark mode is a first-class token set rather than an inversion, and the button fills are mode-stable
  by construction.
