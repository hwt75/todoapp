---
title: 'Story 4.6 — The referee rules'
type: 'feature'
created: '2026-08-25'
status: 'done'
review_loop_iteration: 0
baseline_commit: '47d42b6b12629fa93e82197521c77093c1cc4bfc'
story_key: '4-6-the-referee-rules'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A Held Penalty (Story 4.4) has no way to resolve except timing out in the author's
favor — the referee can read Appeals (4.5) but has no ruling controls and no write access at all.
FR-20 needs the referee's decision to actually move money and, on approval, correct the day the
machine got wrong.

**Approach:** A referee-callable `rule_appeal()` Postgres function (the referee's first-ever write,
gated by `role_from_table()`) resolves one Held Penalty. Approval performs the exact guarded,
first-writer-wins transition `void_expired_appeals()` already uses, then inserts a corrective
`settlement` row — mirroring `supersede_expiries()`'s own append-only pattern — recomputing the
day's verdict with the appealed commitment excluded, restoring the chain rather than merely
forgiving money. Rejection performs the same guarded transition to `owed`, nothing else. Either
path enqueues an outbox notification to the author in the same transaction (AD-3). A new
`/referee/appeals/[id]` screen shows the machine's call, the author's evidence, and the *He did
it* / *He didn't* controls; `referee-home.tsx` gains a real list of pending appeals to open.

## Boundaries & Constraints

**Always:**
- The guarded transition is `update penalty set state = <target> where id = :id and state =
  'held'` — identical shape to `void_expired_appeals()`. Zero rows affected (lost the race to a
  timeout or a second ruling) is refused with a clear message, never silently ignored, since this
  path is a live referee action (mirrors `appeal_hold_penalty()`'s own `if not found then raise`).
- `rule_appeal()` is `security definer`, granted `execute` to `authenticated`, and checks
  `role_from_table() = 'referee'` itself as its first statement — never `role_from_token()`, per
  `lib/roles.ts`'s own rule for anything guarding a money transition.
- Approval's corrective settlement recomputes `admitted`/`silent` the same way `settle_day()` and
  `supersede_expiries()` already do, with the appealed `commitment_id` excluded from `admitted` —
  never a hardcoded `verdict = 'clean'`. If another penalty-carrying commitment genuinely missed
  the same day, the day stays `failed` and a new, smaller-context penalty is inserted; only the
  appealed penalty is voided.
- The `appeal-evidence` Storage bucket gets a third `storage.objects` policy — the referee reads
  what the RLS-table policy (Story 4.5) already lets him see the metadata for; today only the
  submitting owner can read the actual object (flagged as missing in Story 4.4's own review).
- A new `penalty_state` value, `'voided'` — distinct from `'dropped'` (timed out, nobody ruled) and
  from `'waived'` (reserved for Story 5.1's Grace Day, a different fact entirely). `lib/ledger.ts`'s
  exhaustive `PenaltyState` switch and `lib/referee.ts`'s `summarizeReferee` must both handle it.
- Either ruling's outbox notification is enqueued in the same transaction as the state change
  (AD-3), keyed so a re-run of the function after a race loss enqueues nothing new.
- Evidence copy states only what the current schema actually carries — which commitment, which
  day, that the linked check reported it missed — never EXPERIENCE.md's illustrative quantified
  example ("Location saw you for 4 minutes"), since no Auto-check in this codebase records an
  observed value today (Story 4.1/4.2's only resolver is a deterministic stub; FR-8 itself
  resolved negative in Story 1.3).

**Ask First:** None — the corrective-settlement mechanism (mirror `supersede_expiries()`, restore
the chain rather than forgive only the money) was confirmed with the human before drafting.

**Never:**
- No change to `settle_week()` or any weekly-quota path. `appeal_hold_penalty()` already restricts
  eligibility to `kind = 'day'` settlements only (Story 4.4's own boundary) — no Held Penalty can
  exist for a week, so `rule_appeal()` never needs to.
- No collection controls (Mark Collected, the copyable message) — Story 4.7's own goal.
- No email delivery for the ruling notification beyond the existing outbox/push path — no new
  channel.
- No mutation of the original `settlement`/`penalty` rows. Correction is strictly append-only
  (`supersedes`), matching AD-9/2.7's own rule — history is never rewritten.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Approve, sole cause | Held Penalty is the day's only penalty-carrying miss | Penalty -> `voided`; corrective settlement `verdict = 'clean'`, no new penalty; chain restored | N/A |
| Approve, other genuine miss same day | A second, non-appealed commitment also missed that day | Penalty -> `voided`; corrective settlement `verdict = 'failed'` with a new penalty for the remainder | N/A |
| Reject | Referee rules "He didn't" | Penalty -> `owed`; no settlement change | N/A |
| Race: ruling after timeout | `void_expired_appeals()` already moved it to `dropped` | Refused, clear message, nothing written | Referee sees "already resolved" |
| Race: double ruling | Two ruling calls for the same appeal | Second call's guard finds zero rows, refused | Same as above |
| Non-referee calls `rule_appeal()` | Caller's live `profile.role <> 'referee'` | Refused before any read of the appeal | N/A |
| Evidence read | Referee opens an appeal's detail screen | Evidence images load through the new Storage policy | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260824140000_void_expired_appeals.sql:14-33` -- the guarded first-writer-wins UPDATE shape to mirror exactly.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:175-235` -- `supersede_expiries()`, the append-only corrective-settlement pattern (recompute `admitted`, insert `settlement` with `supersedes`, insert `penalty` only if still owed) to mirror for approval.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:104-155` -- `settle_day()`'s own `commitments_owing()`-based admitted/silent/verdict derivation, the exact formula to recompute with the appealed commitment excluded.
- `supabase/migrations/20260824150000_an_appeal_reads_the_day_that_stands.sql:39-113` -- current `appeal_hold_penalty()`; confirms `kind = 'day'`-only eligibility and the `if not found then raise` convention for a client-triggered guarded write.
- `supabase/migrations/20260824130000_contest_a_miss_the_machine_got_wrong.sql:79-106` -- `appeal` table shape (`penalty_id`, `deadline`, `for_day`, `commitment_id`); no status column -- pending/resolved reads off `penalty.state`.
- `supabase/migrations/20260824130000_contest_a_miss_the_machine_got_wrong.sql:325-350` -- existing owner-only `storage.objects` policies on `appeal-evidence`; add the referee's third policy alongside these two.
- `supabase/migrations/20260819230000_penalty.sql:26`, `.../20260824130000_...sql:40-41` -- `penalty_state` enum and the `alter type ... add value` precedent for adding `'voided'`.
- `supabase/migrations/20260819180000_outbox.sql:134-154` -- `outbox_enqueue(owner, dedupe_key, payload)` signature; `.../20260820150000_...sql:306-318` -- a concrete same-transaction call site to mirror.
- `lib/roles.ts` -- `role_from_table()` vs `role_from_token()`; this function's internal role check must use the former.
- `lib/ledger.ts:22` (`PenaltyState` union), `:164-194` (`ledgerPillLabel`/`ledgerPillFamily`) -- both need a `'voided'` case; pick a label distinct from `Dropped`.
- `lib/referee.ts` -- `summarizeReferee`'s exhaustive switch needs a `'voided'` case; extend with ruling copy and an appeal-list/detail read shape, mirroring `lib/appeal.ts`'s own style.
- `components/referee-home.tsx` -- currently counts only (Story 4.5's own "no per-item list yet" boundary); add a real list of pending appeals, each linking to its detail screen.
- `lib/appeal.ts`, `components/appeal-form.tsx` -- author-side copy/type conventions (`holdStateCopy`, idempotency-key handling) to mirror on the referee's ruling side.
- `supabase/tests/4-5-the-referee-has-his-own-way-in.sql` Step 6 (~line 388) -- the referee-has-no-write-access proof this story's own RLS/RPC test extends into a positive case.
- New: `app/referee/appeals/[appealId]/page.tsx`, `components/referee-appeal-detail.tsx`, `supabase/migrations/<ts>_the_referee_rules.sql`, `supabase/tests/4-6-the-referee-rules.sql`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260825090000_the_referee_rules.sql` -- add `penalty_state` value `'voided'`; create `rule_appeal(p_appeal_id uuid, p_approved boolean)` (security definer, `role_from_table()` gate, guarded transition, approval's corrective-settlement recompute, outbox enqueue); grant execute to `authenticated`; add the referee's `storage.objects` read policy on `appeal-evidence`
- [x] `lib/ledger.ts` -- handle `'voided'` in `PenaltyState`, `ledgerPillLabel`, `ledgerPillFamily`
- [x] `lib/referee.ts` -- handle `'voided'` in `summarizeReferee`; add appeal-list/detail types and ruling copy (machine-call statement, evidence framing, timeout-note copy, ruling-outcome strings)
- [x] `components/referee-home.tsx` -- render a real list of pending appeals (day, commitment name), each linking to its detail screen
- [x] `components/referee-appeal-detail.tsx` + `app/referee/appeals/[appealId]/page.tsx` -- shows the machine's call, the author's evidence, *He did it* / *He didn't* controls calling `rule_appeal()` via `supabase.rpc()`
- [x] `supabase/tests/4-6-the-referee-rules.sql` -- proves every I/O Matrix row: both ruling outcomes, both race refusals, the non-referee refusal, and the multi-miss-same-day case recomputing `failed` with a new penalty

**Acceptance Criteria:**
- Given a pending Appeal, when the referee approves it, then the Held Penalty is `voided`, the
  day's chain/Ledger reads as clean unless another genuine miss remains, and the author is
  notified
- Given a pending Appeal, when the referee rejects it, then the Penalty converts to `owed` and the
  author is notified
- Given a Held Penalty already resolved (timeout or a prior ruling), when `rule_appeal()` is
  called again, then it refuses cleanly and changes nothing
- Given a non-referee session, when it calls `rule_appeal()`, then it is refused before any row is
  read or written

## Design Notes

**Corrective recompute.** See `rule_appeal()`'s own recompute
(`supabase/migrations/20260825090000_the_referee_rules.sql`) for the exact formula — an
earlier version of this note condensed it and, in doing so, drifted from the shipped code: it
omitted the `and o.cadence <> 'weekly_quota'` exclusion `settle_day()` itself applies to both
`admitted` and `silent` (20260824100000), and omitted `and o.commitment_id <>
v_appeal.commitment_id` from the `silent` filter entirely. The shipped migration excludes the
appealed commitment from *both* filters and excludes `weekly_quota` from *both* filters,
mirroring `settle_day()`'s own current formula verbatim rather than a condensed
approximation of it.

**Why a directly client-callable `security definer` function, not an Edge Function.** Unlike
pairing (Story 4.5), this needs no service-role key — the referee is an ordinary authenticated
Postgres role with an existing session. The function itself is the privilege boundary
(`role_from_table()`), the same shape `settle_day`/`void_expired_appeals` already use for
schedule-only functions, just granted to `authenticated` instead of revoked from it.

## Verification

**Commands, run 2026-08-25 against the local stack (Docker up throughout), after the review's 9 patch findings were applied:**
- `npx supabase db reset` -- migration applies clean.
- `docker exec supabase_db_todoapp psql -v ON_ERROR_STOP=1 < supabase/tests/4-6-the-referee-rules.sql` -- **9/9 steps pass**: non-referee refusal (real and bogus appeal id, before any row read); bogus-id refusal distinct from role refusal; sole-cause approval (void, day corrects to `clean`, no new penalty, chain restored, drops out of the current Ledger); approval with a second genuine miss the same day (only the appealed Penalty voids, a new smaller-context penalty covers the rest); rejection (`owed`, no settlement row); both directions of the AD-15 race (post-timeout ruling, double ruling) refused cleanly with nothing further written or enqueued; referee reads evidence through the new Storage policy while another doer still cannot; and (Step 9, added during review) a same-day `weekly_quota` slip is correctly excluded from the approval recompute -- the day still corrects to `clean` with no new penalty, proving the `cadence <> 'weekly_quota'` exclusion is live, not just documented.
- Regression: `supabase/tests/4-4-contest-a-miss-the-machine-got-wrong.sql`, `4-5-the-referee-has-his-own-way-in.sql`, `2-7-supersession.sql`, `2-5-settlement.sql` -- all still **PASS**, independently re-run.
- `npm test` -- **814/814 pass** across 39 files (up from 781 pre-story), including new `components/referee-appeal-detail.test.tsx` (20 cases) and new/extended cases in `components/referee-home.test.tsx`, `lib/ledger.test.ts`, `lib/referee.test.ts`.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.

**Review.** Three independent layers (blind-hunter, edge-case-hunter, verification-gap) ran against the full diff. 9 real findings were patched: a NULL-argument hazard in `rule_appeal()` that silently fell through to approval, the untested `weekly_quota` exclusion (closed with SQL test Step 9 above), a Design Notes snippet that had drifted from the shipped formula, evidence signed-URL TTL/failure-surfacing, evidence alt-text numbering, two accessibility gaps in the pending-appeals list, a date-formatting inconsistency between the list and detail screens, and an unused extra read on the approved path. Three edge-case-hunter findings describing "two appeals sharing one bundled Penalty" were evaluated and rejected as unreachable -- `appeal_hold_penalty()`'s own guard (`state = 'owed'` required to hold) already ensures at most one appeal can hold a given day's Penalty at a time. 9 lower-severity findings recorded in `deferred-work.md` rather than patched blind.

**Not run in this environment:** the `/referee/appeals/[id]` UI flow in an actual browser (evidence signed-URL loading, the ruling buttons end to end) and deploy to a live project -- no browser tooling or authenticated live-project CLI session available here, matching the same disclosed gap Story 4.5 left for its own UI flow.

## Suggested Review Order

**The ruling function (the entry point) and the race guard it shares with the timeout path**

- Refuses before any row is read, and refuses a NULL ruling too — both added statements sit before the appeal is ever loaded.
  [`20260825090000_the_referee_rules.sql:110`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L110)

- Rejection: the guarded transition alone, identical shape to `void_expired_appeals()`.
  [`20260825090000_the_referee_rules.sql:131`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L131)

- Approval: the same guard, voiding rather than reverting — everything below only ever runs for the single call that wins it.
  [`20260825090000_the_referee_rules.sql:157`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L157)

**Approval's corrective settlement — the part that actually credits the commitment**

- The recompute: `settle_day()`'s own current formula, mirrored, with the appealed commitment excluded — not a hardcoded `'clean'`.
  [`20260825090000_the_referee_rules.sql:167`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L167)

- The corrective row itself, append-only via `supersedes` — history is never rewritten.
  [`20260825090000_the_referee_rules.sql:188`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L188)

- The freeze `supersede_expiries()`'s own prior bug fix required — without it the whole day, not only the appealed commitment, would vanish from the chain.
  [`20260825090000_the_referee_rules.sql:202`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L202)

- A new, smaller-context penalty only if the day still genuinely owes one once the appealed commitment no longer counts.
  [`20260825090000_the_referee_rules.sql:217`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L217)

- The weekly-quota exclusion proof added during review — the one branch of the recompute the original 8 steps never exercised.
  [`4-6-the-referee-rules.sql:706`](../../supabase/tests/4-6-the-referee-rules.sql#L706)

**Notification and evidence access**

- One outbox enqueue per ruling, keyed so a race loser — which never gets past its own guard — never double-sends.
  [`20260825090000_the_referee_rules.sql:141`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L141)

- The referee's third `storage.objects` policy — closes the gap Story 4.4's own review flagged (metadata was readable, the object itself wasn't).
  [`20260825090000_the_referee_rules.sql:263`](../../supabase/migrations/20260825090000_the_referee_rules.sql#L263)

**Referee's own screens**

- How "approved" is inferred client-side — by comparing the day's current settlement against the appeal's own stored one, not a status column.
  [`referee-appeal-detail.tsx:139`](../../components/referee-appeal-detail.tsx#L139)

- Evidence loading: longer signed-URL TTL and per-item failure tracking, both added during review.
  [`referee-appeal-detail.tsx:179`](../../components/referee-appeal-detail.tsx#L179)

- The ruling states the screen renders — `held`/`voided`/`owed`/`dropped`, each with its own copy and controls.
  [`referee-appeal-detail.tsx:290`](../../components/referee-appeal-detail.tsx#L290)

- The pending-appeals list Story 4.5 deferred — now real, with distinguishing accessible names per row (added during review).
  [`referee-home.tsx:164`](../../components/referee-home.tsx#L164)

**Peripherals**

- The new `penalty_state` value and its ledger pill — `Voided`, distinct from `Dropped`.
  [`ledger.ts:33`](../../lib/ledger.ts#L33)

- The full ruling test file: every I/O Matrix row plus the review-added weekly-quota case.
  [`4-6-the-referee-rules.sql`](../../supabase/tests/4-6-the-referee-rules.sql)

- Ruling copy, appeal-detail types, and the `'voided'` case in `summarizeReferee`.
  [`referee.ts`](../../lib/referee.ts)

- Component tests for the detail screen and the updated home list.
  [`referee-appeal-detail.test.tsx`](../../components/referee-appeal-detail.test.tsx)

- Where this story's own deferred findings are recorded.
  [`deferred-work.md`](../../_bmad-output/implementation-artifacts/deferred-work.md)
