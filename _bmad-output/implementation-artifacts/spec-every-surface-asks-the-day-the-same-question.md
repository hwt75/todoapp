---
title: 'Every surface asks the day the same question'
type: 'bugfix'
created: '2026-09-07'
status: 'done'
baseline_commit: 'a699eb8bec8123b1a60f945153fceeafcca02752'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A regression introduced by `20260907100000` (Epic 6 retrospective item 38) and live on
the project since 2026-09-07. `declaration_derive_day()` was moved onto `due_time_as_of()` so a
queued claim keeps the meaning it had; on the day a due time is switched on, that door reports the
day untimed and the derivation now *refuses* a same-day claim, telling the author to answer in the
next morning's question. Three surfaces that decide **whether to ask** were left reading the live
`commitment.due_time`, so none of them asks: the morning gate skips the commitment
(`isAskedNextMorning`), the gate-reminder pass skips it (`enqueue_gate_reminders`), and Today still
renders a Claim the server can only refuse (`timed_claim_today` plus its client filter). The author
has no route to answer that day at all, and settlement counts it as silence: verdict `expired`, a
penalty minted, the chain broken. The invariant that made the live read correct is written down in
two places — `20260829090000:862-864` and the `timed_claim_today` comment — and item 38 falsified it
without either being opened.

**Approach:** Move every surface that asks "was this commitment timed on day D?" onto the same door
the judge uses. The rule becomes one sentence with one implementation: a day no time governed is the
morning question's to ask about, and a day a time governed is claimed on its own day — decided by
`due_time_as_of()` everywhere, by the live column nowhere.

## Boundaries & Constraints

**Always:** Keep `commitmentsOwing()` and `isAskedNextMorning()` pure and unchanged in shape — they
receive the governing value instead of the live one; keep the client's day arithmetic where it is
(AD-6: the server owns `for_day`, the client only decides what to ask); keep every existing filter
(archived, cadence, already-answered) exactly as it is; correct the two comments that state the
falsified invariant.

**Ask First:** Change what `due_time_as_of()` means; change the morning-hour rule or which day the
gate asks about; change `declaration_derive_day()`'s refusal, which is correct and is not what this
fixes; re-settle or correct any day already settled.

**Never:** Reintroduce a live-column read on an asking surface; let the gate ask about a day a time
did govern; change settlement, penalties, reminders for timed windows, evidence, or the referee
paths.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| A time switched on today | Untimed commitment, due time set at 09:00 today | Today is judged untimed, so the morning question **asks** about it tomorrow and the gate-reminder counts it | N/A |
| The same day, on Today | Same commitment, same day | No Claim control — the server would refuse it, and offering it is the lie | N/A |
| A time switched off today | Timed commitment, time cleared at 09:00 today | Same: today is untimed, asked about tomorrow | N/A |
| An ordinary timed day | Time unchanged, governed all day | Unchanged — not asked in the morning, claimable on its own day | N/A |
| An ordinary untimed commitment | Never timed | Unchanged — asked next morning | N/A |
| A commitment created with a time today | Creation entry, which `due_time_as_of()` excepts | Unchanged — governed today, claimable today, not asked | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:875` — `enqueue_gate_reminders()`
  counts outstanding answers on live `c.due_time is null`; `:855-866` is the comment stating the
  invariant item 38 falsified.
- `supabase/migrations/20260830090000_today_shows_where_the_window_stands.sql:54` —
  `timed_claim_today` selects on live `c.due_time is not null`; its comment repeats the same
  invariant.
- `supabase/migrations/20260907100000_a_queued_claim_keeps_the_meaning_it_had.sql:276-296` — the
  refusal this fix serves rather than undoes.
- `lib/declaration.ts:100-105` `isAskedNextMorning`, `:131-150` `commitmentsOwing` — pure, and the
  place the governing value has to arrive.
- `lib/use-gate.ts:38-45` — selects `due_time` live; this is the read that must change.
- `components/today.tsx:136` — `rows.filter((row) => row.due_time)` builds the timed block from the
  live column.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<generated>_every_surface_asks_the_day_the_same_question.sql` — redefine
      `enqueue_gate_reminders()` onto `due_time_as_of(c.id, asked_day)`; redefine `timed_claim_today`
      onto `due_time_as_of(c.id, today)`; add a view exposing the governing time for the day the
      morning question is about; correct both falsified comments.
- [x] `supabase/tests/every-surface-asks-the-day-the-same-question.sql` — the regression: a
      commitment whose time was switched on part-way through a day is asked about by the
      gate-reminder pass, and one switched on today is absent from `timed_claim_today`. Its own
      file rather than a step appended to `6-4-midnight-decides-the-day.sql`, which is already
      1,024 lines in one scope holding 47 shared variables.
- [x] `lib/use-gate.ts` — read the governing time and pass it where the live one went.
- [x] `components/use-gate.test.tsx` — the gate asks about a day no time governed and still does
      not ask about a day one did. A new file: `useGate` had no test at all, which is why the live
      read survived item 38. Under `components/` because rendering needs the jsdom project.
- [x] `components/today.test.tsx` — correct the mock, which modelled `timed_claim_today` as empty
      until something was claimed. The real view carries a row per commitment governed today.
- [x] `components/today.tsx` — build the timed block from what the server says governed today.

**Acceptance Criteria:**
- Given a commitment whose due time was switched on today, when tomorrow's morning question is
  drawn, then it asks about today and the answer lands on today.
- Given the same commitment on the day of the edit, when Today renders, then it offers no Claim.
- Given a commitment governed by a time all day, when the morning question is drawn, then it is not
  asked about — unchanged.

## Spec Change Log

## Design Notes

This is the second repair in one day caused by the same shape, and the shape is the finding: one
column, several readers, and a rule that lives in each of them separately. `due_time_as_of()` has
been the one door since Story 6.4, but only settlement went through it; item 38 moved the
derivation through it and left the asking surfaces behind, which is how a fix for one silent
misplacement produced another. The repair is not "add another check" but "move the last readers
onto the door", after which the live column has no decision-making reader left.

The refusal item 38 added is correct and stays. What was wrong is that it pointed the author at a
question nobody was asking.

## Verification

**Commands:**
- SQL test-first — the new regression fails before the migration and passes after.
- `npx supabase db reset`, then all `supabase/tests/*.sql` — expected: zero failures.
- `npm test`, `npm run lint`, `npm run format:check`, `npm run build` — expected: clean.
- Both race harnesses — expected: unaffected.
- `npm run migrations:check` — local-only until a separately authorized push.

**Results (2026-09-07):**

- Test-first, server — `supabase/tests/every-surface-asks-the-day-the-same-question.sql` fails
  before the migration at Step 2 with the defect stated plainly: *"No morning question was raised
  for a day no time governed. The claim path refuses that day and points at this question; with
  both closed the author cannot answer at all, and settlement charges him for the silence."*
  Step 1 passes first, so the failure cannot be misread as the door having changed. All four steps
  pass after the migration, with no edit to the test.
- Test-first, client — with the merge removed from `useGate`, exactly one of the four new cases
  fails (*"asks about a day no time governed, even though the commitment carries one now"*) and the
  other three pass. Restoring it turns all four green.
- `useGate` had **no test at all** before this, which is why the live-column read survived item 38.
  `components/use-gate.test.tsx` now pins the one decision it owns.
- `npx supabase db reset` — passed; all 69 migrations apply from scratch.
- All 40 `supabase/tests/*.sql` — passed, 0 failures.
- Both race harnesses — passed.
- `npm test` — passed, 51 files and 1339 tests (four new, and the today-screen fixtures corrected:
  the mock modelled `timed_claim_today` as empty until something was claimed, which is not this
  server and is what hid the coupling).
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero: `20260907140000` is local-only until a
  separately authorized push.

**Exposure while the regression was live:** none reached. Checked on the live project before and
after: no commitment has ever carried a `commitment_due_time_change` entry beyond its own creation,
so no day was ever judged by the broken combination. The window was from the item 38 push until
this fix, and the first due-time edit in it would have been the first loss.
