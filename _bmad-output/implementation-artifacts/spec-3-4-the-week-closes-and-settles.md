---
title: 'Story 3.4 — The week closes and settles'
type: 'feature'
created: '2026-08-20'
status: 'done'
review_loop_iteration: 1
baseline_commit: '06dfb449cb402350ee225cce1f07df6f0a5dfd9f'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A Weekly Quota commitment has never had its own deadline. Story 3.3 gave it a live
position (`weekly_quota_progress`), and the fix in `20260820140000_weekly_quota_is_not_judged_daily.sql`
made sure it is never judged as a daily miss — but nothing ever closes the week. A shortfall
currently produces no verdict and no penalty at all.

**Approach:** One weekly settlement pass, `settle_week()`, mirroring `settle_day()`'s shape exactly
(AD-2, AD-5, AD-16): judges every open Weekly Quota commitment against its own target at the end of
its own week (`week_start_day` is per-commitment, not per-account), and on shortfall writes exactly
one Failed-Day-equivalent penalty for the week — never one per commitment — reusing FR-13's rule.
Delivered as an outbox notification first; the existing Ledger is the screen behind it, extended
with a week row alongside its day rows.

## Boundaries & Constraints

**Always:**

- `settle_week(p_period date, p_override boolean)` and its `settle_due_weeks()` cron wrapper mirror
  `settle_day`/`settle_due_days` structurally: one `security definer` plpgsql pass per call, the
  `app.settlement_invocation` guard, and the AD-16 override refusal for `is_live_doer`.
- `(subject, period, kind)` stays the one idempotency key (AD-5) — `settlement_kind` gains `'week'`;
  no new table.
- The held-count rule lives in one function, read by both `weekly_quota_progress` (live, today) and
  `settle_week` (frozen, a closed week) — never two copies of the same counting logic (AD-8, the same
  reasoning `commitments_owing()` already established).
- A Failed Week costs exactly one `penalty_amount_dong()`, however many Weekly Quota commitments fell
  short that week, and only counts commitments with `carries_penalty = true` (FR-13, mirrored).
- The verdict and its outbox notification are written in the same transaction (AD-3).
- `components/ledger.tsx`'s `settlement_current`/`penalty_current` reads gain `kind = 'day'` before
  this ships — otherwise a week row silently corrupts the existing day list the moment one exists.

**Ask First:**

- The notification's literal copy (no source doc specifies one for Week Close) — proposed in Design
  Notes, modeled on `day_summary_body`'s established voice; the human approves it as part of this spec.

**Never:**

- Held Penalty resolution (AD-15's `'held'`/`'collected'` states) — `penalty_state` has only `'owed'`
  today; nothing exists yet to resolve until Epic 4's appeal flow adds it. Record in deferred-work.md.
- A week-level supersession/correction pass (a 2.7 equivalent for weeks) — a late-but-timely
  declaration arriving after a week already closed is not retroactively corrected by this spec.
  Record the gap in deferred-work.md rather than silently accepting it.
- A new screen. The Ledger is the detail surface; no new component or route.
- Per-commitment week-outcome freezing or a week-level chain — not required by any AC here.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
| --- | --- | --- | --- |
| Shortfall, `carries_penalty = true` | 1 of 3 held, week over | `failed`, one penalty | N/A |
| Target met exactly | 3 of 3 held | `clean`, no penalty | N/A |
| Two commitments, same week_start_day, one short one met | Same account, same period | Still exactly one penalty (FR-13) | N/A |
| Shortfall, `carries_penalty = false` | 1 of 3 held | `clean` — a penalty-free miss costs nothing | N/A |
| Two commitments, different `week_start_day` | Same account | Two separate `settlement` rows, two periods | N/A |
| Commitment archived mid-week | `archived_at` before week end | Excluded, matching `weekly_quota_progress` | N/A |
| Re-run of an already-settled week | Same `(subject, period, kind)` | No-op (AD-5) | N/A |
| Override against the live doer account | `is_live_doer = true` | Raises, never settles (AD-16) | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260820130000_the_week_counts_its_own_days.sql:80-111` — `weekly_quota_progress`;
  its held-count subquery becomes the shared helper (D2), the view calls it instead of inlining it.
- `supabase/migrations/20260819220000_settlement.sql:11-12` — `settlement_kind`, `day_verdict`; kind
  gains `'week'`, `day_verdict` is reused unchanged (week rows only ever write `clean`/`failed`).
- `supabase/migrations/20260820140000_weekly_quota_is_not_judged_daily.sql:60-198` — live `settle_day`,
  the structural twin `settle_week` mirrors (guard clauses, `on conflict ... do nothing`, outbox call).
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:242-267` — `settle_due_days`'s
  lookback-window wrapper shape, mirrored by `settle_due_weeks`.
- `supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql:169-172` — the
  cron-offset convention (`:05`, `:15`, `:25` taken); the new schedule takes `:45`.
- `supabase/migrations/20260819230000_penalty.sql` — `penalty_amount_dong()`, `penalty` table, the
  insert shape `settle_day` already uses.
- `supabase/migrations/20260819180000_outbox.sql:134-154` — `outbox_enqueue(owner, dedupe_key, payload)`.
- `supabase/migrations/20260819150000_commitment.sql:29-30,60-62` — `weekly_target`/`week_start_day`,
  and the comment on why the start day is per-commitment, not per-account.
- `lib/ledger.ts` — `buildLedger`, `LedgerRow`; gains a week row alongside day rows.
- `components/ledger.tsx:29-39` — add `.eq('kind','day')` to both existing reads; add the week read.
- `supabase/tests/2-5-settlement.sql` — structural model for the new SQL test file.

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/20260820150000_the_week_closes_and_settles.sql` — `settlement_kind` gains
      `'week'`; extract `weekly_held_count(p_commitment_id, p_week_start)` from
      `weekly_quota_progress` and have the view call it; `settle_week(p_period, p_override)`;
      `settle_due_weeks()` wrapper + its `cron.schedule` at `:45`.
- [x] `supabase/tests/3-4-week-settlement.sql` — the matrix's database rows, modeled on
      `2-5-settlement.sql`: shortfall/met/mixed-commitments/penalty-free/different-week-start-day/
      re-run/AD-16 override.
- [x] `lib/ledger.ts` + test — a week row (`kind: 'week'`, verdict, amount) folded in and sorted
      alongside day rows; existing day-row behavior unchanged.
- [x] `components/ledger.tsx` + test — `kind = 'day'` filter on both existing reads; a third read for
      `kind = 'week'` settlements/penalties; a week row renders distinctly from a day row.

**Acceptance Criteria:**

- Given a Weekly Quota commitment short of its target when its week ends, then the week settles
  `failed` with exactly one penalty, regardless of how many commitments fell short that account's way.
- Given an already-settled week, when the pass runs again, then nothing changes (AD-5).
- Given a closed week, then a notification is enqueued in the same transaction as the verdict, and the
  Ledger shows the week as its own row without altering any existing day row.

### Review Findings

<!-- Code review 2026-08-21, iteration 1. Layers: blind-hunter, edge-case-hunter, verification-gap, acceptance-auditor. -->

- [x] [Review][Decision] The week settles before the final day's declaration can exist — `for_day := answered_at::date - 1` (20260819200000_declaration.sql:93) means day `P+6`'s declaration is filed on `P+7` (morning gate ~07:00), but `settle_week` gated only `today < p_period + 7` and the cron swept at 00:45 — so a week whose target needs its final day **always** settled `failed` hours before the answer could possibly arrive. **Resolved:** gate moved to `today < p_period + 8`; `settle_due_weeks()`'s sweep window moved to `today-14 .. today-8` to match. [supabase/migrations/20260820150000_the_week_closes_and_settles.sql]
- [x] [Review][Decision] A commitment created mid-week is judged against its full `weekly_target`. **Resolved: kept as-is** — a commitment is charged in full starting the week it exists in, matching `weekly_quota_progress`'s own live behavior; no partial-week exemption.
- [x] [Review][Decision] Shipped notification copy deviates from the Design-Notes literal the Ask-First boundary reserved for human approval. **Resolved: shipped copy approved** — Design Notes below updated to match (weekday in the self-dating is required by `push_body_is_sendable`; the multi-shortfall sum is the one well-defined figure for two-or-more commitments sharing a `week_start_day`).
- [x] [Review][Decision] `missed_count` semantics diverged from `settle_day`: a week row counted penalty-free shortfalls where a day row never can. **Resolved:** `settle_week` now writes `admitted` (penalty-carrying shortfalls only) into `missed_count`, mirroring `settle_day` exactly — `failed <=> missed_count > 0` holds for every row regardless of `kind`. The notification's own `shortfall_count`/`shortfall_name` (which do count a penalty-free miss, so it is still named) are unchanged. [supabase/migrations/20260820150000_the_week_closes_and_settles.sql]
- [x] [Review][Decision] Archiving after the week ends but before the :45 settle erases the closed week's verdict entirely. **Resolved: deferred** — recorded in deferred-work.md; the fix (a boundary tighter than `archived_at is null`) is low-severity and shares reasoning with the missing week-level supersession pass already deferred by this spec.
- [x] [Review][Patch] The SQL test suite could not pass as written: every fixture commitment's `created_at` defaulted to `now()`, filtered out by `settle_week`'s cutoff. Fixed — every fixture now carries an explicit backdated `created_at` via `v_backdate`. [supabase/tests/3-4-week-settlement.sql]
- [x] [Review][Patch] The `created_at` cutoff scenario was planned but never written. Fixed — Step 11 now exercises `v_user8`/`v_c8`. [supabase/tests/3-4-week-settlement.sql]
- [x] [Review][Patch] `settle_due_weeks()` was never executed by any test. Fixed — Step 13 calls it directly and asserts a just-closed week settles through the schedule path, resetting the transaction-local marker afterward. [supabase/tests/3-4-week-settlement.sql]
- [x] [Review][Patch] `settle_week`, `settle_due_weeks`, `week_summary_body` were missing from 2-1's protected-function list. Fixed. [supabase/tests/2-1-roles-and-rls.sql]
- [x] [Review][Patch] `penalty_current`'s new `kind`/`period` columns were asserted nowhere. Fixed — Step 1 now asserts them directly. [supabase/tests/3-4-week-settlement.sql]
- [x] [Review][Patch] Notification-body branches were untested (no `shortfall_count > 1` scenario, no body assertion in steps 3–4). Fixed — Step 12 covers the pluralized/summed branch; Step 4 now asserts its own body. [supabase/tests/3-4-week-settlement.sql]
- [x] [Review][Patch] `buildLedger`'s week-before-day tie-break was never asserted. Fixed. [lib/ledger.test.ts]
- [x] [Review][Patch] Today's owed total including week penalties was an accident of no filter, not a verified decision. Fixed — a test now pins the unfiltered read as intentional. [components/today.test.tsx]
- [x] [Review][Patch] Test cosmetics: step 8's message miscounted passes; date arithmetic lacked explanation. Fixed. [supabase/tests/3-4-week-settlement.sql]
- [x] [Review][Defer] Error swallowing on 4 of 5 `components/ledger.tsx` reads (only the day-settlements read is checked) [components/ledger.tsx:29] — deferred, pre-existing; already recorded in deferred-work.md by this story with the uniform-fix rationale.
- [x] [Review][Defer] Locale coupling in `week_summary_body`: `FMDay` follows `lc_time` (already recorded), `translate(',', '.')` only corrects comma-grouping locales, and the `immutable` label mirrors `day_summary_body`'s own mislabel (`to_char` is stable) [supabase/migrations/20260820150000_the_week_closes_and_settles.sql:118] — deferred, pre-existing mirrored pattern.
- [x] [Review][Defer] Bounded lookback orphan: after a cron outage longer than the window, weeks older than `today - 14` never settle — mirrors `settle_due_days`'s own `today-5 .. today-1` property [supabase/migrations/20260820150000_the_week_closes_and_settles.sql:324] — deferred, pre-existing trade-off, now recorded.

## Design Notes

<!-- Updated 2026-08-21 to match the shipped literal, per the review's Ask-First resolution
     above. The original proposal below is struck through rather than deleted, so the
     renegotiation is traceable. -->

~~**Proposed notification copy**, modeled on `day_summary_body`'s voice and satisfying the outbox
body-rule constraint (self-dated, past tense): `"<held> of <target>, week of <period>. That's
<amount>₫."` on a shortfall, `"<target> of <target> held, week of <period>."` when met — e.g. *"1 of 3
held, week of 2026-08-17. That's 500.000₫."* One commitment named per notification when exactly one
fell short (mirroring `settle_day`'s own single-suggestion rule); otherwise state the count only.~~

**Approved notification copy** (human-approved 2026-08-21, after the deviation forced by
`push_body_is_sendable` — a bare ISO date self-dates against neither its clock-time nor its
weekday check, so a named weekday is required): `"<name>, <held> of <target>, week of
<Weekday>, <date>. That's <amount>₫."` on a single named shortfall, `"<target> of <target>
held, week of <Weekday>, <date>."` when met — e.g. *"Gym, 1 of 3 held, week of Monday,
2026-08-17. That's 500.000₫."* When two or more commitments fall short together, the sentence
names none of them and states the count instead, summing `held`/`target` across every
commitment judged that period — the one well-defined combined figure rather than an
arbitrary pick: `"<N> commitments fell short, <held> of <target> held, week of <Weekday>,
<date>. That's <amount>₫."`

**Why `day_verdict` is reused rather than a new enum.** A week never expires the way a day does —
there is no per-week deadline this spec introduces — so `'expired'` is simply never written for a
`kind = 'week'` row. Reusing the type avoids touching `settlement.verdict`'s column definition at all.

## Verification

**Commands:**

- `npm test` — new/changed `lib/ledger`, `components/ledger` tests pass alongside the existing suite.
- `npx tsc --noEmit && npm run lint && npm run format:check` — clean.
- `npx supabase db reset` then every file under `supabase/tests/`, including the new
  `3-4-week-settlement.sql` — `PASS.` for all.
