---
title: 'Story 4.7 — The app does the asking, the referee does the collecting'
type: 'feature'
created: '2026-08-25'
status: 'done'
review_loop_iteration: 1
baseline_commit: '7f91ad915cc7ae3465a58d7bbbbd6a42198f26a4'
story_key: '4-7-the-app-does-the-asking-the-referee-does-the-collecting'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** An owed Penalty has no collection path at all — the referee can rule an Appeal (4.6)
but has no way to ask for the money or record that it was paid. FR-21 needs the uncomfortable
message written for him and a single action that discharges the debt.

**Approach:** A referee-callable `mark_penalty_collected()` Postgres function (mirroring
`rule_appeal()`'s own shape: `role_from_table()` gate, guarded `owed -> collected` transition) is
the only way a debt is ever discharged — a pure state transition, no settlement/chain correction
needed (the day already correctly counted the miss; paying it doesn't change what happened).
`referee-home.tsx` gains an "Owed penalties" list, oldest first, each row showing the amount, the
day, and the commitment(s) missed, with a pre-written copy-to-clipboard message and a Mark
Collected control. A new referee-read policy on `settlement_commitment` supplies the missed
commitment name(s) this list needs.

## Boundaries & Constraints

**Always:**
- `mark_penalty_collected(p_penalty_id uuid)` checks `role_from_table() = 'referee'` first, before
  any row is read (mirrors `rule_appeal()`'s own `is distinct from` idiom, never `<>`, and never
  `role_from_token()` for a money-guarding write).
- The transition is `update penalty set state = 'collected' where id = :id and state = 'owed'` —
  identical guarded shape to `rule_appeal()`/`void_expired_appeals()`. Zero rows affected is
  refused with a clear message, never silently ignored.
- Marking Collected is the *only* write this story adds and the *only* way a debt is discharged —
  no settlement row, no `settlement_commitment` write, no outbox notification. The day's verdict
  already stands; this only records that the money changed hands.
- A new `penalty_state` value, `'collected'` — `lib/ledger.ts`'s exhaustive `PenaltyState` switch
  and `lib/referee.ts`'s `summarizeReferee` must both handle it.
- A new `security definer` function, `referee_missed_commitments(p_settlement_ids uuid[])`, reads
  `settlement_commitment` filtered `outcome = 'missed'` and `settlement.kind = 'day'`, gated by
  `role_from_table() = 'referee'` — never a new RLS `select` policy directly on
  `settlement_commitment`, because that table is also `chain_current`'s own base table
  (`security_invoker`); any RLS grant on it is a grant on `chain_current` too, which would
  silently reopen the doer-facing surface Story 4.5's own frozen Intent explicitly and repeatedly
  closed to the referee. A function scoped to exactly the columns and rows needed keeps that
  boundary intact while still answering "which commitment(s) missed" for an owed Penalty.
- The owed-penalties list is ordered oldest-first (`created_at` ascending) — "uncollected debts
  age visibly" is satisfied by surfacing the oldest debt first, not by inventing a "N days old"
  counter no planning doc specifies.
- The collection message reuses `formatDong`/`formatDeadline` — the exact formatting already used
  everywhere else in the app (confirmed with the human: the planning doc's comma-separated
  "500,000" is prose convention, not a deliberate different format).
- A failed `navigator.clipboard.writeText()` (unsupported browser, denied permission, insecure
  context — this is the first clipboard use in the codebase) shows a status message, never fails
  silently, matching the failure-surfacing bar Story 4.6 set for evidence loading.
- A day whose Penalty stems from more than one missed commitment names all of them, joined —
  never just the first, and never a bare "and 1 other" that hides which one.

**Ask First:** None — the money-format question (reuse `formatDong` vs. the planning doc's literal
comma string) was confirmed with the human before drafting.

**Never:**
- No settlement/chain correction of any kind — that's Story 4.6's own concern (an Appeal), never
  this one's. Marking Collected never changes a verdict, a chain, or a commitment's outcome.
- No outbox notification to the author on collection. Nothing in FR-21's own AC calls for one —
  Mark Collected is the referee recording a fact between him and the author outside the app, not
  the app addressing the author.
- No compose field, no editable message — the pre-written copy is placed on the clipboard
  unchanged (FR-21's own AC), never opened for editing before it's copied.
- No per-item detail route. Unlike an Appeal (evidence review earns a dedicated screen), a Penalty
  needs nothing beyond what already fits on its list row — inline actions only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mark Collected | An `owed` Penalty, referee clicks Mark Collected | Penalty -> `collected`; row leaves the owed list | N/A |
| Double Mark Collected | Two calls for the same Penalty (double-click, or already collected) | Second call's guard finds zero rows, refused | Referee sees "already resolved" |
| Non-referee calls `mark_penalty_collected()` | Caller's live `profile.role <> 'referee'` | Refused before any read | N/A |
| Held Penalty | A Penalty still `held` (Appeal pending) | Invisible on the owed list — the `state = 'owed'` filter excludes it structurally | N/A |
| Copy message | Referee clicks the copy control | Clipboard holds the pre-written message unchanged, amount/day filled in | N/A |
| Clipboard unsupported/denied | `navigator.clipboard.writeText()` rejects | A status message states the copy failed | Referee sees a clear refusal, not silence |
| Multiple missed commitments | A day's Penalty covers more than one missed commitment | The message/row names all of them | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260825090000_the_referee_rules.sql:88-250` -- `rule_appeal()`, the exact
  pattern to mirror: role gate first (`is distinct from`, never `<>`), guarded transition, execute
  grants. `mark_penalty_collected()` is simpler -- no settlement/chain writes, no outbox call.
- `supabase/migrations/20260819230000_penalty.sql:26`, `.../20260825090000_...sql:40-46` --
  `penalty_state` enum; its own comment already names `collected` as "still ahead."
- `supabase/migrations/20260819260000_chain.sql:24-50,73-` -- `settlement_commitment` table (its
  existing owner-only "read own" policy stays untouched -- do not add a second `select` policy
  here) and `chain_current`, the `security_invoker` view built directly over it -- the reason a new
  referee-read *function* is required instead of a table policy (see Boundaries).
- `supabase/migrations/20260825090000_the_referee_rules.sql:110-118` -- `role_from_table()` used as
  a plain boolean condition (not an early `raise`) is the right shape for a read-only function that
  should filter rather than refuse (AD-7's own convention, per Story 4.5's manual verification).
- `lib/referee.ts:123-132` -- `RefereePenaltyRow`/`RefereeSummary`/`summarizeReferee` (owed
  count/total already correct); `PendingAppealRow` (~line 207) -- the list-row type/query shape to
  mirror for a new `OwedPenaltyRow`.
- `components/referee-home.tsx:90-99,164-195` -- the pending-appeals list (query shape, section
  layout, `formatDeadline`-based date rendering, distinguishing `aria-label`s) -- the direct
  template for the new "Owed penalties" list, added as a second section.
- `lib/money.ts:11,30-35` -- `PENALTY_DONG`, `formatDong` (`vi-VN` locale, dot-grouped, `₫`) -- the
  formatting this story's message reuses, per the human's confirmed decision.
- `lib/appeal.ts:93-99` -- `formatDeadline`, already reused by `referee-home.tsx` for a day; reuse
  again here.
- `lib/ledger.ts:33` (`PenaltyState`), `:175-212` (`ledgerPillLabel`/`ledgerPillFamily`) -- add
  `'collected'`; label `Collected`, family `held` (resolved/good, matching `dropped`/`voided`'s own
  precedent).
- `components/referee-appeal-detail.tsx:179-193,271-286` -- the failure-surfacing bar for a
  non-critical async failure (evidence signing) this story's own clipboard-failure handling must
  match, not fall below.
- `supabase/tests/4-6-the-referee-rules.sql` -- structure to mirror: role-switching idiom (`perform
  set_config('request.jwt.claims', ...)`), role-refusal-before-any-read proof, guarded-transition
  race proof. This story needs only one direction (double Mark Collected), not two, since nothing
  else auto-resolves an owed Penalty the way a timeout races an Appeal ruling.
- New: `supabase/migrations/<ts>_the_app_does_the_asking.sql`,
  `supabase/tests/4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260825100000_the_app_does_the_asking.sql` -- add `penalty_state`
  value `'collected'`; create `mark_penalty_collected(p_penalty_id uuid)` (security definer,
  `role_from_table()` gate, guarded transition, no settlement/chain/outbox writes); grant execute
  to `authenticated`; create `referee_missed_commitments(p_settlement_ids uuid[])` (security
  definer, `role_from_table() = 'referee'` as a row filter, `outcome = 'missed'`, `kind = 'day'`;
  never a new RLS policy on `settlement_commitment` itself); grant execute to `authenticated`
- [x] `lib/ledger.ts` -- handle `'collected'` in `PenaltyState`, `ledgerPillLabel`,
  `ledgerPillFamily`
- [x] `lib/referee.ts` -- handle `'collected'` in `summarizeReferee`; add `OwedPenaltyRow` type,
  the collection-message copy builder, and clipboard-failure copy
- [x] `components/referee-home.tsx` -- add an "Owed penalties" list (oldest first), each row:
  amount, day, commitment(s) missed, a copy-message control, a Mark Collected control calling
  `mark_penalty_collected()` via `supabase.rpc()`
- [x] `supabase/tests/4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql` -- proves
  every I/O Matrix row: collection, double-collection refusal, non-referee refusal, a Held
  Penalty's continued invisibility, and a multi-commitment day naming every commitment

**Acceptance Criteria:**
- Given an owed Penalty, when it appears on the referee's surface, then it shows the amount, the
  day, and the commitment(s) missed, with a pre-written message requiring no composition
- Given the pre-written message, when the referee copies it, then the clipboard holds it unchanged
- Given the referee marks a Penalty Collected, then that is the only way the debt is discharged,
  and it is never written off automatically
- Given a Held Penalty, then it stays invisible on the collection list until it is ruled on

## Spec Change Log

**2026-08-25, iteration 2 (independent review).** The frozen "Always" bullet states the
collection message "reuses `formatDong`/`formatDeadline`," but the shipped code (`lib/referee.ts`)
introduces a new `formatOwedDay` instead — deliberately: `formatDeadline` omits the year
(`lib/appeal.ts:93-99`), and this story's own review found that wrong for a Penalty designed to
persist indefinitely (see Design Notes/Suggested Review Order). The behavior is correct and was
independently verified; this entry only records the substitution against the frozen text, which
had gone stale without a logged amendment. KEEP: `formatOwedDay`, adding the year `formatDeadline`
omits, is the correct function for this message; no code change needed.

**2026-08-25, iteration 1.** The original "Always" bullet specified a new RLS `select` policy
directly on `settlement_commitment` for the referee, scoped to `kind = 'day'`. Building against it
and re-running Story 4.5's own regression test (`supabase/tests/4-5-the-referee-has-his-own-way-in.sql`)
surfaced that `chain_current` — the surface Story 4.5's frozen Intent explicitly and repeatedly
keeps off-limits to the referee — is a `security_invoker` view built directly over
`settlement_commitment`. Any RLS policy granting the referee `select` on the base table is
therefore also a grant on `chain_current`, silently reopening a boundary a prior, already-shipped
story closed. Confirmed with the human before amending. Amended to a `security definer` function
(`referee_missed_commitments`, gated by `role_from_table() = 'referee'` as a row filter rather than
an early refusal, matching AD-7's "filters rather than refuses" read convention) instead of a table
policy — same data reaches the referee (missed commitment names for day-kind, owed Penalties),
same scope (`kind = 'day'`, `outcome = 'missed'`), but `settlement_commitment` itself gets no new
policy, so `chain_current` is untouched. KEEP: everything else in this spec — the
`mark_penalty_collected()` design, the list UI, the copy/clipboard handling — was unaffected and
should carry forward unchanged.

### Review Findings

**Independent code review, 2026-08-25 — commit `f8c36af`, 4-layer (blind-hunter, edge-case-hunter,
verification-gap, acceptance-auditor).**

- [x] [Review][Patch] The doer's own Ledger (`components/ledger.tsx`) had no `row.state ===
  'collected'` branch in its `aria-label` chain — a Collected Penalty (this story's own new,
  reachable state) fell through to the final default and announced itself as still "owed" to a
  screen-reader user, contradicting the sighted pill (correctly labelled "Collected"). Unlike
  `voided` (Story 4.6), which only ever lands on a superseded settlement `penalty_current` never
  surfaces, `collected` transitions the same row in place and is genuinely reachable. Fixed: a
  `collected` branch added, matching `dropped`'s own shape. New test in `ledger.test.tsx` asserts
  the accessible name directly. `npm test` (889/889), `npx tsc --noEmit`, `npm run lint` all clean.
- [x] [Review][Patch] The frozen "Always" boundary said the message reuses `formatDeadline`; the
  shipped code deliberately uses a new `formatOwedDay` instead (to add the year `formatDeadline`
  omits), with no Spec Change Log entry recording the amendment. Logged as iteration 2 above — no
  code change needed, the substitution was already correct.
- [x] [Review][Patch] `sprint-status.yaml` and this spec's own frontmatter disagreed on status —
  synced in this review's own step 6.
- [x] [Review][Defer] No test proves `mark_penalty_collected()` leaves `outbox` untouched — the
  spec's own "Never" boundary ("No outbox notification... on collection") is documented in prose
  but never asserted, unlike Story 4.6's own test file, which does assert outbox counts.
- [x] [Review][Defer] `referee_missed_commitments()`'s migration comment claims it correctly
  excludes a `held`, `dropped`, `voided`, or already-`collected` Penalty's settlement, but only the
  `held` case is exercised by the test file.
- [x] [Review][Defer] Two different doer accounts with an identically-named commitment missed on
  the same day would produce two owed-penalty rows with an identical accessible name — the same
  underlying, already-accepted trade-off as Story 4.5's referee reads not being `is_live_doer`-
  scoped, not a new gap.
- [x] [Review][Defer] No component-level test proves a `collected`-state Penalty is excluded from
  the "Owed penalties" list, unlike the equivalent Held-Penalty exclusion, which is tested.
- [x] [Review][Defer] `collectionMessage()` hardcodes an English sentence with a `vi-VN`-formatted
  amount inside it — no localization hook, no note on whether the mix is intentional.
- [x] [Review][Defer] No confirmation step before Mark Collected — matches the same established
  no-confirm-dialog pattern already recorded for Story 4.6's ruling controls, not a gap specific
  to this story.
- [x] [Review][Defer] `markStatus`/`markErrors`/`copyStatus` in `referee-home.tsx`, all keyed by
  `penalty.id`, are never pruned — a minor memory leak over a long-lived session with many
  collections.
- [x] [Review][Defer] `referee_missed_commitments(p_settlement_ids uuid[])` has no server-side
  bound on the incoming array's size.
- [x] [Review][Defer] The "Owed penalties" section has no empty-state affordance — it simply
  doesn't render when the list is empty, giving the referee no confirmation the list was checked.
- [x] [Review][Defer] `markCollected`/`copyMessage` in `referee-home.tsx` set state after their
  own `await` with no `cancelled` guard, the same class of gap already recorded for Story 4.6's
  `rule()`.

Six further findings were dismissed: three duplicate this same commit's own internal review,
already recorded in `deferred-work.md` with reasoning (Copy-message double-click race, owed-list
ordering tiebreaker, a day-kind zero-missed-commitments row rendering identically to the
intentional week-kind fallback); one (near-verbatim rationale duplicated between the migration's
header comment and its per-function `comment on function`) is a stylistic choice matching this
codebase's own established documentation convention, not a defect; and one (a full held-through-
collected lifecycle test) is subsumed by the `referee_missed_commitments()` test-coverage gap
already deferred above.

## Design Notes

**Why no outbox notification, unlike `rule_appeal()`.** A ruling changes a verdict the author
needs to know about (his day just became clean, or a debt he could contest just became final).
Marking Collected changes nothing about what happened — it only records that money the author
already owed has now changed hands, a fact between him and the referee outside the app. Neither
epics.md's AC nor `epic-4-context.md`'s FR-21 section asks for one.

**Naming multiple missed commitments.** `penalty` is 1:1 with `settlement` (Story 4.6's own
established fact), but a day's settlement can cover more than one missed commitment. Read
`settlement_commitment` filtered `outcome = 'missed'` for the Penalty's own `settlement_id`, join
`commitment.name`, and join the names (e.g. `"Reading, TryHackMe"`) rather than picking one.

## Verification

**Commands, run 2026-08-25 against the local stack (Docker up throughout), after the iteration-1 correction and the review's 8 patch findings:**
- `npx supabase db reset` -- migration applies clean.
- `docker exec supabase_db_todoapp psql -v ON_ERROR_STOP=1 < supabase/tests/4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql` -- **8/8 steps pass**: non-referee refusal (real and bogus id, before any row read); collection (`owed -> collected`, row leaves the owed list); double-collection refusal; a Held Penalty's continued invisibility, its own collection refusal, and its own settlement naming nothing through `referee_missed_commitments()` despite a genuine missed outcome existing for it (the review's `state = 'owed'` scoping fix); a multi-commitment day naming every commitment, with the function returning nothing at all to a non-referee session; a week-kind owed Penalty collecting exactly the same way a day-kind one does; and a bogus penalty id reading a distinct "No such penalty." message, never "already been resolved" (the review's parity fix with `rule_appeal()`).
- Regression: `supabase/tests/4-5-the-referee-has-his-own-way-in.sql` -- **PASS**, independently re-run and re-confirmed clean of the `chain_current` leak the iteration-1 correction fixed. `supabase/tests/4-6-the-referee-rules.sql` -- **PASS**, independently re-run.
- `npm test` -- **842/842 pass** across 39 files (up from 836 pre-review), including new/extended cases in `components/referee-home.test.tsx`, `components/referee-appeal-detail.test.tsx`, `lib/ledger.test.ts`, `lib/referee.test.ts`.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.

**Review.** Three independent layers (blind-hunter, edge-case-hunter, verification-gap) ran against the full diff. 8 real findings were patched: a missing `'collected'` render branch in `referee-appeal-detail.tsx` (a real, reachable bug -- reject an appeal, later mark its Penalty collected from this story's own list, then revisit the appeal's detail screen and the outcome silently disappears); ambiguous `aria-label`s when two owed rows share a day; `referee_missed_commitments()` not actually checking `state = 'owed'`; a missing year on a day label for Penalties designed to persist indefinitely; undeduplicated commitment names; a false-negative window right after a successful Mark Collected; `mark_penalty_collected()` not distinguishing a bogus id from an already-resolved one; and a bare `string` type where the existing `LedgerKind` union belonged. 8 lower-severity findings recorded in `deferred-work.md` rather than patched blind.

**Not run in this environment:** the "Owed penalties" UI flow in an actual browser (the copy control placing the message on the real system clipboard, a denied-permission failure surfacing correctly) and deploy to a live project -- no browser tooling or authenticated live-project CLI session available here, matching the same disclosed gap Stories 4.5/4.6 left for their own UI flows.

## Suggested Review Order

**The collection function, and the correction that avoided a security regression**

- The role gate and the distinct "No such penalty." refusal, added during review to match `rule_appeal()`'s own precedent.
  [`20260825100000_the_app_does_the_asking.sql:64`](../../supabase/migrations/20260825100000_the_app_does_the_asking.sql#L64)

- The guarded transition itself — the only write this story adds.
  [`20260825100000_the_app_does_the_asking.sql:85`](../../supabase/migrations/20260825100000_the_app_does_the_asking.sql#L85)

- `referee_missed_commitments()` — a `security definer` function, not an RLS policy, specifically because `settlement_commitment` is also `chain_current`'s own base table (see the Spec Change Log above for what a table policy here would have leaked).
  [`20260825100000_the_app_does_the_asking.sql:136`](../../supabase/migrations/20260825100000_the_app_does_the_asking.sql#L136)

- The `state = 'owed'` scoping the review added — without it the function would name commitments for a Held, Voided or already-Collected Penalty's settlement too.
  [`20260825100000_the_app_does_the_asking.sql:153`](../../supabase/migrations/20260825100000_the_app_does_the_asking.sql#L153)

**The gap review found in a different story's own screen**

- The `'collected'` branch added to `referee-appeal-detail.tsx` — a rejected appeal's Penalty can be marked collected from this story's own list, and the detail screen had nowhere to say so.
  [`referee-appeal-detail.tsx`](../../components/referee-appeal-detail.tsx)

**Referee's own list**

- The owed-penalties list itself: both kinds included, oldest first, each row naming every missed commitment.
  [`referee-home.tsx:158`](../../components/referee-home.tsx#L158)

- `markCollected` — no longer resets a row to idle until its own reload actually lands (the review's false-negative-window fix).
  [`referee-home.tsx:263`](../../components/referee-home.tsx#L263)

- `copyMessage` — the clipboard failure path this story is the first to need.
  [`referee-home.tsx:287`](../../components/referee-home.tsx#L287)

- `formatOwedDay`, not `formatDeadline` — the year a Penalty designed to persist indefinitely needs.
  [`referee-home.tsx:383`](../../components/referee-home.tsx#L383)

**Peripherals**

- The new `penalty_state` value and its ledger pill.
  [`20260825100000_the_app_does_the_asking.sql:35`](../../supabase/migrations/20260825100000_the_app_does_the_asking.sql#L35)

- The full collection test file: every I/O Matrix row plus the review-added scoping and bogus-id cases.
  [`4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql`](../../supabase/tests/4-7-the-app-does-the-asking-the-referee-does-the-collecting.sql)

- Collection-message copy, `OwedPenaltyRow`, and the `'collected'` case in `summarizeReferee`.
  [`referee.ts`](../../lib/referee.ts)

- Where this story's own deferred findings are recorded.
  [`deferred-work.md`](../../_bmad-output/implementation-artifacts/deferred-work.md)
