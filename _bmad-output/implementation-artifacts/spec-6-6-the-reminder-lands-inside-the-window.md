---
title: 'The reminder lands inside the window'
type: 'feature'
created: '2026-09-03'
status: 'done'
baseline_commit: '8b22bb96e8da951d01f9297fc6cd922adfb18768'
review_loop_iteration: 4
context: []
---

> No spec checkpoint on this story (`stories.yaml`). It carries a **done checkpoint**: a push that
> arrives at the right minute can only be proven by a locked phone.

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every reminder in this product is enqueued by an hourly cron job on its own minute —
`gate-reminders` at `:05`, `settle-days` at `:15`, and so on down to `:55`. A commitment due at
20:30 with the default 30-minute window would first be reminded at 21:05, after the window it names
has already shut. The smallest legal window is five minutes, which no `NN * * * *` schedule can
reach. CAP-6 says the author is reminded at the time he chose, close enough that the time means what
it says.

**Approach:** Do not add a per-minute enqueuer. Enqueue *ahead* of the hour with a delivery instant
attached, and let the outbox worker — which already runs every minute and is not changed — deliver
it when that instant arrives. `outbox.not_before` is the column `outbox_claim()` already filters on;
it was built for a deferred send and has never been used for one.

## Boundaries & Constraints

**Always:** The new cron job is hourly and takes a free minute — `:00 :05 :15 :25 :35 :45 :55` are
taken. Enqueue only: every outbound effect stays behind the outbox, and the worker, its batch size
and its schedule are untouched. The reminder's delivery instant is the moment the window *opens*,
never a moment inside it — a reminder that arrives at minute four of a five-minute window is
technically inside and practically useless. Both boundaries resolve in `Asia/Ho_Chi_Minh` by
explicit conversion (AD-6); no interval is added to a `timestamptz` to find a wall-clock time. One
reminder per commitment per day, enforced by the dedupe key as every other enqueuer does. The
reminder may only assert a consequence the day will actually carry: `due_time_as_of()` decides
whether a window governs a day at all (Story 6.4), and a cadence decides what a missed window
costs. Copy that names a cost the day cannot incur is a defect, not a wording preference.

**Ask First:** Changing `outbox_claim()`, the worker, or any existing dedupe-key shape. Giving this
reminder a `tag`, a sound, or any presentation the other kinds do not have — `app/sw.ts` refuses
`tag` on purpose and that decision is not being reopened here.

**Never:** A `* * * * *` enqueuer. A second notification for the same commitment-day. A reminder
for a day `due_time_as_of()` will judge untimed — a `due_time` written part-way through a day
governs neither the window already passed nor a whole day, so that day falls back to the morning
gate and cannot fail for a missing photo. A queued reminder left standing after the window it names
has been moved or removed. Suppressing
this reminder during a silence episode — that suppression exists for the routine morning gate, and
an author who has gone quiet is exactly the one whose timed day is about to cost him money. Any
reading of the clock in the client for this purpose; `lib/timed-window.ts` renders state and does
not schedule.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Routine | Timed `daily` commitment due 20:30, pass runs 19:50 | One `pending` row, `not_before` = 20:30 local; delivered 20:30–20:31 | N/A |
| Just after midnight | `due_time` 00:10 | The 23:50 pass resolves **tomorrow's** date and enqueues it | Without the second date this time is unreachable |
| Already claimed | A declaration exists for that commitment-day | No row enqueued | N/A |
| Created inside the hour | Commitment **created** 20:15 carrying `due_time` 20:40 | The trigger enqueues on the INSERT: a commitment's own creation entry governs its own day | `on conflict do nothing` if the pass also reaches it |
| Time changed mid-day | Existing commitment, `due_time` moved 20:40 → 22:00 at 20:15 | Every pending row for today and tomorrow is deleted; today is **not** re-queued because `due_time_as_of()` now judges it untimed; tomorrow is re-offered under the new time | N/A |
| Time cleared mid-day | Existing commitment, `due_time` cleared at 20:15 | Same deletion; nothing re-queued for either day | N/A |
| Window already open | Time set at 20:15 for 20:05 | Nothing enqueued — a reminder now would arrive after the window opened | Silent skip, not an error |
| Untimed commitment | `due_time is null` | Never enqueued; the morning gate still owns it | N/A |
| Weekly quota | Timed commitment whose cadence is `weekly_quota` | Reminded at its hour, with copy that does not claim the day fails | N/A |
| Unsendable name | A commitment name that makes `push_body_is_sendable` false | Queues nothing, raises nothing; the rest of the pass survives | Return false, never an exception |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819180000_outbox.sql:73` — the table: `not_before timestamptz not null
  default now()`, `dedupe_key text not null unique`, index `outbox_claimable_idx (not_before) where
  status = 'pending'`. `:134` `outbox_enqueue(uuid, text, jsonb)`; `:162` `outbox_claim`, whose
  `not_before <= now()` predicate is the whole mechanism this story leans on.
- `supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql:68` — the current
  4-argument `outbox_enqueue` with `p_channel`, and at `:110` the drop-and-recreate of
  `outbox_claim` that is the precedent for changing one of these signatures. `:390` — the comment
  explaining why `:55` was chosen, i.e. the minute-offset convention stated out loud.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:677` — `enqueue_gate_reminders()`,
  the enqueuer to mirror: per-doer loop, `continue when` guards, `outbox_enqueue` at `:903`, dedupe
  `gate-<owner>-<day>-<slot>` at `:905`. `:39` `day_ends_at`, `:55` `day_begins_at`, `:216`
  `due_time_as_of`. Note `:875`: the gate excludes timed commitments on the **live** `due_time`.
- `supabase/migrations/20260822090000_weekly_quota_reminder_slack_is_the_trigger.sql:29` — the
  closest shape: a per-commitment reminder with a composite dedupe key, and `continue when not
  push_body_is_sendable(body)` rather than an exception, because Story 3.2's review found a raised
  exception rolls back every row enqueued earlier in the same pass. `:109` its `cron.schedule`.
- `supabase/migrations/20260820101000_outbox_body_rule_where_it_runs.sql:18` —
  `push_body_is_sendable`: non-blank, must carry `HH:MM` or a weekday, must not say "right now",
  "just now", "currently" or "at the moment".
- `supabase/migrations/20260828130000_a_commitment_can_carry_a_time.sql:12` — `due_time`,
  `late_window_minutes`, and the constraints that make the window resolvable: whole minutes (`:44`)
  and never crossing midnight (`:62`).
- `supabase/migrations/20260830090000_today_shows_where_the_window_stands.sql:24` —
  `timed_claim_today`: knows *timed and unclaimed*, carries neither window column and reads no
  clock. Not a source for this story; named so the next reader does not assume it is.
- `supabase/tests/5-2-the-app-notices-i-have-gone-quiet.sql:129`,
  `supabase/tests/6-4-midnight-decides-the-day.sql:479` — the "move the fixture, not the clock"
  idiom, and `:490` reading `outbox` back by `dedupe_key like` + body substring. There is no
  time-freezing helper in this suite and none is added.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:216` — `due_time_as_of()` and
  the comment at `:257` that decides this story's shape: a `due_time` changed part-way through a day
  "governed neither the window that had already passed nor a full day", so the function returns null
  and `commitments_owing()` / `settle_day()` judge that day untimed. A commitment's own creation
  entry is excepted, which is why an INSERT governs its own day and an UPDATE does not.
- `supabase/tests/3-2-focus-prompt.sql:324`, `supabase/tests/3-5-weekly-quota-reminder.sql:263` — the
  poisoned-name fixture both enqueue passes already carry: a commitment whose name defeats
  `push_body_is_sendable` must queue nothing and must not take the rest of the pass down with it.
- `supabase/tests/2-1-roles-and-rls.sql:463` — `commitment_log_due_time_change()` in the
  deciding-function list: a trigger function of exactly this story's shape, already listed. Every
  function this story adds, its trigger function included, belongs there and the count moves with it.
- `supabase/functions/outbox-worker/index.ts:55` — `outbox_claim`, `BATCH = 10`. Read-only here.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql` — drop and
      recreate `public.outbox_enqueue` with a fifth argument `p_not_before timestamptz default
      now()`, passed through to the insert. Drop-and-recreate, not `create or replace`: a second
      overload would make every existing 3- and 4-argument call ambiguous. All 30 existing call
      sites keep their behaviour through the default. **Re-issue `revoke execute ... from public,
      anon, authenticated` on the new signature, and give it back its `comment on function`.**
      `drop function` destroys the ACL `20260826100000:91` established, and a bare `create` hands
      `EXECUTE` back to `PUBLIC` — `/rest/v1/rpc/outbox_enqueue` open to any signed-in account, able
      to queue a push against any `owner_id`. `2-1-roles-and-rls.sql`'s existing
      `has_function_privilege` loop does catch this on the local stack, where a function created in
      `public` comes out `{=X/postgres,...,anon=X/postgres,authenticated=X/postgres,...}`. State the
      revoke as a task anyway: it is the invariant, not the test, that has to hold.
- [x] same migration — `public.due_time_instant(p_day date, p_due_time time) returns timestamptz`,
      resolving the wall-clock time against `Asia/Ho_Chi_Minh` by constructing the local timestamp
      and converting, never by adding an interval to a `timestamptz`. `stable`, revoked.
- [x] same migration — `public.enqueue_due_time_reminder(p_commitment_id uuid, p_day date) returns
      boolean`, taking a third argument `p_now timestamptz default now()`: the single-commitment
      enqueue, and the only place any of these rules live. Every comparison against the present
      reads `p_now`, never `now()`. This seam exists because three loops failed to pin the tomorrow
      branch without it: tomorrow's earliest instant is inside a ninety-minute lookahead only after
      22:30 local, so a behavioural assertion is a tautology for most of the day, and the `prosrc`
      substring that stood in for one is defeated by any edit that keeps the text — a reviewer
      replaced the branch with `case when true then today else today + 1 end` and every file stayed
      green. A defaulted parameter is not a frozen clock: production never passes it, and the suite
      can move the fixture's present the way it already moves every other fixture. It owns
      the lookahead: an instant outside `[now(), now() + interval '90 minutes')` is refused here, so
      every caller obeys one bound instead of the pass obeying it and the triggers not. It reads
      `due_time_as_of(p_commitment_id, p_day)` **once** and builds the instant, the shut time and
      the body from that one value — the day's governing time decides the refusal and the copy
      together, or the reminder can announce a time the day is not judged by. It refuses a day that
      function judges untimed, and refuses an owner whose `profile.role` is not `doer` — the pass filters
      on that and the triggers do not, which is one rule with two answers. Refuses unless the
      commitment is unarchived and timed, its instant for `p_day` is still in the future, and no `declaration` exists for
      `(commitment_id, p_day)`. Dedupe key `due-<commitment_id>-<p_day>`; `not_before` the instant;
      title the window's opening time as `HH24:MI`; body naming the commitment and the hour the
      window shuts, and asserting a failed
      day **only** for cadence `daily` — a `weekly_quota` day is judged at week close and cannot fail
      for a missing photo, so its copy says what the photo is worth instead. Both cadences get an
      explicit `when` arm and anything else returns false rather than inheriting either sentence: a
      cadence added later must show up as a silent commitment, not as copy that guesses. Returns false rather
      than raising for every refusal, `push_body_is_sendable` included: one caller is a trigger
      inside the author's own write, the other a pass whose earlier rows would roll back with it.
- [x] same migration — `public.enqueue_due_time_reminders(p_now timestamptz default now())
      returns integer`, passing `p_now` through to every chokepoint call: for every timed,
      unarchived commitment of every doer, resolve its instant for **both today and tomorrow**
      local, and call the single-commitment function for each — the bound now lives there, so this
      loop states which days exist, not which are near. Both dates because a `due_time` of `00:10`
      is otherwise unreachable: the run before it resolves the previous local date. Each call is
      wrapped so one commitment's failure cannot roll back the rows already queued in the same pass.
      Every such handler — here and in all three triggers — must `raise warning` naming the
      commitment, the day and `sqlerrm` before swallowing. Silence is the failure mode that matters:
      the cron job discards this function's return value, so a pass that queues nothing every hour
      because of a systemic error looks exactly like a healthy one. Revoked from
      `public, anon, authenticated`.
- [x] same migration — `cron.schedule('due-time-reminders', '50 * * * *', ...)`, with the comment
      naming the taken minutes and why `:50` is free. Ninety minutes of lookahead against an hourly
      run is deliberate overlap: the unique dedupe key makes a repeat free, and a slow or missed run
      self-heals on the next one.
- [x] same migration — `public.cancel_due_time_reminders(p_commitment_id uuid, p_day date default
      null)`: delete the not-yet-sent outbox row for that commitment on `p_day`, or on both today
      and tomorrow when no day is named. One function, because the same deletion is wanted from
      several places. The row is deletable while the worker does not hold it: `outbox_claim()` keeps
      `status = 'pending'` and pushes `not_before` a minute out, so `claimed_at is null` alone would
      make a row whose worker died uncancellable forever — the exact stale send this story exists to
      prevent. Key it on not-yet-sent and not-currently-held instead.
- [x] same migration — `public.commitment_due_time_written()`, `security definer`, on
      `public.commitment`, branching on `TG_OP`. On **INSERT** carrying a `due_time`, offer today
      *and tomorrow*: the row's own creation entry is the one `due_time_as_of()` excepts, so a
      commitment created at 20:15 for 20:40 genuinely owns that window and the 19:50 pass could not
      have seen it — and one created at 23:51 for `00:10` owns tomorrow's, which no pass reaches in
      time either. The chokepoint's bound keeps a window fourteen hours out from being queued now.
      On **UPDATE**, cancel, then re-offer **both days** and let the chokepoint decide, exactly as
      every other caller does. Do not special-case today here. When the write moved or cleared
      `due_time`, `due_time_as_of(today)` returns null and the chokepoint refuses today by itself —
      that is the mechanism, and restating it in the caller is what breaks it. A rename, a widened
      `late_window_minutes` or an unarchive writes no `commitment_due_time_change` row, so today is
      still governed; cancelling without re-offering loses that day's reminder outright whenever the
      window opens before the next `:50` pass.
      The UPDATE arm fires on any write that can invalidate a queued row, not only a moved time:
      `update of due_time, late_window_minutes, name, cadence, archived_at`, guarded so an
      unchanged resubmission of every column does not cancel a correct row. `cadence` belongs there
      because the body's second sentence is built from it: a `daily → weekly_quota` change leaves a
      queued push asserting a failed day the week will never charge. It must fire when `due_time` is
      set to null, so it cannot be guarded on `new.due_time is not null`. A rename or a widened
      window leaves a queued body naming facts that no longer hold; an archive leaves a push for a
      commitment the author has just deleted. It returns null and can never fail the author's
      write — the delete included, not only the enqueues.
- [x] same migration — an `after insert on public.declaration` trigger cancelling **only the day
      the declaration names**, `new.for_day`, never both days for that commitment. The chokepoint
      already refuses a day that carries a declaration; deferral is what lets a row outlive that
      rule, and this is the commonest way it happens — he claims at 20:00 for a window that opens at
      20:30. Cancelling both days is wrong in both directions: a claim filed for today at 23:56
      would delete a queued `00:10` reminder for tomorrow that nothing can re-queue in time, and a
      machine-filed or backdated declaration for an earlier day would delete today's still-valid
      one.
- [x] `supabase/tests/6-6-the-reminder-lands-inside-the-window.sql` — following the suite's
      conventions: one rolled-back transaction, fixtures moved instead of the clock. Set a
      fixture's `due_time` to a whole minute a few minutes ahead of the real local clock and assert
      the row's `not_before` equals that instant; assert the same commitment enqueues once, not
      twice, across two runs; assert a claimed day, an untimed commitment and an archived one
      enqueue nothing. Assert each arm of the trigger separately and unconditionally — an INSERT
      queues its own day; an UPDATE deletes what was queued and re-offers both days, the chokepoint deciding which survives — so that
      narrowing the trigger to `after insert` alone, or dropping the delete, turns the file red. A
      poisoned name queues nothing, raises nothing, and does not stop a benign commitment enqueued in
      the same pass. A `weekly_quota` body does not claim the day fails. `outbox_claim()` itself is
      called: a row whose `not_before` is ahead is not returned, one whose instant has passed is —
      the story's mechanism asserted rather than inferred from a column. Assert the row's `owner_id`
      and `channel`, using a second account as `6-5` does. Assert both edges of the lookahead, so
      narrowing or widening it turns the file red. Assert an open `silence_episode` does not
      suppress it, the way `5-2:155` pins the gate's opposite behaviour. Assert cancellation on a
      rename, on an archive and on a declaration filed after the row was queued. No assertion may
      reduce to a tautology depending on the hour the suite runs, and **the file must never `raise`
      because of the wall clock**: every file here runs on every push under `ON_ERROR_STOP=1`, so a
      refused precondition is a red build, not a skip. Loop 2 tried to satisfy this by nudging
      fixture times and still went red between 23:40 and midnight, because assertions were keyed on
      *today* while a fixture twenty minutes ahead had already rolled onto tomorrow. Key every
      assertion on the date its own fixture resolved to, rather than assuming today.
      Three things must be pinned behaviourally, not by reading source and not by luck of the hour.
      **The production path.** Every write the app really makes — the commitment insert, the edit,
      the archive, the declaration — must be exercised as `authenticated`, using the
      `set_config('request.jwt.claims', ...)` / `set_config('role', 'authenticated')` idiom at
      `6-5:86`, and asserted to queue or cancel the row. Loop 3 wrote every fixture as `postgres`;
      a reviewer then dropped `security definer` from the chokepoint and both trigger functions and
      all 40 files stayed green, while a commitment inserted as `authenticated` queued nothing —
      the permission error went into a `when others then null` and vanished. That mutation must
      turn this file red.
      **The tomorrow branch.** Pass a `p_now` late enough in the local day that tomorrow's window
      falls inside the lookahead, and assert the `due-<id>-<tomorrow>` key exists. Any mutation that
      stops tomorrow being offered — deleting it, or short-circuiting it while leaving the text —
      must turn the file red at any hour. Do not assert on `pg_proc.prosrc`.
      **Both halves of the cancel guard.** A row already claimed by `outbox_claim()` survives, and
      so does one already marked `sent` — dropping either half must turn the file red. Deleting a
      `sent` row frees the dedupe key that enforces one reminder per commitment-day and destroys
      the record that the push went out.
- [x] `supabase/tests/6-6-the-reminder-lands-inside-the-window.sql` — assert `cron.job` holds
      `('due-time-reminders', '50 * * * *')`. Nothing in this repo reads `cron.job`, so the wiring
      between every pass and the clock is prose; here it is the whole outcome of the story, and
      dropping the `cron.schedule` call leaves `db reset` and all 36 files green while no reminder
      is ever enqueued in production.
- [x] `supabase/tests/2-1-roles-and-rls.sql` — add every new internal function to the list nothing
      client-side may execute, the trigger functions included, and move the count with them.
      `outbox_enqueue`'s entry must be re-spelled: its old signature no longer exists. Add one
      assertion the existing idiom cannot make: that each of these functions carries a non-null
      `proacl` naming no `PUBLIC`, `anon` or `authenticated` grant. `has_function_privilege` reads
      true on a function whose `proacl` is null, because a null ACL means `acldefault()`, which is
      `EXECUTE` to `PUBLIC`. So the existing loop already catches a dropped revoke; read the ACL
      anyway, because it states the invariant rather than inferring it, and because it can assert
      the other direction — that `postgres` and `service_role` still hold `EXECUTE`, so an
      over-broad revoke cannot pass while killing every cron job and both workers. **Scope the new
      ACL loop to the functions this story adds or re-creates.** Applying it to all thirty-one
      would make any red read as a 6.6 regression and would bind two dozen untouched functions to
      whatever default privileges the running stack happens to have. Add
      `public.outbox_claim(integer, outbox_channel)` to the existing list while it is open: it is
      what this story's mechanism rests on, it can read any account's outbox, and it has never been
      listed.

**Acceptance Criteria:**
- Given a timed commitment whose window opens later today, when the hourly job has run, then a
  single `pending` outbox row exists whose `not_before` is the instant that window opens.
- Given that row, when the outbox worker's next minute arrives at or after that instant, then it is
  delivered — and never before it.
- Given an author with an open silence episode, when his window is about to open, then the reminder
  is still enqueued.
- Given a commitment created today already carrying a time, when nothing else runs, then its reminder
  is queued by the write itself.
- Given an existing commitment whose time is changed or cleared during the day, when the change is
  saved, then no reminder for today survives or appears, and tomorrow's names the new time.
- Given any account with no timed commitments, when every schedule has run, then the outbox holds
  exactly what it held before this story.

## Spec Change Log

### 2026-09-03 — review loop 1 (intent_gap, resolved by hwt75)

**Triggering finding.** The trigger — the mechanism this story added to close the "time set at 20:15
for 20:40" gap — announced a consequence that will not happen. `due_time_as_of()` returns null when a
`due_time` is written part-way through a day, so `commitments_owing()` and `settle_day()` judge that
day **untimed** and it reverts to the morning gate. The queued push nonetheless said "A photo today
or the day fails." Separately, a `weekly_quota` day carries no daily verdict at all, and a changed
`due_time` left the abandoned reminder queued under a dedupe key that could not distinguish it.

**Amended.** The frozen Boundaries now forbid asserting a consequence a day cannot carry and forbid
leaving a queued reminder standing after its window moves. The matrix replaces the
accepted-staleness row with explicit cancellation and gains rows for a mid-day change, a mid-day
clear, a `weekly_quota` commitment and an unsendable name. The trigger splits by `TG_OP`: INSERT
owns its own day, UPDATE cancels and re-offers tomorrow only.

**Known-bad state avoided.** A push arriving at 20:40 telling the author his day fails without a
photo, on a day that cannot fail for a missing photo and whose money is decided by a different rule
entirely.

**KEEP.** These survived review and must survive re-derivation: the `not_before` mechanism and the
hourly `:50` schedule; `due_time_instant()` computing on the local timestamp rather than `time`
arithmetic, and `shuts_at` doing the same so a window ending at midnight reads `00:00`; the
dual-date lookahead in the pass; the half-open `[now(), now() + 90 minutes)` bound and its stated
reason; `sent_at` stamped with the delivery instant rather than the queue time, with its comment;
returning false rather than raising for every refusal; and the drop-and-recreate of
`outbox_enqueue` with the reason it is not a `create or replace`.

### 2026-09-03 — review loop 2 (bad_spec)

**Withdrawn finding, recorded so it is not re-litigated.** This loop was opened partly on a claimed
security hole — that the recreate of `outbox_enqueue` had lost its `revoke`. It had not: the revoke
was present, wrapped across three lines, and a single-line grep missed it. The live `proacl` cited as
confirmation was the *existing* revoke from `20260826100000`, not evidence of a new hole. The premise
attached to it was also false: on this local stack a function created in `public` with no revoke
comes out `anon=X/postgres`, so `has_function_privilege` reads true and
`2-1-roles-and-rls.sql` would have turned red. The revoke is stated as a task and the `proacl`
assertion kept as defence-in-depth, but neither rests on that reasoning.

**Triggering findings.** Four, all from one root: the spec put the ninety-minute bound in the pass
rather than in the chokepoint, so the triggers queued rows fourteen and twenty-four hours ahead while every comment
claimed ninety minutes; the INSERT arm offered only today, leaving a commitment created at 23:51 for
`00:10` reachable by nothing; cancellation keyed only on a moved `due_time`, so a rename, a widened
window, an archive, or a declaration filed after enqueue all left a queued row asserting facts that
no longer held; and the refusal read `due_time_as_of()` while the body read the live column.

**Amended.** The bound and the governing-time read both move into `enqueue_due_time_reminder()`, so
one place decides and every caller obeys. Both trigger arms offer both days. Cancellation becomes
its own function, fired by the four commitment columns that can invalidate a row and by a filed
declaration. The revoke is stated as a task, and `2-1` gains an ACL assertion the local stack cannot
fake.

**Known-bad state avoided.** Comments throughout the migration promising a ninety-minute deferral
while two of the three callers queued rows fourteen and twenty-four hours out, against a
cancellation rule narrow enough that a rename, an archive or a filed claim left them standing.

**KEEP.** Everything the loop-1 entry lists, plus what this loop got right: the `TG_OP` split with
INSERT owning its own day; both triggers written as two objects because a `when` clause referencing
`old` is illegal on an INSERT trigger; the guard that an unchanged resubmission must not cancel a
correct row; the trigger-firing-order note about `due_time_as_of()` reading what
`commitment_log_due_time_change_on_insert` writes; and refusing a day `due_time_as_of()` judges
untimed, which the loop-1 tasks did not name and the implementation added on its own.

### 2026-09-03 — review loop 3 (bad_spec)

**Triggering findings.** Two correctness defects, both written into the loop-2 tasks by hand.

The UPDATE arm was told to cancel and re-offer *tomorrow only*. That reasoning holds for a moved
`due_time` and for nothing else the trigger now fires on: a rename, a widened `late_window_minutes`
or an unarchive writes no `commitment_due_time_change` row, so today stays governed — and the arm
deleted today's queued row without replacing it. A rename at 20:00 against a window opening at 20:30
lost the reminder outright, because the 20:50 pass then refuses the day for `instant < now()`. Loop
2's own principle — callers name a commitment and a day, never whether — was the fix, and the task
text was what violated it.

The declaration trigger was told to cancel by commitment, with no day. It therefore deleted both
days: a claim filed for today at 23:56 removed a queued `00:10` reminder for tomorrow that nothing
could re-queue in time, and a machine-filed or backdated declaration for an earlier day removed
today's still-valid one.

**Amended.** UPDATE re-offers both days and the chokepoint decides. `cancel_due_time_reminders`
takes a day, and the declaration trigger passes `new.for_day`. The cancel's guard moves off
`claimed_at is null`, which would have made a row whose worker died uncancellable. The chokepoint
also absorbs the `role = 'doer'` filter the pass had and the triggers did not. The title stops
asserting the present tense. The test task now demands the tomorrow branch and the claimed-row guard
be pinned deterministically, and says why loop 2's hour-independence attempt still went red.

**Known-bad state avoided.** A rename silently costing the author the reminder for a window still
half an hour away, and a claim filed late at night silently costing him the next morning's.

**KEEP.** Everything the loop-1 and loop-2 entries list, plus what loop 2 got right: the chokepoint
owning the bound and one `due_time_as_of()` read; explicit `daily` / `weekly_quota` copy arms with a
refusal for anything else; both trigger arms offering both days; the `when` guard that an unchanged
resubmission cancels nothing; the trigger names sorting after `commitment_log_due_time_change_*`;
per-commitment subtransactions in the pass; and the mutation-testing habit the loop-2 implementation
adopted on its own — every guard removed in turn to prove the file goes red.

### 2026-09-03 — review loop 4 (bad_spec)

**Triggering findings.** A reviewer ran mutations against the local stack rather than reading, and
two of them exposed verification the previous loops believed they had.

Dropping `security definer` from the chokepoint and both commitment trigger functions left all forty
test files green, while a commitment inserted as `authenticated` — the only way the app ever writes
one — queued nothing: the permission error landed in a `when others then null` and disappeared. Every
fixture in loop 3's file wrote as `postgres`, the trigger functions' own owner, so the suite could
not tell a working privilege chain from a dead one.

Replacing `today + 1` with `case when true then today else today + 1 end` also left every file green.
Loop 3 had pinned that branch with a `prosrc` substring match, which the spec had implicitly licensed
by demanding a red on deletion; a substring survives any edit that keeps the text.

Three smaller ones: `cadence` was missing from the UPDATE trigger's column list, though the body's
second sentence is built from it; the `status = 'pending'` half of the cancel guard was unverified in
both directions, and dropping it deletes the `sent` row that both records the delivery and holds the
dedupe key; and four `when others then null` handlers swallow everything without a `raise warning`,
while the cron job discards the pass's return count — a systemic failure produces no row, no error
and no counter.

**Amended.** The chokepoint and the pass take `p_now timestamptz default now()` so the tomorrow
branch can be asserted behaviourally at any hour — a defaulted parameter, not a frozen clock;
production never passes it. The test task now requires the real `authenticated` path, both halves of
the cancel guard, and forbids `prosrc` assertions. `cadence` joins the trigger's column list. Every
swallowing handler must warn first. The new ACL loop is scoped to the functions this story touches.

**Known-bad state avoided.** A feature that is silently dead for every commitment the author creates
or edits, with a green suite and no error anywhere.

**KEEP.** Everything the loop-1 through loop-3 entries list, plus what loop 3 got right: the cancel
sparing a row a live worker holds while still reaching one whose worker died; the declaration trigger
cancelling `new.for_day` only; UPDATE re-offering both days and letting the chokepoint decide; the
`HH24:MI` title; the fixture helpers verified across all 1440 minutes of a day; and the practice of
mutating each guard in turn to prove the file goes red — which is what found these, and which must be
run against the `authenticated` path this time, not only against `postgres`.

## Design Notes

**Why `not_before` and not a per-minute job.** A `* * * * *` enqueuer is the obvious answer and the
wrong one: it collides with the outbox worker on every minute, and it re-derives, sixty times an
hour, an answer that does not change. The outbox already separates *what to send* from *when to
send it*; this story is the first caller to use the second half. The precision the author sees is
the worker's minute — the reminder lands at the due minute or the one after it, inside every legal
window, the narrowest of which is five minutes.

**Why a queued reminder is cancelled rather than allowed to go stale.** A row now sits in the outbox
for up to ninety minutes, which no previous caller did — every other enqueuer wrote a row meant to go
out on the next worker minute. Deferral makes the row outlive the facts it was built from, so the one
write that can invalidate it cancels it. Deleting a `pending`, unclaimed row is safe and needs no
change to `outbox_claim()`, which is what re-checking at claim time would have cost: a predicate
serving one kind, evaluated for all of them.

**A defaulted `p_now`, and why it is not a frozen clock.** This suite moves fixtures, never the
clock, and that convention is right: a frozen clock hides the boundary conditions that matter. But
two branches here are unreachable by moving a fixture — tomorrow's window is inside a ninety-minute
lookahead only after 22:30 local — and three loops in a row failed to pin them, the last one with a
source-text match that a reviewer defeated in one edit. A parameter that defaults to `now()` is a
different thing from a clock the test controls globally: production calls the function with no
argument and reads the real clock, and the only caller that passes one is the file proving the branch
exists. `settle_day(p_day, p_override)` already carries a parameter that exists for testing, guarded
by `is_live_doer`.

**One chokepoint, one bound.** Every refusal this story makes lives in
`enqueue_due_time_reminder()`: the lookahead, the governing time, the claimed day, the archived
commitment, the unsendable body. Callers say which commitment and which day; they never say whether.
Loop 2 existed because the bound sat in the pass instead — the triggers were callers that did not
know about it, and the code's own comments described a ninety-minute deferral the triggers did not
honour.

**Why UPDATE re-offers today rather than refusing it.** Story 6.4 froze the rule that a time written
mid-day governs neither the window already passed nor a whole day, so that day is judged untimed and
answered by the morning gate. It is tempting to encode that in the trigger by skipping today. Do not:
`due_time_as_of()` already returns null in exactly that case, and the trigger fires on three other
columns for which today is still perfectly governed. Offer both days and let the one function that
knows the rule apply it — a caller that repeats the rule is a caller that will get it wrong for the
cases it was not thinking about.

**Body copy.** Title `Now`. For a `daily` commitment, `Thuốc — window open until 21:00. A photo
today or the day fails.` For a `weekly_quota` one, the second sentence says what the photo is worth
rather than what it prevents — its day is judged at week close and cannot fail for a missing photo,
so the daily sentence would be a lie about money. The hour is what makes either body pass
`push_body_is_sendable`, and it is the useful half: he knows what he is looking at and how long he
has.

## Verification

**Commands:**
- `npx supabase db reset` then every file under `supabase/tests/` — expected: 36 pass, 0 fail,
  including the new file.
- `npm test` — expected: 1191 tests still pass; this story adds no client code.
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check` — expected: clean.
- `select jobname, schedule from cron.job order by jobname;` — expected: ten jobs, the new
  `due-time-reminders` at `50 * * * *`, no existing schedule altered.
- `npm run migrations:check` — expected: the new migration reported as not yet pushed.

## Suggested Review Order

**How a reminder gets its hour**

- The entry point: one function holds every rule, and callers name a commitment and a day.
  [`20260903090000:158`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L158)

- The bound that keeps a deferred row from outliving its facts, half-open at both ends.
  [`20260903090000:222`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L222)

- The one read of the governing time — the refusal and the copy come from the same value.
  [`20260903090000:107`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L107)

- Cadence decides what the day costs, and an unknown cadence says nothing at all.
  [`20260903090000:250`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L250)

**Delivery without a per-minute job**

- The column that already existed for a deferred send, and its first caller.
  [`20260903090000:60`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L60)

- Dropped and recreated, so the revoke has to be re-issued by hand.
  [`20260903090000:90`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L90)

- `:50` is the free minute; the comment names every taken one.
  [`20260903090000:441`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L441)

**Everything that can invalidate a queued row**

- Both days, in one place, so a trigger and the pass cannot disagree.
  [`20260903090000:326`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L326)

- Spares a row a live worker holds; still reaches one whose worker died.
  [`20260903090000:466`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L466)

- INSERT owns its own day; UPDATE cancels and re-offers both, deciding nothing itself.
  [`20260903090000:546`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L546)

- Five columns, because the body is built from all five.
  [`20260903090000:603`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L603)

- A filed claim cancels the day it names, never both.
  [`20260903090000:629`](../../supabase/migrations/20260903090000_the_reminder_lands_inside_the_window.sql#L629)

**Proof**

- The mechanism itself: the row is invisible to `outbox_claim()` until its instant.
  [`6-6:418`](../../supabase/tests/6-6-the-reminder-lands-inside-the-window.sql#L418)

- The tomorrow branch, pinned at any hour — this is what `p_now` exists for.
  [`6-6:503`](../../supabase/tests/6-6-the-reminder-lands-inside-the-window.sql#L503)

- The app's own path, as `authenticated`; the file grants nothing to make it work.
  [`6-6:580`](../../supabase/tests/6-6-the-reminder-lands-inside-the-window.sql#L580)

- Clearing the time takes the reminder with it — the trap the trigger's guard is written around.
  [`6-6:734`](../../supabase/tests/6-6-the-reminder-lands-inside-the-window.sql#L734)

- A day made untimed mid-day is refused by the chokepoint, not by the caller.
  [`6-6:792`](../../supabase/tests/6-6-the-reminder-lands-inside-the-window.sql#L792)

- Both halves of the cancel guard, each red on its own removal.
  [`6-6:893`](../../supabase/tests/6-6-the-reminder-lands-inside-the-window.sql#L893)

**Peripheral**

- Every new function out of reach of a client, with its ACL and `search_path` stated.
  [`2-1-roles-and-rls:486`](../../supabase/tests/2-1-roles-and-rls.sql#L486)

## Done checkpoint — what hwt75 has to check on a real device

Nothing above proves the half this story exists for. The suite drives `enqueue_due_time_reminders()`
by hand and asserts a row's `not_before`; it never waits for a minute to arrive, never wakes the
worker, and never puts anything on a lock screen. What needs a phone:

1. Set a time on a commitment for a few minutes ahead and put the phone down, screen locked. The
   push must arrive at that minute or the one after it — not at `:05` past the next hour, which is
   what happened before this story.
2. Read what it says. The title is the hour the window opens; the body names the commitment and the
   hour it shuts. Neither should claim anything about a day it cannot decide.
3. Create a commitment carrying a time later today, without waiting for `:50`. The reminder must
   still arrive — that is the INSERT trigger, and it is the half no schedule can cover.
4. Change that time, or rename the commitment, before the window opens. Exactly one push must
   arrive, naming the new time or the new name — never two, and never the old one.
5. Claim the day before its window opens. No push for it should arrive at all.

Worth knowing before testing: delivery is the outbox worker's minute, so a reminder lands at its
instant or up to a minute later. `npx supabase db push` has not been run — none of this works
against the live project until it has.
