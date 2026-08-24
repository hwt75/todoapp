---
title: 'Story 4.4 — Contest a miss the machine got wrong'
type: 'feature'
created: '2026-08-24'
status: 'in-review'
review_loop_iteration: 0
baseline_commit: '906d6ae4ba00ae6de32b38e0b41b814ddbe506db'
story_key: '4-4-contest-a-miss-the-machine-got-wrong'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A Penalty-carrying commitment's machine-filed miss (Story 4.3) is currently
authoritative with no way back — the author cannot appeal it, and there is no `Held` state to
protect the money while a dispute is open (FR-14, FR-15). Two data gaps block a naive build: (1)
`penalty` is one row per Failed Day (FR-13), never per-commitment — "the associated Penalty"
means the whole day's Penalty, even if other, non-appealed misses contributed; (2) `declaration`
has no way to tell a machine-filed miss from the author's own honest `slipped` — without closing
that, anyone could self-declare `slipped`, "appeal" it, and let the deadline's timeout void a
Penalty they genuinely earned.

**Approach:** Add `declaration.filed_by` (`'doer' | 'auto_check'`, default `'doer'`), set by
`file_auto_check_result` (Story 4.3) — the cheapest closure of a gap three stories have now hit
(1st: 4.1's own defer; 2nd: 4.3's conflict-message workaround; 3rd: this story's eligibility
check). A new `appeal` table, filed by the author (client insert, RLS-gated) against a specific
`(commitment_id, for_day)`; a `before insert security definer` trigger (mirroring
`focus_session_derive_day`'s shape) validates ownership, that the day's `settlement_commitment`
outcome is `missed`, that the day's own declaration was machine-filed, and that its Penalty is
still `owed` — then atomically moves that Penalty to `held` and stamps the appeal's deadline
(`appeal_deadline()`, a sibling of `declaration_deadline`, using the PRD's own committed
assumption: end of the day following the appeal). A new hourly job voids any `held` Penalty past
its deadline to `dropped` — a plain guarded `update ... where state = 'held'`, AD-15's own
first-writer-wins shape, since `held → dropped`/`held → owed` (Story 4.6, later) racing the same
row is exactly what that guard exists for. Evidence: a private Storage bucket + `appeal_evidence`
table, access derived from the appeal's own `owner_id` (NFR4) — optional at submission, added by
a second, separate insert. Weekly Quota is out of scope (no `settlement_commitment` to trace a
week's Penalty back to one commitment — a pre-existing, already-recorded gap); the Appeal
screen's copy is generic and honest ("Account elsewhere reported a miss"), not UX-DR25's
measured-quantity example (`account_elsewhere` has no observed/required numbers to show, and no
other Auto-check kind exists yet) — both scoped with the human before writing this spec.

## Boundaries & Constraints

**Always:**
- `declaration.filed_by` defaults `'doer'`; only `file_auto_check_result`'s `security definer`
  body ever writes `'auto_check'` — never settable by a client insert (column excluded from the
  client's own insert shape; RLS doesn't need to enforce this since the client never sends it).
- Appeal eligibility requires ALL of: commitment owned by the caller, `carries_penalty = true`,
  cadence-independent but only reachable in practice for `daily` (no `settlement_commitment` row
  exists for `weekly_quota`), `settlement_commitment.outcome = 'missed'` on the *current*
  (`supersedes is null`) day settlement, `declaration.filed_by = 'auto_check'` for that day, and
  the linked `penalty.state = 'owed'`. Any failure raises — no silent no-op insert.
- One appeal per `(commitment_id, for_day)` — a database constraint, not merely a UI guard.
- The `held → dropped` timeout-void is a guarded `update ... where state = 'held'` (AD-15) — a
  raced second writer (a future Story 4.6 ruling) affects zero rows, never errors.
- Evidence upload is a second, separate step after the appeal row exists — never required to
  submit an appeal, never blocking the Penalty-hold transaction.
- Storage bucket `appeal-evidence` is private; its RLS derives access from `appeal.owner_id`
  through `appeal_evidence`, per NFR4 — never a public bucket, never a blanket authenticated
  policy.

**Ask First:** _None outstanding — cadence scope, the Appeal copy's honesty-over-richness
tradeoff, and the `filed_by` fix were confirmed with the human before this spec was written (see
Spec Change Log)._

**Never:**
- No Weekly Quota appeal support (needs `settle_week` to gain `settlement_commitment` writes
  first — a separate, already-deferred gap).
- No fabricated "observed X, needed Y" copy — `account_elsewhere` has no such data.
- No referee surface, login, or ruling (`Held → owed` via a ruling) — Story 4.5/4.6. This story
  only builds the author's submission and the timeout-favors-the-author path.
- No `Collected` ledger state or collection message — Story 4.7.
- No change to `settle_day`, `settle_week`, `auto_check_pending`, or the `penalty_one_per_settlement`
  constraint — the bundled-per-day Penalty model is accepted as-is (epic-4-context.md's own
  design), not restructured.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Eligible appeal | Machine-filed `missed` on an `owed`, Penalty-carrying Daily commitment | `appeal` row created; that day's `penalty.state` becomes `held` in the same transaction | — |
| Self-declared slip | Author's own `slipped` (not machine-filed) on the same shape | Insert raises — `declaration.filed_by <> 'auto_check'` | Refused, no row, no state change |
| Already appealed | A second appeal attempt on the same `(commitment_id, for_day)` | Refused by the unique constraint | No second Penalty hold |
| Timeout, unruled | `held` Penalty past `appeal_deadline` | Voided to `dropped` by the hourly job | Never converts to `owed` on its own |
| Raced terminal write | Two writers attempt to resolve the same `held` Penalty at once | First succeeds; second affects zero rows | No exception, no double-resolution |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819230000_penalty.sql` -- `penalty_state` enum (`'owed'` only today,
  comment already anticipates `held`/`dropped` here); `penalty_one_per_settlement` constraint (no
  `commitment_id` column — bundled-per-day model).
- `supabase/migrations/20260819200000_declaration.sql` -- `declaration` table/RLS; add
  `filed_by` here (new migration, `alter table`).
- `supabase/migrations/20260824110000_the_machines_word_stands.sql:38-92` -- `file_auto_check_result`;
  its `missed`→`slipped` insert (L70-72) gains `filed_by = 'auto_check'`.
- `supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql:90-127` --
  `focus_session_derive_day()`: the exact `before insert security definer` trigger shape to mirror
  (ownership lookup via `select ... where id = new.x`, compare to `new.owner_id`, raise on
  mismatch; revoked from client roles, fires regardless since triggers aren't EXECUTE-gated).
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:58-66` -- `declaration_deadline`:
  the sibling shape `appeal_deadline` mirrors (`language sql stable`), not reuses.
- `supabase/migrations/20260819260000_chain.sql:24` -- `settlement_commitment` schema
  (`settlement_id, subject, commitment_id, outcome`). `supabase/migrations/20260819220000_settlement.sql:25`
  -- `settlement` (`id, subject, period, kind, verdict`); `supersedes` added in
  `20260819241000_expiry_and_supersession.sql`. The join Appeal eligibility reads.
- `supabase/config.toml:115-125` -- `[storage]` block; add a `[storage.buckets.appeal-evidence]`
  entry for local dev (commented example already present).
- `components/ledger.tsx:38-41,71-78,110-150` -- `buildLedger`'s existing `declaration` join
  (already fetches per-commitment misses for a Failed Day) and the row-render block; Contest
  affordance attaches to an `owed`-state failed-day row. `lib/ledger.ts:19,44-54,125-132` --
  `PenaltyState`, `ledgerPillLabel()` gain `held`/`dropped`.
- `supabase/tests/2-1-roles-and-rls.sql` -- pattern for a new RLS-privilege test on `appeal`.
- New: `components/appeal-form.tsx` (submission UI), `lib/appeal.ts` (client-side shape/validation
  mirroring `lib/commitment.ts`'s style).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260824120000_a_slip_the_machine_filed_is_not_a_slip_he_typed.sql` --
  `alter table declaration add column filed_by`; `file_auto_check_result` gains the one-line set
  on its `missed` insert
- [x] `supabase/migrations/20260824130000_contest_a_miss_the_machine_got_wrong.sql` --
  `penalty_state` gains `held`/`dropped`; `appeal` table + RLS (`file own`, `read own`) + unique
  `(commitment_id, for_day)`; `appeal_hold_penalty()` trigger; `appeal_deadline()`;
  `appeal_evidence` table + RLS; `appeal-evidence` storage bucket + `storage.objects` policy
  deriving from `appeal.owner_id`
- [x] `supabase/migrations/20260824140000_void_expired_appeals.sql` -- `void_expired_appeals()`
  (guarded `update ... where state = 'held'`), cron'd hourly. Not `:35` -- that slot turned out
  already taken by `weekly-quota-reminders` (20260822090000, predating this spec); used the one
  genuinely free slot instead, `:55`, deliberately last in the hour so every other pass has
  already run before this one decides whether an appeal was missed.
- [x] `supabase/tests/4-4-contest-a-miss-the-machine-got-wrong.sql` -- covers the I/O matrix:
  eligible appeal holds the Penalty; self-declared slip refused; a second eligible miss cannot
  also claim an already-held Penalty; duplicate appeal refused by the unique constraint itself;
  timeout void; raced terminal write is a no-op second time, from both directions of the AD-15
  race. All 19 files pass, including under CI's exact `-x` service exclusions (storage schema
  survives excluding the `storage-api` service, verified directly).
- [x] `supabase/tests/2-1-roles-and-rls.sql` -- `appeal`/`appeal_evidence` added to the
  negative-privilege sweep (step 5c); a cross-account read/insert refused for both tables
- [x] `lib/ledger.ts` -- `PenaltyState`/`ledgerPillLabel()` gain `held` (urgent family, never the
  held-color or failed families, per epic-4-context.md's own color note) and `dropped`
  (held-color family, alongside `waived`); `LedgerRow.appealable` added so the UI knows which
  misses are eligible without re-deriving server logic
- [x] `components/ledger.tsx` -- Contest affordance on an eligible `owed` failed-day row, one
  control per contestable commitment
- [x] `components/appeal-form.tsx` + `.test.tsx` -- claim + optional evidence upload; the
  hold-state copy (verbatim from EXPERIENCE.md, see Design Notes)
- [x] `lib/appeal.ts` + `.test.ts` -- client-side shape/validation

Manual check (Storage, per the story's own note that this can't run in `supabase/tests/*.sql`):
performed against a full local stack (`npx supabase start`, Storage included) via real REST
calls with two signed-in accounts -- an eligible appeal filed through `appeal: file own`, an
evidence photo uploaded to `appeal-evidence/{appeal_id}/...`, read back by the submitting
account (200, real bytes), refused for a different account both to upload (403 RLS) and to read
(404 -- filtered, not merely forbidden) and to read the `appeal_evidence` metadata row. Full
transcript in this session's tool history.

**Acceptance Criteria:**
- Given a machine-filed `missed` on a Penalty-carrying Daily commitment, when the author submits
  an Appeal, then that day's Penalty moves to `held` before it is ever shown as owed, and the
  screen states in words that the money is held, not charged, and what happens if nobody rules on
  it by the deadline.
- Given the same shape but the day's own declaration was the author's own honest `slipped` (not
  machine-filed), then the appeal is refused — nothing to contest.
- Given a `held` Penalty whose deadline passes with no ruling, then it is voided to `dropped` and
  never converts to `owed` on its own.
- Given evidence attached to an appeal, then it is stored in a private bucket only the submitting
  account (and, once Story 4.5/4.6 exist, the ruling referee) can reach.

## Spec Change Log

- **2026-08-24, pre-approval scoping (human decisions, recorded for traceability):** Two
  questions asked before writing this spec. (1) AC1's UX-DR25 example ("Location saw you for 4
  minutes. It needed 30.") requires measured observed-vs-required data `auto_check_result` never
  stored and `account_elsewhere` (the only real Auto-check kind) has no such concept of — human
  chose a generic, honest message over inventing a speculative data model for a resolver shape
  that doesn't exist yet. (2) `penalty` bundles per Failed Day/Week with no per-commitment
  attribution for Weekly Quota (`settle_week` writes no `settlement_commitment`, a pre-existing,
  already-recorded gap) — human chose Daily-only for v1, deferring Weekly Quota appeal support
  until `settle_week` gains that traceability. **Independently found while designing eligibility
  (not asked, judged in-scope):** without a way to tell a machine-filed miss from the author's
  own honest `slipped`, Appeal would be exploitable — self-declare a slip, appeal it, let the
  timeout void a Penalty that was never actually the machine's call. Closed with
  `declaration.filed_by`, the cheapest fix and the third story to need this exact,
  already-recorded gap (4.1 deferred it, 4.3 worked around it in copy, this story cannot work
  around it at all without becoming exploitable).

- **2026-08-24, round 2 (independent review, 3 layers — blind-hunter, edge-case-hunter,
  verification-gap — against the implementation subagent's own diff):**
  - **Fixed, critical:** the first cut of `declaration.filed_by` only carried a column
    `default 'doer'` — a client insert that explicitly sent `filed_by: 'auto_check'` was accepted
    as-is, since the live project's own default table-level `INSERT` grant to `authenticated` is
    not scoped to a column allowlist. That forges a machine-filed miss and defeats this whole
    story's premise (self-declare a slip, appeal it, let the timeout drop a Penalty that was never
    the machine's call). Closed by extending `declaration_derive_day()` (already the one trigger
    that sees every insert regardless of caller) to force `filed_by := 'doer'` whenever
    `current_user in ('anon', 'authenticated')` — genuine client calls, never
    `file_auto_check_result`'s own `security definer` context. Proven with a new regression test
    (`2-1-roles-and-rls.sql` Step 5d): inserts as `authenticated` with `filed_by` explicitly set to
    `'auto_check'`, asserts it reads back `'doer'`; confirmed the test fails with the fix reverted
    and passes with it restored.
  - **Fixed:** `appeal_evidence.storage_path` carried no check that it actually led with its own
    `appeal_id` — a client could point the metadata row at a path outside its own appeal (a
    different appeal's folder, or nothing real at all). `storage.objects`' own RLS already refuses
    the client any real access to a mismatched object, but the metadata row itself could still
    misreport what it owns — a gap worth closing now, cheaply, before a future referee surface
    (Story 4.6) has reason to trust it. Closed with a `check (storage_path like (appeal_id::text ||
    '/%'))` on the column. Proven with a new regression test (`4-4-...sql` Step 6): a mismatched
    path is refused, a correctly-scoped one succeeds; confirmed the test fails with the constraint
    reverted and passes with it restored. Also fixed two pre-existing fixtures in
    `2-1-roles-and-rls.sql` Step 5c that used unscoped literal paths and would otherwise have
    started failing the new constraint.
  - **Fixed, test coverage:** `verification-gap` found two behavioral changes only exercised by
    `lib/ledger.test.ts`'s pure-function tests, never by `components/ledger.test.tsx`'s real render
    path — (1) a `held`/`dropped` Penalty's pill `className` (the `held → pill-urgent`,
    `dropped → pill-held` mapping `ledgerPillFamily()` makes, deliberately not sharing a class with
    either `pill-held`'s "resolved" meaning or `pill-failed`), and (2) that each Contest button on
    a multi-miss Failed Day fires with its own commitment, not the first/last iteration's. Both
    were single-miss or text-only fixtures before, unable to catch a mixup. Added two component
    tests; confirmed each fails against a deliberately broken version of `components/ledger.tsx`
    (pill family collapsed to two states; every button's `onClick` reading `row.appealable[0]`)
    and passes against the real code.
  - **Investigated, not a gap (edge-case-hunter):** a commitment behind a held appeal being hard-
    deleted (cascade) — `commitment` carries no `delete` RLS policy anywhere in this schema (`20260819150000_commitment.sql`'s own "archive rather than delete"), so this path is unreachable
    through the app. A settlement an already-held appeal points to being superseded later —
    `supersede_expiries()` only ever touches `settlement_current` rows with `verdict = 'expired'`;
    an appealable day is always `verdict = 'failed'` (fully answered, at least one admitted/
    machine-filed slip), which supersession's own scope never revisits. A pre-existing
    `declaration` row needing a `filed_by` backfill — `resolve_account_elsewhere` always returns
    `'unavailable'` on the live project (no real Auto-check provider exists yet), so `'missed'`
    — the only branch that writes `filed_by = 'auto_check'` — has never actually fired outside a
    test/direct-SQL call; no live row needs backfilling. A raw Postgres error surfacing on a
    non-`23505 appeal` insert failure — matches `morning-gate.tsx`'s own established handling of a
    `'rejected'` classification (showing `error.message` directly), not a regression this story
    introduced.
  - **Deferred, deployment step, not a code change:** the `appeal-evidence` bucket is created from
    `supabase/config.toml` only on `supabase start`/`db reset` (local dev) — the live project needs
    it provisioned directly (dashboard or Management API) as part of applying this story's
    migrations, tracked as a manual step below rather than a schema change. **Done**: provisioned
    on the live project via `insert into storage.buckets` matching `config.toml` exactly (private,
    10MiB, the same three MIME types) as part of this round's live deployment.

- **2026-08-24, round 3 (standalone `/code-review`, 8 finder angles against the pushed commit,
  after the story's migrations had already reached the live project):**
  - **Fixed, critical (money-trust):** `appeal_hold_penalty()`'s eligibility lookup read the wrong
    settlement in two compounding ways. First, it filtered `s.supersedes is null` to mean "the
    current settlement," which only holds for a day never corrected by `supersede_expiries()` — for
    a corrected day, the row that stands is the *correction* (`supersedes is not null`), not the
    original the query actually matched. A day that closed `expired` on one commitment's silence
    while another commitment's own machine-filed `missed` was already frozen, later corrected to
    `failed` once the silent commitment's late-but-timely answer arrived, leaves two separate
    Penalty rows — the original's (now historical) and the correction's (the only one
    `penalty_current`/the Ledger ever read). An appeal filed after such a correction matched the
    stale original and held *its* Penalty — not the live one — so the author would see "held" on the
    Appeal screen while the Ledger kept naming the same money as owed, completely untouched. Second,
    the query never checked `s.verdict` at all, so a day that closed `expired` (silence from a
    *different* commitment) but still froze one machine-filed `missed` outcome could be appealed
    server-side, even though `lib/ledger.ts`'s pill/aria-label logic has no branch that ever reflects
    `held`/`dropped` for an `expired` verdict — the row would have stayed permanently mislabeled
    "Expired ... owed X" regardless of what the appeal actually did. One fix closes both: the query
    now reads the settlement that is genuinely current (mirroring `settlement_current`'s own
    "nothing supersedes it" definition directly) and requires `verdict = 'failed'`. Shipped as a new
    migration (`20260824150000_an_appeal_reads_the_day_that_stands.sql`) rather than editing
    `20260824130000` in place, since that migration had already reached the live project by the time
    this was found. `lib/ledger.ts`'s own `appealable` gate was narrowed to match in the same round,
    so the client mirror and the trigger it mirrors agree on scope again. Found independently by two
    of the eight finder angles (line-by-line and cross-file-tracer), and a third (removed-behavior)
    independently found the downstream display symptom — triangulated confirmation before any fix
    was written. Reproduced directly against the local stack before fixing (reverted the query,
    confirmed the appeal silently held the wrong, disconnected penalty exactly as predicted, restored
    it), and proven with a new regression test in both layers: `supabase/tests/4-4-...sql` Step 7
    (a full expire-then-correct fixture, asserting the appeal's `penalty_id` matches
    `penalty_current`'s row, not the historical one) and a new `lib/ledger.test.ts` case for the
    `verdict = 'expired'` exclusion — both independently confirmed to fail against the reverted code
    and pass with the fix restored.
  - **Fixed:** `lib/appeal.ts`'s `formatDeadline()` hardcoded the literal `'Asia/Ho_Chi_Minh'`
    instead of importing the shared `ZONE` constant `lib/declaration.ts` already exports and
    `lib/expiry.ts` already reuses for the identical purpose — closed by importing it.
  - **Deferred (7 findings, all recorded in `deferred-work.md` under "independent code-review of
    commit bbcca81"):** `void_expired_appeals()`'s timeout guard isn't scoped to the appeal
    currently holding a Penalty (unreachable until Story 4.6's ruling can move a Penalty
    `held → owed`, which doesn't exist yet); `appeal_hold_penalty()` re-reads `carries_penalty`
    live rather than from a frozen snapshot (no UI path to exploit it, and toggling could only ever
    hurt the toggler); the `storage.objects` ownership check is duplicated across two policies
    (only two call sites exist; revisit when a third, e.g. a referee's read, arrives); the evidence
    filename sanitizer strips file extensions (no consumer reads them back yet); `lib/ledger.ts`'s
    pill label/family and `components/ledger.tsx`'s aria-label independently re-derive the same
    decision tree three times (a real duplication risk, but a deliberate refactor rather than a
    late addition to this round); `components/appeal-form.tsx` builds the same held-state shape and
    the same evidence-failure error at multiple call sites with no behavioral difference; and four
    small efficiency notes (extra round trips in the trigger, an indexed-column cast in the storage
    policies, an O(n²) array build in `buildLedger`) — all real but immaterial at this app's current
    single-doer-per-account scale.

## Design Notes

**`appeal_hold_penalty()`, the shape (full body at implementation time):**
```sql
create function public.appeal_hold_penalty() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid; v_carries boolean; v_filed_by text;
  v_settlement_id uuid; v_outcome public.commitment_outcome; v_penalty record;
begin
  select owner_id, carries_penalty into v_owner, v_carries
    from public.commitment where id = new.commitment_id;
  if not found or v_owner <> new.owner_id then
    raise exception 'Appeal commitment does not belong to the appealing account.';
  end if;
  if not v_carries then
    raise exception 'Only a Penalty-carrying commitment can be appealed.';
  end if;

  select sc.settlement_id, sc.outcome into v_settlement_id, v_outcome
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
   where sc.commitment_id = new.commitment_id and s.period = new.for_day
     and s.kind = 'day' and s.subject = new.owner_id and s.supersedes is null;
  if not found or v_outcome <> 'missed' then
    raise exception 'No machine miss on record for this commitment/day.';
  end if;

  select filed_by into v_filed_by from public.declaration
   where commitment_id = new.commitment_id and for_day = new.for_day;
  if v_filed_by is distinct from 'auto_check' then
    raise exception 'Only a machine-filed miss can be appealed.';
  end if;

  select id, state into v_penalty from public.penalty where settlement_id = v_settlement_id;
  if not found or v_penalty.state <> 'owed' then
    raise exception 'This day''s Penalty is not appealable.';
  end if;

  new.settlement_id := v_settlement_id;
  new.penalty_id := v_penalty.id;
  new.deadline := public.appeal_deadline(now());

  update public.penalty set state = 'held' where id = v_penalty.id and state = 'owed';
end;
$$;
```
Mirrors `focus_session_derive_day`'s shape exactly (ownership lookup, raise on mismatch,
`security definer`, revoked from client roles — a trigger fires regardless of the EXECUTE grant,
the revoke is only to keep it off `/rest/v1/rpc`).

**Hold-state copy, verbatim (EXPERIENCE.md):** *"500,000 is on hold, not charged. It stays on
hold until [Referee] decides, or until [deadline] closes — and if he doesn't get to it, it's
dropped."*

**Why a plain client `insert`, not an RPC.** No function in this codebase is both
`security definer` and granted `EXECUTE` to `authenticated` — every privileged client-triggered
write goes through an RLS-gated insert plus a `before insert security definer` trigger
(`focus_session_derive_day`, `declaration_derive_day`). Appeal follows the same idiom rather than
introducing a new one.

**Storage can't run in `supabase/tests/*.sql`.** `db-tests`' CI job starts the stack with
`-x ... Storage` (`supabase/tests/README.md:40`), and no bucket/`storage.objects` precedent
exists anywhere in this repo yet. The evidence-bucket RLS is verified by a manual check against a
full local stack (`npx supabase start`, no `-x` exclusions), recorded as a manual step, not a
`supabase/tests/*.sql` file — the first story-shipped feature this project's own "verification is
a file, not a paragraph" rule can't fully honor, and said so rather than silently claiming
coverage it doesn't have.

## Verification

**Commands, round 1, run 2026-08-24:**
- `npx supabase db reset` -- all 39 migrations, including the three new ones, applied clean; the
  Storage bucket `appeal-evidence` was created from `supabase/config.toml` on the same reset.
- All 19 files under `supabase/tests/` via `docker exec supabase_db_todoapp psql -v
  ON_ERROR_STOP=1` -- **19/19 pass**, including `4-4-contest-a-miss-the-machine-got-wrong.sql`'s
  7 steps (fixture: one Failed Day, one Penalty, three frozen misses; self-declared slip refused;
  eligible appeal holds the Penalty atomically; a second eligible miss cannot also claim an
  already-held Penalty; a duplicate appeal refused by the unique constraint itself; timeout void
  to `dropped`, idempotent on retry; the AD-15 race proven from both directions). `2-1-roles-and-
  rls.sql`'s new Step 5c: `appeal`/`appeal_evidence` readable/writable only by their own account,
  including that `appeal_evidence_derive_owner()` silently reassigns a planted `appeal_id` back
  to its true owner rather than letting a different account attach evidence to it.
  `4-3-the-machines-word-stands.sql` (whose `filed_by`-tagged fixtures this reads) passes
  unchanged.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.
- `npm test` -- **747/747 pass** across 35 files, including new cases in `lib/appeal.test.ts`,
  `components/appeal-form.test.tsx`, and updates to `lib/ledger.test.ts`/`components/ledger.test.tsx`
  for the `held`/`dropped` pill states and the Contest affordance.

**Manual checks (Storage cannot run in `supabase/tests/*.sql` -- see Design Notes):**
- Ran the real flow end-to-end via REST with two live accounts against a full local stack: an
  eligible appeal filed, evidence uploaded under `{appeal_id}/...`, readable by the owner (200,
  real bytes back); a different account refused both an upload (403) and a read (404 -- filtered
  by RLS, not merely forbidden) -- matching NFR4. Database reset afterward to leave the
  environment clean.

**Commands, round 2 (post-review fixes), run 2026-08-24:**
- `npx supabase db reset` -- clean, including the now-enforced `declaration_derive_day()` guard
  and `appeal_evidence`'s new `storage_path` check constraint.
- All 19 files under `supabase/tests/` -- **19/19 pass**, including two new steps:
  `2-1-roles-and-rls.sql` Step 5d (`filed_by` forgery attempt from an `authenticated` insert) and
  `4-4-...sql` Step 6 (`storage_path` scoped-to-own-`appeal_id` check). Both regression tests
  independently proven to actually catch their bug: reverted each fix in isolation, confirmed the
  matching test fails with the exact expected message, restored the fix, confirmed it passes
  again.
- `npm test` -- **749/749 pass** across 35 files (747 + 2 new `components/ledger.test.tsx` cases:
  pill `className` for `held`/`dropped`, and per-button payload correctness on a multi-miss Failed
  Day). Both new component tests independently proven to catch their bug the same way: broke the
  matching logic in `components/ledger.tsx` (collapsed pill family, button reading
  `appealable[0]` unconditionally), confirmed the test failed with the expected diff, restored the
  real code, confirmed 749/749 passes again.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.

**Commands, round 3 (post-review fixes, standalone code-review), run 2026-08-24:**
- `npx supabase db reset` -- clean, 40 migrations including the new
  `20260824150000_an_appeal_reads_the_day_that_stands.sql`.
- All 19 files under `supabase/tests/` -- **19/19 pass**, including a new Step 7 in
  `4-4-...sql` (an expire-then-correct fixture proving an appeal against a corrected day holds
  the CURRENT penalty, not a disconnected historical one). Proven to actually catch the bug:
  reverted the fix, confirmed the appeal silently held the wrong penalty exactly as the finding
  predicted, restored the fix, confirmed the test passes again.
- `npm test` -- **753/753 pass** across 35 files (749 + 1 new `lib/ledger.test.ts` case for the
  `verdict = 'expired'` exclusion, plus the `lib/appeal.ts` ZONE-import fix). The new test proven
  to catch the bug the same way: reverted `lib/ledger.ts`'s `appealable` gate, confirmed the test
  failed with the expected diff, restored the real code, confirmed 753/753 passes again.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` -- clean.
- Live project (`hxzalpnlrunctbajgtkv`): `20260824150000` applied via `apply_migration`;
  `get_advisors(type=security)` re-checked -- clean, only the known pre-existing
  `auth_leaked_password_protection` warning.
