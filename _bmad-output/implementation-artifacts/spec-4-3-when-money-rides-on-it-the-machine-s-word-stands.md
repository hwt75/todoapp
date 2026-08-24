---
title: 'Story 4.3 — When money rides on it, the machine''s word stands'
type: 'feature'
created: '2026-08-24'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'ef3c6cea8ab102427194c67baa82c5e83c53956d'
story_key: '4-3-when-money-rides-on-it-the-machine-s-word-stands'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-2a requires that a Penalty-carrying commitment's Auto-check `missed` result stand
as authoritative; with no Penalty, the author's own Declaration overrides it. Today
`file_auto_check_result` treats `missed` identically to `unavailable` (files nothing) — a machine
miss never becomes authoritative. Separately, `morning-gate.tsx`'s write-error handling classifies
*any* unique-violation as "my own answer, arrived out of order" and silently advances past the
question — so even once a machine result exists, a contradicting tap would appear to succeed while
recording nothing.

**Approach:** `file_auto_check_result` gains a `missed` branch: on a Penalty-carrying commitment,
file a `slipped` declaration (the existing `held` branch's exact idempotent shape); with no
Penalty, file nothing (already-correct — asserted by a test, not changed, per AC2). The existing
per-day uniqueness then makes a filed machine result structurally authoritative. Close the gap that
hides this: on a unique-violation, compare the conflicting row's `idempotency_key` to the one just
attempted — a match is the author's own retry (unchanged); a mismatch means something else already
decided the day, given its own message rather than a silent "answered." Add a disclosure to the
commitment form, shown before the first save, when Penalty and an Auto-check are both enabled.

## Boundaries & Constraints

**Always:**
- `file_auto_check_result`'s new `missed`→`slipped` branch mirrors the `held` branch's exact shape
  (server-generated `idempotency_key`, `answered_at = now()`, `on conflict (commitment_id,
  for_day) do nothing`) — one more branch, not a rewrite.
- Whether `missed` files anything is decided by the commitment's own `carries_penalty`, read inside
  the function itself — no new parameter (mirrors `auto_check_pending`'s self-contained design,
  Story 4.2).
- The retry-vs-conflict check is a pure, unit-testable function in `lib/declaration-submit.ts`
  (`classifyConflict`), not logic inlined only in `morning-gate.tsx`.
- The commitment-form disclosure renders only when `draft.carriesPenalty && checksPossible &&
  draft.autoCheckEnabled` are all true — exactly the AC's own "both toggles" condition.
- A conflicting insert removes the queue item (no infinite retry against a row that will never
  accept it) and shows a message distinct from a genuine server rejection.

**Ask First:** _None outstanding — the exact disclosure/conflict-message copy is drafted below and
open to the human's edit at the CHECKPOINT, not a blocking design decision._

**Never:**
- No Appeal table, submission flow, or `Held` penalty state — Story 4.4's scope, per human
  decision (AC1's "Appeal is the only route" and all of AC4 deferred there; see Spec Change Log).
- No change to `resolve_account_elsewhere`'s stub (still always `unavailable`), or to
  `auto_check_pending`/`settle_day`/`settle_week` (Story 4.2) — `missed` reaches settlement
  entirely through the existing `slipped`-declaration path already built by Epic 2/3.
- No change to `declaration`'s columns, RLS policies, or its no-update/no-delete rule.
- No machine/human marker column on `declaration` (a recorded, deferred gap from Story 4.1's
  review) — not needed for this story's ACs, still out of scope.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| `missed`, Penalty-carrying | Resolver returns `missed` on a `carries_penalty=true` commitment | `file_auto_check_result` files `declaration(answer='slipped')` | Already-declared day: `on conflict do nothing`, unchanged |
| `missed`, no Penalty | Resolver returns `missed` on a `carries_penalty=false` commitment | Files nothing; falls through to the author's own Declaration | — |
| Author retries own answer | Insert whose `idempotency_key` matches an existing row (AD-4) | Classified `duplicate`; gate proceeds as answered, unchanged from today | — |
| Author contradicts a filed machine result | Insert for a day already filed by the machine, different `idempotency_key` | Classified a conflict; gate shows a distinct message, does not advance as if the tap succeeded | Queue item removed — retrying changes nothing |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260823100000_an_account_elsewhere_is_attached_not_read.sql:122-146` --
  `file_auto_check_result`; current guard `if p_result is distinct from 'held' then return; end
  if;` — replace with a branch per result, reading `carries_penalty` from `commitment` for the
  `missed` case.
- `lib/declaration-submit.ts:23-42` -- `WriteOutcome`/`classifyWriteError`; the `23505 →
  'duplicate'` line (35) is the exact assumption this story breaks — its own comment ("this
  attempt raced its own acknowledgement") is only true when the existing row's key matches. Add
  `classifyConflict(existingKey, attemptedKey)` alongside it.
- `components/morning-gate.tsx:88-117` -- the `send` callback and `rejection` handling; on a
  `23505`, add a follow-up `select idempotency_key from declaration where commitment_id=... and
  for_day=...` (RLS already allows via "declaration: read own"), call `classifyConflict`, and set
  `rejection` with distinct copy (not the generic "server refused") when it's a real conflict --
  reuses the existing `{kind:'failed'}` render path, no new `Sending` state.
- `components/commitment-form.tsx:173-233` -- `carriesPenalty` checkbox (173-182), Auto-checks
  block (184-233); new disclosure `<p>` after the Auto-checks block closes, guarded by
  `draft.carriesPenalty && checksPossible && draft.autoCheckEnabled`.
- `lib/commitment.ts:37-51` -- `CommitmentDraft` (`carriesPenalty`, `autoCheckEnabled` fields
  already exist, nothing to add here).
- `supabase/tests/4-1-account-elsewhere.sql` -- structure/naming template; extend or sibling with
  a new `4-3-*.sql` file per the manifest convention.
- `components/morning-gate.test.tsx` -- mock pattern (`vi.mock('@/lib/supabase/client')`,
  fake-timers) for the new conflict-path test.
- `components/commitment-form.test.tsx` -- RTL query pattern for the new disclosure test.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_the_machines_word_stands.sql` -- `file_auto_check_result` gains the
  `missed`→`slipped` (Penalty-carrying) branch, no-op (no Penalty) branch -- makes a machine miss
  authoritative for money, structurally, via existing per-day uniqueness
- [x] `supabase/tests/4-3-the-machines-word-stands.sql` -- covers the I/O matrix's two DB rows,
  plus a direct proof that a second insert attempt for the same day (simulating the author) is
  refused once the machine has filed
- [x] `lib/declaration-submit.ts` -- add `classifyConflict(existingIdempotencyKey, attemptedKey)`
- [x] `lib/declaration-submit.test.ts` -- unit tests for `classifyConflict`
- [x] `components/morning-gate.tsx` -- on `23505`, resolve retry-vs-conflict via a follow-up select
  and `classifyConflict`; distinct message for a genuine conflict
- [x] `components/morning-gate.test.tsx` -- covers the I/O matrix's two client-side rows (own
  retry proceeds; conflict shows the distinct message and does not call `onAnswered`)
- [x] `components/commitment-form.tsx` -- disclosure paragraph when both toggles are enabled
- [x] `components/commitment-form.test.tsx` -- disclosure renders only when both toggles are true

**Acceptance Criteria:**
- Given a Penalty-carrying commitment whose Auto-check resolves `missed`, then a `slipped`
  declaration is filed and a later human attempt to declare that same day is refused, not silently
  accepted as if it were recorded.
- Given a commitment carrying no Penalty whose Auto-check resolves `missed`, then nothing is filed
  and the author's own Declaration is what settles the day, with no other involvement.
- Given the author enables both the Penalty toggle and an Auto-check while creating a commitment,
  then the screen states, before the first save, that the machine's result will stand and (once
  Story 4.4 ships) an Appeal will be the only way to overturn it.

## Spec Change Log

- **2026-08-24, pre-approval scoping (human decision, recorded for traceability):** epics.md's
  Story 4.3 ACs 1 and 4 name Appeal ("an Appeal is the only route", "a pending Appeal... resolves
  in my favor") and a `Held` penalty state — both Story 4.4's scope, which `epic-4-context.md`'s
  own Cross-Story Dependencies section states depends on 4.3, not the reverse. Asked the human how
  to resolve the resulting circular reference. Decided: build AC1's data-level precedence (a
  Penalty-carrying `missed` becomes authoritative and structurally uncorrectable) and AC3's
  disclosure now; defer AC1's own "Appeal is the only route" clause and all of AC4 to Story 4.4,
  once Appeal and `Held` exist to make them true. AC2 requires no code change (already correct,
  per Story 4.1/4.2's `missed`-treated-like-`unavailable` behavior) — covered here by a test only.

- **2026-08-24, round 2 (patch, no loopback needed):** Independent review (blind-hunter +
  edge-case-hunter + verification-gap, run against the round-1 diff) converged on two real bugs
  in the new `morning-gate.tsx` conflict path and one real test-coverage gap: (1) the follow-up
  `select`'s own `error` was never checked — a transient read failure (the same flaky connection
  that produced the `23505` retry in the first place) left `existing` `null`, which
  `classifyConflict` reads identically to "a genuine conflict," permanently discarding a real,
  honest answer and reporting a false cause. Fixed: a non-null `readError` now returns `'failed'`
  (kept queued, retried later — the same outcome as any other unreachable write), never
  misreported as a conflict. (2) The conflict message asserted "decided by an Auto-check"
  specifically, but `classifyConflict` only proves the winning row wasn't filed by *this*
  attempt — it could just as well be the author's own second device (the offline queue design
  explicitly anticipates multi-device use). Fixed: reworded to name both possible causes, and
  `classifyConflict`'s own doc comment now says so explicitly. (3) No test exercised the
  `declaration: read own` RLS policy `morning-gate.tsx`'s whole conflict check depends on as an
  `authenticated` role — every existing test either ran as `postgres` (bypassing RLS) or mocked
  the Supabase client away. Added Step 5b to `2-1-roles-and-rls.sql`, proving the owning account
  reads a machine-filed declaration (filed via `file_auto_check_result` itself, the real path)
  through that policy exactly like its own, and a different account sees nothing. **New tests:**
  `morning-gate.test.tsx` gained a read-failure case; the existing conflict-message test and its
  fixture key were reworded to match. Two lower-value findings (a pre-existing, non-exploitable
  missing `owner_id` cross-check in `file_auto_check_result`, matching the untouched `held`
  branch; a redundant, harmless `removeFromQueue` call already covered by `flush`'s own contract)
  were investigated and not actioned — neither changes behavior.

## Design Notes

**Why not fix this with `on conflict` client-side.** The client's insert has no `on conflict`
clause today; adding `on conflict (commitment_id, for_day) do nothing` there would make a genuine
conflict silently vanish exactly like the bug this story closes — the fix is to *detect* the
conflict and say what happened, not to swallow it more quietly.

**`classifyConflict`, in full:**
```ts
export function classifyConflict(
  existingIdempotencyKey: string | null,
  attemptedIdempotencyKey: string,
): 'duplicate' | 'conflict' {
  return existingIdempotencyKey === attemptedIdempotencyKey ? 'duplicate' : 'conflict';
}
```
Only reachable after a `23505` **whose follow-up read itself succeeded**; a `null` existing key
(row vanished between insert and select — not possible today, `declaration` has no delete policy)
reads as `'conflict'`, the safe default. Read *failure* is the caller's job to catch first
(`morning-gate.tsx` returns `'failed'` on a non-null `readError` before ever calling this) — never
pass a failed read's `null` data through as if it were a genuine empty result (round 2 finding).

**Conflict message, final** (reworded in round 2 — `classifyConflict` cannot tell an Auto-check
from the author's own second device, so the copy no longer claims to know which): *"This day has
already been answered — from another device, or by an Auto-check if one is attached — before this
reached the server. Reopen the app and it will be gone from today's questions."* Mirrors the
existing `rejected` copy's own pattern (explain, point at reopening the app) rather than inventing
a new interaction.

**Disclosure copy draft** (open to edit at CHECKPOINT): *"Because this costs money and has an
Auto-check attached, the Auto-check's result will stand once it reports a miss — you won't be able
to correct it yourself."* Deliberately does not yet promise an Appeal (Story 4.4 is what makes
that true); revisit this exact sentence when 4.4 ships.

**Why the client needs a follow-up `select`, not just the insert error.** Postgres's `23505`
error carries the violated constraint, not the winning row's `idempotency_key` — the only way to
tell "my own retry" from "someone else already decided" is to ask.

## Verification

**Commands, run 2026-08-24:**
- `npx supabase db reset` -- all 34 migrations, including
  `20260824110000_the_machines_word_stands.sql`, applied clean.
- All 18 files under `supabase/tests/` via `docker exec supabase_db_todoapp psql -v
  ON_ERROR_STOP=1` -- **18/18 pass**, including the new `4-3-the-machines-word-stands.sql`'s 5
  steps (`missed`+Penalty files `slipped`, idempotent, no outbox row; `missed`+no-Penalty files
  nothing; a second insert with a different `idempotency_key` for the same day is refused
  `23505` once the machine has filed; the author's own declaration is accepted normally where
  nothing was filed; an existing human answer is never overwritten by a later `missed`).
  `4-1-account-elsewhere.sql` (the `held` branch this sits beside) passes unchanged. Re-run after
  round 2 with `2-1-roles-and-rls.sql`'s new Step 5b -- still **18/18**.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.
- `npm test` -- **691/691 pass** across 33 files, including new cases in
  `lib/declaration-submit.test.ts` (own-retry, conflict, null-as-safe-default for
  `classifyConflict`), `components/morning-gate.test.tsx` (own retry proceeds; a genuine
  conflict shows the distinct, cause-agnostic message and does not call `onAnswered`; **round 2:
  a failed follow-up read keeps the item queued rather than reporting a false conflict**), and
  `components/commitment-form.test.tsx` (disclosure shown only with both toggles on; suppressed
  on an `abstain` commitment even with Penalty on).

**Note on round 2:** independent review found the follow-up `select`'s own `error` was never
checked (a transient read failure was indistinguishable from a genuine conflict, discarding a
real answer) and the conflict message asserted a cause (`classifyConflict` cannot verify who
filed the winning row) it couldn't prove. Both fixed; `2-1-roles-and-rls.sql` gained Step 5b
proving the RLS policy this whole mechanism depends on (`declaration: read own`) actually lets
the owning account read a machine-filed row and blocks a different account, exercised as
`authenticated`, not assumed or run only as `postgres`.

**Note on round 3 (independent `code-review`, post-push against commit `a6c92f9`):** 3
correctness angles (line-by-line, removed-behavior, cross-file) found nothing survive
verification. One simplification finding landed: the disclosure's guard re-spelled
`checksPossible && draft.autoCheckEnabled`, already used to gate the account-ref input a few
lines above — extracted to one `autoCheckActive` constant, reused at both sites. A second,
independently-raised-but-investigated candidate (the follow-up conflict select using the
component's single render-time `day` rather than each queued item's own actual day) was traced
end-to-end and **REFUTED as an observable bug** — the callback always returns `'sent'` on this
path regardless of the classification, and `flush()`'s own outer loop removes any `'sent'` item
from the queue unconditionally, so the imprecision changes nothing today. Fixed anyway (cheap,
removes a latent fragility that would only bite if that redundant removal were ever "cleaned
up") — the select now derives the day from `pending.answeredAt` itself, the same instant its own
`insert` already uses, instead of the outer closure. Three architectural observations (an RPC
would make conflict-detection atomic instead of insert-then-select; the extra round-trip costs a
little latency on every legitimate retry, not only genuine conflicts; the machine/human marker
column gap — already deferred from Story 4.1 — is now also what this story's conflict copy has
to work around in prose) were investigated and recorded in `deferred-work.md` rather than
expanding this story's scope further.

**Manual checks (if no CLI):** _None — the conflict path is timing-dependent (a machine result
landing between the gate's load and the author's tap) and only exercisable in the local suite via
a mocked/seeded conflict, not by hand._

## Suggested Review Order

**The precedence rule (DB)**

- Entry point: `file_auto_check_result`'s new `missed` branch — the whole mechanism FR-2a rests on.
  [`20260824110000...sql:38`](../../supabase/migrations/20260824110000_the_machines_word_stands.sql#L38)

**Why a filed `missed` is uncorrectable (client)**

- `classifyConflict` — the pure logic, including round 2's read-failure contract.
  [`declaration-submit.ts:71`](../../lib/declaration-submit.ts#L71)

- Where it's used: the follow-up read, the round-2 `readError` guard, and the conflict branch.
  [`morning-gate.tsx:111`](../../components/morning-gate.tsx#L111)

**The disclosure (UI)**

- The both-toggles-enabled paragraph.
  [`commitment-form.tsx:235`](../../components/commitment-form.tsx#L235)

**Tests — including the two round-2 fixes**

- The DB suite: `missed`→`slipped`, the no-Penalty no-op, and the refused second insert.
  [`4-3-the-machines-word-stands.sql:1`](../../supabase/tests/4-3-the-machines-word-stands.sql#L1)

- Round 2: `declaration: read own` exercised as `authenticated`, not assumed.
  [`2-1-roles-and-rls.sql:152`](../../supabase/tests/2-1-roles-and-rls.sql#L152)

- Round 2: the read-failure case, alongside the reworded conflict-message test.
  [`morning-gate.test.tsx:161`](../../components/morning-gate.test.tsx#L161)
