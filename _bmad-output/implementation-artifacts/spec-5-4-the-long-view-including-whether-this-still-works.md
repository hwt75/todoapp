---
title: 'Story 5.4 — The long view, including whether this still works'
type: 'feature'
created: '2026-08-26'
status: 'done'
review_loop_iteration: 1
baseline_commit: 'eed2336985701d42bd1b7de510459d88e6cba967'
story_key: '5-4-the-long-view-including-whether-this-still-works'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-24 — a month can look fine on the Today screen (no debt showing, no red) while
the mechanism underneath has quietly died: the Referee has stopped ruling or collecting, or
Silence has become routine. Nothing today lets the author see that at the only altitude where it
would actually show.

**Approach:** A new, author-only, read-only "Monthly report" screen (spine-only fidelity,
reached from Settings) computing every PRD §8 measure for the most recently completed calendar
month, following this codebase's own established shape: the database exposes facts (existing
views plus two new nullable timestamp columns), TypeScript folds them into report figures
(`lib/monthly-report.ts`, mirroring `lib/ledger.ts`'s own row-folding style) — no new bespoke
aggregation RPC except the one metric (declaration answer-rate) that structurally requires
reusing server-side owing-logic the client cannot otherwise reach.

Two schema gaps block the AC's own "divergence is the only evidence" requirement and are closed
here rather than approximated: `penalty` never stamped when a Penalty was collected, and `appeal`
never stamped when the Referee ruled — both confirmed absent by investigation before this spec
was written, both closed with a human decision already made (see Boundaries).

## Boundaries & Constraints

**Always:**
- `penalty` gains `collected_at timestamptz` (nullable); `mark_penalty_collected()`
  (`create or replace`, its argument list unchanged so this really is a replace) stamps it
  alongside the existing `state = 'collected'` write.
- `appeal` gains `ruled_at timestamptz` (nullable); `rule_appeal()` (`create or replace`) stamps
  it on **both** branches — reject and approve — so SM-5 never has to infer a rejection's timing
  from an absent column.
- One new function, `commitment_answer_rate_for_month(p_month date) returns table(commitment_id
  uuid, asked integer, answered integer)` — `security definer`, resolves `auth.uid()` internally
  (never a client-supplied owner), loops every calendar day in `p_month` via `commitments_owing()`
  (already excludes `daily_hours_quota` and pre-archive days) summing `asked`/`answered` per
  commitment. This is the *only* new RPC — every other measure reads an existing or lightly
  extended table/view directly, client-scoped by that table's own existing RLS.
- SM-6 (declaration answer rate) is the sum of `asked`/`answered` across every row
  `commitment_answer_rate_for_month` returns for the month — not "answered within the morning
  window" (no such signal exists in this schema; confirmed by investigation and accepted by the
  human as the story's own scope decision).
- SM-3 (commitment completion) is one row per commitment from the same function —
  `answered / asked` — generic per-commitment, never hardcoded to a specific commitment name
  ("gym", "no-fap") the way no other code in this app hardcodes a commitment's identity.
- SM-1 (chains) reads `chain_current` directly (`current_days`, `longest_days` per
  `commitment_id`) — never recomputed, matching `chains-detail.tsx`'s own convention.
- SM-2 (median days to return) and SM-C2 (median days to acknowledge) both fold
  `settlement_current` (kind `day`, `verdict = 'failed'`, `period` in-month) against a later
  event — SM-2 against the next `verdict = 'clean'` settlement for the same subject; SM-C2
  against the next `declaration.answered_at` (any commitment) after that Failed day's `period` —
  reusing this codebase's own established "any Declaration = acknowledged" framing
  (`declaration_satisfies_silence()`, Story 5.2) rather than inventing a new signal. Both look
  ahead up to 14 days past the failed day for the qualifying later event; a Failed day with no
  qualifying event inside that window is excluded from the median, not treated as zero.
- SM-C1 (penalties) reads `penalty_current`: **incurred** = rows with `created_at` in-month;
  **collected** = rows with `collected_at` in-month — two figures total, never merged into one
  (UX-DR19, and epics.md's own AC names exactly two), each its own count and `amount_dong` sum.
  `penalty_current` carries `kind` (day/week) as a fact the view already exposes, but neither
  the AC nor `EXPERIENCE.md`'s own Monthly-report row asks for a further day/week split of
  these two figures — clarified 2026-08-26 (see Spec Change Log) after the first implementation
  read this bullet's earlier "split by kind" phrasing ambiguously; the code already landed on
  the correct two-figure reading and needs no change.
- SM-4 (silence count) is `count(*)` from `silence_episode` where `started_day`'s month matches
  — every row already represents ≥2 consecutive quiet days by construction (Story 5.2's own
  opening threshold), so no additional duration filter is applied.
- SM-C3 (appeal reject share) reads `appeal` rows with `created_at` in-month, joined to their
  `penalty.state` the same way `referee-appeal-detail.tsx` already infers outcome (`owed` →
  rejected, `voided`/row-superseded → approved, `dropped` → dropped, `held` excluded from the
  denominator as still-pending) — `rejected / (rejected + approved + dropped)`.
- SM-5 (referee still active) is a boolean: any `appeal.ruled_at` **or** `penalty.collected_at`
  falling in-month.
- Every month-boundary comparison uses `date_trunc('month', <col> at time zone
  'Asia/Ho_Chi_Minh')`, mirroring `grace_day_validate()`'s own established convention — never a
  client-computed month range.
- Entry point: a new row/button in `components/settings.tsx` (`onOpenMonthlyReport`), mirroring
  the existing `onOpenLedger`/`onOpenSettings` pattern in `app/page.tsx` exactly — a new
  `showMonthlyReport` boolean and a `<MonthlyReport onClose=.../>` branch in that file's existing
  ternary chain, not a new route.
- The report defaults to, and this story only builds, the most recently fully completed calendar
  month — no month picker. AC #3 (daily-summary-absence is the heartbeat failure) requires no
  code: it is satisfied by the existing daily-summary mechanism already being the only alarm, and
  is recorded here as a documentation fact, not a feature.
- Author-only: RLS on `penalty`/`appeal`/`silence_episode`/`chain_current` already scopes every
  read to the signed-in doer; no Referee-facing change.

**Ask First:** None — both schema gaps (collected_at, ruled_at) and the SM-6 scope reduction were
already decided by the human before this spec was written.

**Never:**
- No month picker, no historical archive of past months' reports — one month, computed live, no
  stored report row.
- No change to `settle_day()`, `rule_appeal()`'s eligibility/transition logic, or
  `mark_penalty_collected()`'s eligibility logic — both functions gain only the new timestamp
  stamp, nothing else.
- No new alerting/observability mechanism for AC #3 — the daily summary already is the heartbeat
  (`ARCHITECTURE-SPINE.md`'s own Deferred section); this story documents that, never builds a
  second one.
- No Referee-facing surface change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Penalty collected this month | `mark_penalty_collected()` called within the report month | `collected_at` stamped; SM-C1's collected figure includes it | N/A |
| Appeal rejected this month | `rule_appeal(approved=false)` called within the report month | `ruled_at` stamped; counts toward SM-C3 and SM-5 | N/A |
| Failed day never returned-from | No later `clean` day-settlement within 14 days | Excluded from SM-2's median, not counted as a large outlier | N/A |
| Failed day never acknowledged | No later `declaration.answered_at` within 14 days | Excluded from SM-C2's median | N/A |
| No Failed days this month | Zero `verdict='failed'` day-settlements in-month | SM-2/SM-C2 both report "no data," not zero or a crash | N/A |
| No appeals filed this month | Zero `appeal.created_at` in-month | SM-C3 reports "no data," not a divide-by-zero | N/A |
| Referee ruled nothing, collected nothing | No `ruled_at`/`collected_at` in-month anywhere | SM-5 reads false | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819230000_penalty.sql:28-46` -- `penalty` table; add `collected_at`
  via new migration's `alter table`.
- `supabase/migrations/20260825120000_the_same_lock_the_same_day.sql:130-193` -- current
  `mark_penalty_collected()`; `create or replace` to stamp `collected_at`.
- `supabase/migrations/20260824130000_contest_a_miss_the_machine_got_wrong.sql:79-` -- `appeal`
  table; add `ruled_at` via new migration's `alter table`.
- `supabase/migrations/20260825090000_the_referee_rules.sql:88-193` -- current `rule_appeal()`;
  `create or replace` to stamp `ruled_at` on both the reject branch (~line 128-133) and the
  approve branch (~line 157-193).
- `supabase/migrations/20260820140000_weekly_quota_is_not_judged_daily.sql:23-52` --
  `commitments_owing(p_owner, p_day)`, the exact function the new
  `commitment_answer_rate_for_month` loops per-day; already excludes `daily_hours_quota` and
  pre-archive days -- do not re-derive those exclusions.
- `supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql:127-164` -- the
  `quiet_yesterday`/`quiet_day_before` block, the exact `count(*), count(o.answer) from
  commitments_owing(...)` shape to replicate per-day inside the new function's loop.
- `supabase/migrations/20260819260000_chain.sql:73-113` -- `chain_current` view
  (`subject, commitment_id, current_days, longest_days`), read directly for SM-1.
- `supabase/migrations/20260820150000_the_week_closes_and_settles.sql:385-390` --
  `penalty_current` view (`penalty.*` + `kind, period`), read directly for SM-C1, now also
  carrying `collected_at`.
- `supabase/migrations/20260819220000_settlement.sql:25-38`,
  `supabase/migrations/20260819241000_expiry_and_supersession.sql:31-36` -- `settlement` /
  `settlement_current`, read for SM-2/SM-C2's failed-day/return-event folding.
- `supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql:21-34` --
  `silence_episode` (`started_day`), read directly for SM-4.
- `supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql:185-186` --
  `grace_day_validate()`'s `date_trunc('month', ... at time zone 'Asia/Ho_Chi_Minh')` pattern,
  the exact month-boundary idiom to replicate.
- `components/referee-appeal-detail.tsx:92-155` -- the existing `penalty.state`-inference
  pattern for an appeal's outcome; replicate for SM-C3 rather than inventing a new mapping.
- `lib/referee.ts:240-249` (`daysSinceQuiet`) -- the exact UTC date-string-arithmetic idiom
  (`Date.UTC`, `+1` inclusive) to replicate for every day-count computation in the new lib file.
- `lib/ledger.ts:117-185` (`buildLedger`, `outstandingTotal`) -- the row-folding style
  `lib/monthly-report.ts`'s new pure functions should match.
- `app/page.tsx:46-47,201-246` -- `showLedger`/`showSettings` state and the render ternary; add
  `showMonthlyReport` the same way.
- `components/settings.tsx` -- add the entry-point row (`onOpenMonthlyReport` prop, a button),
  alongside the existing referee-pairing/grace-days rows.
- New: `supabase/migrations/<ts>_the_long_view_including_whether_this_still_works.sql`,
  `lib/monthly-report.ts`, `components/monthly-report.tsx`,
  `supabase/tests/5-4-the-long-view-including-whether-this-still-works.sql`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_the_long_view_including_whether_this_still_works.sql` --
  `penalty.collected_at`, `appeal.ruled_at`, updated `mark_penalty_collected()`/`rule_appeal()`,
  new `commitment_answer_rate_for_month()`
- [x] `lib/monthly-report.ts` -- pure folding functions per Boundaries (median, per-metric
  summarizers), fed by rows the component fetches
- [x] `components/monthly-report.tsx` -- fetches raw rows + calls the new RPC, renders all nine
  measures via `lib/monthly-report.ts`
- [x] `components/settings.tsx` -- entry-point row
- [x] `app/page.tsx` -- `showMonthlyReport` state + render branch
- [x] `supabase/tests/5-4-the-long-view-including-whether-this-still-works.sql` -- proves every
  I/O Matrix row that is server-side behavior (the two new timestamp stamps, and
  `commitment_answer_rate_for_month`'s per-day summation against a known fixture)
- [x] `components/monthly-report.test.tsx` -- the client-side folding for at least one measure
  per PRD §8 category (primary, secondary, counter-metric)
- [x] `app/page.test.tsx`, `components/settings.test.tsx` -- new-wiring coverage added during
  review round 1

**Acceptance Criteria:**
- Given the most recently completed calendar month, when the report is opened, then it states
  all nine PRD §8 measures, with Penalties Incurred and Penalties Collected as two separate
  figures
- Given the report, then it includes Chains (current + longest per commitment), median days to
  return after a Failed Day, and the count of Silence episodes that month
- Given the daily summary has stopped arriving, then that absence is understood as the
  heartbeat failure the architecture spine already documents — no new alarm is built by this
  story

## Spec Change Log

- **2026-08-26, round 1 (blind-hunter):** the original SM-C1 Boundaries bullet said "reads
  `penalty_current`, split by `kind` (day/week)," which the implementation read as describing
  the view's own columns rather than a mandate to produce four figures (incurred-day,
  incurred-week, collected-day, collected-week). Cross-checked against `epics.md`'s AC ("states
  Penalties incurred and Penalties Collected as separate figures") and `EXPERIENCE.md`'s
  Monthly-report row ("penalties incurred and collected separately") — both name exactly two
  figures, never a kind split, so there is exactly one correct reading once the authoritative
  source is consulted. Amended the bullet to state two figures explicitly. **KEEP:** the shipped
  `foldPenaltyFigure`/two-query implementation is already correct under the clarified reading —
  no code change follows from this entry.

## Design Notes

`commitment_answer_rate_for_month` is the one new RPC because SM-6/SM-3 both need "was this
commitment owed an answer on this day" — logic `commitments_owing()` already owns and the client
cannot reach directly (`revoke execute ... from authenticated`). Every other measure is a plain
client read of an existing or lightly-extended table/view; this keeps the story's server surface
minimal and matches how `lib/ledger.ts` already does the equivalent folding for the Ledger
screen, rather than growing a second aggregation RPC per measure.

The 14-day lookahead window (SM-2/SM-C2) is a deliberate, stated boundary, not a discovered
constant: a Failed day in the last days of the month may not have "returned" or been
"acknowledged" yet by the time the report is viewed, and an unbounded search would let one
very-late return dominate a small month's median. Revisit if real data ever calls for widening
it.

## Verification

**Commands:**
- `npx supabase db reset && docker exec supabase_db_todoapp psql -v ON_ERROR_STOP=1 <
  supabase/tests/5-4-the-long-view-including-whether-this-still-works.sql` -- expect every I/O
  Matrix row to pass
- `npm test`, `npx tsc --noEmit`, `npm run lint`, `npm run format:check` -- all clean

**Manual checks (if no CLI):** open Settings, confirm the new entry point opens the report, and
that a month with no Failed days/no appeals renders "no data" rather than a crash or a bare zero.

## Suggested Review Order

**The schema fix review round 1 found (start here)**

- `penalty_current` re-created with every pre-existing column spelled out and `collected_at`
  genuinely appended last — the fix for a bug that would have broken the whole report against a
  real Postgres instance (`CREATE OR REPLACE VIEW` cannot reorder or rename an existing column).
  [`20260826110000_..._works.sql:41-54`](../../supabase/migrations/20260826110000_the_long_view_including_whether_this_still_works.sql#L41)

**The two new timestamp stamps**

- `mark_penalty_collected()` — `collected_at` stamped in the same guarded update as the
  `owed → collected` transition, one write, never a two-step race.
  [`20260826110000_..._works.sql:56`](../../supabase/migrations/20260826110000_the_long_view_including_whether_this_still_works.sql#L56)

- `rule_appeal()` — `ruled_at` stamped on both the reject and approve branches, each only after
  that branch's own guarded transition has already won.
  [`20260826110000_..._works.sql:136`](../../supabase/migrations/20260826110000_the_long_view_including_whether_this_still_works.sql#L136)

**The one new RPC**

- `commitment_answer_rate_for_month()` — sums `commitments_owing()`'s own per-day shape across a
  month, `auth.uid()`-scoped internally, with the null-`p_month` guard review round 1 added.
  [`20260826110000_..._works.sql:293`](../../supabase/migrations/20260826110000_the_long_view_including_whether_this_still_works.sql#L293)

**Client-side folding — the nine measures**

- `mostRecentCompletedMonth` — the "no month picker" boundary, and the month-boundary idioms
  (`monthDayBounds`/`monthInstantBounds`) every query below is scoped by.
  [`monthly-report.ts:50`](../../lib/monthly-report.ts#L50)

- `gapsToNextTarget` — the shared gap-search SM-2 and SM-C2 both fold through, and why a Failed
  day with no qualifying event in the lookahead window is excluded rather than counted as zero.
  [`monthly-report.ts:165`](../../lib/monthly-report.ts#L165)

- `foldAppealOutcomes` — the `penalty.state` → outcome mapping, mirroring
  `referee-appeal-detail.tsx`'s own inference rather than inventing a new one.
  [`monthly-report.ts:335`](../../lib/monthly-report.ts#L335)

**The screen itself**

- `load()`/`loadReport()` — the try/catch review round 1 added, and the eleven parallel reads
  that feed every fold above.
  [`monthly-report.tsx:71`](../../components/monthly-report.tsx#L71)

**Entry point**

- Settings gains the row; `app/page.tsx` gains the state and render branch, mirroring
  `showLedger`/`showSettings` exactly.
  [`settings.tsx:352`](../../components/settings.tsx#L352) ·
  [`page.tsx:243`](../../app/page.tsx#L243)

**Peripherals**

- The full I/O Matrix, proven against a real local Postgres — including the review round's own
  `penalty_current`-through-the-view assertion.
  [`5-4-the-long-view-including-whether-this-still-works.sql`](../../supabase/tests/5-4-the-long-view-including-whether-this-still-works.sql)

- The pure-function unit tests, the component tests, and the two wiring tests review round 1
  added.
  [`monthly-report.test.ts`](../../lib/monthly-report.test.ts) ·
  [`monthly-report.test.tsx`](../../components/monthly-report.test.tsx) ·
  [`settings.test.tsx`](../../components/settings.test.tsx) ·
  [`page.test.tsx`](../../app/page.test.tsx)
