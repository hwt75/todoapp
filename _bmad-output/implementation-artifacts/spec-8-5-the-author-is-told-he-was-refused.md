---
title: 'Story 8.5 — The author is told he was refused'
type: 'feature'
created: '2026-09-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: 'e2f65a66824b5478b16c6c4395c9c6b731d04d9b'
story_key: '8-5-the-author-is-told-he-was-refused'
context:
  - '{project-root}/_bmad-output/specs/spec-commitments-the-referee-signs-off/SPEC.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-8-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-8-4-what-is-waiting-for-him-today.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Since Story 8.2 a refusal fails the author's day, and Story 8.4 gave the referee the
button — but `sign_off_day()` enqueues nothing, so the author learns his day was refused only by
finding it failed. CAP-7: one message naming the commitment, the day and the reason verbatim.

**Approach:** The refusal's own transaction enqueues exactly one push through the outbox (AD-3),
the way `object_to_day()` does. **Decided by hwt75 on 2026-09-29:** the referee's words ride in a
separate `quote` field that the service worker shows under the app's own sentence, so
`push_body_is_sendable` judges only what the app says; a reason too large for a push is left out
whole — never cut — and the push says where to read it. The Ledger shows every refusal's reason
verbatim on its day.

## Boundaries & Constraints

**Always:** One push per refusal, keyed by the decision's id; none for an approval, none for
silence. The reason travels byte-for-byte as `referee_decision.reason` stores it (8.2
already trims the ends before writing) — never cut, paraphrased or wrapped in the app's words
beyond quotation marks. Nothing the referee wrote, and
nothing the author named, may be able to make the body fail `push_body_is_sendable`: a refusal
that aborts because of someone's wording is the failure this story exists to avoid. So the body is
built only from the app's words and the date, and the commitment name goes in the title. The push
is part of the refusal's transaction: if the enqueue fails, the refusal does not land.

**Ask First:** Any change to `push_body_is_sendable`, the outbox check, or `outbox_enqueue`. Any
change to what `sign_off_day()` decides or refuses. A notification to the referee.

**Never:** No change to `object_to_day()` or `objection_body()`. No Today change (8.6). No email
channel for the author. No truncation of the reason anywhere.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected |
|---|---|---|
| Refusal | Referee refuses with a reason | One `push` row for the author: title names the commitment; body names the weekday and date and that the day closes failed; `quote` is the reason verbatim |
| Approval | Referee marks done | No outbox row |
| Silence | No decision | No outbox row |
| Hostile wording | Reason or commitment name contains "right now", "currently" | Refusal lands; push enqueued; body passes the check |
| Too long | Reason whose payload would pass the push size budget | Refusal lands; push has no `quote`; body says the reason is in the Ledger from midnight |
| Double tap / race | Second refusal on the same commitment-day | Refused as today; still exactly one push |
| Push renders | Payload with `quote` | Notification body = app sentence, blank line, the reason in quotation marks |
| Push renders | Payload without `quote`, or `quote` not a usable string | Body alone, exactly as every push before this story |
| Ledger | Day with one or more refusals | Each shown on that day with its commitment name and the reason verbatim |
| Ledger | Day with no refusal, or only an approval | Unchanged |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql:306-535` — the live
  `sign_off_day()`. Re-create it **verbatim** plus the enqueue; `:525-530` is where 8.2 says the
  `returning` arrives with this story. `8-3-...sql` step 7 reads its text: keep
  `photograph_reaches_the_referee` in it and no copy of the parentage join.
- `supabase/migrations/20260914090000_...refusal_costs.sql:975-1004` — `object_to_day()`'s enqueue:
  dedupe key shape, `title`/`body`/`sent_at` payload, `sent_at` format. Copy the shape.
- `supabase/migrations/20260903140000_the_referee_may_object.sql:262-300` — `objection_body()`:
  weekday self-dating, and why the reason was kept out of the body. Model for `refusal_body()`.
- `supabase/migrations/20260820101000_outbox_body_rule_where_it_runs.sql:18-48` —
  `push_body_is_sendable` and the check on `payload ->> 'body'` only. Read-only.
- `supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql:60-90` —
  `outbox_enqueue(owner, key, payload, channel, not_before)`; revoked from clients.
- `supabase/functions/outbox-worker/index.ts:25,83-85` — sends `JSON.stringify(row.payload)`
  whole. Web push caps the encrypted record at 4096 bytes (≈3993 of plaintext), so the budget is
  measured in bytes of the payload's JSON text, not characters.
- `lib/push-payload.ts:11-60` + `app/sw.ts:40-50` — `resolvePushContent` and `showPush`; the
  quote is composed in the pure function, never in the worker.
- `lib/ledger.ts:76-96,145-205` — `ObjectionRecord`, `OBJECTION_COPY`, the `buildLedger` fold;
  `components/ledger.tsx:95-170,255-320` — the parallel read and the objection render + aria.
- `referee_decision: read own` (`20260914090000:166-168`) already lets the author read his rows.

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql` — `refusal_body(date,
      boolean)` (immutable, revoked from clients); `refusal_payload(text, date, text)` building
      `{title, body, quote?, sent_at}` and dropping `quote` when the payload's UTF-8 JSON text
      would exceed 3500 bytes; `create or replace sign_off_day()` verbatim except `returning id`
      and, for a refusal only, one `outbox_enqueue` keyed `'refusal-' || id`.
- [x] `lib/push-payload.ts` + `lib/push-payload.test.ts` — optional `quote`; body gains
      `\n\n“quote”` when usable; every existing case unchanged.
- [x] `lib/ledger.ts`, `components/ledger.tsx` + tests — `RefusalRecord`, `REFUSAL_COPY`, a
      `refusals` parameter appended last with a default, rendered per day in aria and visibly.
- [x] `supabase/tests/8-5-the-author-is-told-he-was-refused.sql` — every DB row of the matrix,
      the byte budget at its edge, `push_body_is_sendable` true for the body in every case, and
      the catalog check that `sign_off_day()` still passes 8.3's step 7.
- [x] `supabase/tests/2-1-roles-and-rls.sql`, `supabase/tests/README.md`, `sprint-status.yaml`.

**Acceptance Criteria:**

- Given every pre-existing file in `supabase/tests/`, when run after this migration, then each
  passes unmodified except `2-1-roles-and-rls.sql` — `8-2-...sql` passing is what proves
  `sign_off_day()` decides nothing differently.
- Given a refusal whose reason is exactly the byte budget and one a byte over, when enqueued, then
  the first carries `quote` and the second does not, and both refusals land.

## Design Notes

**Why the name goes in the title.** `push_body_is_sendable` refuses "currently" anywhere in the
body. A commitment named "Stop scrolling right now" would abort every refusal of it. The title is
unchecked and is where a lock screen shows the subject anyway: `Thuốc — your referee refused it`.

**The budget is 3500, not 3993,** because `jsonb::text` is not what the worker sends: it adds
spaces after separators, so it over-counts, which is the safe direction, and the headroom covers
`sent_at` and the title growing. The fallback sentence says "after midnight": a Ledger row
exists only once `settle_day()` has closed the day, shortly after midnight (see Review).

## Verification

**Commands:**

- `npx supabase db reset`, then every file in `supabase/tests/` — all pass.
- `npm test`, `npx tsc --noEmit`, `npm run lint`, `npm run format:check`, `npm run build` — clean.
- `node scripts/test-sign-off-race.mjs` — PASS (a race loser still enqueues nothing).

**Run 2026-09-29, implementation.**

- `npx supabase db reset`, then all 50 files under `supabase/tests/` — **all pass.**
  `node scripts/test-sign-off-race.mjs` and `node scripts/test-current-penalty-race.mjs` — both
  PASS. The race script asserts one decision row and a raising loser; it does not read the outbox.
  That the loser enqueues nothing holds by construction — it raises at `if not found` before the
  enqueue is reached — and `8-5-...sql` step 3 asserts the single-session repeat.
- `npm test` — 1528 passed, 53 files. `tsc`, `lint`, `format:check`, `build` — clean.
- `npm run migrations:check` — not run: this machine is not `supabase link`ed.

**Mutants watched.** Budget moved to 3499 — caught by `8-5` step 5's fixture (the edge payload is
no longer 3500). The commitment name put back into the body — the hostile refusal aborts on
`outbox_body_is_sendable`, which is the exact failure the title placement exists to prevent. The
refusal line dropped from the Ledger row's `aria-label` — caught by `ledger.test.tsx`.

**One acceptance criterion was wrong, and the file it named was edited.** The AC said every
pre-existing SQL file passes unmodified except `2-1-roles-and-rls.sql`. But
`8-2-the-referee-s-decision-and-what-a-refusal-costs.sql` step 2 asserted that eleven decisions
enqueue **zero** outbox rows — "sign_off_day() tells the author nothing — that is Story 8.5" —
which is precisely what this story changes. It now asserts **ten**: one per refusal, none for the
approval, still counted across the whole queue so a stray second enqueue turns it red. Every other
assertion in that file passes unmodified, which is still what proves `sign_off_day()` decides
nothing differently.

**Deviation, small:** the Ledger reads `referee_decision` with `.eq('approved', false)` server-side;
the component mock does not filter, so the "only an approval → unchanged" matrix row is covered by
the query shape and by `buildLedger` receiving only refusals, not by a rendered approval.

## Review — 2026-09-29

Three layers (blind, edge-case, verification-gap). Two ran before a usage-limit interruption and
the third was re-run after it. **No `intent_gap` and no `bad_spec`** — the one spec error, the AC
about `8-2-...sql`, was already recorded above. Patched:

- **The quote-less payload was unbounded.** `commitment.name` has no length limit, so a long name
  could push even the fallback past what a push service accepts and the author would never be
  told. The title now clips the name at 80 characters (the app's own line — hwt75's never-cut rule
  is about the referee's words, which are untouched); a 200-character name is in the SQL test.
- **The catalog lied.** `create or replace` kept 8.2's comment, which ended "Enqueues nothing —
  telling the author is Story 8.5". Re-issued. The migration header's "8-2 passes unmodified" was
  corrected to what happened.
- **Copy.** "Refused that day" became "refused it for <day>" — a refusal names one commitment, and
  the other commitments that day are untouched. "From midnight" became "after midnight": the
  Ledger row exists only once `settle_day()` has run.
- **Ledger.** Refusals are keyed by decision id (two same-named, same-worded refusals collided);
  approvals are filtered client-side as well as in the query, so a dropped `.eq()` cannot render a
  refusal of "null"; a blank name falls back to `A commitment` as the push does. Tests cover each.
- **Push.** A quote is attached only under a body the app actually sent, never under the fallback.
- **SQL test.** The repeat refusal must raise the already-decided sentence, not any error; both
  sides of the byte edge are asserted (3500 and 3501); the title is compared exactly rather than
  with `LIKE`; step 6 asserts `sign_off_day()` is the only writer of a `refusal-` key, which is what
  "none for a silence" rests on; three comments that said the wrong number were corrected.

Rejected, with the reason checked: `immutable` on `to_char(date)` — `objection_body()` is declared
the same way; lock screens truncating long bodies — a display limit, not a cut, and the reason is
whole in the notification and the Ledger; a long `aria-label` and an unbounded read — the shape the
objection already has; reusing `row-objection` for styling — deliberate.

After the patches: all 50 SQL files, 1531 unit tests, `tsc`, `lint`, `format:check`, `build` —
clean.

## Suggested Review Order

**Nobody's wording can abort a refusal**

- The body is built from a date and a boolean — nothing anyone typed.
  [`20260929100000:47`](../../supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql#L47)

- Name in the title, reason in `quote`, budget in bytes; too large means left out whole.
  [`20260929100000:95`](../../supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql#L95)

- The byte check itself.
  [`20260929100000:120`](../../supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql#L120)

- The title clip that bounds the fallback.
  [`20260929100000:108`](../../supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql#L108)

**sign_off_day(), verbatim plus two lines**

- The `returning` 8.2 promised this story.
  [`20260929100000:372`](../../supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql#L372)

- One enqueue, refusals only, keyed by the decision.
  [`20260929100000:388`](../../supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql#L388)

- The catalog comment, which would otherwise still say it enqueues nothing.
  [`20260929100000:398`](../../supabase/migrations/20260929100000_the_author_is_told_he_was_refused.sql#L398)

**Where the author reads it**

- The quote under the app's sentence, never inside it.
  [`push-payload.ts:65`](../../lib/push-payload.ts#L65)

- The Ledger read, approvals excluded twice.
  [`ledger.tsx:123`](../../components/ledger.tsx#L123)

- The fold: several per day, by name then id.
  [`ledger.ts:252`](../../lib/ledger.ts#L252)

**The proofs**

- The byte edge, both sides.
  [`8-5-…sql:258`](../../supabase/tests/8-5-the-author-is-told-he-was-refused.sql#L258)

- The only writer of a refusal key.
  [`8-5-…sql:287`](../../supabase/tests/8-5-the-author-is-told-he-was-refused.sql#L287)

- The one assertion 8-2 had to change, and why.
  [`8-2-…sql:671`](../../supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql#L671)

## On the live project — 2026-09-29

`npx supabase db push` applied `20260929090000` and `20260929100000` to `hxzalpnlrunctbajgtkv`
after a dry run named exactly those two; `npm run migrations:check` then reported **all 82
matching**. PRs #19 and #20 merged green, in that order.

**Security advisor, run against the live schema** — the debt Stories 8.1 and 8.3 recorded. No
ERROR-level finding and nothing executable by `anon`. Sixteen WARNs of
`authenticated_security_definer_function_executable`, every one a door granted on purpose and
documented where it is granted — `referee_waiting_today()` among them, `sign_off_day()`,
`photograph_reaches_the_referee()` and the rest of Epic 8's. `commitment_day_photographs()`,
`refusal_body()` and `refusal_payload()` are executable by neither client role, read from the live
catalog. The one other WARN, leaked-password protection, is Auth configuration and predates the
epic.
