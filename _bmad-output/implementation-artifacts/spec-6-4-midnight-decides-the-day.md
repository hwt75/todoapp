---
title: 'Story 6.4 — Midnight decides the day'
type: 'feature'
created: '2026-08-29'
status: 'done'
review_loop_iteration: 1
baseline_commit: '2481b86288524c961cd9bf9fc81086a940ad92c3'
story_key: '6-4-midnight-decides-the-day'
context:
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/lifecycle.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-3-evidence-detaches-from-an-appeal.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **Spec checkpoint.** This is the only story in Epic 6 that moves money, and it decides the
> question Story 6.2 deliberately left open. It stops here for hwt75 before any code is written.
> It carries a **done checkpoint** as well.

## Intent

**Problem:** Stories 6.1 through 6.3 let a commitment carry an hour, let the author claim it on
its own day, and let a photo hang off that claim. Nothing reads any of it. `settle_day()` still
holds every day open until one account-wide deadline of `D+3`, so a timed commitment claimed with
no photo — or never claimed at all — sits unjudged for three days and then settles by the same
rule as a gym commitment. `enqueue_gate_reminders()` still asks about it the next morning, a
question that died at midnight. And a claim with no photo currently reads as `held`, which is the
exact thing this epic exists to stop: a word standing in for proof.

**Approach:** Two changes to the same seam. `commitments_owing()` — the one read every settlement
path shares — learns that a timed commitment's `held` is earned by evidence, not by the tap; and
the deadline it is judged against becomes each commitment's own rather than the account's. Every
consumer (settlement, penalties, expiry correction, the day summary, chains, an appeal ruling, a
Grace Day) then reads the same truth without being touched.

## Boundaries & Constraints

**Always:**
- An untimed commitment behaves exactly as it does today: `D+3` at the morning hour, the morning
  question, the same verdicts. No existing row changes meaning.
- A timed commitment's deadline is the end of its own local day in `Asia/Ho_Chi_Minh`. A day mixing
  both kinds closes each on its own clock.
- Settlement stays the single writer of derived state (AD-8). Nothing here writes a verdict outside
  the existing settlement functions.
- `answer is null` keeps meaning **he said nothing**. Nothing may synthesise an answer for a
  commitment that carries no declaration — Silence detection (5.2) and the monthly answer-rate
  measures (5.4) both count on it.
- A day that has already settled is not re-judged. This story changes when a day closes, never
  whether a closed one reopens.
- **A rule may only judge a day it governed.** A commitment is judged by the time it carried
  *through that day*, never by the time it carries now, and never for a day it did not exist on.
  Editing a commitment today may not move money for a day that has already been answered.

**Ask First:**
- Any change to `penalty_amount_dong()`, the Grace Day cap, or what a Grace Day forgives. A failed
  day's only remedy stays two per calendar month.
- Making a timed commitment's miss cost differently from an untimed one. One miss, one penalty.

**Never:**
- Do not exclude timed commitments from `commitments_owing()`. That function decides what is
  **true**; excluding them there would mean nothing ever judges them. The morning question's
  exclusion belongs in `enqueue_gate_reminders()`, which decides what is **asked**.
- Do not give the referee anything. He cannot see a claim's photo and cannot object to a day until
  Story 6.7.
- Do not build the Today surface's window states. That is Story 6.5.
- Do not touch the reminder schedule. That is Story 6.6.

## The decisions worth your attention

**1. A claim with no photo is a miss, not a silence.**
The declaration exists — he answered — but the answer is not the thing that holds a timed day. So
`commitments_owing()` reports `slipped` for it once the day has ended, and the day settles `failed`
with outcome `missed`, a penalty if the commitment carries one, and a broken chain. Reporting it as
`unanswered` instead would suppress the day summary (2.8 skips expired days), file it against a
history of silences he did not commit, and inflate the "went quiet" measures. He spoke; the proof
never came.

**2. No claim at all stays a silence, judged at midnight.**
A timed commitment with no declaration keeps `answer is null` and settles exactly as an unanswered
commitment does today — verdict `expired`, outcome `unanswered`, and a penalty via `silent`. Only
the clock changes: midnight of its own day rather than `D+3`. Synthesising a miss here would be
cheaper to write and would quietly break two shipped features, because both read
`count(*) / count(answer)` over this same function to decide whether a day was quiet.

**3. A timed commitment may not carry an Auto-check.**
This closes Story 6.2's open question. A sensor and a photo are two answers to one question, and
this epic named the photo. Left legal, a machine `held` filed the next morning would hold a day no
photo ever proved — the exact hole the epic exists to close — and a machine `slipped` would file a
verdict for a day whose question had already been decided at midnight. Refused by a check
constraint, mirrored in `lib/commitment.ts`, in the shape
`commitment_auto_check_not_on_abstain` already uses.

**4. The weekly quota counts proven days only.**
`weekly_held_count()` reads `declaration.answer = 'held'` straight off the table, so without this a
timed Weekly Quota commitment could meet its target on unproven claims and `settle_week()` would
pay out on them. It is the one place outside `commitments_owing()` that tallies a held day, and it
learns the same rule.

**5. `due_time` freezes by day, the way `carries_penalty` already does.**
Read live, it re-judges the past: a day answered `held` under the untimed rule reads `slipped` the
moment a time is added, and settles `failed` with a penalty and a broken chain. This is the exact
defect the Epic 4 retrospective fixed for the column two lines above it, so it gets the same
machinery — an append-only change log, a trigger, and a `due_time_as_of()` that is the one door.
Its rule is stricter than `carries_penalty_as_of()`'s and deliberately so: a window governs a day
only if it was set for **the whole** of that day. A time switched on at 15:00 cannot govern a
window that closed at 10:30, and a time switched off mid-day must not fail a day the app has
stopped offering a claim for. Both directions of a mid-day edit therefore fall back to the morning
question, which is the only reading that never charges for a rule that was not in force.

`late_window_minutes` is not logged. It is read at one instant only — the tap — and by whoever is
tapping, so the live value is the correct one.

**6. A timed Weekly Quota commitment owes nothing on a day it was not claimed.**
A Weekly Quota is judged at week close; not doing it on a Tuesday is the shape of the commitment,
not a silence. Left in the owing set it would make every unclaimed day settle `expired` — no day
summary, a broken chain, and Story 5.2's intervention firing at an author who is on target. So an
unclaimed timed Weekly Quota day is excluded from `commitments_owing()` the way `daily_hours_quota`
already is, and `weekly_held_count()` stays the only thing that judges it. A day it *was* claimed
on still appears, held or slipped, because there is something to say about it.

**7. Nothing is judged for a day it did not exist on.**
`commitments_owing()` has never had a `created_at` guard, so a commitment created today is owed an
answer for days that predate it. That was survivable while every deadline was `D+3`; with midnight
it means a commitment created this afternoon fails and is charged for five days it was not alive
for. Fixed with the same guard `resolve_auto_checks()` and `settle_week()` already carry, and it
corrects the untimed case too.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Untimed commitment, any answer | As today | Unchanged in every respect: `D+3` deadline, same verdict | — |
| A time added to a commitment with history | Days already answered under the untimed rule | Those days keep the verdict they had; no penalty, no broken chain | — |
| A time added or removed part-way through a day | Change lands between midnight and midnight | That day is judged untimed — the morning question, `D+3` | — |
| Timed Weekly Quota, day never claimed | No declaration | Not owed at all; the day says nothing about it, and the week still judges it | — |
| Commitment created today | Any earlier day | Not judged for it, timed or not | — |
| Timed, claimed, photo accepted | Evidence row on the claim | `held`; day settles held once every other commitment is decided | — |
| Timed, claimed, no photo, day over | Claim only, past midnight | `slipped` → verdict `failed`, outcome `missed`, penalty if it carries one | — |
| Timed, claimed, no photo, day still running | Claim only, before midnight | Not yet decided; the day stays open | — |
| Timed, never claimed, day over | No declaration | `unanswered` → verdict `expired`, penalty if it carries one | — |
| Mixed day, timed decided, untimed silent | One of each | Day stays open to `D+3` for the untimed one; the timed verdict is already fixed | — |
| Timed commitment, next morning | Day D has ended | The gate never asks about it | — |
| Timed Weekly Quota, unproven claim | Claim, no evidence | Does not count toward the week's held days | — |
| Expired day later corrected | Every untimed answer arrived in time | Correction reads the same effective answers; an unproven timed claim still counts as a miss | — |
| Auto-check on a timed commitment | Draft sets both | Refused by the database; the form refuses first | Constraint raises; `draftProblems` names it |
| Day already settled | Settlement row exists | Nothing re-judged, no second penalty | Existing `on conflict do nothing` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260827130000_carries_penalty_freezes_by_day.sql:144` — the live
  `commitments_owing(p_owner, p_day)`: returns `commitment_id, carries_penalty, answer, cadence`,
  left-joining `declaration` on `for_day`. The function to extend.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:58` — `declaration_deadline(day,
  morning_hour)` = `day + 3` at the morning hour. Kept exactly; the new per-commitment deadline
  falls back to it for an untimed commitment.
- `supabase/migrations/20260824100000_a_check_that_cannot_run_never_says_i_missed.sql:166` — the
  live `settle_day()`. `past_deadline := now() >= declaration_deadline(...)` and
  `continue when answered < total and not past_deadline` are the two lines that become
  per-commitment. Its AD-13 Auto-check guard, its `admitted`/`silent` counts and its
  `settlement_commitment` outcome mapping all read `o.answer` and need no change.
- `supabase/migrations/20260820140000_weekly_quota_is_not_judged_daily.sql` — the live
  `supersede_expiries()`. Computes one `deadline` per account and reads `d.answer` for `admitted`;
  both become per-row.
- `supabase/migrations/20260826130000_the_chain_speaks_again.sql` — the live
  `enqueue_gate_reminders()`. The `outstanding` query already filters
  `c.cadence <> 'daily_hours_quota'`; that `where` is where the timed exclusion goes. Its Silence
  detection above it reads `commitments_owing()` and is deliberately left alone.
- `supabase/migrations/20260820150000_the_week_closes_and_settles.sql:39` — `weekly_held_count()`,
  the one direct reader of `declaration.answer` outside `commitments_owing()`.
- `supabase/migrations/20260828150000_evidence_detaches_from_an_appeal.sql` — `evidence`, its
  `declaration_id`, and `evidence_derive_owner()`, which already refuses a claim's photo after the
  day it proves has ended. The existence of an evidence row **is** acceptance; nothing here
  re-checks capture dates.
- `supabase/migrations/20260828130000_a_commitment_can_carry_a_time.sql` — `due_time`,
  `late_window_minutes` and the constraint style (`commitment_time_needs_a_moment`) to copy for
  decision 3.
- `supabase/migrations/20260819221000_settlement_schedule.sql` — the hourly `:15` pass; and
  `settle_due_days()` in `20260825110000_a_countable_way_to_be_forgiven.sql:481`, which settles
  `today - 5 .. today - 1` and never today. Not changed: a day is already only settled after its
  own midnight.
- `lib/commitment.ts:140` `canBeTimed()`, `:200` `draftProblems()` — the mirror for decision 3.
  `autoCheckEnabled` is the draft field.
- `lib/expiry.ts` — a documentation-only copy of the `D+3` rule; its header must stop claiming that
  rule is the only one.
- `supabase/migrations/20260827130000_carries_penalty_freezes_by_day.sql:31` — the change-log
  table, its two triggers, its backfill and `carries_penalty_as_of()`. The pattern
  `commitment_due_time_change` / `due_time_as_of()` copies, and the one place to look before
  changing either.
- `supabase/tests/2-1-roles-and-rls.sql:443` — the list of functions `anon` and `authenticated`
  must not be able to execute. Every new internal function belongs in it.
- `supabase/tests/6-1-timed-commitment-constraints.sql`, `6-2-*.sql`, `6-3-*.sql`,
  `5-2-*.sql`, `5-4-*.sql`, `carries_penalty_freezes_by_day.sql` — the checks most likely to feel
  this change. All 33 files under `supabase/tests/` must still pass.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_midnight_decides_the_day.sql` — `commitment_due_time_change` plus
      its insert/update triggers and backfill, and `due_time_as_of(commitment_id, day)`, mirroring
      `commitment_carries_penalty_change` / `carries_penalty_as_of()`; `commitment_deadline(p_day,
      p_morning_hour, p_due_time)`, returning midnight ending `p_day` for a timed commitment and
      `declaration_deadline()` otherwise; `commitments_owing()` returning `due_time` and an
      effective `answer` per decisions 1 and 2; `settle_day()`'s deadline gate rewritten per row;
      `supersede_expiries()` reading a per-row deadline and `o.answer`; `enqueue_gate_reminders()`
      excluding `due_time is not null` from `outstanding`; `weekly_held_count()` requiring evidence
      for a timed commitment; the `commitment` check constraint from decision 3; the unclaimed
      Weekly Quota exclusion and the `created_at` guard in `commitments_owing()`; `day_begins_at()`
      alongside `day_ends_at()`; and a pre-flight that refuses to apply rather than repairing a
      commitment already carrying both a time and an Auto-check.
- [x] `supabase/tests/2-1-roles-and-rls.sql` — the four new internal functions added to the list of
      functions `anon` and `authenticated` must not be able to execute. `due_time_as_of()` is
      deliberately not among them: it is granted, for `weekly_held_count()`.
- [x] Eighteen existing `supabase/tests/*.sql` fixtures — state when their commitments began, so
      the `created_at` guard does not silently empty the set each of them is about.
- [x] `lib/commitment.ts` — refuse a draft that carries both a time and an Auto-check, in its own
      message; keep `canBeTimed()` and `autoChecksPossible()` separate.
- [x] `lib/commitment.test.ts` — the new draft rule, both directions.
- [x] `lib/expiry.ts` — correct the header: the deadline it describes is now the untimed one.
- [x] `supabase/tests/6-4-midnight-decides-the-day.sql` — every row of the matrix that a database
      can reach, including the mixed day and the expired-day correction.
- [x] Any existing `supabase/tests/*.sql` that a changed function's signature or output touches —
      none needed one. All 33 pass unchanged, which is the assertion that matters most here.

**Acceptance Criteria:**
- Given a day whose only commitment is timed and unproven, when the pass runs after midnight, then
  the day settles that same pass rather than three days later.
- Given a timed commitment claimed with an accepted photo, when the day settles, then it reads
  `held` and its chain continues.
- Given a day already settled, when the pass runs again, then no second settlement and no second
  penalty is written.
- Given an account with only untimed commitments, when every settlement, expiry, appeal, Grace Day
  and summary path runs, then every result is byte-for-byte what it was before this story.
- Given a day answered before a time existed on the commitment, when a time is added afterwards,
  then that day keeps the verdict it had.
- Given a timed Weekly Quota commitment and a day it was not claimed, when the pass runs, then no
  settlement is written on its account of that day.

## Spec Change Log

### 2026-08-29 — review loop 1

**Triggering findings.** The review found, and a database run confirmed, that `commitments_owing()`
read `c.due_time` live: a commitment edited today re-judged days already answered, turning a `held`
day into `slipped` with a penalty and a broken chain. The same live read made every unclaimed day
of a timed Weekly Quota settle `expired`, and the function's long-standing lack of a `created_at`
guard meant a commitment created this afternoon was charged for five days it had not existed for.

One reviewer finding was checked and rejected: that `weekly_held_count()` reading `public.evidence`
would break `3-3-weekly-quota-progress.sql` on privileges. Reading `weekly_quota_progress` as
`authenticated` in a clean transaction raises nothing, and all 34 files pass.

**Amended.** Decisions 5, 6 and 7 added, with four matrix rows and one `Always` clause. Decision 6
was renegotiated with hwt75 — the Weekly Quota question had more than one defensible answer and was
his to settle. Tasks extended with the change log, its triggers, `due_time_as_of()`, and the
eighteen fixtures.

**Known-bad state avoided.** A settings edit moving money backwards — the exact defect the Epic 4
retrospective fixed for `carries_penalty`, reintroduced one column later in the one story that
moves money.

**Cost, measured after the fact.** Decision 7's one-line guard broke 18 of the 34 database checks:
every fixture in the repository creates its commitments moments before judging days that predate
them. hwt75 was shown the number and reaffirmed the decision, so all 18 now state when their
commitments began, and `4-2-unavailable-is-not-missed.sql` — whose step 5d reasons explicitly about
`commitments_owing()` having no such filter — was rewritten to assert both guards rather than have
one quietly absorb the other.

**KEEP.** The seam is right and must survive: `commitments_owing()` is where a timed commitment's
`held` is earned, every consumer reads through it untouched, and `answer is null` keeps meaning
silence. Decisions 1 through 4 are unchanged and were confirmed by the database checks. The
`enqueue_gate_reminders()` exclusion stays on the **live** `due_time` while settlement reads the
frozen one — what to ask and what is true are different questions, and asking about a day that can
no longer be answered is worse than not asking.

## Verification

**Commands:**
- `npm test` — expected: every existing test passes, plus the new `lib/commitment.test.ts` cases.
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check` — expected: clean.
- `npx supabase db reset` then every file under `supabase/tests/` — expected: 34 pass, 0 fail.

**Manual checks (if no CLI):**
- `npm run migrations:check` — expected: the new migration is reported as not yet pushed until it
  is, and the count read is non-zero.

## Close — 2026-08-29 (stops here for the done checkpoint)

**Everything runnable ran, and passed.** `npm test` — 1155 tests across 48 files.
`supabase/tests/6-4-midnight-decides-the-day.sql` passes all 16 steps on a real database, and all
34 files under `supabase/tests/` pass: **34 pass, 0 fail**. `tsc --noEmit`, `eslint` and
`prettier --check` are clean. `npm run migrations:check` correctly reports the new migration as not
yet pushed.

**What the review changed, and it was the important half.** The first implementation read
`due_time` live. A database run proved what that meant: a day answered `held` under the untimed
rule read `slipped` the moment a time was added to the commitment, settled `failed`, charged a
penalty and broke the chain — the exact defect the Epic 4 retrospective had already fixed for
`carries_penalty`, sitting one column away in the same `select`. Three decisions came out of that
loop and are now the spec's 5, 6 and 7.

**Three things the work found that the spec did not anticipate:**

1. **Two log entries written in one transaction tie under `now()`.** `commitment_due_time_change`
   uses `clock_timestamp()` instead, because a log whose whole purpose is ordering cannot have
   ties. Found by the step-12 check failing on a fixture that created and then edited a commitment
   in the same transaction — which is also the shape any future data migration would have.
2. **`weekly_held_count()` is `security_invoker` and granted to `authenticated`**, so it cannot
   call a revoked function. `due_time_as_of()` is granted for that one caller; the exposure is the
   one `weekly_held_count()`'s own grant already accepts, on the same unguessable key.
   `carries_penalty_as_of()` stays revoked because it has no such caller.
3. **The gate and settlement now read `due_time` differently on purpose.**
   `enqueue_gate_reminders()` reads the live column, settlement reads the frozen one. A commitment
   timed this morning can only be claimed today (`declaration_derive_day()` reads live too), so
   asking about yesterday would be a prompt with no reachable answer. What to ask and what is true
   are different questions, and this is the first place in the codebase where they diverge.

**Deliberately not built, and why.** The referee still gets nothing — he cannot see a claim's
photo, and cannot contest a proven day. Story 6.7 gives him the objection and the access together
or neither. Nothing in `components/` changed beyond the draft rule: Today still shows no window
state, which is Story 6.5.

**Still true:** this migration is applied locally only.

## Done checkpoint

What a database cannot prove: that a real day, on a real phone, in the author's own timezone, fails
at his midnight and not at some other instant. Every check above pins the boundary against the
database's own clock; only a live day proves the hourly schedule fires on the right side of it.

1. Set a commitment's time, claim it inside its window, and take the photo. The next morning the
   gate must not ask about it, and the day must read held.
2. Do the same and *skip* the photo. After midnight the day must read as a failed day with its
   penalty — not sit open for three days.
3. Before pushing this migration, check the live project for a commitment carrying both a time and
   an Auto-check. The migration refuses to apply rather than choosing for you, and the message
   names the query.
   ```sql
   select id, name, due_time, auto_check_kind from public.commitment
    where due_time is not null and auto_check_kind is not null;
   ```

## Suggested Review Order

**What a timed day is worth**

- The entry point: one `case` decides everything downstream, and every consumer reads it.
  [`20260829090000:308`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L308)

- Not silence when he never claimed, so 5.2 and the answer-rate measures still read true.
  [`20260829090000:330`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L330)

- A Weekly Quota is judged at week close; an unclaimed day says nothing.
  [`20260829090000:359`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L359)

- Nothing is judged for a day it did not exist on — the guard that cost 18 fixtures.
  [`20260829090000:348`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L348)

**Which clock judges it**

- Midnight for a timed commitment, `D+3` for everything else, one place.
  [`20260829090000:82`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L82)

- The gate that replaced one account-wide deadline: hold the day per commitment.
  [`20260829090000:472`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L472)

- The expiry correction now measures each answer against its own deadline.
  [`20260829090000:578`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L578)

**A rule may only judge a day it governed**

- Why the change log exists at all, and why its rule is stricter than its sibling's.
  [`20260829090000:143`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L143)

- Changed mid-day means the day was untimed; the creation entry is not a change.
  [`20260829090000:216`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L216)

- The weekly tally reads the same frozen value, or a mid-week edit drops proven days.
  [`20260829090000:951`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L951)

**What is asked, versus what is true**

- The morning question skips a timed commitment, and reads the live column on purpose.
  [`20260829090000:875`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L875)

**A sensor and a photo are two answers to one question**

- Refused by constraint, after a pre-flight that will not repair anyone's data silently.
  [`20260829090000:1022`](../../supabase/migrations/20260829090000_midnight_decides_the_day.sql#L1022)

- The client mirror, in its own message rather than folded into the Auto-check one.
  [`commitment.ts:314`](../../lib/commitment.ts#L314)

**Supporting**

- The three findings the review produced, each pinned by the sequence that produced it.
  [`6-4-midnight:699`](../../supabase/tests/6-4-midnight-decides-the-day.sql#L699)

- The claim is worth nothing until the photo lands, and `held` once it has.
  [`6-4-midnight:206`](../../supabase/tests/6-4-midnight-decides-the-day.sql#L206)

- Four new internal functions added to the list nothing client-side may execute.
  [`2-1-roles-and-rls:443`](../../supabase/tests/2-1-roles-and-rls.sql#L443)

- The documentation-only copy of the deadline stops claiming to be the only rule.
  [`expiry.ts:10`](../../lib/expiry.ts#L10)
