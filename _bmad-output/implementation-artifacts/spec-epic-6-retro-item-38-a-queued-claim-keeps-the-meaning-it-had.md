---
title: 'A queued claim keeps the meaning it had when it was tapped'
type: 'bugfix'
created: '2026-09-07'
status: 'in-progress'
baseline_commit: 'eb29a57ea650fa4051cca6cf548741090adce6ff'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `declaration_derive_day()` reads the live `commitment.due_time` to decide whether a
tap answers its own day or the day before. A claim tapped offline carries only its instant, so if
another device clears or moves that time before the queue flushes, a same-day timed claim silently
lands on the previous day — answering a day the author never spoke about, spending that day's one
allowed declaration, and leaving the day he did claim to fail at close.

**Approach:** Derive the day from `due_time_as_of(commitment, the tap's own local day)` — the same
historical door Story 6.4's judge already uses — instead of the live column, so a later edit cannot
re-point a queued tap. Carry the mode the client remembered to the server as an assertion, and
refuse the write in plain words when it no longer matches what governed that day, rather than
recording it against a day nobody meant.

## Boundaries & Constraints

**Always:** Derive a doer-filed row from `due_time_as_of()` for the tap's local day; keep the
existing late-window refusal, its wording and its half-open boundary, reading the same governing
time; treat an absent assertion as "not asserted" and derive without refusing, so a claim queued by
an older client still lands; refuse with a message that names what changed and what to do next.

**Always (window):** Judge a tap against the `late_window_minutes` in force **at the instant of the
tap**, read from the same log — not the value in force at day start, and not the live column. For an
online tap those are the same value, so nothing about today's behavior changes; for a queued one it
is the window the author actually saw.

**Ask First:** Change AD-6 (the server owns `for_day`, no client ever sends a date); change the
late-window rule itself (which taps are inside a window), the morning-answer rule, or
`due_time_as_of()`'s "governed the whole day" semantics; add a column the client may write that is
not verified by the server.

**Never:** Trust the client's remembered mode as a value — it is only ever checked against the log;
let a machine-filed (`auto_check`) row take the new path; change which days `due_time_as_of()` calls
timed, so no settled day is re-judged; change settlement, reminders, Today's window view, evidence,
or Penalty behavior; edit an applied migration.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Time cleared after the tap's day | Timed claim tapped on D, due time removed on D+1, flushed on D+2 | Still lands on D as a timed claim; the window is judged by the time that governed D | N/A |
| Time cleared during the tap's day | Timed claim tapped on D, time cleared later on D, then flushed | Refused: no time governed the whole of D, so D is judged untimed and the tap cannot mean what it said | Clear refusal, nothing recorded |
| Morning answer on a day that had a window | Untimed assertion, but a due time governed the whole of D | Refused for the same reason, from the other side | Clear refusal, nothing recorded |
| Assertion absent | Row queued by an older client, no remembered mode | Derived from the governing time alone, exactly as today; never refused for the mismatch | N/A |
| Machine-filed row | `file_auto_check_result()` inserts for a timed commitment | Unchanged previous-day derivation, no assertion, no refusal | N/A |
| Window widened after the tap | Tap at 20:14 inside a 30-minute window, window later changed to 60 | Judged by the 30 minutes in force at the tap, not by the live 60 | N/A |
| Window widened before the tap | Window changed 30 → 60 at 20:10, tap at 20:45 online | Accepted — the window in force at the tap is the one the app showed | N/A |
| Window never recorded | Pre-migration history: a governing time with no logged window | Refused, saying the window that governed that day was never recorded | Clear refusal, nothing recorded |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260828140000_a_claim_lands_on_the_day_it_was_made.sql:31-119` — active
  trigger; line 50's live `commitment.due_time` read is the defect. Preserve the machine-filed
  branch, `filed_by` forcing, the seconds-from-midnight window arithmetic and its refusal wording.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:216-273` — `due_time_as_of()`,
  the one door to `commitment_due_time_change`; already `security definer` and granted to
  `authenticated`, so an invoker-rights trigger may call it. Its mid-day-change-returns-null rule
  is what makes the second row of the matrix a refusal rather than a silent previous-day landing.
- `supabase/migrations/20260824120000_a_slip_the_machine_filed_is_not_a_slip_he_typed.sql:14-59` —
  the precedent for a client-sent column the trigger overrides rather than trusts.
- `lib/declaration-write.ts:24-36,69-78` — `QueuedClaim.timed` exists and never reaches the server;
  this is the one line that must send it. Both call sites already pass it
  (`components/morning-gate.tsx:86`, `components/today.tsx:422`).
- `lib/declaration-submit.ts:28-45` — a SQLSTATE refusal is already permanent and never retried, so
  the new refusal leaves the queue rather than looping.
- `components/today.tsx:425-435` and `components/morning-gate.tsx:91-96` — both surface a refusal's
  reason verbatim, so the server's own words are the whole of the UI change.
- `supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql` — where the derivation is proven.
- `lib/declaration-write.test.ts` — where the insert's shape is proven without a browser.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql` — add the failing regressions:
      a claim tapped on D and flushed after the time was cleared on D+1 still lands on D; a claim
      whose day lost its governing time mid-day is refused; an untimed assertion on a day that had
      a window is refused; an absent assertion derives as before; a machine-filed row is untouched.
- [x] `supabase/migrations/<generated>_a_queued_claim_keeps_the_meaning_it_had.sql` — log
      `late_window_minutes` alongside `due_time` (column, comment, backfill, trigger on either
      column); keep `due_time_as_of()`'s mid-day rule counting only rows where the *time* actually
      moved, so no settled day changes; add `late_window_at(commitment, instant)`; add the nullable
      assertion column on `declaration`; redefine `declaration_derive_day()` to read both historical
      values and to refuse a mismatch, preserving every existing branch and message.
- [x] `lib/declaration-write.ts` — send the remembered mode with the insert; update the header note
      that currently says it never reaches the server.
- [x] `lib/declaration-write.test.ts` — the insert carries the assertion for both call sites, and a
      legacy item with no remembered mode sends null rather than false.
- [x] `_bmad-output/implementation-artifacts/sprint-status.yaml` — item 38 tracks implementation and
      remote parity separately, as items 36 and 37 did.

**Acceptance Criteria:**
- Given a timed claim tapped on day D and flushed after the due time was changed on a later day,
  when the insert runs, then it lands on D and is judged by the time that governed D.
- Given the due time was changed during day D itself, when a claim tapped on D is flushed, then the
  write is refused in words naming that D is judged untimed, and no row is recorded.
- Given a queued item carrying no remembered mode, when it is flushed, then it derives exactly as it
  does today and is never refused for a mismatch.

## Spec Change Log

- 2026-09-07 — direction chosen by the maintainer between preserving the tap's intent unconditionally,
  refusing on any due-time change, and this historical-door-plus-explicit-refusal reading. The third
  was taken because it makes the declaration agree with the judge that already reads
  `due_time_as_of()`, and needs no trusted client value.
- 2026-09-07 — scope widened by the maintainer, on an Ask First raised during the code map: reading
  the *time* historically exposes that `late_window_minutes` is not logged at all and the schema
  forces it null whenever `due_time` is null, so a claim on a day whose time was later cleared would
  meet a null window and be accepted at any hour. The window now shares the log. The rejected
  alternatives were refusing such a claim outright, which costs the author a day he legitimately
  claimed, and deferring the window to its own next-work item, which leaves that hole open in the
  meantime.

## Design Notes

The assertion is checked, never used. A client that lies about its mode can only produce a refusal
or agree with the log, so the column adds no way to place a claim on a day the log does not support
— the same reasoning `filed_by` settled for the machine's word.

Refusing a same-day claim on a day whose time moved mid-day is a real behavior change beyond the
offline case, and it is the point: settlement already judges that day untimed, so the author is
asked about it in the next morning's question instead. Recording a same-day claim there would be
the only writer disagreeing with the judge.

## Verification

**Commands:**
- SQL test-first run of `supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql` — expected:
  fails before the migration, passes after it, with no edit to the test in between.
- `npx supabase db reset` — expected: every migration applies from scratch locally.
- All `supabase/tests/*.sql` through local container `psql -v ON_ERROR_STOP=1` — expected: zero
  failures, including 6-4, 6-5 and 6-6, which read the same governing time.
- `npm test`, `npm run lint`, `npm run format:check`, `npm run build` — expected: clean.
- `npm run migrations:check` — expected: local-only until a separately authorized push.

**Results (2026-09-07):**

- Test-first, schema — the extended `supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql`
  fails before the migration on the first reference to `declaration.claimed_timed`, which does not
  exist yet.
- Test-first, behavior — with the migration applied and only `declaration_derive_day()` reverted to
  its `20260828140000_a_claim_lands_on_the_day_it_was_made.sql:31-109` definition, the file fails at
  Step 7 with exactly the reported defect: *"A claim tapped on 2026-06-21 and flushed after the time
  was cleared today was filed for 2026-06-20."* One day earlier than it was tapped, silently.
  Restoring the new function turns all eleven steps green without touching the test.
- `npx supabase db reset` — passed; every migration, including `20260907100000`, applies from
  scratch.
- All 38 `supabase/tests/*.sql` files — passed, 0 failures. Story 6.4's `due_time_as_of()`
  regressions, 6.5's window view and 6.6's reminder windows all stayed green, which is what proves
  the widened log did not change which days are judged timed.
- `node scripts/test-current-penalty-race.mjs` — passed both winner orders.
- `npm test` — passed, 50 files and 1321 tests (6 new).
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero result: `20260907100000` is local-only until a
  separately authorized push.

**Found and deliberately not fixed here:** `due_time_as_of()`'s `coalesce` fallback answers with the
commitment's *creation* time for any day after its time was cleared, so a genuinely untimed day can
read as timed. Recorded in `deferred-work.md` rather than fixed, because repairing it changes which
days settlement calls timed and this spec's boundary is that no settled day may be re-judged.
