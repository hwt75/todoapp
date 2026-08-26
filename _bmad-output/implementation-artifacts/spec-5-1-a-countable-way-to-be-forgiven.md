---
title: 'Story 5.1 — A countable way to be forgiven'
type: 'feature'
created: '2026-08-25'
status: 'done'
review_loop_iteration: 1
baseline_commit: 'f8c36afbc00703df0cf72d46de1896f5d99778e3'
story_key: '5-1-a-countable-way-to-be-forgiven'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A Failed Day has no way out that doesn't require lying about it — the author can
only watch a penalty stand or contest a machine's call he didn't actually dispute. FR-17 gives him
a limited, honest allowance instead: 2 Grace Days per calendar month (confirmed with the human;
non-carrying — unused ones do not roll into the next month), each of which voids one Failed Day's
Penalty and restores that day's chain.

**Approach:** Spending a Grace Day is a plain append-only event (`grace_day`, one row per
`(owner_id, for_day)`), validated synchronously by an insert trigger for immediate feedback
(eligible day, still owed, allowance remaining) — mirroring `appeal_hold_penalty()`'s own
trigger-validation shape. The actual correction — the terminal `penalty.state = 'waived'`
transition, the corrective `settlement` row, and the chain-restoring `settlement_commitment`
freeze — never happens synchronously. It is folded in by a new `apply_grace_days()` function
called from `settle_due_days()`'s own hourly pass, alongside `supersede_expiries()`, so settlement
remains the only writer of derived state (AD-8) — this is a deliberate departure from Story 4.6's
`rule_appeal()`, which does write the correction synchronously, because a prior review found two
independent correctors of the same chain disagreeing with each other.

## Boundaries & Constraints

**Always:**
- `grace_day(id, owner_id, for_day, created_at, processed_at)` — append-only (AD-9), a
  `unique (owner_id, for_day)` constraint so the same day can never be graced twice (also closes
  a double-insert race: two rapid inserts for the same day before either is processed).
- A `before insert` trigger validates, before the row is ever written, exactly the way
  `appeal_hold_penalty()` validates an Appeal: (a) `owner_id`'s current settlement for `for_day`
  (`kind = 'day'`) reads `verdict = 'failed'`; (b) that settlement's own Penalty currently reads
  `state = 'owed'` (excludes `held` — an Appeal in flight — and `collected`, per this story's own
  AC); (c) fewer than 2 `grace_day` rows already exist for this `owner_id` with `created_at` in
  the current calendar month (Asia/Ho_Chi_Minh, AD-6). Any failure raises a clear, specific
  message — this is a live, client-triggered action and needs synchronous feedback, unlike the
  scheduled fold-in below.
- `apply_grace_days()`, called from `settle_due_days()` immediately alongside
  `supersede_expiries()` (same hourly pass, `:15`) — never a separate schedule, never a
  synchronously-callable RPC. For each unprocessed `grace_day` row (`processed_at is null`):
  re-guard `state = 'owed'` in the transition's own `where` clause (silent no-op on a lost race,
  `void_expired_appeals()`'s convention — there is no synchronous caller left to raise to by the
  time this runs); on success, `penalty.state -> 'waived'`, insert a corrective `settlement`
  (`verdict = 'clean'`, `supersedes` the original, `missed_count = 0`), freeze every commitment
  for that day in `settlement_commitment` as `held` (mirroring `rule_appeal()`'s own
  chain-restoration fix, `20260820102000_supersession_freezes_the_day.sql`'s bug class), and set
  `grace_day.processed_at`.
- A new `penalty_state` value, `'waived'` — distinct from `voided` (an Appeal the referee
  approved) and `dropped` (an Appeal that timed out). `lib/ledger.ts`'s `PenaltyState`,
  `ledgerPillLabel`, `ledgerPillFamily` (label `Waived`, family `held` — already anticipated in
  that file's own comment) and `lib/referee.ts`'s `summarizeReferee` must all handle it.
- `grace_allowance_remaining` — a `security_invoker` view (mirroring `weekly_quota_progress`'s own
  shape) computing `2 - count(grace_day rows this calendar month)` per account. No client-side
  tally of raw `grace_day` rows (AD-8's own convention, stated verbatim in
  `weekly_quota_progress`'s own comment).
- The Grace Day control appears on the Day summary and on an owed Ledger row for a Failed,
  uncollected day, always stating the remaining count — never only inside a future Silence
  intervention (Story 5.2 doesn't exist yet, so this is satisfied by construction, not by a
  special case).
- `components/settings.tsx`'s previously-deferred "Grace Days remaining" row is filled in
  (read-only display, mirrors the row's own comment marking it absent since Story 3.0).

**Ask First:** None — the 2-per-calendar-month, non-carrying allowance was confirmed with the
human before drafting (the PRD's own `[ASSUMPTION]` flag).

**Never:**
- No synchronous RPC that writes `penalty`/`settlement`/`settlement_commitment` directly (unlike
  `rule_appeal()`). This is the one boundary this story exists to hold — the whole reason for the
  event-table-plus-scheduled-fold-in shape.
- No grace day on a day whose Penalty is `held` (an Appeal in flight), `voided`, `dropped`, or
  `collected` — only `owed`. No unspend/undo once a `grace_day` row is inserted.
- No changes to `settle_week()`/weekly-quota Penalties — Grace Days are day-scoped only, matching
  Appeal's own day-only restriction (Story 4.4).
- No new notification. Nothing in FR-17's own AC calls for one, and the Day summary/Ledger
  already carry the remaining count wherever it can be spent.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Spend, allowance available | A Failed, owed day; < 2 grace days used this month | `grace_day` row inserted | N/A |
| Spend, day already Collected | The day's Penalty reads `collected` | Insert refused | Clear message, nothing written |
| Spend, day under Appeal | The day's Penalty reads `held` | Insert refused | Clear message, nothing written |
| Spend, allowance exhausted | 2 `grace_day` rows already this calendar month | Insert refused | Clear message stating none remain |
| Double-spend same day | Two rapid inserts for the same `(owner_id, for_day)` | Second refused by the unique constraint | Clear message, only one counted |
| Fold-in, normal | The next hourly pass processes an unprocessed `grace_day` row | Penalty `-> waived`; corrective settlement `clean`; chain reads restored | N/A |
| Fold-in, lost race | Between insert and fold-in, the Penalty left `owed` some other way (should not happen given the Never boundary, guarded anyway) | Silent no-op, `processed_at` still set | N/A |
| Ledger display | A waived day | Pill reads `Waived`, tinted, row otherwise neutral (UX-DR13) | N/A |
| Grace Day then Appeal, same day | A Grace Day already exists for `(owner_id, for_day)` (whether or not folded in yet); an appeal is then attempted against the same day | Appeal insert refused | Clear message naming the Grace Day; nothing written, Penalty untouched |
| Appeal then Grace Day, same day | The day's Penalty reads `held` (an Appeal in flight) | Grace Day insert refused (already covered above: `held` is never `owed`) | Clear message, nothing written |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819241000_expiry_and_supersession.sql:175-235` -- `supersede_expiries()`,
  the exact "read-only-source-table, fold in by the next pass" precedent to mirror for
  `apply_grace_days()` (no dedicated event/inbox table pattern exists elsewhere in this codebase
  -- confirmed by investigation -- a plain source table read by the scheduled pass is the norm).
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:242-269` -- `settle_due_days()`;
  add the `apply_grace_days()` call here, alongside the existing `supersede_expiries()` call, same
  hourly `:15` pass (`20260819221000_settlement_schedule.sql:45-49`'s own cron registration).
- `supabase/migrations/20260824140000_void_expired_appeals.sql:14-40` -- the guarded,
  silent-no-op-in-the-`where`-clause shape `apply_grace_days()`'s own transition must mirror (no
  synchronous caller to raise to by fold-in time).
- `supabase/migrations/20260824150000_an_appeal_reads_the_day_that_stands.sql:39-113` --
  `appeal_hold_penalty()`, the trigger-validation shape (synchronous, raises) `grace_day`'s own
  insert trigger must mirror for immediate client feedback.
- `supabase/migrations/20260825090000_the_referee_rules.sql:202-210` -- the
  `settlement_commitment` freeze `rule_appeal()`'s approval path added, and exactly why
  (`20260820102000_supersession_freezes_the_day.sql`'s own bug class) -- `apply_grace_days()`'s
  own freeze must do the same for every commitment that day, not only one.
- `supabase/migrations/20260820130000_the_week_counts_its_own_days.sql:80-116` --
  `weekly_quota_progress`, the `security_invoker` rolling-period-count view shape to mirror for
  `grace_allowance_remaining` (calendar month instead of ISO week).
- `supabase/migrations/20260819230000_penalty.sql:26,44,50` -- `penalty_state` enum,
  `penalty_one_per_settlement`, and the table's own append-only comment, which already names
  "a grace day" as a future row-adding event.
- `lib/ledger.ts:36` (`PenaltyState`), `:178-224` (`ledgerPillLabel`/`ledgerPillFamily`, whose own
  comment already anticipates `waived` in the `held` colour family) -- add the `'waived'` case.
- `lib/referee.ts` -- `summarizeReferee`'s exhaustive switch needs a `'waived'` case (referee never
  sees a waived Penalty as owed, but the switch must still resolve it).
- `components/settings.tsx:46-50` -- the exact comment marking the Grace Days row "absent rather
  than disabled" since Story 3.0 -- this story fills it in, read-only.
- `components/ledger.tsx:5,188-190` -- the single call site pair for
  `ledgerPillLabel`/`ledgerPillFamily`; no other change needed there.
- `supabase/tests/2-7-supersession.sql` -- the structural template for this story's own test: call
  `settle_day`/`apply_grace_days()`/`settle_due_days()` directly inside the test transaction (no
  `pg_cron` fires in a SQL test), never a synchronous RPC-and-assert pattern like `4-6`'s.
- New: a Grace Day control component (or extend `components/day-summary.tsx`/`components/ledger.tsx`
  directly, implementer's call -- read whichever file actually renders the Day summary first),
  `supabase/migrations/<ts>_a_countable_way_to_be_forgiven.sql`,
  `supabase/tests/5-1-a-countable-way-to-be-forgiven.sql`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql` -- `grace_day` table
  + unique constraint + RLS (select/insert own, no update/delete); insert-validation trigger; add
  `penalty_state` value `'waived'`; `apply_grace_days()`; wire it into `settle_due_days()`;
  `grace_allowance_remaining` view
- [x] `lib/ledger.ts` -- handle `'waived'` in `PenaltyState`, `ledgerPillLabel`,
  `ledgerPillFamily`
- [x] `lib/referee.ts` -- handle `'waived'` in `summarizeReferee`
- [x] Day summary (`components/today.tsx`) and Ledger row (`components/ledger.tsx`) -- a Grace Day
  control on a Failed, uncollected day, always showing `grace_allowance_remaining`, inserting into
  `grace_day` on spend
- [x] `components/settings.tsx` -- fill in the Grace Days remaining row (read-only)
- [x] `supabase/tests/5-1-a-countable-way-to-be-forgiven.sql` -- proves every I/O Matrix row
- [x] `components/referee-appeal-detail.tsx` -- fixed a cross-story regression found while
  verifying this story (not in the original Code Map): a later Grace Day can supersede the same
  settlement an appeal ruling would, on either a rejected appeal's own day or an approved appeal's
  residual (non-appealed) miss. The settlement-comparison inference this screen used could not
  tell the two apart correctly in every case; replaced with a direct read of the appeal's own
  original `penalty` row by `penalty_id` (Story 4.5's own "penalty: referee reads day and week"
  RLS policy grants this), whose `state` is a permanent, unambiguous record of that specific
  appeal's own outcome regardless of what happens later to any other settlement

**Acceptance Criteria:**
- Given a Failed Day that is still uncollected, when viewed from the Day summary or its Ledger
  row, then a Grace Day control is offered, always stating how many remain
- Given a Grace Day is spent, then that day's Penalty is voided and its chain is preserved, and
  the Ledger row shows `Waived`
- Given a day already marked Collected, then a Grace Day cannot be applied to it
- Given a Grace Day is spent, then it is recorded as an event and folded in by settlement (AD-8)
  -- it never repairs derived state directly

## Spec Change Log

**2026-08-25, iteration 1.** Review (blind-hunter + edge-case-hunter, independently) found a real
race the frozen I/O & Edge-Case Matrix never named: a Grace Day spent on a day, followed by an
Appeal later filed against that same day before the hourly fold-in runs, would consume the Grace
Day (no unspend/undo) while `apply_grace_days()` silently no-ops against the now-`held` Penalty —
forgiving nothing. Fixed at the root by making the two mechanisms mutually exclusive:
`appeal_hold_penalty()` (Story 4.6) now refuses if any `grace_day` row already exists for that
day, regardless of `processed_at`. Two new I/O Matrix rows record both directions of this
interaction. KEEP: every other Boundary and the `apply_grace_days()`/`grace_day_validate()` design
were unaffected and carried forward unchanged.

Separately (not a spec amendment, a code-level correction): the first-pass fix to
`referee-appeal-detail.tsx` (itself a review finding, not in the original Code Map) inferred a
ruling's outcome by comparing settlement ids, which a second review pass found could misreport an
*approved* appeal with a residual, non-appealed miss as "rejected, later graced" once that
residual was itself Grace Day'd. Replaced with a direct read of the appeal's own original penalty
row's `state` — see the Tasks list and Design Notes above.

### Review Findings

**Independent code review, 2026-08-25 — commit `4642217`, 4-layer (blind-hunter, edge-case-hunter,
verification-gap, acceptance-auditor).**

- [x] [Review][Patch] The iteration-1 mutual-exclusion fix (Grace Day vs. Appeal) only
  serializes under sequential commits, not true concurrency: `appeal_hold_penalty()` never took
  `grace_day_validate()`'s own per-account advisory lock, so two genuinely concurrent
  transactions (two devices/tabs) could each read the other's uncommitted state as absent and
  both commit — a `grace_day` row *and* a `held` Penalty for the same day at once, exactly the
  "Grace Day spent for nothing" failure the iteration-1 fix exists to close. Fixed in a new
  migration, `20260825120000_the_same_lock_the_same_day.sql` (this codebase's own "migrations are
  additive" discipline — never editing a past one): `appeal_hold_penalty()` now takes the
  identical lock, first statement, before any of its own reads.
- [x] [Review][Patch] The same gap existed, undefended, for collection: `mark_penalty_collected()`
  (Story 4.7) had no `grace_day` awareness at all. Unlike the Appeal race, this direction needs no
  concurrency — the fold-in delay is up to an hour wide, and a referee collecting an owed Penalty
  is ordinary behavior. A Grace Day spent, then that same Penalty marked Collected before the next
  `:15` pass, would consume the Grace Day for nothing. Fixed in the same migration: a symmetric
  "a grace_day row for this day means it's already spoken for" guard, mirroring
  `appeal_hold_penalty()`'s own. Applied against the local stack (`create or replace function`,
  non-destructive); compiles clean. **Not run end-to-end**: the shared local stack already has a
  live referee from other concurrent work, so no SQL test file in this repo (4-6, 4-7, or 5-1, all
  of which build their own referee fixture) can run against it without a `supabase db reset`,
  which was avoided to not disrupt that session. `npm test` (892/892), `npx tsc --noEmit`,
  `npm run lint` all clean — this fix is SQL-only, no TypeScript touched.
- [x] [Review][Patch] `components/ledger.test.tsx` and `components/today.test.tsx` both start
  with a stray UTF-8 BOM (an editor artifact, not intentional). Removed from both files.
- [x] [Review][Patch] `sprint-status.yaml` and this spec's own frontmatter disagreed on status —
  synced in this review's own step 6.
- [x] [Review][Defer] `apply_grace_days()` is never tested through its real production entry
  point, `settle_due_days()` — the SQL test calls `apply_grace_days()` directly. A regression in
  the one added line wiring them together would ship undetected.
- [x] [Review][Defer] Neither advisory lock (the pre-existing one in `grace_day_validate()`, nor
  the one this review's own patch added to `appeal_hold_penalty()`) has an automated
  concurrent-session test — this test suite's format (one transaction, sequential) cannot express
  true concurrency.
- [x] [Review][Defer] A waived day's Ledger row-muted caption still reads "Everything held" (the
  same `verdict === 'clean'` branch a plain clean day uses) — only the pill and screen-reader-only
  `aria-label` actually distinguish it. Extends the identical, already-recorded gap for
  penalty-free slipped commitments (Story 3.4's own deferred entry): a real product-language
  decision (a third state distinct from both `Held` and `Failed`), not a one-line patch.
- [x] [Review][Defer] `GRACE_DAY_COPY.alreadySpent` is defined but never referenced — both
  `ledger.tsx` and `today.tsx` deliberately collapse `'spent'`/`'already-spent'` into the same UI
  state (a reasoned, commented choice, not an oversight), leaving this string genuinely unused.
- [x] [Review][Defer] The Day summary's Grace Day control shows only the date and the
  remaining-allowance sentence — never the amount or which commitment(s) were missed, unlike the
  equivalent Ledger-row control.
- [x] [Review][Defer] `EXPERIENCE.md` was not updated with this story's new user-facing copy
  (`GRACE_DAY_COPY`, the Settings row, `gracedAfterRejection`), despite the epic's own Naming
  Conventions bullet requiring copy to originate there first.
- [x] [Review][Defer] The frozen I/O Matrix's "Appeal then Grace Day" row is tested by directly
  `UPDATE`-ing the penalty to `held`, not by inserting a real `appeal` row and letting
  `appeal_hold_penalty()` derive that state — weaker proof than its sibling row, which does.
- [x] [Review][Defer] `apply_grace_days()`'s corrective `settlement_commitment` freeze depends on
  `commitments_owing()` returning every commitment for that day; a commitment archived between the
  original Failed Day and the fold-in would silently narrow the freeze.
- [x] [Review][Defer] No test exercises a graced day's interaction with `weekly_quota_progress`
  for a commitment that also has weekly-cadence tracking.
- [x] [Review][Defer] The Ledger's Contest button isn't hidden once a Grace Day is spent on that
  row — cosmetic; the server already refuses the resulting appeal attempt.
- [x] [Review][Defer] The `grace_day` insert's promise rejection (as opposed to a `{data, error}`
  result) is uncaught in both `ledger.tsx` and `today.tsx` — the same class of gap already
  recorded for Story 4.6's `rule()`.
- [x] [Review][Defer] `apply_grace_days()`'s own fold-in loop (and `settle_due_days()`'s call to
  it) has no per-row exception isolation — one bad `grace_day` row could abort the whole hourly
  pass. Matches `supersede_expiries()`'s own identical, pre-existing loop shape (verified by
  reading it) — a systemic pattern this story reproduces, not a regression it introduces.

Four further findings were dismissed as already recorded with reasoning in `deferred-work.md` by
this same commit's own internal review (`grace_allowance_remaining`'s referee misread,
`grace_day_owner_idx`'s possible redundancy, the client's blindness to an unprocessed spend within
the fold-in window) or as low-value/theoretical (`classifyGraceDaySpend`'s empty-string message
fallback, never observed to occur given the server always sends a non-empty message).

## Design Notes

**Why the fold-in is delayed up to an hour, and why that's acceptable.** The doer's insert is
synchronously validated (eligible, owed, allowance remaining) — he knows immediately whether his
Grace Day was accepted. Only the *chain-restoring correction* waits for the next `:15` pass, the
same latency `supersede_expiries()`'s own corrections already carry. Nothing in FR-17's AC
requires the Ledger to update instantly, and the alternative (a second synchronous corrector)
recreates the exact defect this story's own Approach exists to avoid.

**Where the Grace Day control actually renders.** Read `app/page.tsx`/`components/today.tsx` and
`components/ledger.tsx` first to find the real Day-summary and Ledger-row components before
adding a new one — the Code Map's own uncertainty here is deliberate: better to extend the actual
existing surface than to guess its name.

## Verification

**Commands, run 2026-08-25 against the local stack (Docker up throughout), after the review's 10 patch findings and the iteration-1 mutual-exclusion correction:**
- `npx supabase db reset` -- migration applies clean.
- `docker exec supabase_db_todoapp psql -v ON_ERROR_STOP=1 < supabase/tests/5-1-a-countable-way-to-be-forgiven.sql` -- **14/14 steps pass**: spend accepted with allowance available; double-insert refused by the unique constraint; a second legitimate spend accepted; a third refused (allowance exhausted, no carry-over); a Collected day refused; a Held (Appeal in flight) day refused; cross-account isolation; append-only enforced; the fold-in itself (day waived, corrective settlement `clean`, chain reads restored, `penalty_current` shows `waived`); a lost-race no-op still marks `processed_at`; `grace_allowance_remaining` reads 0 once both are spent; a corrected day refuses a second Grace Day; and (Step 14, added during review) an Appeal attempted against a day that already has a Grace Day is refused, in either order.
- Regression: `supabase/tests/4-4-contest-a-miss-the-machine-got-wrong.sql`, `4-5-the-referee-has-his-own-way-in.sql`, `4-6-the-referee-rules.sql`, `4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql` -- all still **PASS**, independently re-run.
- `npm test` -- **888/888 pass** across 40 files, including the redone `components/referee-appeal-detail.test.tsx` cases (direct-penalty-read approach, plus the residual-miss-then-graced regression) and new race/consistency cases in `components/ledger.test.tsx`/`components/today.test.tsx`.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.

**Review.** Three independent layers (blind-hunter, edge-case-hunter, verification-gap) ran against the full diff. 10 real findings were patched, the most significant being: a flaw in this story's own first-pass fix to a prior story's screen (verification-gap caught that the settlement-comparison inference could misreport an approved appeal as rejected-then-graced; replaced with a direct, permanent read of the appeal's own original penalty state); a genuinely wasteful race where a Grace Day and a later Appeal on the same day could both proceed, consuming the Grace Day for nothing (closed by making the two mechanisms mutually exclusive, recorded in the Spec Change Log above); a real concurrency bug in the monthly-allowance check across different days (closed with a per-account advisory lock); and a display bug double-decrementing the shown allowance on a reload-and-reclick. 3 lower-severity findings recorded in `deferred-work.md` rather than patched blind.

**Manual checks (if no CLI):**
- Confirm in a browser that the Grace Days remaining count on Settings, the Day summary, and a Ledger row all agree.
- Not run in this environment (no browser tooling, no live-project CLI session, matching the same disclosed gap every prior referee/doer-surface story left): the actual click-through of spending a Grace Day and watching the Ledger row update after the next scheduled pass.

## Suggested Review Order

**The event and its synchronous validation (the entry point)**

- `grace_day` itself — append-only, one row per day, ever.
  [`20260825110000_a_countable_way_to_be_forgiven.sql:83`](../../supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql#L83)

- `grace_day_validate()` — eligible day, still owed, allowance remaining, all checked before the row is ever written.
  [`20260825110000_a_countable_way_to_be_forgiven.sql:133`](../../supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql#L133)

- The per-account lock the review added — without it, two different days spent concurrently could both pass the same monthly count.
  [`20260825110000_a_countable_way_to_be_forgiven.sql:156`](../../supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql#L156)

- `appeal_hold_penalty()`'s own new refusal — the mutual-exclusion fix the review's own I/O Matrix amendment records.
  [`20260825110000_a_countable_way_to_be_forgiven.sql:253`](../../supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql#L253)

**The fold-in — where settlement, alone, does the actual correcting**

- `apply_grace_days()` — read-only-source-table, mirrors `supersede_expiries()`'s own shape exactly.
  [`20260825110000_a_countable_way_to_be_forgiven.sql:391`](../../supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql#L391)

- `grace_allowance_remaining` — the one source every screen reads, never a client-side tally.
  [`20260825110000_a_countable_way_to_be_forgiven.sql:357`](../../supabase/migrations/20260825110000_a_countable_way_to_be_forgiven.sql#L357)

**The cross-story fix — and why it had to be redone once**

- The appeal's own original penalty, read directly by its own id — permanent and unambiguous, unlike the settlement-comparison approach it replaced.
  [`referee-appeal-detail.tsx:141`](../../components/referee-appeal-detail.tsx#L141)

- Every outcome this screen now renders from that one read.
  [`referee-appeal-detail.tsx:280`](../../components/referee-appeal-detail.tsx#L280)

**Referee's own list, and doer-facing controls**

- Where a doer actually spends one — the Ledger row and Day summary controls, including the review's race/consistency fixes (already-spent no longer double-decrements, distinguishing accessible names, the `mounted` guard).
  [`ledger.tsx`](../../components/ledger.tsx)
  [`today.tsx`](../../components/today.tsx)

**Peripherals**

- The full Grace Day test file: every I/O Matrix row plus the review-added mutual-exclusion case.
  [`5-1-a-countable-way-to-be-forgiven.sql`](../../supabase/tests/5-1-a-countable-way-to-be-forgiven.sql)

- The new `'waived'` case, and the label/family it renders as.
  [`ledger.ts`](../../lib/ledger.ts)

- Where this story's own deferred findings are recorded.
  [`deferred-work.md`](../../_bmad-output/implementation-artifacts/deferred-work.md)
