-- Week Close. The deadline a Weekly Quota commitment has never had.
--
-- 3.3 gave a Weekly Quota commitment a live position (`weekly_quota_progress`) and
-- 20260820140000 made sure it is never judged as a daily miss. Neither one ever closes the
-- week — a shortfall has produced no verdict and no penalty at all until now.
--
-- `settle_week()` mirrors `settle_day()`'s shape exactly (AD-2, AD-5, AD-16): one
-- `security definer` plpgsql pass per call, the `app.settlement_invocation` guard, the
-- AD-16 override refusal for `is_live_doer`, and `(subject, period, kind)` as the one
-- idempotency key. `settlement_kind` gains `'week'` rather than a new table.
--
-- **What is unlike `settle_day`.** A day can be `expired` because an answer can arrive
-- late; a week cannot — `weekly_held_count` only ever counts declarations that already
-- landed, and there is no per-week deadline this spec introduces. So `settle_week` never
-- gates on "answered vs owed" the way `settle_day` does; it gates on time alone — a week is
-- judged once its own last day's answer day has fully passed (`p_period + 8`, not `+ 7`;
-- see the guard below for why), and `day_verdict` is reused unchanged: `'expired'` is
-- simply never written for a `kind = 'week'` row.
--
-- **What settle_week deliberately does not write.** No `settlement_commitment` row —
-- per-commitment week-outcome freezing is not required by any AC here (recorded as a gap
-- in deferred-work.md alongside the missing week-level supersession pass). Held Penalty
-- resolution (AD-15) is also out of scope: `penalty_state` has only `'owed'` today.

-- `settlement_kind` gains 'week'. Nothing in this file uses the literal outside a plpgsql
-- function body (deferred to when that body actually runs, in its own later transaction),
-- mirroring 20260819240000_expiry.sql's own isolation of `alter type ... add value`.
alter type public.settlement_kind add value if not exists 'week';


-- ---------------------------------------------------------------------------------
-- The held-count rule, in one place (AD-8) — read live by `weekly_quota_progress` and,
-- frozen at a closed week, by `settle_week` below. Extracted verbatim from the lateral
-- subquery 20260820130000 wrote inline; the view is rewritten underneath to call it rather
-- than repeat it, so a week's declaration-counting logic is never two copies that could
-- drift apart the moment one of them is touched.
-- ---------------------------------------------------------------------------------

create function public.weekly_held_count(p_commitment_id uuid, p_week_start date)
returns integer
language sql
stable
set search_path = ''
as $$
  select count(*)::integer
    from public.declaration dec
   where dec.commitment_id = p_commitment_id
     and dec.answer = 'held'
     and dec.for_day >= p_week_start
     and dec.for_day < p_week_start + 7
$$;

comment on function public.weekly_held_count(uuid, date) is
  'How many days a commitment was declared held within the 7 days starting p_week_start. '
  'The one counting rule read by both weekly_quota_progress (live, today''s week) and '
  'settle_week (frozen, a closed week) — never two copies (AD-8).';

-- Same reasoning as `week_days_remaining`'s own grant comment: this runs under the
-- caller's own privileges inside `weekly_quota_progress` (security_invoker), so it needs a
-- grant of its own or every read of that view fails "permission denied" rather than an
-- RLS-empty result. `settle_week` reaches it as a security definer function owned by the
-- migration role, which is unaffected by this revoke.
revoke execute on function public.weekly_held_count(uuid, date) from public, anon;
grant execute on function public.weekly_held_count(uuid, date) to authenticated;

-- `weekly_quota_progress`, rewritten to call the shared function instead of inlining it.
-- Same columns, same `security_invoker`, same RLS-through-commitment-and-declaration
-- scoping — only the held count's own arithmetic moved.
create or replace view public.weekly_quota_progress
with (security_invoker = true)
as
with today as (
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date as d
),
weeks as (
  select c.id as commitment_id,
         c.owner_id,
         c.weekly_target as target,
         c.week_start_day,
         t.d as today,
         t.d - ((extract(isodow from t.d)::integer - c.week_start_day + 7) % 7) as week_start
    from public.commitment c
    cross join today t
   where c.cadence = 'weekly_quota'
     and c.archived_at is null
)
select w.owner_id,
       w.commitment_id,
       w.target,
       public.weekly_held_count(w.commitment_id, w.week_start) as held,
       public.week_days_remaining(w.today, w.week_start_day) as days_remaining
  from weeks w;

comment on view public.weekly_quota_progress is
  'Live position for every open Weekly Quota commitment: qualifying days held this week, the '
  'target, and days remaining (D1). Reads weekly_held_count (AD-8) — no client-side tally of '
  'raw declaration rows, and no inline copy of the counting rule settle_week also reads.';


-- ---------------------------------------------------------------------------------
-- The notification. Modeled on `day_summary_body`'s voice (self-dated, past tense, the
-- amount named once, never a list of what fell short), adjusted in one way Design Notes'
-- own literal example did not account for: `push_body_is_sendable` requires a body to
-- self-date with either a clock time or a named weekday, and a bare ISO date
-- ("week of 2026-08-17") satisfies neither — so the weekday is spelled out alongside it
-- ("week of Monday, 2026-08-17"), which is also the more honest self-dating of the two:
-- "week of <date>" names the week's first day, not the day the message was sent.
--
-- `held`/`target` are summed across every commitment judged this period rather than
-- picked from one — for the common case of one Weekly Quota commitment per week_start_day
-- this sum equals that commitment's own numbers exactly (matching the design's own "1 of
-- 3" and "3 of 3" examples); for two or more sharing a week_start_day it is the one
-- well-defined combined figure rather than an arbitrary pick. Naming follows `settle_day`'s
-- own single-suggestion rule: the one commitment that fell short is named only when exactly
-- one did; otherwise the sentence states the count and nothing more.
-- ---------------------------------------------------------------------------------

create function public.week_summary_body(
  p_held integer,
  p_target integer,
  p_period date,
  p_amount bigint,
  p_shortfall_count integer,
  p_shortfall_name text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select concat_ws(' ',
    case
      when p_shortfall_count = 1 then p_shortfall_name || ','
      when p_shortfall_count > 1 then p_shortfall_count::text || ' commitments fell short,'
    end,
    p_held::text || ' of ' || p_target::text,
    'held, week of ' || to_char(p_period, 'FMDay') || ', ' || to_char(p_period, 'YYYY-MM-DD') || '.',

    -- The amount, once. Null on a clean or penalty-free-only week, and concat_ws drops it.
    -- Dots, not commas: Vietnamese grouping, matching `formatDong` and `day_summary_body`'s
    -- own fix (20260819250100) — `G` follows the database's `lc_numeric`, which is exactly
    -- what made the two copies of this rule disagree once already.
    case when p_amount is not null
         then 'That''s ' || translate(to_char(p_amount, 'FM999G999G999'), ',', '.') || '₫.'
    end
  );
$$;

comment on function public.week_summary_body(integer, integer, date, bigint, integer, text) is
  'Week Close''s notification body. "week of <Weekday>, <date>" self-dates against '
  'push_body_is_sendable (a bare ISO date matches neither its clock-time nor weekday check).';

revoke execute on function public.week_summary_body(integer, integer, date, bigint, integer, text)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Settlement.
-- ---------------------------------------------------------------------------------

/* Closes every open Weekly Quota commitment whose own week starts on p_period, for every
   doer whose week has actually ended.

   One settlement row per (subject, period) — not per commitment — because every
   commitment sharing a week_start_day shares a period, and FR-13's rule (one penalty per
   Failed Week, however many commitments fell short) is mirrored exactly from
   `settle_day`'s own Failed Day rule. A commitment with a *different* week_start_day gets
   its own period and therefore its own settlement row (the matrix's own "two commitments,
   different week_start_day" case) — this is what makes `p_period` an argument rather than
   something derived once per account, exactly as `settle_day` takes `p_day` rather than
   deriving "today" itself. */
create function public.settle_week(p_period date, p_override boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  invocation text := coalesce(current_setting('app.settlement_invocation', true), '');
  today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  account record;
  quota record;
  total_commitments integer;
  held_sum integer;
  target_sum integer;
  shortfall_count integer;
  shortfall_name text;
  admitted integer;
  verdict public.day_verdict;
  inserted integer;
  new_settlement uuid;
  settled integer := 0;
begin
  if current_user in ('anon', 'authenticated') then
    raise exception 'settle_week is never callable from the application (AD-2)';
  end if;

  if invocation <> 'schedule' and not p_override then
    raise exception
      'settle_week ran outside its schedule with no override. Pass p_override => true, '
      'which is refused for the live doer account (AD-16).';
  end if;

  for account in select p.id, p.is_live_doer from public.profile p where p.role = 'doer' loop
    -- AD-16 is checked before anything else in the loop, unconditionally — including
    -- before the "week not over" skip below — so an override against the live doer
    -- account always raises rather than sometimes quietly returning 0, matching
    -- `settle_day`'s own guard being the first thing per account, every time.
    if p_override and account.is_live_doer then
      raise exception
        'settle_week refuses an override against the live doer account (AD-16). '
        'Only the schedule may settle it.';
    end if;

    -- A week is judged only once every day of it has passed *and* the last of those days
    -- has had its own chance to be declared. `for_day` is derived as `answered_at - 1`
    -- (AD-6, `declaration_derive_day`): a declaration made in the morning answers for
    -- yesterday, so the earliest a declaration for the week's last day (`p_period + 6`) can
    -- exist is `p_period + 7`. Gating on `today < p_period + 7` (one day short of this)
    -- would settle the week hours before that declaration could ever land, guaranteeing a
    -- `failed` verdict on any week whose target needs its last day — not a race, the
    -- mainline case. `p_period + 8` waits one full day past that, mirroring `settle_day`'s
    -- own refusal to decide a day before its deadline, with the calendar (AD-6) as the
    -- boundary rather than an answered-vs-owed count, because a week has no analogue of a
    -- late-arriving declaration reopening the question — it only needs to wait long enough
    -- for an on-time one to have already arrived.
    continue when today < p_period + 8;

    total_commitments := 0;
    held_sum := 0;
    target_sum := 0;
    shortfall_count := 0;
    shortfall_name := null;
    admitted := 0;

    -- Every open Weekly Quota commitment whose own week starts today's p_period — the
    -- same "archived_at is null" exclusion weekly_quota_progress applies (the matrix's
    -- "commitment archived mid-week" case), not the day-based cutoff commitments_owing
    -- uses for a Daily commitment, because a Weekly Quota commitment is never in that
    -- function's set at all (20260820140000).
    --
    -- The commitment has to have existed before the week's own last day rolled over
    -- (AD-6, Asia/Ho_Chi_Minh — the same conversion commitments_owing() uses for
    -- archived_at), or it never had a chance to be declared held for any day inside it.
    -- `settle_due_weeks()` sweeps a two-week-wide window of candidate periods every hour,
    -- so a commitment created today can otherwise share a week_start_day with an
    -- already-elapsed period purely by coincidence — `weekly_held_count` would correctly
    -- read 0 for it, which reads as a shortfall it never had the chance to meet, and a
    -- real penalty within the hour of adding it if carries_penalty is on.
    for quota in
      select c.id, c.name, c.carries_penalty, c.weekly_target,
             public.weekly_held_count(c.id, p_period) as held
        from public.commitment c
       where c.owner_id = account.id
         and c.cadence = 'weekly_quota'
         and c.archived_at is null
         and c.week_start_day = extract(isodow from p_period)::integer
         and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date < p_period + 7
    loop
      total_commitments := total_commitments + 1;
      held_sum := held_sum + quota.held;
      target_sum := target_sum + quota.weekly_target;

      if quota.held < quota.weekly_target then
        shortfall_count := shortfall_count + 1;
        shortfall_name := quota.name;

        if quota.carries_penalty then
          admitted := admitted + 1;
        end if;
      end if;
    end loop;

    -- Nothing owned this account's own week_start_day this period.
    continue when total_commitments = 0;

    -- A Failed Week costs exactly one penalty_amount_dong(), however many commitments
    -- fell short, and only a penalty-carrying shortfall triggers it at all — FR-13,
    -- mirrored: a penalty-free miss costs nothing (the matrix's own case).
    verdict := case when admitted > 0 then 'failed' else 'clean' end;

    -- `missed_count` mirrors `settle_day`'s own meaning exactly: `admitted`, the
    -- penalty-carrying shortfalls, not `shortfall_count`, which also carries a
    -- `carries_penalty = false` miss for the notification's own naming below. `settle_day`
    -- writes `admitted + silent` (both filtered to `carries_penalty`) for the identical
    -- reason — one column, one meaning, `failed <=> missed_count > 0` true for every row
    -- regardless of `kind`.
    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (account.id, p_period, 'week', verdict, admitted)
    on conflict (subject, period, kind) where supersedes is null do nothing
    returning id into new_settlement;

    get diagnostics inserted = row_count;
    settled := settled + inserted;

    -- AD-5: already settled, so nothing else below may run for this account/period —
    -- no second penalty, no second notification.
    continue when new_settlement is null;

    if admitted > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (account.id, new_settlement, public.penalty_amount_dong());
    end if;

    -- The verdict and its outbox notification, same transaction (AD-3).
    perform public.outbox_enqueue(
      account.id,
      'week-' || account.id::text || '-' || p_period::text,
      jsonb_build_object(
        'title', 'This week',
        'body', public.week_summary_body(
                  held_sum, target_sum, p_period,
                  case when admitted > 0 then public.penalty_amount_dong() end,
                  shortfall_count,
                  case when shortfall_count = 1 then shortfall_name end),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_week(date, boolean) from public, anon, authenticated;


/* `settle_due_days`'s own lookback-window shape, mirrored for weeks.

   A week can start on any of the 7 ISO weekdays (`week_start_day` is per-commitment, not
   per-account), so there is no single "yesterday" to settle the way a day has — instead
   there is exactly one candidate period per weekday that `settle_week`'s own `p_period + 8`
   guard now considers just-closed: the date exactly 8 days before today (one later than the
   `+ 7` week boundary itself, to clear the last day's own answer window — see that guard's
   comment). `today - 14` through `today - 8` covers all seven of those candidates in one
   pass. `settle_week` itself no-ops on a period whose week has not yet ended and is
   idempotent (AD-5) on one already settled, so re-checking this window every hour costs
   nothing and survives a cron pass that ran late — the same trade `settle_due_days`'s own
   wider-than-strictly-needed lookback already makes. */
create function public.settle_due_weeks()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  today date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  period_to_settle date;
  settled integer := 0;
begin
  perform set_config('app.settlement_invocation', 'schedule', true);

  for period_to_settle in
    select generate_series(today - 14, today - 8, interval '1 day')::date
  loop
    settled := settled + public.settle_week(period_to_settle);
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_due_weeks() from public, anon, authenticated;

-- Hourly, at :45 — the offset convention's one remaining slot (:05 gate reminders, :15
-- settlement, :25 focus prompts).
select cron.schedule(
  'settle-weeks',
  '45 * * * *',
  $$select public.settle_due_weeks()$$
);


-- ---------------------------------------------------------------------------------
-- The Ledger's own reads (`components/ledger.tsx`) must gain `kind = 'day'` before a week
-- row can exist, or a week row silently corrupts the existing day list the moment one
-- lands (stated as an "Always" boundary of this spec). `settlement_current` already
-- exposes `kind` directly (`select s.*`); `penalty_current` does not — it selects only
-- `p.*` from the penalty table, which has no kind or period column of its own. Both are
-- added here as plain columns so the client can filter and read them without depending on
-- PostgREST's resource-embedding-through-a-view behaviour for a column that determines
-- which list a row belongs to.
-- ---------------------------------------------------------------------------------

create or replace view public.penalty_current
with (security_invoker = true)
as
select p.*, s.kind, s.period
  from public.penalty p
  join public.settlement_current s on s.id = p.settlement_id;

comment on view public.penalty_current is
  'Penalties that still stand (AD-9). Carries kind and period from its settlement so a '
  'reader can tell a day''s penalty from a week''s without a second query.';
