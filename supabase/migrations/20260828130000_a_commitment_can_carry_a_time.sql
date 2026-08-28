-- Story 6.1 — a commitment can name a time of day, and a window after it.
--
-- Until now every commitment was judged by one question asked the next morning. That works for
-- "did you go to the gym at all" and says nothing about "take the pill at 20:00". These two
-- columns are what let a commitment carry a moment; nothing here files a claim, uploads a photo,
-- reminds anyone or closes a day (Stories 6.2 through 6.6).
--
-- Configuration only, like every other column on this table. Derived state has exactly one
-- writer and it is settlement (AD-8).

alter table public.commitment
  add column due_time time,
  add column late_window_minutes integer;

comment on column public.commitment.due_time is
  'AD-6: a wall-clock time of day in Asia/Ho_Chi_Minh, never an instant. Deliberately not '
  'named due_at -- every _at column in this schema is a timestamptz, and `now() >= due_at` '
  'would be a bug that compiles. Null on an untimed commitment, which behaves exactly as '
  'every commitment did before this migration.';

comment on column public.commitment.late_window_minutes is
  'Minutes after due_time during which the commitment still counts as met. Never called a '
  'grace period: Grace Day already names a countable forgiveness token in this product '
  '(20260825110000_a_countable_way_to_be_forgiven.sql, two per calendar month), and two '
  'meanings for one word in a codebase that decides money is how the wrong one gets read.';

-- A time without a window is a half-filled form, and a window without a time is a number
-- nothing reads. Biconditional for the same reason `commitment_weekly_quota_targets` is one.
alter table public.commitment
  add constraint commitment_time_and_window_together
    check ((due_time is null) = (late_window_minutes is null));

-- Below five minutes the window cannot be hit by a human interaction; beyond four hours a
-- "time of day" has stopped naming one. Zero is refused rather than allowed and discouraged:
-- a window of zero requires landing on an exact second and would read as a bug every time it
-- fired.
alter table public.commitment
  add constraint commitment_late_window_range
    check (late_window_minutes is null or late_window_minutes between 5 and 240);

-- Whole minutes only, so the check below is exact rather than approximately exact. Without
-- this, 23:55:30 with a five-minute window compares as 1440 and is accepted, while the window
-- it describes actually ends half a minute into the next day.
alter table public.commitment
  add constraint commitment_due_time_whole_minute
    check (due_time is null or extract(second from due_time) = 0);

-- The window may not cross midnight.
--
-- Written on extracted minutes and NOT as `due_time + make_interval(mins => ...)`, because
-- Postgres time arithmetic wraps: `time '23:30' + interval '60 minutes'` is `00:30`, not
-- `24:30`. A constraint written the obvious way would silently accept exactly the case it
-- exists to refuse.
--
-- `<= 1440` and not `< 1440`: the window is half-open, so one ending at exactly 24:00:00 is
-- still inside its own day -- its last valid instant is 23:59:59.999.
--
-- The rule exists because of the evidence trigger, not for its own sake. A window crossing
-- midnight would produce a photo captured on D+1 proving a day D, and
-- appeal_evidence_derive_owner() (20260827100000_evidence_must_be_dated_the_day_it_proves.sql)
-- refuses that. The trigger is correct; this is the cheaper place to make the case impossible.
alter table public.commitment
  add constraint commitment_window_within_the_day
    check (
      due_time is null
      or (extract(hour from due_time) * 60
          + extract(minute from due_time)
          + late_window_minutes) <= 1440
    );

-- Some commitments have no moment to name.
--
-- An abstention is a thing not done: there is no instant of doing it, and nothing to
-- photograph at that instant. An Hours-per-day commitment is judged against banked Focus
-- Session minutes rather than a declaration at all (FR-2; `commitments_owing()` excludes it
-- entirely, 20260820140000_weekly_quota_is_not_judged_daily.sql), so a due time would name a
-- moment nothing would ever read.
--
-- This deliberately does NOT reuse the predicate behind `commitment_auto_check_not_on_abstain`
-- and `commitment_auto_check_not_on_hours_quota`, which exclude the same two cases for
-- unrelated reasons -- those are about whether a *sensor* exists, this is about whether a
-- *moment* exists. The match is a coincidence, and a shared rule would couple two things that
-- will not change together.
alter table public.commitment
  add constraint commitment_time_needs_a_moment
    check (
      due_time is null
      or (kind <> 'abstain' and cadence <> 'daily_hours_quota')
    );
