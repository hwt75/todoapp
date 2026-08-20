---
title: 'Story 2.4 — Answer for yesterday'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '71e1995'
review_loop_iteration: 0
story_key: '2-4-answer-for-yesterday'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75, revised after Story 2.4a.** The first draft said half this gate
> was blocked on infrastructure that did not exist. It exists now and has been seen to deliver, so
> that section is replaced rather than left standing as a false constraint. One limitation remains
> and is still named below.

## Intent

**Problem:** The one thing no machine can check is whether the author actually did the thing. Every
Auto-check in v1 is either deferred or, in TryHackMe's case, settled as impossible — so his own word
is not a fallback, it is the mechanism. A question he can scroll past is a question that gets
answered on the days it is easy and skipped on the days it matters.

**Approach:** A declaration is an observation, not a verdict: the author states whether yesterday
held, it is recorded with the instant he tapped, and settlement folds it in later (2.5). The gate
that asks him blocks the app by having nothing else to offer, never by trapping him.

## The gate now has both legs

Story 2.4a built the outbox, its worker and its own `pg_cron` schedule, and a notification has
reached the author's phone with nobody running a command. So this story can build the gate as
`EXPERIENCE.md` designed it rather than as half of it:

- **The push**, enqueued after the configured morning hour for every account with an unanswered
  declaration, re-delivered on a schedule until it is answered. It reaches him at 07:30 when he is
  not thinking about the app.
- **The launch modal**, which is what remains when the push was swiped away.

Neither is relied on alone, which was the whole point of the design and the thing the first draft
could not honour.

**What the push may say.** A reminder is enqueued while a declaration is outstanding and read at a
time the sender cannot know — Story 2.4a's payload rules already forbid a body that describes the
present, and this is the case they were written for. "Yesterday is unanswered as of 07:30" survives
being read at 09:00; "you still have not answered" does not.

**Re-delivery must not become nagging.** The dedupe key carries the day and the delivery slot, so a
morning produces one notification per slot and never a queue of identical ones. Answering stops the
next one; nothing cancels one already accepted by Apple, and it will say the time it was sent.

## What this story still cannot build

**"First phone interaction" is not available to a web app.** FR-9 asks for the prompt at the author's
first phone interaction after a configured hour. A PWA cannot observe phone interaction; it observes
being opened, and it can be pushed to. The move to a web app already closed two of the four
mechanisms once open here, and this is the residue of that. The push is what now covers the case
where he does not open the app — which is the case that matters, and is why 2.4a came first.

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
- [x] `supabase/migrations/<ts>_declaration.sql` -- the `declaration_answer` enum, the `declaration`
  table keyed to owner and commitment with its idempotency key, the tap instant, and the day it
  answers for **derived server-side** by trigger in `Asia/Ho_Chi_Minh`; RLS in the same file; a
  `morning_hour` column on `profile`.
- [x] `lib/declaration.ts` -- which commitments owe a declaration for which day given a set of
  commitments, the morning hour and an instant -- pure, so the boundary rule is tested without a
  clock or a database.
- [x] `lib/declaration.test.ts` -- the day boundary in `Asia/Ho_Chi_Minh` including the hour either
  side of the morning hour, and the rule that nothing is owed before it.
- [x] `lib/offline-queue.ts` + test -- append, flush, and flush-twice-yields-one, with the tap instant
  preserved.
- [x] `components/morning-gate.tsx` -- the blocking surface, two identical neutral controls, and the
  accessibility contract: two focusable elements, no rotor capture, app always closable.
- [x] `supabase/migrations/<ts>_gate_reminder.sql` -- the `pg_cron` job that enqueues a reminder for
  each account with an outstanding declaration after its morning hour, deduped per day and slot so a
  morning produces one notification per slot rather than a queue of identical ones.
- [ ] `components/settings.tsx` -- the morning hour, alongside notification permission state.
- [x] `app/page.tsx` -- the gate takes precedence over Today when a declaration is outstanding.

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
- Given an outstanding declaration and the morning hour passing, then exactly one reminder is
  enqueued per slot, its body states the time it was sent, and answering stops the next one.

## Design Notes

**Verified in a browser and against the live project on 2026-08-19.** With two declarations
outstanding, the gate was the entire screen: exactly **two focusable elements**, both `It held` and
`I slipped` with identical computed background, border, weight, size and padding and neither carrying
a fill class; no `role="dialog"`, no `aria-modal`, no focus trap; and no Today, no install hint, no
push probe rendered behind it. Answering advanced to the next commitment, and the wording changed
with the cadence — "Did No fap hold on 2026-08-18?" for the daily one, "Did you do Gym on
2026-08-18?" for the weekly, because "held" would imply a week FR-2 has not judged yet.

Both answers landed with `for_day` derived by the trigger from the tap instant, the offline queue
emptied itself, and `enqueue_gate_reminders()` returned 0 once the answers existed — answering stops
the next reminder. The reminder itself was checked separately: it enqueued one row keyed
`gate-{owner}-{day}-{slot}`, said "2 commitments are unanswered for 2026-08-18, as of 15:54", counted
2 rather than 3 because the hours-quota commitment is measured rather than declared, and returned 0
on a second call in the same hour.

**Two things the browser found that reading would not have.** The push probe and the install hint
were still rendered while the gate was up, so the gate was blocking without offering nothing —
`page.tsx` now returns the gate as the whole screen rather than rendering it alongside. And the first
attempt to set `morning_hour = 0` to "always open the gate" enqueued nothing, which was the slot cap
working correctly and my test setup being wrong.

**One wrinkle left for Story 2.5.** After answering, Today still shows `Not yet` for the commitment
just declared. That is honest — settlement has not run, and Story 2.3 deliberately refuses to display
a state nothing computed — but it will read as the answer having been ignored until 2.5 closes the
day. Worth doing soon rather than eventually.

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

**Not built, and unticked above** (added 2026-08-20, after the Epic 2 retrospective):
`components/settings.tsx` — the morning hour, alongside notification permission state. It is a
declared acceptance criterion of this story (`epics.md` Story 2.4, per UX-DR17) and it was
neither built nor recorded as dropped, which is how it went unnoticed until a retrospective read
the epic against the tree. The back end is ready: `morning_hour` is `not null default 7` with a
`between 0 and 23` check and a column grant to `authenticated`, and `supabase/tests/
2-1-roles-and-rls.sql` now drives a session setting it. There is simply no way in.

The gap turned out to be larger than one file, so it is **promoted to a story at the front of
Epic 3** rather than carried as a task here: the product has no Settings surface at all, the gate
is pinned at 07:00 with no way to move it, and notification permission is granted only through
Story 1.2's diagnostic push probe. Recorded in `deferred-work.md`.
