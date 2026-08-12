# Internal contradiction review — todoapp UX spines

`DESIGN.md` against `EXPERIENCE.md`, and each against itself. Verdict: **three genuine conflicts,
one of them load-bearing.** The two documents agree on the things that matter most — color meaning,
the neutral declaration controls, the no-full-red rule.

## Findings

**high — Geofence configuration lives in two places at once.**
`prd.md` FR-6 states "The Commitment stores its own geofence and dwell minutes; these are not global
settings." `EXPERIENCE.md` § Information Architecture lists Settings as holding "Geofence location and
dwell minutes". Both cannot be true. The per-Commitment form is correct under the Auto-check model —
a second Commitment with a location check would otherwise silently share the gym's geofence.
*Fix:* remove geofence from Settings; it belongs to the Auto-check row in Task setup. Settings keeps
the morning hour, permissions, referee pairing, and grace-day count.

**medium — "One action button per screen" breaks on the referee's surface.**
`DESIGN.md` § Components: "At most one per screen. If a screen appears to need two, one of them is
not an action." The referee's single page can show an appeal card (green *He did it*) and a
collection card simultaneously. Both are actions, both are green, neither is wrong.
*Fix:* scope the rule to the card, not the screen — "at most one per card, and at most one card
demanding action above the fold". The doer's surfaces are unaffected since they are single-purpose.

**medium — The Ledger contradicts the no-full-red rule in spirit.**
`DESIGN.md` forbids a screen going fully red, on the grounds that a wall of red is what makes the
author stop opening the app. The Ledger is a list whose rows are mostly *Owed* pills — a screen that
is structurally almost all red, reached by tapping the debt block on Today. The rule as written
constrains Today but not the surface that will actually look worst during a bad month.
*Fix:* either extend the rule explicitly to the Ledger with a defined treatment (owed rows carry the
pill but not a tinted row; collected and waived rows keep their color), or state that the Ledger is a
deliberate exemption because the author asked to see the debt. Do not leave it unaddressed — it is
the screen most likely to be open on the worst day.

## Checked and consistent

- Color families map one-to-one across both documents; no color carries two meanings.
- Neutral declaration controls are stated identically in `DESIGN.md` Do's and Don'ts and
  `EXPERIENCE.md` Component Patterns, with the same reasoning. This is the system's most important
  rule and it does not drift.
- `{typography.figure}` is claimed by exactly two elements in `EXPERIENCE.md`: the debt total and the
  running timer. Matches the DESIGN.md restriction.
- The serif string appears exactly once, on the collection message, in both documents.
- Timeout-resolves-in-the-author's-favor is stated on both surfaces with matching wording.
- `EXPERIENCE.md` § Interaction Primitives ("nothing destructive is one tap; declaring a slip is not
  destructive") is consistent with the button system rather than an exception to it.
