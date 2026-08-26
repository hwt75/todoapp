---
title: 'Story 5.2 — The app notices I have gone quiet'
type: 'feature'
created: '2026-08-26'
status: 'done'
review_loop_iteration: 0
baseline_commit: '16c6eda859ed8e1042bc7d2ea1cc44df0fb73938'
story_key: '5-2-the-app-notices-i-have-gone-quiet'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-16 — after two quiet days the author gets more red (the same nagging
Declaration prompt, again) instead of anything that names the pattern, so the moment he usually
disappears has nothing in it besides his own failures.

**Approach:** Detect a Silence streak (consecutive asked-days with zero Declarations answered)
inline inside the existing hourly reminder pass, mirroring `supersede_expiries()`'s read-a-
source-table-and-fold-in shape. At streak 2, open one append-only `silence_episode` row (a
due/satisfied-at pair, AD-11), enqueue exactly one push through the existing outbox
(`outbox_enqueue`'s own dedupe key is the one-shot mechanism — no separate "already sent" flag
needed), and suppress routine gate-reminder pushes for that owner while the episode stays
unsatisfied. Client-side, `app/page.tsx` gains a third top-level branch — ahead of the existing
Declaration gate — that renders the intervention whenever an unsatisfied episode exists.
`[ASSUMPTION]` "no app interaction" (epic-5-context.md's own Silence definition) has no tracked
signal anywhere in this schema (no session/last-seen table); Silence is operationalized here as
Declaration-silence only, the one signal every AC in this story actually exercises.

## Boundaries & Constraints

**Always:**
- `silence_episode(id, owner_id, started_day date, notified_at timestamptz, satisfied_at
  timestamptz null)`, RLS select-own, no client insert/update. A partial unique index on
  `owner_id where satisfied_at is null` — at most one active episode per account.
- Streak/detect/enqueue logic lives inside `enqueue_gate_reminders()` (or a sibling function it
  calls in the same transaction) — not a new cron. It already loops doer accounts and already
  computes outstanding Declarations per `asked_day`; extend it rather than duplicating that read.
- A streak reaching 2 with no active episode inserts one row (`started_day` = the earlier of the
  two quiet days) and enqueues via `outbox_enqueue(owner, 'silence-' || owner || '-' ||
  started_day, payload)` — the existing `on conflict (dedupe_key) do nothing` is what makes this
  genuinely one-shot; no new "already sent" column.
- While an owner has an active (`satisfied_at is null`) episode, that owner's routine
  gate-reminder pushes are skipped entirely (every slot, every morning) — not only the morning
  the episode opened. The day-summary push (`day_summary`) is unaffected; nothing in FR-16 or its
  AC calls for suppressing it, only "routine notifications... including the outstanding
  Declaration prompt."
- An `after insert on public.declaration` trigger sets `satisfied_at = now()` on any active
  episode for `new.owner_id` — immediate, not fold-in-delayed, since the client (`app/page.tsx`)
  reads this synchronously to decide what to render next.
- Two copy variants (verbatim per UX-DR21, `epic-5-context.md`'s own Requirements section): no
  Declarations outstanding, and Declarations outstanding (names the specific outstanding days).
  Both state Grace Days remaining via the existing `grace_allowance_remaining` view/formatter
  (`lib/grace.ts`'s `formatGraceAllowance`) — never a second computation of that number. Add both
  strings to `EXPERIENCE.md` first (Story 5.1's own deferred finding: copy must originate there
  before landing in a component).
- The intervention's one concrete action, when Declarations are outstanding, opens the existing
  `MorningGate` flow unchanged — answering saves the day and (via the trigger above) ends the
  episode. No parallel declaration-answering UI is built.
- No debt figure, no itemized miss list, no red — reuse the existing `pill`/`row` classes' neutral
  variants, never a new color.

**Ask First:** None — the streak-length-2 trigger and the "Declaration-silence only" reading of
epic-5-context.md's broader definition were both already stated as the epic's own confirmed
requirement or this spec's own flagged assumption above; no other undecided figure exists in this
story (the FR-18 escalation threshold `[ASSUMPTION: four days]` belongs to Story 5.3, out of
scope here).

**Never:**
- No Story 5.3 (Referee escalation) work — no email, no `referee-home.tsx` change. This story only
  opens the episode and ends it; 5.3 reads the same table later.
- No change to `settle_day()`/`settle_due_days()`'s verdict logic — Silence detection is additive,
  reading `declaration` the same way `enqueue_gate_reminders()` already does, never touching
  `expired`/`failed` verdict computation.
- No gating of the Grace Day control behind the intervention — it must stay reachable from the Day
  summary and Ledger exactly as Story 5.1 left it (both files already carry a guard-rail comment
  saying so).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Second quiet morning | 2 consecutive asked-days, zero Declarations answered, no active episode | `silence_episode` opened; one push enqueued | N/A |
| Re-run same hour | Detection re-runs before the next asked-day advances | Same dedupe key → `outbox_enqueue` no-ops; no duplicate row/push | N/A |
| Declaration answered mid-episode | Any Declaration insert while an episode is active | Trigger sets `satisfied_at`; next load renders routine content again | N/A |
| Declarations outstanding when it fires | Episode opens while 1+ Declarations remain unanswered | "Declarations pending" copy variant; action opens `MorningGate` | N/A |
| Nothing outstanding when it fires | Episode opens with all Declarations current, streak from pure inactivity | "No Declarations pending" copy variant; action names one commitment | N/A |
| Routine reminder while episode active | Gate-reminder pass runs for an owner with an unsatisfied episode | That owner's push skipped entirely, any slot | N/A |
| New episode after satisfaction | Prior episode `satisfied_at` set; a later, separate 2-day streak begins | New row opens normally — the partial unique index only blocks a second *active* row | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819210000_gate_reminder.sql:33-99` -- `enqueue_gate_reminders()`, the
  function to extend: per-account loop, existing outstanding-Declaration read, `gate-` dedupe
  pattern to mirror for the new `silence-` key.
- `supabase/migrations/20260819180000_outbox.sql:134-154` -- `outbox_enqueue()`; `on conflict
  (dedupe_key) do nothing` is the one-shot mechanism this story relies on, not a new column.
- `supabase/migrations/20260819200000_declaration.sql:46-100` -- `declaration` table + `for_day`
  derivation trigger; add the new `after insert` satisfaction trigger alongside/after this one.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:58-68,175-235` --
  `declaration_deadline()` (the 48h window this story's timing must land inside) and
  `supersede_expiries()` (the read-only-source-table fold-in shape to mirror for streak detection).
- `supabase/migrations/20260824140000_void_expired_appeals.sql:14-33` -- the guarded-update,
  no-raise, silent-no-op convention every scheduled writer in this codebase follows.
- `supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql:357-370` --
  `grace_allowance_remaining`, read verbatim (not recomputed) for the intervention's own figure.
- `lib/grace.ts:99-110` (`formatGraceAllowance`) -- reuse for the Grace Days sentence; its own
  comment already anticipates this exact call site.
- `app/page.tsx:114-123` -- the existing `gate.owing.length > 0` branch rendering `MorningGate`;
  the new Silence branch sits ahead of or beside this one (implementer's call after reading the
  surrounding routing).
- `components/today.tsx:18-37,85-188` -- `View` union and load effect; **do not** fold the
  Silence state into this file's own `View` type per the investigation -- `app/page.tsx` already
  owns the MorningGate-vs-Today fork, so a third top-level branch belongs there, consistent with
  how the Declaration gate itself is wired, rather than as a fourth `Today` variant.
- `components/morning-gate.tsx` -- unchanged; the intervention's one action, when Declarations are
  outstanding, renders this component as-is.
- `EXPERIENCE.md` -- add both copy variants here first, per Story 5.1's own deferred finding.
- New: `supabase/migrations/<ts>_the_app_notices_ive_gone_quiet.sql` (`silence_episode` table +
  RLS + streak/detect/enqueue logic + satisfaction trigger), `components/silence-intervention.tsx`,
  `supabase/tests/5-2-the-app-notices-i-have-gone-quiet.sql`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql` -- `silence_episode`
  table + partial unique index + RLS; streak detection and episode-open/enqueue folded into
  `enqueue_gate_reminders()`; routine-push suppression while an episode is active; `after insert`
  satisfaction trigger on `declaration`
- [x] `EXPERIENCE.md` -- both intervention copy variants already present verbatim from original UX
  planning (`_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md`,
  Voice and Tone rows "Day two of silence"/"Day two, unanswered days pending") -- confirmed by
  reading, no edit needed
- [x] `components/silence-intervention.tsx` -- new component: reads `grace_allowance_remaining`,
  renders the matching copy variant (`lib/silence.ts`) off the `owing` prop, and (when
  Declarations are outstanding) renders `MorningGate` unchanged beneath the copy. The "active
  episode" read itself lives in `app/page.tsx` instead (see that file's own comment), not
  duplicated here
- [x] `app/page.tsx` -- new top-level branch, ahead of the existing Declaration gate, driven by an
  inline `silence_episode` read
- [x] `supabase/tests/5-2-the-app-notices-i-have-gone-quiet.sql` -- proves every I/O Matrix row
  that is server-side behavior (all rows except the two copy-variant rows, covered below)
- [x] `components/silence-intervention.test.tsx` -- both copy variants and MorningGate's target
  (the two remaining I/O Matrix rows)

**Acceptance Criteria:**
- Given two consecutive days of Silence, when the morning arrives, then a single intervention
  replaces routine notifications (including the outstanding Declaration prompt) instead of adding
  to them
- Given the intervention, then it carries no debt figure, no itemized miss list, and no red, and
  delivers once rather than persisting or re-delivering
- Given Declarations are outstanding when it fires, then it still arrives before the first 48-hour
  expiry, and answering from inside the app still saves the day
- Given any Declaration is answered, then the Silence episode ends and routine notifications
  resume

## Design Notes

Streak detection lives inside `enqueue_gate_reminders()` (not a new function/cron) because it
already runs on the "morning slot" cadence and already knows per-account outstanding Declarations
— a separate detector risks disagreeing about which day is "today" for a given account. Streak
counting walks `asked_day` backward from yesterday; a day is quiet when the account had
commitments owing (`commitments_owing()`) and zero `declaration` rows exist for that day —
re-derived each run, no counter column, matching `apply_grace_days()`/`supersede_expiries()`.

## Verification

**Commands:**
- `npx supabase db reset && docker exec supabase_db_todoapp psql -v ON_ERROR_STOP=1 <
  supabase/tests/5-2-the-app-notices-i-have-gone-quiet.sql` -- expect every I/O Matrix row to pass
- `npm test`, `npx tsc --noEmit`, `npm run lint`, `npm run format:check` -- all clean

**Manual checks (if no CLI):** confirm in a browser that a manually-inserted `silence_episode` row
renders the correct copy variant on next load, and that answering the outstanding Declaration (if
any) clears it on the following load.

## Suggested Review Order

**Detection and one-shot delivery (the entry point)**

- The streak check itself — two consecutive quiet asked-days, re-derived every run.
  [`20260826090000_..._quiet.sql:164`](../../supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql#L164)

- The episode table — a due/satisfied-at pair (AD-11), one active row per account.
  [`20260826090000_..._quiet.sql:21`](../../supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql#L21)

- The partial unique index doubling as the dedupe target for a same-hour re-run.
  [`20260826090000_..._quiet.sql:47`](../../supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql#L47)

**Ending the episode, and who may touch it**

- The after-insert trigger — any Declaration ends the episode immediately, not fold-in-delayed.
  [`20260826090000_..._quiet.sql:96`](../../supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql#L96)

- RLS: read-own only, no insert/update policy at all — opening and closing are both server-side.
  [`20260826090000_..._quiet.sql:55`](../../supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql#L55)

**Client routing — where the intervention wins the fork**

- The new top-level branch, ahead of the Declaration gate.
  [`page.tsx:168`](../../app/page.tsx#L168)

- The render-time reset that keeps a second account, signed in with no sign-out, from
  rendering one more frame under the previous account's episode.
  [`page.tsx:94`](../../app/page.tsx#L94)

**The intervention screen itself**

- Both verbatim copy variants and the one dynamic clause (the specific outstanding days).
  [`silence.ts:67`](../../lib/silence.ts#L67)

- The component: Grace Days reused verbatim, MorningGate rendered unchanged when Declarations
  are outstanding, no second declaration-answering UI invented.
  [`silence-intervention.tsx:36`](../../components/silence-intervention.tsx#L36)

**Peripherals**

- The full I/O Matrix, proven against a real local Postgres.
  [`5-2-the-app-notices-i-have-gone-quiet.sql`](../../supabase/tests/5-2-the-app-notices-i-have-gone-quiet.sql)

- Both copy variants and MorningGate's target, at the component level.
  [`silence-intervention.test.tsx`](../../components/silence-intervention.test.tsx)

