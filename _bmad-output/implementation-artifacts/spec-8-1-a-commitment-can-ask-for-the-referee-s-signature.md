---
title: 'Story 8.1 — A commitment can ask for the referee''s signature'
type: 'feature'
created: '2026-09-11'
status: 'done'
review_loop_iteration: 1
baseline_commit: 'db72cc0ff35d95359ed7b5ba362960152ed8a955'
story_key: '8-1-a-commitment-can-ask-for-the-referee-s-signature'
context:
  - '{project-root}/_bmad-output/specs/spec-commitments-the-referee-signs-off/SPEC.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-8-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-09-11 by hwt75** — including all three decisions below: the day-start read with no
> mid-day veto, the pairing rule as a write-time trigger rather than a CHECK, and lifting the photo
> helper's inline sentences into a tested constant. Also approved at full length, above the 1600-token
> guidance, on the grounds that the Code Map is what keeps the implementer out of a blind search.
> Frozen from here.

## Intent

**Problem:** The author wants his friend's signature on some days, not all of them, and there is
nowhere to say which. Nothing on a commitment records that it wants a referee's sign-off, and the
referee's only power today is an objection filed 48 hours after the day closed and the money moved.

**Approach:** One column on `commitment`, the append-only log that lets it be read as of any past
day, the four refusals that stop it meaning nothing, and the sentence that tells the author what he
just switched on — including that his friend forgetting costs him nothing. Nothing reads the flag
yet; Story 8.2 is what makes it decide anything.

## Boundaries & Constraints

**Always:** The flag decides money, so it ships with its log and its `_as_of()` reader in the same
migration — `20260903120000`'s own comment says this column needs the log *before* the story that
makes it cost anything, and this is that story. The four refusals are enforced in the database and
mirrored in `lib/commitment.ts` so the form refuses a bad draft without a round trip, exactly as the
cadence-target rules do. A commitment saved without the flag behaves as it does today, and no
existing row changes. The setup copy states the silence rule in the moment the flag is turned on.

**Ask First:** Any reading of the flag that is not "the value in force when the day began" (decision
1 below). Granting the reader to `authenticated`. Any copy that asks the author to chase his friend.

**Never:** Anything that reads the flag — no settlement change, no `commitments_owing()` clause, no
decision table, no referee surface, no notification. No change to `object_to_day()`. No re-judging of
days already answered: turning the flag on reaches forward only. No unpair path, and no enforcement
that a pairing *stays* — a pairing revoked later simply auto-approves, which is Story 8.2's silence.

## The three decisions worth your attention

**1. The reader freezes the day at its start, and has no mid-day veto.** `carries_penalty_as_of()`
reads the value at the instant the day closed, because a cost is settled when a day ends.
`due_time_as_of()` reads the value at the day's start *and* judges the day untimed if the time moved
during it, because a window is a question about the whole day. This flag takes the first half of the
second and refuses the second half, for one reason: the veto is a hole here. A refusal lands at
21:00; the author switches the flag off at 22:00; under a mid-day veto the day is judged unflagged
and the refusal he just earned evaporates. Under a day-start read with no veto it stands, and a flag
switched *on* mid-day governs nothing until tomorrow — which is the SPEC's own "reaches forward
only" written as SQL. Two branches, not three: the entry in force before `day_begins_at(p_day)`, and
the earliest known value extrapolated backward for a day at or before the commitment's creation.

**2. "It cannot be set with no referee paired" cannot be a CHECK constraint.** A check cannot query
`profile`, so this rule is a trigger, and it fires only when the flag is written. That is the whole
rule: a pairing revoked afterwards does not retroactively refuse anything, because the SPEC says a
revoked pairing auto-approves. The client mirror has no read to reuse either — `paired_doer_id()` is
revoked from `authenticated` and answers the referee's question, and `"profile: read own"` stops a
doer seeing the row where `referee_of` points at him. So this story adds `has_paired_referee()`, a
`security definer` boolean for the calling doer, and threads it into the form the way `ownerId`
already is. It is the only rule in `draftProblems()` that is not a pure function of the draft.

**3. The flag makes an existing sentence false, and that sentence has to move.** Under the photo
checkbox the form says, inline, *"Nothing reads it: it never decides a day, and a day with no photo
ends exactly as it would have ended anyway."* With sign-off on, a photo is what the referee reads.
This is the A2 defect one step earlier — the app promising something the rules no longer keep — and
the cheap moment to fix it is now: lift both inline sentences into a tested copy constant beside
`TIMED_COMMITMENT_COPY` and give the flagged case its own. Not doing this leaves the contradiction
on screen for the whole epic.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| The flag is saved | `kind='do'`, no auto-check, `requires_photo` on, a referee paired | Stored; a log row is written. On a commitment **created** with the flag already on, `…_as_of(id, today)` reads `true`: its own creation day has no earlier verdict to rewrite, so the backward extrapolation two rows down governs, exactly as it does for `carries_penalty_as_of()` and `due_time_as_of()`. A commitment that already existed is the "Switched on mid-day" row instead | N/A |
| Nothing is flagged | Any commitment saved with the flag off | Byte-identical to today. One log row is still written | N/A |
| Wrong kind | `kind='abstain'` or `'open_ended'` with the flag on | Refused | `commitment_sign_off_needs_a_do`; the form said so first |
| A machine already answers | `auto_check_kind` set with the flag on | Refused | `commitment_sign_off_not_with_auto_check`; form said so first |
| No photograph to look at | `requires_photo` false with the flag on | Refused | `commitment_sign_off_implies_photo`; the form sets the photo on with the flag rather than letting him cause it |
| No referee | Flag on, no row in `profile` with `referee_of = owner_id` | Refused by the trigger | Raises; the form's checkbox was disabled and said to pair one in Settings |
| Switched on mid-day | Flag off all of day D, on at 14:00 on D | `…_as_of(id, D)` is `false`; `…_as_of(id, D+1)` is `true` | N/A |
| Switched off after the fact | Flag on since D-10, off today | `…_as_of(id, D-5)` is still `true` | N/A |
| A day before the commitment existed | `p_day` at or before `created_at` | The earliest logged value, extrapolated backward | N/A |
| Kind changed away from `do` | Flag on, author switches to `abstain` | `withKind()` clears the flag, so the draft is saveable | N/A |
| Auto-check switched on afterwards | Flag on, author ticks Auto-check | Save refused with a sentence, flag not silently cleared | The conflict is shown, not swallowed |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260827130000_carries_penalty_freezes_by_day.sql:29-123` — the whole shape to
  copy: log table `:29-34`, comment `:36-39`, lookup index `:41-42`, the explicit deny policy
  `:50-53`, `revoke all` `:55`, trigger fn `:57-69`, the insert + conditional-update trigger pair
  `:79-88`, the `created_at` backfill `:90-96`, reader `:98-123`. **The backfill matters** — without
  it the reader's third branch has nothing to extrapolate from.
- `supabase/migrations/20260907120000_a_time_switched_off_stays_off.sql:24-90` — the newer reader
  idiom: explicit `case` branches over a `coalesce`, `public.day_begins_at()`/`day_ends_at()` rather
  than an inline `at time zone`. Take its branch structure, **drop its mid-day veto** (decision 1).
- `supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql:33-44` — the
  counter-example and the hook. Its column comment ends *"If a later story ever makes a missing photo
  cost anything, this column needs the log before that story ships."* Answer it in the new migration's
  header: a missing photo still costs nothing, because the referee's list will only ever show
  commitment-days that have one, so `requires_photo` still needs no log. **Do not edit that migration.**
- `supabase/migrations/20260828130000_a_commitment_can_carry_a_time.sql:71-83` — `commitment_time_needs_a_moment`
  and the comment refusing to share a predicate with the auto-check rules. Cite it; this flag is
  narrower still (`kind = 'do'` only), so it shares nothing with either.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:1002-1023` — the pre-flight
  `do $$ … raise exception` before a mutually-exclusive constraint. **Not needed here** — a new column
  defaulting `false` cannot have an offending row. Say so rather than copying it.
- `supabase/migrations/20260907160000_a_referee_belongs_to_one_doer.sql:29-42,57-79` — `profile.referee_of`
  (set on the *referee's* row, pointing at the doer), the `profile_one_referee_per_doer` index, and
  `paired_doer_id()`'s shape + its `revoke … from authenticated`. `has_paired_referee()` is its mirror.
  **Note:** `profile_single_referee`, which SPEC.md:84 cites, was dropped at `20260907170000:17`.
- `lib/commitment.ts:37` `CommitmentDraft`; `:87` `EMPTY_DRAFT`; `:134` `autoChecksPossible()`;
  `:156` `canBeTimed()` — the two gates this flag joins neither; `:194-207` `TIMED_COMMITMENT_COPY`,
  the copy constant to sit beside; `:216` `draftProblems()`; `:342` `withKind()` — clears `dueTime`
  because a constraint would refuse it, which is now also true of this flag; `:362` `withCadence()`;
  `:380` `toRow()`.
- `components/commitment-form.tsx:69` the derived gates; `:230-239` the money checkbox;
  `:241-271` the photo checkbox and **the two inline sentences that decision 3 moves**; `:274-294`
  the Auto-check block — the model for *disabled with three mutually exclusive explanations*, which
  EXPERIENCE.md:155 requires for a check-like row; `:334-339` the KF-7 combined warning.
- `components/commitment-list.tsx:16-33` `CommitmentRow`, `:42-43` the `SELECT` string, `:54-73`
  `toDraft()`, `:132-160` `save()` — **all three spell columns by hand and will silently drop the new
  one.** `save()` is a direct supabase write, so there is no server hop where the pairing could be read
  in passing; `CommitmentList` must fetch `has_paired_referee()` and pass it down.
- `lib/commitment.test.ts:21-23` the `draft()` helper; `:482-495` a refusal case;
  `:560-569` the clause-by-clause copy assertion — the idiom for testing the new warning.
- `components/commitment-form.test.tsx:295-301` copy appears only once its trigger is set;
  `:340-420` the 6.8 block asserting *absence* of cost copy — this flag's block is its inverse.
- `supabase/tests/carries_penalty_freezes_by_day.sql:81-100,120-127` — the fixture idiom for
  backdating log stamps inside one transaction (`now()` is transaction-stable, so two entries written
  in one test would tie). Copy it; **no `ci-clock-window` marker is needed** because nothing here
  depends on the hour the test runs at.
- `supabase/tests/README.md` — hand-written `begin; do $$ … $$; rollback;` with `raise exception`
  assertions, **not pgTAP**; add a row to its "What is here" table.
- `lib/evidence.ts:393-407` `EVIDENCE_COPY` and the A2 rationale comment — the precedent decision 3
  follows. **No change to this file in this story.**

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql` — add
      `requires_referee_approval boolean not null default false` with a `comment on column` stating
      that it decides money, that it is why it carries a log where `requires_photo` does not, and that
      a missing photo still costs nothing. Add the three CHECK constraints
      (`commitment_sign_off_needs_a_do`, `commitment_sign_off_not_with_auto_check`,
      `commitment_sign_off_implies_photo`). Add `public.commitment_requires_referee_approval_change`
      with its comment, `(commitment_id, changed_at desc)` index, RLS, the explicit deny policy,
      `revoke all`, the trigger function + insert/conditional-update trigger pair, and the
      `created_at` backfill. Add `public.requires_referee_approval_as_of(p_commitment_id uuid,
      p_day date) returns boolean`, `stable security definer set search_path = ''`, two branches per
      decision 1, revoked from `public, anon, authenticated`. Add the write-time trigger enforcing a
      paired referee, and `public.has_paired_referee() returns boolean` granted to `authenticated`.
- [x] `lib/commitment.ts` — `requiresRefereeApproval` on `CommitmentDraft` with the doc comment
      explaining why it joins neither existing gate, `false` in `EMPTY_DRAFT`, carried by `toRow()`,
      cleared by `withKind()` when kind leaves `'do'` and untouched by `withCadence()`. New
      `canBeSignedOff(kind)` predicate, kept separate from `canBeTimed()`/`autoChecksPossible()`.
      `draftProblems(draft, context?)` gains the four refusals, the pairing one reading from a new
      optional second argument. Export `REFEREE_SIGN_OFF_COPY` and the photo-helper sentences lifted
      out of the form (decision 3).
- [x] `components/commitment-form.tsx` — a checkbox after the photo one, disabled with three mutually
      exclusive explanations (wrong kind / a machine already answers / no referee paired), turning it
      on also turns the photo requirement on, `REFEREE_SIGN_OFF_COPY.warning` shown only while it is
      on, and the photo helper read from the constant with its new flagged branch. New `hasReferee` prop.
- [x] `components/commitment-list.tsx` — the column in `CommitmentRow`, the `SELECT`, and `toDraft()`;
      an `rpc('has_paired_referee')` read passed into `CommitmentForm`.
- [x] `lib/commitment.test.ts` — the four refusals, the clearing behaviour, `toRow()` carrying the
      column, and `REFEREE_SIGN_OFF_COPY.warning` asserted clause by clause including the silence one.
- [x] `components/commitment-form.test.tsx` — the control is disabled with the right sentence in each
      of the three cases, the warning appears only once the flag is on, and turning the flag on turns
      the photo requirement on.
- [x] `supabase/tests/8-1-a-commitment-can-ask-for-the-referee-s-signature.sql` — the reader across
      all three branches including switched-on-mid-day and switched-off-after-the-fact, each of the
      four refusals, the log written on insert and on change but not on an unrelated update, and that
      an unflagged commitment's rows are untouched. Add its row to `supabase/tests/README.md`.
- [x] `_bmad-output/implementation-artifacts/sprint-status.yaml` — `epic-8` to `in-progress`, `8-1…`
      to `in-progress`, `last_updated` to today.

**Acceptance Criteria:**

- Given a commitment flagged since ten days ago, when the author switches the flag off today, then
  `requires_referee_approval_as_of()` still reads true for every one of those ten days.
- Given an unflagged commitment, when it is saved, edited and archived, then every column, constraint
  and settlement path behaves exactly as it did before this migration, and the SQL suite proves it by
  passing unmodified.
- Given a draft with the flag on and no referee paired to the account, when the author tries to save,
  then the form had already refused it and the database's trigger refuses it too.
- Given the flag is switched on in the form, then the photo requirement switches on with it, and the
  photo helper stops saying the photo decides nothing.
- Given the flag is off, when the setup surface is rendered, then none of the sign-off copy is on
  screen and the form is indistinguishable from today's.

## Spec Change Log

### 2026-09-11 — iteration 1, `intent_gap`: the matrix asked for two different answers on a creation day

**Triggering finding.** The blind-hunter layer, confirmed against the local database: a commitment
created with the flag already on reads `requires_referee_approval_as_of(id, today) = true`, while the
first matrix row said it must read `false` for today and `true` from tomorrow. Reproduced by inserting
a flagged row and reading the door — `as_of(today) = t`.

**Root cause, and it was inside the frozen block.** Matrix row 1 and the row "A day before the
commitment existed" contradict each other whenever `p_day` is the creation day of a row created
flagged: one demands `false`, the other demands the earliest logged value, which is `true`. Row 1 had
silently assumed every flag arrives by being switched on later, which is the "Switched on mid-day"
row's case, not this one. No implementation could satisfy both, and no test caught it because the SQL
suite asked the reader about `today - 30` and never about `today`.

**Amended.** Row 1 only, on hwt75's decision of 2026-09-11: a commitment created with the flag on
reads `true` for its own creation day. "Reaches forward only" exists so a flag flipped today cannot
rewrite yesterday's verdict, and a commitment created today has no yesterday to rewrite;
`carries_penalty_as_of()` and `due_time_as_of()` both extrapolate backward for exactly this case. The
reader is unchanged — the code already implemented the resolved intent.

**Known-bad state avoided.** A third branch returning `false` for a creation day. It would have made a
commitment deliberately created with sign-off on unsignable on its first day, made the setup copy
false on the day the author read it, and left the backward-extrapolation row dead for this flag alone
while both sibling readers keep it.

**KEEP — must survive.** The reader's two branches and the absence of a mid-day veto (decision 1), and
the reasoning in its `comment on function` about a refusal at 21:00 surviving a flag switched off at
22:00. Neither is touched by this amendment.

## Design Notes

The reader's two branches, in the shape `20260907120000` established:

```sql
select case
         when exists (select 1 from history h where h.changed_at < public.day_begins_at(p_day))
           then (select h.requires_referee_approval from history h
                  where h.changed_at < public.day_begins_at(p_day)
                  order by h.changed_at desc limit 1)
         else (select h.requires_referee_approval from history h order by h.changed_at asc limit 1)
       end;
```

No `coalesce`: the column is `not null` so the two shapes agree today, but the existence test is what
`late_window_at()` established and it cannot be broken by a later nullable column.

The reader is revoked from `authenticated`, matching `carries_penalty_as_of()`. Story 8.6 is the
first client reader and must choose then between a grant and a `security_invoker` view — the
`morning_question_day` precedent, and the `components/ledger.tsx:156` live read is what happens when
neither is done.

## Verification

**Commands:**

- `npm test` — expected: every existing test passes, plus the new `lib/commitment.test.ts` and
  `components/commitment-form.test.tsx` cases.
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check`, `npm run build` — expected: clean.
- `npx supabase db reset`, then every file under `supabase/tests/` — expected: the current count plus
  one file, 0 fail, with every pre-existing file passing unmodified. The new file needs no
  `ci-clock-window` marker.
- `npm run migrations:check` — expected: the new migration reported as not yet pushed.

**Deploy order is not optional here.** `components/commitment-list.tsx` names
`requires_referee_approval` in its `SELECT`, so against a database without this migration the request
errors and the whole commitments screen fails to draw — not the sign-off control, the screen. The
migration reaches the project before the client ships, never the other way round. This is the
migration-before-client rule the project already holds itself to, and this story is a case where
breaking it costs the author every commitment he has.

## Suggested Review Order

**The one door — read this first**

- The whole story in one function: the value in force when the day began, and no mid-day veto.
  [`20260911090000…sql:184`](../../supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql#L184)

- Why the log stamps `clock_timestamp()` and not `now()`: two writes in one transaction must stay ordered.
  [`20260911090000…sql:81`](../../supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql#L81)

- The column that decides money, and the comment answering `20260903120000`'s standing question.
  [`20260911090000…sql:35`](../../supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql#L35)

**The four refusals, and the one no CHECK could make**

- Three constraints; the narrowest predicate in the table, sharing nothing with its neighbours.
  [`20260911090000…sql:61`](../../supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql#L61)

- The fourth: a trigger, write-time only, so a revoked pairing never makes a row unsaveable.
  [`20260911090000…sql:263`](../../supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql#L263)

- The only function here the client may call, and the reason it exists.
  [`20260911090000…sql:325`](../../supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql#L325)

**The client mirror, and where it nearly locked the author out**

- The rule that is not a pure function of the draft — it mirrors the trigger's `when`, not just its body.
  [`commitment.ts:483`](../../lib/commitment.ts#L483)

- Three states, not two: unasked is not the same as no.
  [`commitment.ts:311`](../../lib/commitment.ts#L311)

- Never disabled while ticked — unticking is always the way out.
  [`commitment-form.tsx:111`](../../components/commitment-form.tsx#L111)

- A failed pairing read is said out loud rather than read as "no referee".
  [`commitment-list.tsx:151`](../../components/commitment-list.tsx#L151)

**The copy that had to move**

- Both photo sentences lifted out of JSX, plus the one the flag makes necessary.
  [`commitment.ts:257`](../../lib/commitment.ts#L257)

- What the author is told, including that his friend forgetting costs him nothing.
  [`commitment.ts:285`](../../lib/commitment.ts#L285)

**Tests**

- The precondition that would catch a lost grant; proven non-vacuous by revoking it.
  [`8-1-…sql:33`](../../supabase/tests/8-1-a-commitment-can-ask-for-the-referee-s-signature.sql#L33)

- The creation day the review caught, now pinned in both directions.
  [`8-1-…sql:246`](../../supabase/tests/8-1-a-commitment-can-ask-for-the-referee-s-signature.sql#L246)

- Midnight belongs to the day it opens, asserted rather than crossed by accident.
  [`8-1-…sql:169`](../../supabase/tests/8-1-a-commitment-can-ask-for-the-referee-s-signature.sql#L169)

## Close — 2026-09-11 (stops here for the done checkpoint)

**What ran, and passed**, re-run independently after the review patches rather than taken on report:
`npm test` — 1451 tests across 53 files, all green (1441 before the patches). `npx tsc --noEmit`,
`npm run lint`, `npm run format:check`, `npm run build` — clean. `npx supabase db reset` then every
file under `supabase/tests/` — **46 pass, 0 fail**, every pre-existing file unmodified.
`npm run migrations:check` — `20260911090000` reported as not yet on the remote.

**What the review changed.** Three layers ran; one finding was a contradiction inside the frozen
block itself and went to hwt75 (see the Spec Change Log). Seven patches landed, of which two were
serious: the form locked an author out of an already-flagged commitment once his pairing was revoked
or the pairing read merely failed — stricter than the database, which Step 6 proves permits it — and
the grant this migration makes was tested by a file running as superuser, so losing it would have
killed the feature in production with every test green. The second was verified by revoking the grant
inside a throwaway transaction and watching the new precondition raise.

**Why this is not `done`.** Two gates are open, and both are outside this session's authority.
`20260911090000` is not on the live project, and AGENTS.md forbids promoting a schema-carrying story
to `done` before remote migration parity. The `## Done checkpoint` below is human-only and unrun.

**Deliberately not built.** The `do` + `daily_hours_quota` combination stays flaggable and inert, and
the warning names a refusal Story 8.2 has not built yet — both put to hwt75 on 2026-09-11, both
accepted, both recorded in `deferred-work.md` with what would reopen them.

## Done checkpoint

What a database cannot prove: that the author, on his own phone, reads the sentence and understands
that his friend forgetting costs him nothing.

1. Open the setup surface on a real commitment and switch sign-off on. The photo requirement must
   switch on with it, and the warning must read as information about his friend rather than a task
   for him.
2. With no referee paired, the control must be disabled and say where to pair one.
3. Switch it on, save, reopen. The flag must still be on — the three hand-written column lists are
   where it would silently vanish.
4. Do 1–3 only after the migration is on the project. The client's `SELECT` names the new column, so
   against an un-migrated database the commitments screen does not render at all and there is
   nothing to check.

## Both gates closed — 2026-09-14

**Remote migration parity.** `npx supabase db push` applied `20260911090000` to
`hxzalpnlrunctbajgtkv`; `npm run migrations:check` then reported **all 77 matching**, where before it
named this file as the one outstanding. The push was authorised by hwt75 on the day, as AGENTS.md
requires — it is not something a session takes on itself.

**The done checkpoint ran.** hwt75 reports steps 1–3 pass. Recorded on his word, not on an
observation this session could make: that is what makes the checkpoint human-only in the first
place.

**PR [#14](https://github.com/hwt75/todoapp/pull/14)**, `check` and `db-tests` both green on GitHub
Actions, Vercel preview deployed. `Supabase Preview` skips, as it does on every PR in this
repository — there is no branch database, so the preview read the live project, which is precisely
why the migration had to land before the checkpoint could be run against it.

**Still unrun: the security advisor.** README asks for it after any schema change and it has not
been run against this one. Not a `done` gate — the two gates this story named were parity and the
checkpoint — but it is owed, and this is where it is recorded so it is not lost. What it would be
looking at: a new table (`commitment_requires_referee_approval_change`, RLS on, no client policy,
all privileges revoked), three new functions, and one `grant execute` to `authenticated`
(`has_paired_referee()`), which is the only widening of reach in the migration.

Story promoted to `done` in `sprint-status.yaml` on this evidence.
