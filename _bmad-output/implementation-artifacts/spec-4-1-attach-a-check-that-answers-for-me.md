---
title: 'Story 4.1 — Attach a check that answers for me'
type: 'feature'
created: '2026-08-23'
status: 'done'
review_loop_iteration: 0
baseline_commit: '72cc31b7'
story_key: '4-1-attach-a-check-that-answers-for-me'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Task setup already shows a disabled "Account elsewhere" checkbox (Epic 4's own
placeholder) with nothing behind it — every commitment is still settled entirely by the author's
own morning Declaration, even the one case FR-8 anticipated a machine confirming instead. Story
1.3 found the one concrete candidate (TryHackMe) unreadable from outside, so there is no real
external service to integrate against in v1.

**Approach:** Wire the checkbox into a real per-commitment link/unlink flow (a free-text account
identifier the author types, no OAuth, no live fetch at link time — human-confirmed: v1 ships the
generic attach/resolve/file mechanism only, no real API call). A `security definer` resolution
pipeline runs on its own cron slot, resolves each linked commitment through a pluggable per-kind
resolver (`account_elsewhere`'s own resolver has no live data source yet and always reads
`unavailable` — the seam a future story fills), and silently files the day's Declaration when a
result reads `held`. `missed`/`unavailable` file nothing, per FR-8b's fall-through — the author's
own Declaration still stands for those days.

## Boundaries & Constraints

**Always:**
- Auto-check config (kind, account ref, last-checked-at) is new nullable `commitment` columns,
  mirroring `weekly_target`/`week_start_day`'s symmetry-constraint pattern — never a global setting
  or JSON blob.
- The link control only saves what the author typed. No OAuth, no fetch/validation against the
  identifier at link or resolve time.
- `auto_check_kind` accepts only `'account_elsewhere'` for now — Location/Phone movement/Timer stay
  disabled placeholders, unchanged by this story.
- Resolution and filing run `security definer`, `set search_path = ''`, schema-qualified, revoked
  from `public`/`anon`/`authenticated` — server/cron-only, matching `settle_day`'s house style.
- A `held` result files exactly one `declaration` row (`answer = 'held'`, server-generated
  `idempotency_key`, `answered_at = now()`) per commitment/day, and only when that day has no
  declaration yet.
- Filing this way calls no `outbox_enqueue` — machine confirmation is silent (UX-DR29).
- Auto-check cannot attach to an `abstain`-kind commitment (mirrors `autoChecksPossible()`).

**Ask First:**
- Any change to `declaration_answer`'s enum values, or to `commitments_owing`/`settle_day` — this
  story only files into `declaration` ahead of settlement; it must not touch settlement itself.

**Never:**
- No real external API/HTTP call — `resolve_account_elsewhere` has no live data source in v1.
- No OAuth flow, no credential storage.
- No Location/Phone movement/Timer Auto-check.
- No multi-Auto-check-per-commitment — one slot per commitment; per-check availability (FR-8b's
  "the working one still counts") is Story 4.2's scope once a second real kind exists.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Link | Author enters an account ref and enables Account elsewhere on a non-`abstain` commitment | Saved: `auto_check_kind='account_elsewhere'`, `auto_check_account_ref=<text>`, `auto_check_last_checked_at=null` | Empty ref refused client- and DB-side |
| Unlink | Author disables it on a linked commitment | All three columns cleared to `null` | — |
| Attempted on `abstain` | Author tries to enable it on an Avoid-it commitment | Refused — checkbox stays disabled, as today | — |
| Resolve pass, no signal | Cron runs; linked commitment has no data source (v1's only case) | No declaration filed; `auto_check_last_checked_at` bumped | — |
| Already declared | Commitment's target day already has a declaration | Resolver skips it — never queried or overwritten | — |
| Held, direct file | `file_auto_check_result` called with `'held'` for an undeclared day | One `declaration` row, `answer='held'`, no outbox row | — |
| Missed / unavailable, direct file | `file_auto_check_result` called with `'missed'` or `'unavailable'` | No row written | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819150000_commitment.sql:13-71` — mirror `weekly_target`'s
  symmetry-check pattern; `kind commitment_kind` is the abstain guard.
- `supabase/migrations/20260819200000_declaration.sql:46-121,87-102` — `declaration` schema;
  `declaration_derive_day()` files `answered_at=now()` as *yesterday* — no date logic needed here.
- `supabase/migrations/20260820140000_weekly_quota_is_not_judged_daily.sql:60-198` — `settle_day`,
  the `security definer` house style to copy.
- `supabase/migrations/20260819180000_outbox.sql:134-154` — `outbox_enqueue`; silence = never call it.
- `supabase/migrations/20260820150000_the_week_closes_and_settles.sql:367-370` — cron rotation
  (`:05/:15/:25/:35/:45` taken) — new pass uses `:00`, ahead of `settle-days`.
- `lib/commitment.ts:34-58,93-144,159-171` — `CommitmentDraft`/`EMPTY_DRAFT`/`draftProblems()`/
  `toRow()`, same places `weeklyTarget` lives.
- `components/commitment-form.tsx:29-30,169-187` — `AUTO_CHECKS` loop; only `'Account elsewhere'`
  goes live, the other three unchanged.
- `components/commitment-list.tsx:15-24,33-34,45-55` — `CommitmentRow`/`SELECT`/`toDraft()`.
- `.../EXPERIENCE.md:158` — "Account-elsewhere link" component spec already covers this UI.
- `supabase/tests/README.md:72-88` — manifest table, `<epic>-<story>-<slug>.sql` naming.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_an_account_elsewhere_is_attached_not_read.sql` — enums
  `auto_check_kind ('account_elsewhere')`, `auto_check_result ('held','missed','unavailable')`;
  three `commitment` columns + symmetry + abstain-guard checks; `resolve_account_elsewhere(uuid)
  returns auto_check_result` (stub, always `'unavailable'`); `file_auto_check_result(commitment_id,
  owner_id, result) returns void` (files only on `'held'`); `resolve_auto_checks() returns integer`
  (loops linked+undeclared commitments, calls both, bumps `auto_check_last_checked_at`);
  `cron.schedule('resolve-auto-checks', '0 * * * *', ...)`.
- [x] `lib/commitment.ts` — add `autoCheckEnabled`/`autoCheckAccountRef` to `CommitmentDraft`,
  `EMPTY_DRAFT`, `draftProblems()` (non-empty ref when enabled, refused on `abstain`), `toRow()`.
- [x] `components/commitment-form.tsx` — the `'Account elsewhere'` row becomes a live checkbox +
  conditional text input; optional `autoCheckLastCheckedAt` prop for the "last read" display.
- [x] `components/commitment-list.tsx` — extend `CommitmentRow`/`SELECT`/`toDraft()`; pass
  `auto_check_last_checked_at` to `CommitmentForm` in edit view.
- [x] `supabase/tests/4-1-account-elsewhere.sql` — link/unlink round-trip; constraints refuse bad
  rows; `file_auto_check_result` files on `'held'` only; `resolve_auto_checks()` skips an
  already-declared commitment, bumps `auto_check_last_checked_at` with zero rows filed on an
  undeclared one, zero outbox rows throughout.
- [x] `supabase/tests/README.md` — add the new file to the manifest table.

**Acceptance Criteria:**
- Given the Task setup surface, when I enable Account elsewhere, then an unlinked state shows a
  link control; once linked it shows the account identifier and when it was last read.
- Given a linked account whose resolver reads `held` for an undeclared day, when the pass runs,
  then the Declaration is filed automatically and I am never prompted for that commitment, and no
  notification is generated.
- Given any Auto-check attached to a commitment, then its configuration is stored on that
  commitment, never as a global setting.

## Design Notes

**`resolve_account_elsewhere` can never say `held` in v1** — FR-8 was resolved negative for the
only concrete service considered (TryHackMe, Story 1.3); no data source exists today. Splitting the
per-kind resolver from the dispatcher/filer is the one seam a future story needs to plug in a real
check, nothing more. The "day with completion data" AC is proven by calling `file_auto_check_result`
directly with `'held'` in the test file, not by the cron path — recorded here, not overclaimed.

**`missed` files nothing, same as `unavailable`, in this story.** Distinguishing them (FR-8b) and
making a penalty-carrying `missed` authoritative (FR-2a) belong to Stories 4.2/4.3; 4.1 only proves
the `held`-files/else-silent shape they build precedence on.

## Verification

**Commands, run 2026-08-23:**
- `npx supabase start` → `npx supabase db reset` — every migration (including this story's) applies
  clean.
- All 16 files under `supabase/tests/` run via `docker exec supabase_db_todoapp psql -v
  ON_ERROR_STOP=1` — **15/16 pass**, including `4-1-account-elsewhere.sql` (all seven I/O-matrix rows
  covered: malformed/abstain attaches refused, link/unlink round-trip, `resolve_account_elsewhere`
  always `unavailable`, `file_auto_check_result` files on `held` only and is idempotent,
  `resolve_auto_checks()` skips an already-declared commitment, resolves exactly the undeclared
  linked one, ignores the unlinked one, and stays silent throughout). `3-2-focus-prompt.sql` did not
  run — its own 07:00–20:00 Asia/Ho_Chi_Minh wall-clock guard, unrelated to this story.
- `npm run lint`, `npx tsc --noEmit`, `npm run format:check` — clean.
- `npm test` — **673/673 pass** across 33 files, including new coverage in `lib/commitment.test.ts`
  and updated `commitment-form.test.tsx`/`commitment-list.test.tsx`.
- Applied to the live project (`hxzalpnlrunctbajgtkv`) via the Supabase MCP server's
  `apply_migration` (post-review, so the null-safety fix shipped in the same pass as the rest) —
  re-checked after: all three functions exist with the expected `security definer`/schema-qualified
  shape, `file_auto_check_result`'s definition contains the `is distinct from` fix,
  `cron.job` lists `resolve-auto-checks` at `0 * * * *`, and `get_advisors(type=security)` shows
  only the pre-existing, unrelated `auth_leaked_password_protection` warning.

**Code review, 2026-08-23 (3 layers — blind-hunter, edge-case-hunter, verification-gap):** 3
findings patched, all re-verified against the commands above after fixing:
- `withKind()` (new, `lib/commitment.ts`) clears a linked Auto-check when the Kind switches to
  `abstain` — otherwise the checkbox rendered checked-and-disabled with no way left to uncheck it
  (found independently by all three layers).
- `file_auto_check_result`'s guard changed from `<>` to `is distinct from` — a null result (an
  unmatched `auto_check_kind` in the dispatcher's own `case`, which has no `else`) fell through the
  old check and filed an erroneous `held` declaration instead of nothing. Not reachable today (the
  only resolver in play never returns null), but hardens exactly the seam this spec's own Design
  Notes calls out as a future story's to fill.
- `resolve_auto_checks()`'s final `update` now guards on `auto_check_kind is not null` — a
  concurrent unlink between the loop's `select` and that `update` would otherwise violate
  `commitment_auto_check_last_checked_requires_kind` and abort the whole pass, not just the racing
  row.

Two findings deferred (test-coverage gaps in the new SQL suite: an archived+linked commitment and a
negative-privilege check, both one-line patterns already proven elsewhere) — recorded in
`deferred-work.md`. The rest (a stale "last read" timestamp when an already-linked ref is edited,
sprint/spec status labels, minor doc wording) were rejected as either already-disclosed, workflow
sequencing, or cosmetic.

**Manual checks (only the author can do these) — not yet performed:**
- In the installed app, enable Account elsewhere on a real commitment, confirm the linked state
  shows the identifier, then unlink and confirm it clears.

## Suggested Review Order

**Schema & resolution pipeline**

- Entry point: config, resolver, filer and dispatcher, in that order.
  [`20260823100000_...sql:22`](../../supabase/migrations/20260823100000_an_account_elsewhere_is_attached_not_read.sql#L22)

- The per-kind resolver stub — the seam a future story plugs a real check into.
  [`20260823100000_...sql:88`](../../supabase/migrations/20260823100000_an_account_elsewhere_is_attached_not_read.sql#L88)

- The filer's null-safe guard (`is distinct from`) — a review fix, see line comment.
  [`20260823100000_...sql:138`](../../supabase/migrations/20260823100000_an_account_elsewhere_is_attached_not_read.sql#L138)

- The dispatcher loop and its concurrency-safe final update — also a review fix.
  [`20260823100000_...sql:168`](../../supabase/migrations/20260823100000_an_account_elsewhere_is_attached_not_read.sql#L168),
  [`:205`](../../supabase/migrations/20260823100000_an_account_elsewhere_is_attached_not_read.sql#L205)

- The cron slot, ahead of settle-days.
  [`20260823100000_...sql:223`](../../supabase/migrations/20260823100000_an_account_elsewhere_is_attached_not_read.sql#L223)

**Client wiring**

- `CommitmentDraft`'s two new fields and `toRow()`'s null-vs-undefined column mapping.
  [`lib/commitment.ts:48`](../../lib/commitment.ts#L48),
  [`:195`](../../lib/commitment.ts#L195)

- `withKind()` — the review fix clearing a linked Auto-check on a kind that can't carry one.
  [`lib/commitment.ts:172`](../../lib/commitment.ts#L172)

- The live checkbox, conditional ref input, and the Kind select wired through `withKind()`.
  [`components/commitment-form.tsx:88`](../../components/commitment-form.tsx#L88),
  [`:205`](../../components/commitment-form.tsx#L205)

- `CommitmentRow`/`SELECT`/`toDraft()` carrying the three columns into the edit view.
  [`components/commitment-list.tsx:25`](../../components/commitment-list.tsx#L25),
  [`:189`](../../components/commitment-list.tsx#L189)

**Tests**

- The SQL suite proving attach/resolve/file, including the null-result review-fix assertion.
  [`supabase/tests/4-1-account-elsewhere.sql`](../../supabase/tests/4-1-account-elsewhere.sql#L1)

- `withKind()` unit coverage.
  [`lib/commitment.test.ts`](../../lib/commitment.test.ts#L1)

- The component-level dead-end regression test for the Kind-switch review fix.
  [`components/commitment-form.test.tsx`](../../components/commitment-form.test.tsx#L115)

- Linked-row round trip through the list/edit view.
  [`components/commitment-list.test.tsx`](../../components/commitment-list.test.tsx#L204)
