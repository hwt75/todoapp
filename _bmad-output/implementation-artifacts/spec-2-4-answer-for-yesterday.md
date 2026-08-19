---
title: 'Story 2.4 — Answer for yesterday'
type: 'feature'
created: '2026-08-19'
status: 'awaiting-approval'
baseline_commit: '71e1995'
review_loop_iteration: 0
story_key: '2-4-answer-for-yesterday'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **NOT YET APPROVED.** Half of this story's gate needs infrastructure that does not exist, and one
> of its acceptance criteria describes a capability a web app cannot have. Both are named below
> rather than quietly delivered as something smaller. Read *What this story cannot honestly build*
> before the task list.

## Intent

**Problem:** The one thing no machine can check is whether the author actually did the thing. Every
Auto-check in v1 is either deferred or, in TryHackMe's case, settled as impossible — so his own word
is not a fallback, it is the mechanism. A question he can scroll past is a question that gets
answered on the days it is easy and skipped on the days it matters.

**Approach:** A declaration is an observation, not a verdict: the author states whether yesterday
held, it is recorded with the instant he tapped, and settlement folds it in later (2.5). The gate
that asks him blocks the app by having nothing else to offer, never by trapping him.

## What this story cannot honestly build

**1. The push half of the gate needs the outbox, which is deferred.** `EXPERIENCE.md` is explicit
that the gate is *two* mechanisms — a push that re-delivers until answered, plus a launch modal —
and that neither alone is sufficient: the push reaches him at 07:30 when he is not thinking about the
app, and the modal is what remains when the push was swiped away.

Scheduled, repeating delivery requires the transactional outbox, the Edge Function worker and the
`pg_cron` schedule of AD-3, all recorded in `deferred-work.md` and none of them built. Story 1.2
proved the channel with a local CLI precisely so this infrastructure could be built *after* the
channel was known to work — and it now is.

So this story builds the modal half completely and the push half not at all. **The gate is therefore
weaker than designed until the outbox lands**, and that is a real gap rather than a rounding error:
a modal only asks once he opens the app, and not opening the app is the author's documented failure
mode. The proposal is to build the outbox as Story 2.4b immediately after this, before Epic 2 relies
on any notification.

**2. "First phone interaction" is not available to a web app.** FR-9 asks for the prompt at the
author's first phone interaction after a configured hour. A PWA cannot observe phone interaction; it
observes being opened. The move to a web app already closed two of the four mechanisms once open here,
and this is the residue of that. The gate triggers on app open, and the push — once it exists — is
what covers the case where he does not open it.

## Boundaries & Constraints

**Always:**
- The gate blocks **the app, never the device**. The notification stays dismissable at the OS level,
  the app stays closable, and the modal exposes its two controls to VoiceOver as the only focusable
  elements *without capturing the rotor*. This is the accessibility review's one `high` finding, and
  a design intention that becomes a locked device is a defect, not a strong opinion.
- The two answers are **visually identical neutral outline buttons**. No default, no pre-selection,
  no confirmation on either. Tinting the honest answer green and the costly one red taxes telling the
  truth, and nothing in this system can detect a lie. This rule outranks every consistency argument
  that will be made against it.
- Every answer carries a client-generated idempotency key created **at the moment of the tap**, not
  at send time (AD-4), and carries **the instant tapped**, never a date the client derived (AD-6).
- A declaration is an observation. It never writes a verdict, a penalty or a chain — settlement owns
  every derived value (AD-8).

**Ask First:**
- Any wording that makes one answer easier than the other, including button order that implies a
  default.
- Storing the morning hour anywhere other than the author's own row.

**Never:**
- No focus trap, no `aria-modal` without an escape, no disabling the app's close path.
- No settlement, no penalty, no chain, no day-close computation. That is Story 2.5.
- No third answer. "Not sure" is a way out, and silence already has a defined meaning (FR-16).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Outstanding declaration | Yesterday unanswered, after the morning hour | The app opens onto the gate and offers nothing else | Today is not rendered behind it |
| Answer `It held` | Tap | Observation recorded with the tap instant; gate advances | — |
| Answer `I slipped` | Tap | Observation recorded; no extra friction, no confirmation | Adding friction here would tax the truth |
| Answer neither | App closed | Nothing charged, nothing cleared; the open declaration starts counting toward Silence | — |
| Offline | No connectivity at tap | Queued locally with the tap instant, flushed on reconnect | The queued instant is the tap, never the delivery |
| Queue flushed twice | Same key twice | One declaration | The unique key makes the second a no-op |
| Two commitments outstanding | Both unfiled | Asked one at a time, in a stable order | — |
| Commitment archived after the day | Archived yesterday | Still answerable — the day it belongs to predates the archive | — |
| VoiceOver active | Gate showing | Exactly two focusable controls, announced as a question with two answers; the rotor still leaves | A trap here is a failed story |
| Morning hour changed | Settings | Takes effect the next morning, not retroactively | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819150000_commitment.sql` -- the conventions: table and RLS together,
  `search_path` pinned, `with check` on `role_from_table()`, idempotency key unique.
- `lib/commitment-state.ts` -- `held` and `missed` already exist as states with their families. A
  declaration is what will eventually produce them; this story records it, 2.5 acts on it.
- `components/today.tsx` -- what the gate stands in front of.
- `lib/supabase/client.ts` -- the browser client; the offline queue wraps writes through it.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_declaration.sql` -- the `declaration_answer` enum, the `declaration`
  table keyed to owner and commitment with its idempotency key, the tap instant, and the day it
  answers for **derived server-side** by trigger in `Asia/Ho_Chi_Minh`; RLS in the same file; a
  `morning_hour` column on `profile`.
- [ ] `lib/declaration.ts` -- which commitments owe a declaration for which day given a set of
  commitments, the morning hour and an instant -- pure, so the boundary rule is tested without a
  clock or a database.
- [ ] `lib/declaration.test.ts` -- the day boundary in `Asia/Ho_Chi_Minh` including the hour either
  side of the morning hour, and the rule that nothing is owed before it.
- [ ] `lib/offline-queue.ts` + test -- append, flush, and flush-twice-yields-one, with the tap instant
  preserved.
- [ ] `components/morning-gate.tsx` -- the blocking surface, two identical neutral controls, and the
  accessibility contract: two focusable elements, no rotor capture, app always closable.
- [ ] `components/settings.tsx` -- the morning hour, alongside notification permission state.
- [ ] `app/page.tsx` -- the gate takes precedence over Today when a declaration is outstanding.

**Acceptance Criteria:**
- Given an unfiled declaration for yesterday after the morning hour, when the app opens, then the
  gate is what is shown and Today is not reachable behind it.
- Given the gate, then its two controls are the same colour, the same size and the same weight, and
  neither is pre-selected.
- Given VoiceOver, then exactly two elements are focusable within the gate, they announce as a
  question with two answers, and focus can still leave the app.
- Given any answer, then the stored row carries the instant of the tap and a key generated at the
  tap, and the day it answers for was derived by the server.
- Given the same key submitted twice, then one row exists.
- Given no answer, then no penalty, verdict or chain is written by this story at all.

## Design Notes

**Why the day is derived by trigger rather than a generated column.** `timestamptz at time zone
'Asia/Ho_Chi_Minh'` is `STABLE`, not `IMMUTABLE` — timezone rules can change — so Postgres will not
allow it in a stored generated column. A `BEFORE INSERT` trigger does the same job and keeps AD-6's
rule intact: the client sends an instant and never a date.

**Two commitments, one question at a time.** Asking about four commitments in one screen invites
answering them as a batch, and a batch answer is the one most likely to be untrue for at least one of
them. Order is stable so the same commitment is not asked twice.

## Verification

**Commands:**
- `npm test` -- expected: boundary and queue tests pass alongside the existing 154
- `npm run build && npm run lint && npm run format:check` -- expected: clean
- Advisor after applying -- expected: no new lints
- Browser: the gate's two controls have identical computed background, border and font-weight

**Manual checks (if no CLI):**
- With an outstanding declaration, opening the app shows the gate and nothing else
- The two buttons are indistinguishable apart from their words
- Airplane mode: answer, re-enable, confirm exactly one row arrives
