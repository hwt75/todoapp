---
title: 'Story 6.1 — A commitment can carry a time and a late window'
type: 'feature'
created: '2026-08-28'
status: 'approved'
review_loop_iteration: 0
baseline_commit: '0114c34'
story_key: '6-1-a-commitment-can-carry-a-time-and-a-late-window'
context:
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/brownfield.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-28 by hwt75** — all four decisions below: `due_time` over `due_at`, the
> extracted-minutes midnight check, `canBeTimed()` kept separate from `autoChecksPossible()`, and
> the window at 5–240 minutes defaulting to 30. Frozen from here.

## Intent

**Problem:** Every commitment in this product is judged by one question asked the next morning.
That works for "did you go to the gym at all" and fails for anything with a moment in it — take the
pill at 20:00, leave the house by 07:30. The author cannot say *when*, so the machine cannot hold
him to a when, and the only thing holding him to it is the memory he paid money to stop trusting.

**Approach:** Two columns on `commitment` and the constraints that make them mean something. A time
of day, a window of minutes after it, a rule that the window cannot cross midnight, and a rule that
the two arrive together or not at all. A form that offers them only where they can mean something,
and states — at the moment the time is turned on — what a forgotten photo will cost.

This story ends at what a *timed* commitment **is**. Nothing here files a claim, uploads a photo,
reminds anyone, or closes a day.

## Boundaries & Constraints

**Always:**
- The window may not cross midnight, and that is a check constraint on the table, not a form rule.
  `lib/commitment.ts` mirrors it so the form can refuse a bad draft without a round trip — the
  mirror is a convenience, the constraint is the authority.
- Time and window arrive together. One without the other is a half-filled form, refused the same way
  a weekly quota without a target already is.
- `due_time` is a **wall-clock time of day in `Asia/Ho_Chi_Minh`**, never an instant. No client
  derives a date or an instant from it (AD-6).
- Every write keeps its client-generated idempotency key, generated at the action and reused by
  retries (AD-4).
- Untimed commitments are untouched. A null time means exactly today's behaviour, and no existing
  row changes.

**Ask First:**
- Any change to `declaration`, `settle_day()`, or `gate_reminder()`. Those belong to 6-2 and 6-4,
  and a column added here that only they will read is a column added in the wrong story.
- Sharing a predicate with `autoChecksPossible()` — see decision 3.

**Never:**
- Do not use the word **grace** for this window anywhere: not a column, function, identifier, test
  name, or copy string. Grace Day already names a countable forgiveness token in this product
  (`lib/grace.ts`, two per calendar month). Two meanings for one word in a codebase that decides
  money is how the wrong one gets read at 3am.
- Do not add a monthly cadence. It is an explicit non-goal in `SPEC.md` and there is no month-close
  layer to hang it on.
- Do not build an occurrence or schedule table. Columns, not tables — settled decision.
- Do not colour the new controls by outcome. The destructive button remains the only control in this
  product that carries a filled colour.

## The four decisions worth your attention

**1. The column should be `due_time`, not `due_at`.**
`SPEC.md` wrote `due_at`, and that name is wrong for this codebase. Every `_at` here is a
`timestamptz` — `archived_at`, `created_at`, `answered_at`, `auto_check_last_checked_at`. This value
is a Postgres `time`: a wall-clock time of day with no date and no zone, resolved against
`Asia/Ho_Chi_Minh` by whoever reads it. Naming it `due_at` would make it the one `_at` in the schema
that is not an instant, and the first person to write `now() >= due_at` would be writing a bug that
compiles. **Settled: `due_time`.** `SPEC.md`, `brownfield.md`, `lifecycle.md` and `stories.yaml`
were amended to match.

**2. The midnight check cannot be written the obvious way.**
`due_time + interval '60 minutes'` **wraps**: `23:30` + 60 minutes is `00:30`, not `24:30`. A
constraint written that way would silently accept exactly the case it exists to refuse. It has to
compare extracted minutes:

```
extract(hour from due_time) * 60 + extract(minute from due_time) + late_window_minutes <= 1440
```

`<= 1440` and not `< 1440`: the window is half-open, so one ending exactly at 24:00:00 is still
inside its own day — its last valid instant is 23:59:59.999. Both `extract` and `make_interval` are
already used in this schema, so neither is a new idiom.

**3. "Can this be timed?" happens to equal `autoChecksPossible()`, and must not share it.**
Both exclude `kind = 'abstain'` and `cadence = 'daily_hours_quota'`, and the reasons are unrelated.
`autoChecksPossible()` is about *sensors*: nothing observes a thing not done, and an hours quota is
measured in banked minutes rather than declared. This one is about *moments*: an abstention has no
instant of doing to photograph, and an hours quota is not settled by a declaration at all. The
predicates match today by coincidence. Merging them creates a single function two unrelated rules
depend on, and the next change to either will quietly break the other. Write a separate
`canBeTimed()` and put this paragraph above it.

**4. `late_window_minutes` is 5–240, defaulting to 30.**
This was the open question in `SPEC.md` that blocked the migration — a column with no range check is
a column that accepts 100000. **Settled:**

- **Range 5–240 minutes.** Below five the window is unhittable in practice; above four hours the
  "time of day" stops meaning one.
- **Default 30** when a time is first switched on.
- **Zero not allowed.** A window of zero means the claim must land on the exact second, which no
  human interaction can guarantee — it would read as a bug every time it fired.

The midnight constraint bounds this further and independently: a `due_time` of 22:00 caps its own
window at 120 regardless of the 240 ceiling. Both checks stay — the range says what a window may be,
the midnight check says where it may end.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Untimed commitment | Time left off | Both columns null; behaves exactly as today | — |
| Timed, ordinary | `due_time` 20:00, window 30 | Both stored; window ends 20:30 same day | — |
| Window ends exactly at midnight | 23:30, window 30 | Accepted — 1440 is inside the day | — |
| Window crosses midnight | 23:30, window 60 | **Refused** | Check constraint; form refuses first with the same reason |
| Time without a window | `due_time` set, window null | **Refused** | Pairing constraint, mirrored in `draftProblems()` |
| Window without a time | Window set, time null | **Refused** | Same constraint, both directions |
| Window out of range | 0, or 1000 | **Refused** | Range check (decision 4) |
| Kind is `abstain` | Time controls | Not offered; a stored value is refused | Nothing to photograph — stated on screen, not merely greyed |
| Cadence is `daily_hours_quota` | Time controls | Not offered; a stored value is refused | Judged by measured minutes, not by a moment |
| Switching to a kind or cadence that cannot be timed | Time was set | Time and window cleared from the draft | Same pattern `withCadence()` already uses for stale targets |
| Editing an existing untimed commitment | Save without touching time | Row unchanged; no migration backfill | — |
| Double-tap save | Same idempotency key twice | One row | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819150000_commitment.sql` — the table this story alters, and the
  constraint style to copy. `commitment_weekly_quota_targets` is the exact pattern for the pairing
  rule: `(cadence = 'weekly_quota') = (weekly_target is not null)`.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql` — `make_interval` in use;
  `20260819210000_gate_reminder.sql` — `extract(hour from …)` in use. Neither idiom is new.
- `lib/commitment.ts` — `CommitmentDraft`, `EMPTY_DRAFT`, `requiredTargets()`, `draftProblems()`,
  `withKind()`, `withCadence()`, `toRow()`. Every one of them is touched. `toRow()` is the only
  place database column names are spelled.
- `lib/appeal.ts` (`APPEAL_COPY`), `lib/focus-session.ts` (`FOCUS_COPY`) — the pattern for the
  warning string: copy lives in `lib/`, testable without a component, and the component reads from
  it rather than inventing it inline.
- `components/commitment-form.tsx` — where the controls go. The conditional-target blocks
  (`targets.includes('weeklyTarget')`) are the shape to copy.
- `supabase/tests/2-2-commitment-rules.sql` — the existing checks for this table. The new
  constraints extend this file's job; `supabase/tests/README.md` states the rule that a story's
  verification leaves a runnable file here, not a paragraph in its spec.
- `app/tokens.css`, `app/globals.css` — every colour, radius and spacing value. A literal in a
  component is a defect the token suite already catches.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_a_commitment_can_carry_a_time.sql` — add `due_time time` and
  `late_window_minutes integer`; the pairing constraint, the midnight constraint written on extracted
  minutes, the range check, and the constraint refusing a time on `abstain` or `daily_hours_quota`.
  Column comments carry the wall-clock/`Asia/Ho_Chi_Minh` rule and the reason the midnight check is
  not written with an interval.
- [x] `lib/commitment.ts` — the two draft fields, `canBeTimed()` with decision 3's paragraph above
  it, the new `draftProblems()` messages, clearing in `withKind()`/`withCadence()`, the columns in
  `toRow()`, and the warning copy constant.
- [x] `lib/commitment.test.ts` — every row of the matrix above, including the two boundary cases
  (window ending at exactly 1440 accepted, 1441 refused) and that an untimed draft is unchanged.
- [x] `components/commitment-form.tsx` — time and window controls, offered only where `canBeTimed()`
  allows, cleared on a kind or cadence switch, with the warning shown whenever a time is set.
- [x] `components/commitment-form.test.tsx` — the controls appear and disappear with kind and
  cadence, and the warning is present whenever a time is.
- [x] `supabase/tests/6-1-timed-commitment-constraints.sql` — one self-rolling-back transaction per
  the README's form, asserting each constraint refuses what it must and accepts what it must.

**Acceptance Criteria:**
- Given a commitment with kind `do` and cadence `daily`, when a time of 20:00 and a window of 30 is
  saved, then both are stored and the commitment is unchanged in every other respect.
- Given a time of 23:30 and a window of 60, when saved, then the database refuses it, and the form
  had already refused it with the same reason.
- Given a time of 23:30 and a window of 30, when saved, then it is accepted — a window ending at
  exactly midnight is inside its own day.
- Given a time with no window, or a window with no time, then the row is refused by constraint.
- Given kind `abstain` or cadence `daily_hours_quota`, then the time controls are not offered, and
  the screen states that these are settled by something other than a moment.
- Given a commitment with a time set, when the kind or cadence is switched to one that cannot be
  timed, then the time and window are cleared from the draft rather than left to be refused later.
- Given any commitment with a time set, then the setup screen states — verbatim, not as a link to a
  document — that a timed commitment is settled by a photo rather than by the morning question, that
  no photo before midnight is a failed day, and that Grace Days are limited to two a month.
- Given an existing untimed commitment, when it is saved unchanged, then no column moves and no
  migration has backfilled a value into it.

## Verification gate

This machine has no `psql`, no Docker and no local Supabase (established in the Epic 2 retrospective
work and unchanged since). `npm test` will cover `lib/` and `components/` and will genuinely prove
the mirror; it cannot execute a single one of the constraints above. `6-1-timed-commitment-constraints.sql`
will therefore ship **written and unrun**, exactly as `2-5-settlement.sql` and `2-7-supersession.sql`
did — and that must be stated in the story's close rather than dressed up as verified.

The open choice from that retrospective is still open: Docker locally, or a Supabase preview branch.
It is not this story's job to settle it, but this story is the third to be blocked by it.

## Close — 2026-08-28

**What ran, and passed:** `npm test` — 1112 tests, 46 files, all green, including 42 new ones
across `lib/commitment.test.ts`, `components/commitment-form.test.tsx` and
`components/commitment-list.test.tsx`. `npx tsc --noEmit` clean. `npm run lint` clean.
`npm run format:check` clean.

**What ran later the same day, and passed.** The first close of this story said the database checks
had shipped unrun, because the Epic 2 retrospective's note that this machine has no Docker was taken
as still true. It is not: Docker 29.5.3 is installed and running, and `npx supabase` works. The local
stack was started, `supabase db reset` applied every migration including this story's, and:

```
docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-1-timed-commitment-constraints.sql
```

passed all three steps. **Every one of the five constraints is now exercised**, including the pair
that matters most — 23:30 with a thirty-minute window accepted, 23:30 with thirty-one refused. All
31 files under `supabase/tests/` were then run against the same database: 31 pass, 0 fail, so this
story's migration breaks nothing that came before it.

**Still true:** the migration is applied *locally only*. `npm run migrations:check` fails with
`LegacyProjectNotLinkedError` and the author's own project has not received it.

**Two things the work found that the spec did not anticipate:**

1. **Seconds.** `extract(hour) * 60 + extract(minute)` silently drops them, so `23:55:30` with a
   five-minute window compares as exactly 1440 and passes, while the window it describes ends half a
   minute into the next day. Closed with `commitment_due_time_whole_minute` rather than by rewriting
   the approved expression.
2. **`components/commitment-list.tsx` was not in the Code Map and had to change.** Postgres renders
   a `time` as `20:00:00`; `<input type="time">` renders and produces `20:00`. Without the
   normalisation in `toDraft()`, an edit that never touched the field would send back a different
   value than it read. The list line also now shows the time, so a timed commitment is identifiable
   without opening it.
