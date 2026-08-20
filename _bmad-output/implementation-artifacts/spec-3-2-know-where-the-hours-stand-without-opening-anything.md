---
title: 'Story 3.2 — Know where the hours stand without opening anything'
type: 'feature'
created: '2026-08-20'
status: 'done'
baseline_commit: 'a400e52457601ec9ea67543ac5af15279072d0a9'
review_loop_iteration: 0
story_key: '3-2-know-where-the-hours-stand-without-opening-anything'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-20 by tmtuan123** — all five decisions, including D1's answer to the
> "configured hour" ambiguity (a fixed offset after `morning_hour`, not a new column or Settings
> field), and the full spec kept rather than split despite running past the 1,600-token proposal —
> one goal across the database, `lib/`, tokens and one surface. Frozen from here.
>
> Stamped in its own commit, before any implementation, as Stories 3.0 and 3.1 were (retro P2b).

## Intent

**Problem:** A *Put hours in* commitment can be created and timed since Story 3.1, but the app never
tells him anything about it unless he opens the Focus Session screen himself — `focus_day_minutes`
has "nothing recomputes it" written into its own comment (`20260820110000...sql:133`), and nothing
reads it yet. FR-12 requires progress legible without opening the app; FR-5 requires a prompt when
he has not started. Neither exists. The running screen itself shows the total only as text, never as
something felt at a glance (AC1's second half), and no document anywhere specifies which hour "a
configured hour" in FR-5 means — `morning_hour` is the only hour this app has ever asked him to set.

**Approach:** One hourly database pass reads `focus_day_minutes` for every open, unmet
`daily_hours_quota` commitment and enqueues at most one push — its body branches on whether anything
is banked yet, and it falls silent the moment the target is met. `morning_hour + 3` (capped at 23) is
the hour it starts asking, chosen over a second Settings field because this app has exactly one hour
the author has ever been asked to set, and a second one is its own decision for its own day. The
Focus Session screen gains a plain CSS width bar beside its existing text total — the first and only
motion this product introduces, suppressed to an instant snap by one media query rather than removed.

## Decisions

### D1. The prompt's hour is derived, not configured — `morning_hour + 3`, capped at 23

FR-5 names "a configured hour" but no document says which, and the schema has exactly one hour field
(`profile.morning_hour`, built by Story 3.0). Adding a second Settings row is a real product decision
this story was not asked to make, and Story 3.0 D4 already declined it once, naming referee pairing
and grace days as the only rows left out on purpose.

**Decided (human, 2026-08-20):** derive it — `least(morning_hour + 3, 23)` — rather than add a
column or a second Settings field. Three hours gives the morning to the Declaration and the day's own
rhythm before the app starts asking about a different commitment; capping at 23 means a very late
`morning_hour` (say 20) still gets checked the same calendar day rather than wrapping into the next
one, which would silently be asking about the wrong day's target.

### D2. One reminder pipeline, and the body is what changes

`enqueue_gate_reminders()` is the shape to copy exactly: one hourly `security definer` function,
looped over doers, a slot count bounding how many times a day may ask, one `outbox_enqueue` call per
row, deduped so a retried cron pass is a no-op.

**Proposed:** `enqueue_focus_prompts()`, cron `'25 * * * *'` — offset from gate-reminders (`:05`) and
settlement (`:15`) so no pass shares a minute, matching the existing convention's own stated reason.
For every open `daily_hours_quota` commitment past its prompt hour: skip it entirely once
`focus_day_minutes` shows the target met that day — nothing is sent, which is the product's whole
answer to a quota that succeeded (Story 3.1 already refused to add congratulatory chrome anywhere).
Otherwise the body reads `<name>, <banked> of <target>, as of <HH:MM>.` in the screen's own `H:MM`
format — `0:00 of 3:00` when nothing is banked, matching every other duration in the product rather
than inventing a second register for the notification alone. `focus_prompt_slots()` bounds it to four
hourly attempts, the same defensible number `gate_reminder_slots()` already uses, for the same reason
stated there: enough to be useful, not enough to become the thing he mutes.

### D3. Tapping the notification opens the app, not a specific screen

The product has no router (Story 3.0 D5, again) and no notification here or elsewhere deep-links to a
component — `notificationclick` calls `openApp()`, which focuses or opens `/`. "Exactly one action"
(UX-DR27) is satisfied by the tap doing one thing, not by routing into Focus Session directly.

**Proposed:** no change to `app/sw.ts`. Landing on Today, the row still opens Focus Session in one
more tap through the routing Story 3.1 D5 already built. Inventing a deep link for this one
notification would be new infrastructure this story does not need.

### D4. The bar is the first motion this product has, and one media query is the whole of Reduce Motion

Every other surface in this app has no transition and no animation — Story 3.1's own comment says so
of the timer it built. `EXPERIENCE.md`, NFR13 and the accessibility review all separately describe
the quota bar as filling, which nothing built so far has done: this is genuinely new, not compliance
by construction the way the timer's stillness was.

**Proposed:** a plain `width` transition on the bar's fill element, driven by one new token
(`--motion-duration`, the first of its kind — nothing existing names a duration), removed entirely
inside `@media (prefers-reduced-motion: reduce)`. No JavaScript reads the media query: CSS alone
decides whether the width change animates or snaps, so there is nothing to get out of sync with the
OS setting after first paint.

### D5. The bar's colours and shape come from tokens that already carry the right meaning

No component-behaviour row anywhere specifies a bar's height, fill colour or radius (confirmed absent
from both `EXPERIENCE.md` and `DESIGN.md`). Inventing a colour would be a design decision this spec
is not positioned to make well.

**Proposed:** fill `--action-fill` (the same green *Stop and bank it* already uses — the bar fills
with the colour of the button that deposits the time), track `--surface-sunken`, radius
`--radius-default`. **Not** `--radius-pill`: `app/globals.css:108-111` and `DESIGN.md` both reserve
that radius to non-interactive status labels on purpose, and a bar is neither a label nor pressable.
Height reuses `--space-2` (8px) rather than a new size token.

## Boundaries & Constraints

**Always:**

- The server is the sole judge of what is banked (AD-1). The bar's percentage and the notification's
  numbers both come from `focus_day_minutes`; nothing is computed from the client's own queue.
- A push body is self-dating and never describes the present (`push_body_is_sendable`); this story's
  bodies carry `as of HH:MM` for the same reason `enqueue_gate_reminders`' do.
- A retried or overlapping cron pass is a no-op — one dedupe key per (account, commitment, day, slot).
- Copy is added to `EXPERIENCE.md` before it is used in a body or a component (UX-DR26), same as
  Story 3.1's D6.

**Ask First:**

- Any escalation beyond four flat hourly attempts (frequency change, tone change past attempt one).
- Anything that reads `commitments_owing()` or touches `enqueue_gate_reminders()` — this story is
  additive, a second independent pipeline, not an edit to the existing one.
- A status-pill or Today-row change for `daily_hours_quota` commitments. Out of this story's AC —
  the bar belongs to the Focus Session screen only, per the acceptance criteria's own text.

**Never:**

- A second Settings field for this story (D1).
- A deep link or route change to satisfy "one action" (D3).
- CSS animation anywhere else in the product, or a second motion token for the same purpose (D4).
- Sending a notification once the target is met that day.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
| --- | --- | --- | --- |
| Nothing banked, past the prompt hour | `focus_day_minutes` has no row today | `<name>, 0:00 of <target>, as of HH:MM.` | N/A |
| Some banked, target not yet met | e.g. 80 of 180 minutes | `<name>, 1:20 of 3:00, as of HH:MM.` | N/A |
| Target met that day | banked ≥ target | Nothing enqueued for that commitment this pass | N/A |
| Before the prompt hour | `local_hour < morning_hour + 3` | Nothing enqueued | N/A |
| `morning_hour` = 22 | `least(22+3, 23) = 23` | Checked once, at 23:00 local, same calendar day | N/A |
| Fifth hourly pass in a day | `slot >= focus_prompt_slots()` | Nothing enqueued — the day stays quiet after four | N/A |
| Two `daily_hours_quota` commitments, one account | Different banked/target each | Each gets its own row and its own dedupe key | N/A |
| Same pass runs twice (cron retry) | Identical (account, commitment, day, slot) | Second enqueue is a no-op | Unique violation on `dedupe_key`, swallowed by `on conflict do nothing` |
| Commitment archived mid-day | `archived_at is not null` | Excluded from the loop | N/A |
| Focus Session screen, banked > target | e.g. 200 of 180 | Text reads `3:20 of 3:00`; the bar's fill is visually capped at 100% | N/A |
| Reduce Motion enabled | `prefers-reduced-motion: reduce` | The bar's width still updates on reload; it does not transition to get there | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819210000_gate_reminder.sql:11-25` — `gate_reminder_slots()`, the exact
  shape `focus_prompt_slots()` copies.
- `supabase/migrations/20260819261000_gate_names_the_chain.sql:17-95` — `enqueue_gate_reminders()`,
  the full pipeline shape: account loop, slot gate, one `outbox_enqueue` call, dedupe key, revoke.
- `supabase/migrations/20260819183000_outbox_schedule.sql`,
  `supabase/migrations/20260819221000_settlement_schedule.sql` — existing cron minute offsets to sort
  a new `'25 * * * *'` schedule against without collision.
- `supabase/migrations/20260820101000_outbox_body_rule_where_it_runs.sql:18-35` —
  `push_body_is_sendable`; the new bodies must clear its clock-time/weekday check.
- `supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql:130-155` —
  `focus_day_minutes`, the seam this story reads, and its own comment naming this story.
- `supabase/migrations/20260819150000_commitment.sql:33,53` — `daily_minutes_target`, always present
  and always `> 0` for this cadence, so no null-target branch is needed in the reminder.
- `supabase/tests/3-2-focus-prompt.sql` (new) — model on `supabase/tests/3-0-morning-hour.sql`'s
  structure; the matrix's database rows.
- `lib/focus-session.ts:197-220` — `formatDuration`, `bankedAgainstTarget`; the bar's percentage
  helper belongs beside these, reusing the same numbers the text already computes.
- `components/focus-session.tsx:360-374` — the existing `Banked today` row the bar sits inside; view
  already carries `bankedSeconds`/`targetMinutes` in scope.
- `app/globals.css:341-350`, `app/tokens.css:80-81` — `.focus-figure` and the figure tokens, the
  precedent for how this screen's other element documents its own restraint.
- `app/globals.css:108-111` — the pill-radius reservation the bar must not use.
- `lib/design-tokens.test.ts:173-224` — the structural-rule tests a new token and a new class must
  not trip: no shadow, no literal colour, hairline width, pill-radius reservation, figure budget
  (unaffected — the bar's own number, if any, must not use `--type-figure`).

## Tasks & Acceptance

**Execution:**

- [x] `EXPERIENCE.md` — add the progress-sentence template (`<name>, <banked> of <target>, as of
      <time>.`) alongside the existing KF-2 example, per UX-DR26 (D2).
- [x] `supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql` —
      `focus_prompt_slots()`, `enqueue_focus_prompts()` (D1, D2), a small `minutes_as_clock(integer)`
      formatting helper mirroring `formatDuration`, cron registration, trailing revokes.
- [x] `supabase/tests/3-2-focus-prompt.sql` — the matrix's database rows: before/after the prompt
      hour, the 22→23 cap, target-met silence, the four-slot bound, two commitments enqueuing
      independently, the retried-pass no-op, and an archived commitment excluded.
- [x] `lib/focus-session.ts` + test — a clamped-0-to-100 percentage helper alongside the existing
      duration formatters.
- [x] `app/tokens.css` — `--motion-duration`, the first motion token, with a one-line comment naming
      what it is for and that nothing else in the product uses it yet.
- [x] `app/globals.css` — the bar's track/fill classes (D5) and the `prefers-reduced-motion` block
      that removes the transition (D4).
- [x] `components/focus-session.tsx` + test — the bar rendered beside `Banked today`, capped at 100%
      width when over target, and not a second announcement of the same number the row's
      `aria-label` already carries.

**Acceptance Criteria:**

- Given a *Put hours in* commitment with minutes banked and the target unmet, when the hourly pass
  runs after the prompt hour, then a single push states the banked total against the target,
  self-dated, without the app being open.
- Given a *Put hours in* commitment with nothing banked once the prompt hour has passed, then a push
  prompts a session; tapping it opens the app, and nothing more than that one action is offered.
- Given the target is met for the day, when the pass runs again, then nothing is sent for that
  commitment.
- Given the Focus Session screen open with minutes banked, then a bar is visible beside `Banked
  today`'s existing text, reflecting the same fraction, capped visually at 100% when banked exceeds
  target.
- Given Reduce Motion is enabled, then the bar's width still updates but never animates to get there.

## Design Notes

**Why the bar and the notification share one number rather than two.** The bar reads
`bankedSeconds`/`targetMinutes`, already in scope in the component's `view` (Story 3.1 built it for
the text total). The notification reads the same ratio from `focus_day_minutes` server-side. Both
derive from one view; neither invents its own arithmetic, which is the same discipline AD-8 already
requires of settlement.

**Why four slots and not an escalating cadence like the weekly quota's (FR-4, Story 3.3).** FR-4's
escalation is explicitly about a quota that can still fail — Story 3.3's territory. A Daily Hours
Quota carries no penalty at all (Story 3.1's own epic context, restated here): there is nothing to
escalate *toward*. Four flat, identical attempts is the honest shape for a nudge with no consequence
behind it; inventing urgency for a commitment that cannot fail would be manufacturing stakes the
product does not have, the same objection Story 2.9 raised about naming a chain that isn't running.

## Verification

**Commands:**

- `npm test` — expected: the new `lib/focus-session` percentage test and `components/focus-session`
  bar tests pass alongside the existing 569.
- `npx tsc --noEmit && npm run lint && npm run format:check` — expected: clean.
- `npx supabase db reset` then every file under `supabase/tests/` against the local stack — expected:
  `PASS.` for all, including the new `3-2-focus-prompt.sql`.

**Manual checks (only the author can do these):**

- With a *Put hours in* commitment banking nothing, wait past the prompt hour on the installed app
  and confirm a push arrives stating the target, not merely "start."
- Enable Reduce Motion in iOS Settings, open the Focus Session screen with minutes already banked,
  and confirm the bar is simply present at its value rather than filling into place.

## Verification record

**Built and checked on 2026-08-20**, on the branch this spec was approved on.

`npm test` — 581 passing across 30 files, up from 569. `npx tsc --noEmit`, `npm run lint` and
`npm run format:check` all clean. All twelve files under `supabase/tests/` were re-run against a
local stack and every one reports `PASS.`, including `2-2-commitment-rules.sql`'s untouched
assertion that an hours quota is never declared. `supabase/tests/README.md`'s manifest table gained
rows for `3-1-focus-session.sql` and this story's `3-2-focus-prompt.sql` — the first had shipped
without one — closing a gap before a third story could leave it open too.

**A three-layer review ran against the diff and found two real code defects — no `intent_gap`, no
`bad_spec`.** One was severe: `commitment.name` is freeform text spliced directly into the
notification body, and a name that happens to contain a phrase `push_body_is_sendable` refuses
("right now", "just now", "currently", "at the moment") would have hit the table's own check
constraint and raised an unhandled exception out of `enqueue_focus_prompts()` — a single statement,
so every outbox row already enqueued that pass, for every doer account processed before the poisoned
one, would have rolled back with it. One badly-named commitment could have silently broken the
notification pipeline for the whole product, every hour, until renamed. Fixed by checking
`push_body_is_sendable` before calling `outbox_enqueue` and skipping that one commitment, the same
way every other disqualifying condition in the loop is already handled — and proven by a new step in
`3-2-focus-prompt.sql` that poisons one commitment and confirms a second account, processed in the
same call, still gets its row.

The second was a fragile-but-currently-correct `NULL`/`coalesce` interaction: reading
`focus_day_minutes` via `select ... into` left the target `NULL` on the zero-row case despite the
`coalesce` inside the select list — verified directly against a live Postgres instance before asking
for the fix — and the code only produced the right `"0:00"` output because `GREATEST` silently
ignores `NULL` arguments and `continue when NULL` is treated as "don't skip." Both were accidents,
not decisions. Rewritten as a scalar subquery so `coalesce` wraps the read directly; behavior is
unchanged, but no longer depends on two unrelated NULL-propagation quirks nobody chose on purpose.

**One finding evaluated and rejected.** A reviewer flagged `total !== null && percent !== null` in
`components/focus-session.tsx` as redundant, since both derive from the identical `view.kind ===
'ready'` gate. Checked before touching it: `total` and `percent` are two independently-computed
`number | null` values, and TypeScript cannot infer that narrowing on one narrows the other — removing
`percent !== null` would either fail `tsc` at the `${percent}%` template literal or require a type
assertion, which is worse. Left as written.

**One gap named rather than silently accepted, in `deferred-work.md`.** An account whose
`morning_hour` is 21 or later gets fewer than the four hourly attempts every other account gets,
because `focus_prompt_hour`'s cap at 23 (D1) interacts with the local-midnight boundary: the number
of hours remaining in the calendar day shrinks as the derived prompt hour approaches it. This is a
mechanical consequence of the already-approved cap — not a defect in the cap's own reasoning, which
was specifically about not wrapping into the wrong day — and fixing the asymmetry (carrying a
remaining-attempts count across midnight, or accepting fewer attempts as correct) is a design
decision, not a patch.

**Left for the author, because no file here can answer it.** Waiting past the prompt hour on the
installed app with nothing banked, to confirm a push arrives stating the target; and enabling Reduce
Motion in iOS Settings to confirm the quota bar is simply present at its value rather than filling
into place. Both are why this story stays at `review` rather than moving itself to `done`.

## Suggested Review Order

**The reminder pipeline (D1, D2): one hourly pass, and the two defects review found in it**

- The entry point: the whole pipeline's shape, copied from `enqueue_gate_reminders()`, and where
  both review fixes landed.
  [`20260820120000_a_prompt_reads_the_view_it_was_promised.sql:76`](../../supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql#L76)

- The severe fix: a freeform commitment name can trip `push_body_is_sendable`, and this is what
  keeps one bad name from rolling back every account's row enqueued earlier the same pass.
  [`20260820120000_a_prompt_reads_the_view_it_was_promised.sql:147`](../../supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql#L147)

- The NULL fix: a scalar subquery, not `select ... into`, because the view returns zero rows rather
  than a null-`minutes` row when nothing is banked yet.
  [`20260820120000_a_prompt_reads_the_view_it_was_promised.sql:122`](../../supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql#L122)

- D1's derivation on its own, checkable independent of the wall clock: three hours after
  `morning_hour`, capped at 23 so a late hour never wraps into the wrong day.
  [`20260820120000_a_prompt_reads_the_view_it_was_promised.sql:40`](../../supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql#L40)

- Proof both fixes hold together: a poisoned commitment is skipped, and a second account processed
  in the same call still gets its row.
  [`3-2-focus-prompt.sql:335`](../../supabase/tests/3-2-focus-prompt.sql#L335)

**The bar (D4, D5): the product's first real motion, and the one media query that is all of Reduce
Motion**

- The clamped fraction the bar and the existing text total now share — one number, not two.
  [`focus-session.ts:234`](../../lib/focus-session.ts#L234)

- The transition and the token that drives it — the first duration this product has ever named.
  [`globals.css:369`](../../app/globals.css#L369)

- Where Reduce Motion actually lives: no JavaScript, one media query, nothing to fall out of sync
  with the OS setting after first paint.
  [`globals.css:381`](../../app/globals.css#L381)

- The bar rendered beside the existing `Banked today` row, `aria-hidden` because the row's own
  label already states the same fraction as text.
  [`focus-session.tsx:373`](../../components/focus-session.tsx#L373)

**Documentation kept in step with the code**

- The new push template added to `EXPERIENCE.md` before being used, per UX-DR26.
  [`EXPERIENCE.md`](../../_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md)

- The test manifest closing the gap Story 3.1 left open, one story before it could become two.
  [`README.md:73`](../../supabase/tests/README.md#L73)
