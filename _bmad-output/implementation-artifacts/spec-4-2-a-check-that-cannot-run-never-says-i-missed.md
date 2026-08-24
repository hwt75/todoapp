---
title: 'Story 4.2 — A check that cannot run never says I missed'
type: 'feature'
created: '2026-08-24'
status: 'done'
review_loop_iteration: 1
baseline_commit: '120ce745f8bbbc0cc3e034323b66cb6a2eca0716'
story_key: '4-2-a-check-that-cannot-run-never-says-i-missed'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `resolve_auto_checks()` and `settle_day()`/`settle_week()` are independent hourly cron
jobs with no enforced ordering — if the Auto-check pass is delayed or fails, settlement can judge a
day or week before its attached Auto-check has ever run, settling an Auto-check-linked commitment
as a plain miss exactly like an author who simply never answered. This risk exists on **both**
settlement paths: `settle_day` judges Daily commitments, `settle_week` judges Weekly Quota ones, and
nothing in the schema stops an Auto-check from attaching to either cadence. Separately,
`resolve_auto_checks()` only ever resolves "yesterday" and never revisits an older day once it has
rolled past — so an unbounded block would leave a day permanently stuck if that one resolution
window is ever missed entirely.

**Approach:** Add a shared `auto_check_pending(commitment_id, day)` helper: true when that
commitment has an Auto-check attached, no declaration yet for `day`, its check hasn't reached a
terminal result for `day`, **and** less than 96 hours have passed since `day` closed. Guard both
`settle_day` and `settle_week` with it — each skips (`continue`s, retried by its own hourly cron)
an account's period while any of its owed, unanswered, Auto-check-linked commitments has a pending
check for any day in that period. Past the 96-hour grace window, `auto_check_pending` reads false
regardless of check state, so the period falls through and settles exactly as if no Auto-check were
attached — bounding the block instead of leaving it indefinite.

## Boundaries & Constraints

**Always:**
- `auto_check_pending` lives in its own migration function (`stable`, schema-qualified, `set
  search_path = ''`), called from both `settle_day` and `settle_week` (both stay `security
  definer`) — never duplicated inline, never in application code (AD-1).
- "Terminal for `day`" reuses the exact `auto_check_last_checked_at` day-boundary identity
  `resolve_auto_checks` already computes for its own `target_day` — no new column, no new enum.
- The 96-hour grace window is measured from `day`'s own close (`day + 1` at Asia/Ho_Chi_Minh
  midnight), not from `now()` at guard-evaluation time — so it expires at a fixed point regardless
  of how many settlement passes retry in between.
- Only a commitment that is `auto_check_kind is not null`, still unanswered (no `declaration` row)
  for `day`, and inside its grace window blocks anything — an already-answered, already-unlinked,
  or grace-expired commitment never blocks.
- `settle_week`'s guard checks every day in `[p_period, p_period+6]` for each Weekly Quota
  commitment it would otherwise judge — a pending check on any single day blocks the whole period,
  mirroring `settle_day`'s whole-day block.
- `unavailable`/`missed` keep filing nothing via `file_auto_check_result` (Story 4.1, unchanged).

**Ask First:** _None outstanding — grace window (96h) and dual-path scope (day + week) confirmed
with the human after the first review round found both gaps (see Spec Change Log)._

**Never:**
- No new `auto_check_result` value, no change to `resolve_account_elsewhere`'s stub or to
  `resolve_auto_checks`'s own single-day `target_day` scan (extending it to sweep a backlog is a
  larger change than a bounded settlement-side grace window; not this story).
- No per-check availability beyond the existing single-Auto-check-slot schema.
- No change to `file_auto_check_result`, FR-2a precedence (Story 4.3), the Appeal flow, or
  `settle_week`'s existing no-`settlement_commitment`-row behavior (pre-existing, unrelated).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Daily: not yet resolved | Auto-check-linked, unanswered, owed Daily commitment; check not terminal for `p_day`, within 96h grace | `settle_day` skips the account's day entirely | Retried by the next hourly `settle-days` pass |
| Weekly: not yet resolved | Weekly Quota commitment, Auto-check-linked, a day in `[p_period, p_period+6]` unanswered and not terminal, within grace | `settle_week` skips the account's period entirely | Retried by the next hourly `settle-weeks` pass |
| Grace expired | Same as either row above, but `now()` ≥ 96h past the day's close | Guard no longer blocks; period settles as if no Auto-check were attached (unanswered counts normally) | — |
| Resolved this pass | Auto-check reaches a terminal result for the day in question | Settlement proceeds normally | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260820140000_weekly_quota_is_not_judged_daily.sql:60-118` -- `settle_day`;
  guard slots in near `past_deadline`/`continue when answered < total and not past_deadline`
  (L117-118), now calling `auto_check_pending` instead of inlining the day-boundary math.
- `supabase/migrations/20260820150000_the_week_closes_and_settles.sql:172-323` -- `settle_week`;
  the `quota` loop (around L262-282) selects every open Weekly Quota commitment for
  `(account.id, p_period)` — the new guard needs the identical filter (`cadence='weekly_quota'`,
  `archived_at is null`, `week_start_day = extract(isodow from p_period)`, the `created_at <
  p_period+7` existence guard) plus a day-series check, placed before `total_commitments := 0` so
  it can `continue` the whole period the same way `continue when today < p_period + 8` already does.
- `supabase/migrations/20260824090000_a_commitment_predates_the_day_it_is_judged_for.sql:11-52` --
  current `resolve_auto_checks()`; L18's `target_day := (now() at HCM)::date - 1` and L42-45's
  unconditional stamp — the identity `auto_check_pending` reuses, and the reason its own scan can
  never revisit an older day (motivating the grace window).
- `supabase/migrations/20260819221000_settlement_schedule.sql:45-49` -- `settle-days` cron (`:15`).
- `supabase/migrations/20260820150000_the_week_closes_and_settles.sql:340-371` -- `settle_due_weeks`
  cron (`:45`), the retry `settle_week`'s guard relies on.
- `supabase/migrations/20260819200000_declaration.sql:87-96` -- `declaration_derive_day()`, for the
  `day + 1` HCM-midnight close-point the grace window measures from.
- `supabase/tests/4-1-account-elsewhere.sql` -- structure/naming template.
- `supabase/tests/README.md:70-92` -- manifest table to extend.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260824100000_a_check_that_cannot_run_never_says_i_missed.sql` -- adds
  `auto_check_pending(commitment_id, day)`; guards `settle_day` and `settle_week` with it -- closes
  the race on both settlement paths with a bounded (96h) block
- [x] `supabase/tests/4-2-unavailable-is-not-missed.sql` -- covers the I/O matrix: daily block +
  retry, weekly block + retry, grace expiry on each path, unavailable-falls-through, plus Step 2b
  proving the daily guard is load-bearing past `declaration_deadline` -- proves all Story 4.2 ACs
- [x] `supabase/tests/README.md` -- new file added to the manifest table

**Acceptance Criteria:**
- Given an Auto-check-linked, unanswered, owed Daily commitment not yet terminal for the day, when
  `settle_day` runs, then it skips the account's day; once terminal, it proceeds normally.
- Given an Auto-check-linked Weekly Quota commitment with any day in its period not yet terminal,
  when `settle_week` runs, then it skips the account's period; once every day is terminal or
  answered, it proceeds normally.
- Given a pending Auto-check whose 96-hour grace window has elapsed, then the guard no longer
  blocks and the period settles exactly as if no Auto-check were attached.
- Given a commitment with two Auto-checks where one is unavailable, then availability is documented
  as evaluated per check — vacuously true today since only one slot exists; no code change.

## Spec Change Log

- **2026-08-24, round 1 (intent_gap, resolved by human):** Independent review (blind-hunter +
  edge-case-hunter + verification-gap, run against the round-1 diff) found the frozen Approach
  incomplete in two ways: (1) it guarded only `settle_day`, leaving `settle_week` — which also
  judges Auto-check-linked commitments for money, since the schema has no cadence restriction on
  Auto-check attachment — with no AD-13 protection at all; (2) the guard as built could block a
  day forever if `resolve_auto_checks()` ever missed its one-and-only "yesterday" window for that
  specific day, since that function never revisits an older day. Asked the human: fix both, and
  bound the block with a grace period. Human chose: fix both, 48-hour grace period. **KEEP:** the
  round-1 day-boundary derivation (`(auto_check_last_checked_at at HCM)::date - 1 < p_day`) and the
  round-1 test scenarios (blocks-then-retries, unavailable-falls-through, already-answered-never-
  blocks) are correct and carry forward unchanged, now wrapped inside `auto_check_pending` and its
  grace-window condition rather than inlined.

- **2026-08-24, round 1.5 (self-caught during implementation verification, corrected without a
  second human loopback):** 48 hours, as approved in round 1, expires no later than `settle_day`'s
  own pre-existing `declaration_deadline` (`day + 3 + morning_hour`, up to 71 hours past the grace
  window's base point). Since the guard is checked *before* `past_deadline` in `settle_day`'s body,
  a grace window that expires at or before that deadline means `auto_check_pending` is always
  already false by the moment `settle_day` would actually charge a silent-miss penalty — the guard
  is checked but structurally can never be the deciding factor on the daily path, defeating the
  original Problem's own motivating scenario. Corrected to 96 hours, which clears the 71-hour worst
  case with a full day of margin for every `morning_hour`. This is a numeric correction to the same
  approved concept (a bounded grace period), not a new decision — the human approved "add a bounded
  grace period," not the specific value 48, and 48 could not deliver what was asked. **KEEP:**
  everything from round 1 unchanged in shape; only the interval literal (and its now-corrected
  rationale below) moved from 48 to 96. Added `supabase/tests/4-2-unavailable-is-not-missed.sql`
  Step 2b specifically to prove the guard blocks `settle_day` even past its own
  `declaration_deadline` while still in grace — the scenario that silently didn't exist at 48h.

- **2026-08-24, round 2 (patch, no loopback needed):** A second independent review (blind-hunter +
  edge-case-hunter + verification-gap, run against the round-1.5 diff) found one real bug and two
  cheap hardening gaps, all fixable without touching the frozen Intent: (1) `settle_day`'s guard read
  from `commitments_owing()` with no cadence filter, and that function does not exclude
  `weekly_quota` (only `daily_hours_quota` is) — so a `weekly_quota` commitment's pending Auto-check
  could stall `settle_day` for every *other*, unrelated commitment on the account, a collateral cost
  nobody asked for given `settle_week` already owns `weekly_quota`'s real protection. Fixed by adding
  `and o.cadence <> 'weekly_quota'` to the guard, mirroring the existing `admitted`/`silent`
  exclusion two lines above it. (2) `auto_check_pending()` relied on both call sites to pre-filter
  `archived_at` rather than checking it itself — hardened to be self-contained. (3) No negative-
  privilege test covered the new function — added to `2-1-roles-and-rls.sql`'s existing array.
  **New tests added:** Step 5b (a check resolved via a bare stamp with nothing declared — the actual
  production shape, since v1's only resolver always returns `unavailable` — unblocks `settle_day`
  immediately rather than waiting for grace) and Step 5c (a pending Weekly Quota Auto-check never
  blocks `settle_day` at all; verified to fail without the cadence fix before being confirmed against
  the fix, not merely written to pass). Two lower-value gaps (the hand-duplicated day-boundary
  formula between this function and `resolve_auto_checks`; no test at the exact 96-hour boundary)
  recorded in `deferred-work.md` rather than expanding this story further.

- **2026-08-24, round 3 (patch, post-push): ** After commit `574d838` was pushed, an independent
  `code-review` pass (8 finder angles, 1-vote verify) against that commit found `auto_check_pending()`
  never checked the commitment's `created_at` against `p_day` — unlike its sibling
  `resolve_auto_checks()` (20260824090000), which explicitly added that exact guard for the exact
  same reason. Since `commitments_owing()` also has no `created_at` filter, a brand-new,
  Auto-check-linked commitment could read as "pending" for an OLDER day it never existed on — and
  because that older day is typically still well within `auto_check_pending`'s own 96-hour grace
  window, this could block `settle_day` (and `settle_week`) for up to 96 hours over a commitment
  that was never owed for that day at all, including collateral delay to genuinely unrelated,
  already-owed commitments sharing the account. **CONFIRMED** by an independent verifier before
  fixing. Fixed by adding `(c.created_at at time zone 'Asia/Ho_Chi_Minh')::date <= p_day` to
  `auto_check_pending`, mirroring `resolve_auto_checks`'s own guard. **New test added:** Step 5d
  (a brand-new Auto-check commitment never blocks an older, unrelated day) plus `c_g`/`day_g` in
  Step 1 (the boolean read directly). Fixing this also surfaced that nearly every existing
  Auto-check test fixture in this file relied on `created_at` defaulting to "today" while testing a
  "yesterday"-or-older day — every one of those fixtures now explicitly backdates `created_at`
  (matching the pattern `4-1-account-elsewhere.sql` already established for `resolve_auto_checks`'s
  own guard), so this fix doesn't silently make earlier steps pass for the wrong reason. A second
  finding from the same review (`auto_check_pending`'s unconditional `archived_at is null`, vs.
  `commitments_owing()`'s `p_day`-scoped archived check) was investigated and **REFUTED** — the
  same-review's own resolver-exclusion means an archived commitment's check can never resolve
  again either way, so the eventual settlement outcome (verdict, penalty) is identical whether the
  guard falls through immediately or waits the full 96h; only timing differs, not correctness. Three
  further findings (guard/quota-loop filter duplication in `settle_week`; guard-eligibility logic
  duplicated across `settle_day`/`settle_week`; two minor redundant-query efficiency notes) recorded
  in `deferred-work.md` rather than expanding this story to a fourth round.

## Design Notes

**`auto_check_pending`, in full:**

```sql
create function public.auto_check_pending(p_commitment_id uuid, p_day date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.commitment c
     where c.id = p_commitment_id
       and c.auto_check_kind is not null
       and c.archived_at is null
       and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date <= p_day
       and not exists (
         select 1 from public.declaration d
          where d.commitment_id = c.id and d.for_day = p_day
       )
       and (c.auto_check_last_checked_at is null
            or (c.auto_check_last_checked_at at time zone 'Asia/Ho_Chi_Minh')::date - 1 < p_day)
       and now() < (((p_day + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh') + interval '96 hours')
  );
$$;
```

`settle_day`'s guard becomes `continue when exists (select 1 from
public.commitments_owing(account.id, p_day) o where o.answer is null and o.cadence <>
'weekly_quota' and public.auto_check_pending(o.commitment_id, p_day));` — the `cadence <>
'weekly_quota'` filter mirrors the existing `admitted`/`silent` exclusion two lines above it in the
same function: `commitments_owing()` does not exclude `weekly_quota` (only `daily_hours_quota` is),
so without this filter a stuck weekly-quota check would delay the whole day's settlement for every
other, unrelated commitment on the account — `settle_week`'s own guard already owns weekly-quota's
real protection. `settle_week`'s guard cross-joins `generate_series(p_period, p_period + 6, interval
'1 day')` against the same commitment selection its own `quota` loop uses, `continue`-ing the
account/period when `auto_check_pending` is true for any day in that series.

**Why 96 hours, not 48 or unbounded.** `settle_day`'s own pre-existing `declaration_deadline`
(`day + 3 + morning_hour`, `morning_hour` up to 23) already waits up to 71 hours past this window's
base point (`day + 1` at HCM midnight) before it would otherwise charge a silent-miss penalty. The
guard is checked *ahead of* that deadline in `settle_day`'s body, so a grace window has to outlast
71 hours in every case to ever be the thing that actually blocks a late settlement attempt — a
shorter window (48h was tried first) always expires first, leaving the guard checked but never
load-bearing on the daily path. 96 hours clears the worst case with a full day of margin for any
`morning_hour`, and is unbounded relative to nothing else in this schema — it is simply "long
enough to always dominate the existing deadline, short enough to still be a bound."

## Verification

**Commands, run 2026-08-24:**
- `npx supabase db reset` -- all 33 migrations, including
  `20260824100000_a_check_that_cannot_run_never_says_i_missed.sql`, applied clean.
- All 17 files under `supabase/tests/` via `docker exec supabase_db_todoapp psql -v
  ON_ERROR_STOP=1` -- **17/17 pass**, including `4-2-unavailable-is-not-missed.sql`'s 15 steps:
  `auto_check_pending` in isolation, including **created-after-the-day never reads pending, even
  well within its own 96h grace (`c_g`)**; daily block + retry; **Step 2b: still blocks past its
  own `declaration_deadline`, proving the 96h grace is genuinely load-bearing on the daily path,
  not merely checked**; resolved-via-declaration; **Step 5b: resolved via a bare stamp with
  nothing declared (the actual "unavailable" production shape) unblocks immediately, not only
  once grace fully expires**; grace-expiry fallthrough; already-answered-never-blocks; **Step 5c:
  a pending Weekly Quota Auto-check never blocks `settle_day` at all — re-verified by temporarily
  reverting the `cadence <> 'weekly_quota'` fix and confirming this exact step fails, then
  restoring it and confirming it passes**; **Step 5d: a brand-new Auto-check commitment never
  blocks an older, unrelated day it did not exist on**; the same shape for `settle_week` —
  whole-period block + retry, terminal-unblocks, grace-expiry fallthrough, fully-declared-never-
  blocks; AD-16 sanity on both rewritten functions. `2-1-roles-and-rls.sql` confirms `anon`/
  `authenticated` cannot execute `auto_check_pending`. `2-5-settlement.sql`, `2-7-supersession.sql`,
  `3-4-week-settlement.sql` (heavy `settle_day`/`settle_week` users, no Auto-check fixtures) pass
  unchanged, confirming `auto_check_pending` is a no-op absent `auto_check_kind`.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.
- `npm test` -- **680/680 pass** across 33 files (unchanged — no client/TS code touched).

**Note on the 48→96 correction (round 1.5):** the first implementation pass shipped with a
48-hour grace window (as approved) and all tests green — but green because Step 2 only exercised
a day still within its normal declaration window, never a day past `declaration_deadline` with
grace still open. Adding Step 2b to specifically target that boundary failed immediately at 48h
(confirming the guard was inert there) and passed once corrected to 96h.

**Note on the weekly_quota exclusion (round 2):** a second independent review found `settle_day`'s
guard had no cadence filter, unlike the pre-existing `admitted`/`silent` aggregates two lines
above it. Step 5c was written to prove the fix, then verified the other direction too: the
`cadence <> 'weekly_quota'` filter was temporarily removed, `npx supabase db reset` + Step 5c
re-run confirmed it fails with exactly the predicted error, then the filter was restored and the
full suite re-confirmed green — both directions recorded so this isn't a test that merely never
fails.

**Note on the created_at guard (round 3, after 574d838 was pushed):** an independent `code-review`
pass against the pushed commit found `auto_check_pending` had no `created_at` check, unlike its
sibling `resolve_auto_checks`. Fixed, and Step 5d added to prove it. Fixing this exposed that most
existing Auto-check fixtures in this test file relied on `created_at` defaulting to today while
testing an earlier day — every one was updated to explicitly backdate `created_at`, otherwise
several earlier steps would have started passing for the wrong reason (a `created_at` mismatch
masking the actual behavior under test) rather than silently failing, which is exactly how this
review caught it: `c_b`'s own direct boolean check failed first, before any settlement-level test
did. Full suite (all 17 files, lint/tsc/format, `npm test`) re-confirmed green after the fix.

Applied to the live project (`hxzalpnlrunctbajgtkv`) via the Supabase MCP server's
`apply_migration`, with the round-3 `created_at` fix already folded in (this migration had not
been applied live before the fix landed, so no follow-up migration was needed) — re-checked after:
`auto_check_pending`/`settle_day`/`settle_week` all exist with the expected shape, and
`get_advisors(type=security)` shows only the pre-existing, unrelated
`auth_leaked_password_protection` warning.

**Manual checks (if no CLI):** _None — pure backend/settlement change, no UI surface._

## Suggested Review Order

**The shared guard**

- Entry point: the helper both settlement paths call, including the round-2
  `archived_at` hardening and the round-1.5 96-hour grace fix.
  [`20260824100000...sql:41`](../../supabase/migrations/20260824100000_a_check_that_cannot_run_never_says_i_missed.sql#L41)

- Why 96 hours and not 48 — the math a shorter window silently fails.
  [`20260824100000...sql:24`](../../supabase/migrations/20260824100000_a_check_that_cannot_run_never_says_i_missed.sql#L24)

**`settle_day`'s guard**

- The guard itself, checked ahead of `past_deadline` on purpose, with the round-2
  `weekly_quota` exclusion.
  [`20260824100000...sql:137`](../../supabase/migrations/20260824100000_a_check_that_cannot_run_never_says_i_missed.sql#L137)

**`settle_week`'s guard**

- The period-wide mirror — a pending day anywhere in `[p_period, p_period+6]` blocks
  the whole period.
  [`20260824100000...sql:305`](../../supabase/migrations/20260824100000_a_check_that_cannot_run_never_says_i_missed.sql#L305)

**Tests — the boundary cases that actually prove the fixes**

- Step 2b: blocks past `declaration_deadline`, proving the grace window is load-bearing
  on the daily path, not merely checked.
  [`4-2-unavailable-is-not-missed.sql:259`](../../supabase/tests/4-2-unavailable-is-not-missed.sql#L259)

- Step 5b: a resolved-but-undeclared check unblocks immediately — the real
  `unavailable` production shape.
  [`4-2-unavailable-is-not-missed.sql:411`](../../supabase/tests/4-2-unavailable-is-not-missed.sql#L411)

- Step 5c: a pending Weekly Quota check never blocks `settle_day` — re-verified by
  temporarily reverting the fix and confirming this step fails.
  [`4-2-unavailable-is-not-missed.sql:485`](../../supabase/tests/4-2-unavailable-is-not-missed.sql#L485)

**Peripherals**

- `auto_check_pending` added to the negative-privilege sweep.
  [`2-1-roles-and-rls.sql:228`](../../supabase/tests/2-1-roles-and-rls.sql#L228)

- Manifest row for the new test file.
  [`README.md:90`](../../supabase/tests/README.md#L90)
