---
title: 'Story 3.5 — The loudest thing on the phone'
type: 'feature'
created: '2026-08-22'
status: 'approved'
baseline_commit: '0c4e8fe6'
review_loop_iteration: 0
story_key: '3-5-the-loudest-thing-on-the-phone'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-3-a-weekly-quota-that-counts-down.md'
  - '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-22 by hwt75.** D2's second-slot offset confirmed as `morning_hour + 12h`
> (no fixed evening hour). Frozen from here — it does not move without a recorded renegotiation.
>
> Stamped in its own commit, before any implementation, as every Epic 3 story before it (retro P2b).

## Intent

**Problem:** Story 3.3 built `weekly_quota_progress` and the Today pill that reads it — the author
can see a Weekly Quota commitment's position if he opens the app. But `epics.md`'s own acceptance
criterion for Story 3.3 ("**When** reminders are generated, **Then** their frequency and urgency
increase, per FR-4") was split out at authoring time and never built: no cron job ever pushes
anything for a Weekly Quota commitment. A quota that only speaks when looked at can be forgotten
past the point where a normal week's pace could still recover it — exactly the silent failure mode
FR-4 exists to prevent, and the one every other cadence in this product already has (the morning
gate, the daily hours prompt) except this one.

**Approach:** A third independent reminder pipeline, alongside `enqueue_gate_reminders` and
`enqueue_focus_prompts` — same shape (a `security definer` function, one `outbox_enqueue` call per
qualifying commitment, dedupe key carries account/commitment/day/slot, its own `cron.schedule`),
reading `weekly_quota_progress` (AD-8: the one counting rule, not re-derived here) rather than
querying `declaration` directly. Escalation is keyed on **slack = days_remaining − sessions_remaining**
(`sessions_remaining = target − held`), the design already carried forward from the spec this was
split from (`deferred-work.md`, entry sourced from `spec-3-3`):

- **slack > 0** — silent. The week has more days left than sessions still owed; nagging here is the
  exact failure mode UX-DR1 warns about (a Tuesday miss must not read as a Friday failure).
- **slack = 0** — one push a day. Every remaining day is now load-bearing; this is KF-6's Thursday
  ("2 gym sessions left, 3 days remaining").
- **slack < 0** — two pushes a day. The pace has already slipped past what's recoverable one day at
  a time; this is KF-6's Saturday ("one left and one day remaining, it is the loudest thing on the
  phone").

No reminder ever states failure — FR-2 is explicit that a Weekly Quota commitment cannot fail
mid-week, and Week Close (3.4) is the only place a verdict is written. This story only decides
*whether and how often* to say something; the words say position and time, never a miss.

## Decisions

### D1. Escalation is computed from `weekly_quota_progress` directly, not stored

`slack` is `days_remaining − (target − held)`, both already columns/derivable on
`weekly_quota_progress` — cheap to recompute every pass, and computing it live means it can never
drift from what the pill itself shows (the same discipline AD-8 already requires between this view
and `settle_week`). No new column, no new table.

### D2. Slot count is 2, not escalating attempt-count-per-tier

`enqueue_gate_reminders`/`enqueue_focus_prompts` use a slot count capped by hours since a fixed
start hour. This pipeline instead runs on a fixed two-slot clock: **slot 0 at the account's own
`morning_hour`** (the hour already used for every other daily prompt in this product — no new
per-account setting) and **slot 1 twelve hours later** (`(morning_hour + 12) mod 24`), reachable only
when `slack < 0`. `slack = 0` gets slot 0 only; `slack > 0` gets neither. This keeps the "once daily /
twice daily" language literal rather than translating it into an hourly-attempt budget the design
never asked for. **Confirmed 2026-08-22:** `morning_hour + 12h`, not a fixed wall-clock hour — the
second slot stays anchored to the account's own morning hour rather than an absolute time.

### D3. The body must self-date, same gap Story 3.4 found for `week_summary_body`

KF-6's literal copy — "2 gym sessions left, 3 days remaining" — matches neither
`push_body_is_sendable`'s clock-time nor weekday check, exactly the trap 3.4's `week_summary_body`
already hit and fixed by naming the weekday. Proposed body, added to `EXPERIENCE.md` before use
(UX-DR26): `"<held> of <target>, <days_remaining> day(s) left this week, as of <weekday>
<HH:MM>."` — e.g. *"1 of 3, 3 days left this week, as of Thursday 07:30."* for the once-daily tier,
identical shape for the twice-daily tier (the second push differs only in its slot's clock time).
Singular/plural on "day(s)" follows the existing `commitment`/`commitments` pattern in
`enqueue_gate_reminders`.

### D4. Dedupe key carries the slot, not the tier

`weekly-<account>-<commitment>-<week_start>-<slot>` (`slot` 0 or 1), mirroring
`focus-<account>-<commitment>-<today>-<slot>` from 3.2. Keying on slot rather than on
silent/once/twice means a commitment crossing from `slack = 0` to `slack < 0` mid-week (or back, if
a `held` declaration lands late within 2.7's window) never collides with or skips a key it already
used — each slot's row is independent of which tier put it there.

### D5. Reads `weekly_quota_progress`, which already excludes `archived_at`; no new exclusion needed

The view's own `where c.archived_at is null` (3.3) means an archived commitment simply does not
appear in the loop — no separate check to write or forget, unlike `enqueue_gate_reminders`'s
day-scoped archival check (that one has to allow a commitment archived *after* today; this one has
no such case since the view is always "as of now").

### D6. No explicit guard against a just-settled week — the view already recomputes past it

Traced directly from `20260820130000_the_week_counts_its_own_days.sql`: `weekly_quota_progress`
derives `week_start` fresh from *today*, every read (`t.d - ((extract(isodow from t.d) -
week_start_day + 7) % 7)`) — it is never joined to `settlement` and never reads a stored period. The
moment the calendar rolls into a new week, the view's `week_start` advances with it and every column
(`held`, `days_remaining`) recomputes against the new week, whether or not `settle_week` has run yet
for the one that just ended. `settle_week` itself only runs at `p_period + 8` (3.4's own guard) —
strictly after the week it judges has already rolled over in wall-clock terms — so by the time it
judges period P, this pipeline is already reading period P+1's fresh numbers for that commitment.
No explicit `continue when days_remaining = 0 and already-settled` is needed; the two pipelines
never observe the same period at the same time by construction.

## Boundaries & Constraints

**Always:**
- Reads `weekly_quota_progress` for `target`/`held`/`days_remaining` — never re-derives the counting
  rule inline (AD-8, matching `settle_week`'s own reuse of `weekly_held_count`).
- Every enqueue checks `push_body_is_sendable(body)` before calling `outbox_enqueue` and skips (not
  raises on) a commitment whose name poisons the body — the exact defect Story 3.2's own review
  found and fixed, in the exact same shape here (D3, `continue when not
  push_body_is_sendable(body)`).
- No reminder ever uses the word "miss," "fail," or "failed," and no reminder is sent once
  `slack < 0` crosses into the week actually being over (`days_remaining = 0` and the day has
  fully passed) — that boundary belongs to `settle_week` (3.4), not this pipeline.
- New copy is added to `EXPERIENCE.md` before it is used in a body (UX-DR26), same as every prior
  Epic 3 story.

**Ask First:**
- Any change to `weekly_quota_progress`'s own columns or `week_days_remaining`'s signature.

**Never:**
- No new column on `commitment` or new table — `slack` is computed, not stored (D1).
- No change to `weekly_quota_progress`, `weekly_held_count`, or `settle_week` — this story only
  reads what 3.3/3.4 already built.
- Does not touch the Today pill (`components/today.tsx`) or its urgency-color logic — that shipped
  in 3.3 and is out of scope here.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Comfortable | `slack > 0` | No push this pass | — |
| Tightening | `slack = 0`, local hour = `morning_hour` | One push, slot 0, states held/target/days-left | — |
| Overdue | `slack < 0`, local hour = `morning_hour` | Push, slot 0 | — |
| Overdue, evening | `slack < 0`, local hour = `morning_hour + 12` | A second push, slot 1, same commitment | — |
| Already sent this slot | Cron re-runs within the same hour | No second row — dedupe key already claimed (D4) | — |
| Poisoned commitment name | `push_body_is_sendable` refuses the composed body | That commitment is skipped; every other qualifying commitment/account this pass still enqueues (Story 3.2's fix, same shape) | — |
| Week rolls over | Calendar crosses into a new week before `settle_week` has judged the last one | The view's `week_start`/`days_remaining`/`held` already recompute against the new week (D6) — this pipeline reads only ever-current numbers, never a just-judged period | — |
| Target already met | `held >= target` | No push — `slack` computed from `target − held`, so this reads as maximally slack, not zero | — |

## Code Map

- `supabase/migrations/` — new migration, `weekly_quota_reminder_slack_is_the_trigger` (or similar):
  `enqueue_weekly_quota_reminders()`, reading `weekly_quota_progress`, `profile.morning_hour`.
- `_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md` — the reminder
  body template, added beside KF-6 (D3), per UX-DR26.
- `supabase/tests/3-5-weekly-quota-reminder.sql` — new file, added to `supabase/tests/README.md`'s
  manifest table (the gap Story 3.1 originally shipped without one, per that story's own note).
- Precedent to mirror directly: `supabase/migrations/20260819210000_gate_reminder.sql`
  (`enqueue_gate_reminders`, the slot/dedupe/outbox shape) and
  `supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql`
  (`enqueue_focus_prompts`, the `push_body_is_sendable` guard, D3's precedent).

## Tasks & Acceptance

**Execution:**
- [ ] `EXPERIENCE.md` — add the reminder body template beside KF-6, per UX-DR26 (D3).
- [ ] Migration — `enqueue_weekly_quota_reminders()`: loop `weekly_quota_progress` joined to
  `profile` for `morning_hour`, compute `slack`, gate on local hour matching slot 0 or (if
  `slack < 0`) slot 1, build the self-dating body, `continue when not
  push_body_is_sendable(body)`, `outbox_enqueue` with the D4 dedupe key.
- [ ] Migration — `cron.schedule('weekly-quota-reminders', '35 * * * *', ...)`, the one remaining
  offset in the existing 05/15/25/35/45 rotation.
- [ ] `supabase/tests/3-5-weekly-quota-reminder.sql` — silent at `slack > 0`; one push at
  `slack = 0`; two pushes across both slots at `slack < 0`; dedupe holds across a repeated cron
  pass within the same slot; a poisoned commitment name is skipped and a second account/commitment
  in the same pass still enqueues (Story 3.2's own proof, repeated here).
- [ ] `supabase/tests/README.md` — add this file to the manifest table.

**Acceptance Criteria:**
- Given a Weekly Quota commitment with `slack > 0`, when the reminder pass runs, then nothing is
  enqueued for it, per FR-4 and UX-DR1 (a mid-week gap must not read as urgent before it is).
- Given `slack = 0` at the account's `morning_hour`, when the pass runs, then exactly one push is
  enqueued naming sessions held, target, and days remaining — never the word "miss" or "fail."
- Given `slack < 0`, when the pass runs at both the morning and evening slot, then two pushes are
  enqueued that day, each independently deduped.
- Given a commitment name that poisons `push_body_is_sendable`, when the pass runs, then that
  commitment is skipped and every other qualifying commitment/account still enqueues in the same
  pass.
- Given the reminder body, when read on a lock screen, then it self-dates with a weekday and clock
  time and states no present-tense claim, per the outbox's own check constraint.

## Design Notes

*(Filled in during implementation.)*

## Verification

**Commands:**
- `npm test` — expected: clean, no regressions.
- `npx supabase db reset` then `psql ... < supabase/tests/3-5-weekly-quota-reminder.sql` — expected:
  `PASS.`
- `npm run migrations:check` — expected: local and remote match after `db push`.

**Manual checks (only the author can do these):**
- With a Weekly Quota commitment at `slack = 0`, wait past `morning_hour` on the installed app and
  confirm a push arrives naming the position, not a generic reminder.
- Confirm the body is fully legible on the lock screen (NFR1), same check Story 2.8 required.

## Open Questions

None — D2 was the only open item and is confirmed above.
