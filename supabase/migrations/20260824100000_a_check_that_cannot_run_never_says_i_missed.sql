-- Story 4.2 — a check that cannot run never says I missed.
--
-- `resolve_auto_checks()` and `settle_day()`/`settle_week()` are independent hourly cron
-- jobs with no enforced ordering. If the Auto-check pass is delayed or fails, settlement
-- could judge a day or week before its attached Auto-check has ever run — settling an
-- Auto-check-linked commitment as a plain miss exactly like an author who simply never
-- answered. This risk exists on both settlement paths: `settle_day` judges Daily
-- commitments, `settle_week` judges Weekly Quota ones, and nothing in the schema stops an
-- Auto-check from attaching to either cadence.
--
-- Fixed with one shared helper, `auto_check_pending(commitment_id, day)`: true when that
-- commitment has an Auto-check attached, no declaration yet for `day`, its check hasn't
-- reached a terminal result for `day`, and less than 96 hours have passed since `day`
-- closed. Both `settle_day` and `settle_week` are guarded with it — each `continue`s
-- (retried by its own hourly cron) an account's period while any of its owed, unanswered,
-- Auto-check-linked commitments has a pending check for any day in that period.
--
-- The 96-hour grace window bounds the block. `resolve_auto_checks()` only ever resolves
-- "yesterday" and never revisits an older day once it has rolled past — so an unbounded
-- block would leave a day permanently stuck if that one resolution window is ever missed
-- entirely. Past 96 hours, `auto_check_pending` reads false regardless of check state, and
-- the period falls through and settles exactly as if no Auto-check were attached.
--
-- 96 hours, not 48: `settle_day`'s own `declaration_deadline` (20260819241000) already
-- waits until `(p_day + 3) + morning_hour` — up to 71 hours after this window's own base
-- point (`p_day + 1` at HCM midnight) for `morning_hour = 23`. A grace window shorter than
-- that (48h was tried first and rejected) expires *before* `settle_day` ever reaches the
-- point it would actually charge a silent miss, making the guard inert exactly where it
-- matters — checked but never the deciding factor. 96 hours clears the worst case with a
-- full day of margin for every `morning_hour`, keeping `auto_check_pending` genuinely
-- load-bearing on both settlement paths, not merely present.
--
-- "Terminal for `day`" reuses the exact `auto_check_last_checked_at` day-boundary identity
-- `resolve_auto_checks` already computes for its own `target_day`
-- (20260824090000:18) — no new column, no new enum. The grace window is measured from
-- `day`'s own close (`day + 1` at Asia/Ho_Chi_Minh midnight, the same close-point
-- `declaration_derive_day` uses, 20260819200000:87-96), not from `now()` at
-- guard-evaluation time, so it expires at a fixed point regardless of how many settlement
-- passes retry in between.

create function public.auto_check_pending(p_commitment_id uuid, p_day date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.commitment c
     where c.id = p_commitment_id
       and c.auto_check_kind is not null
       and c.archived_at is null
       and not exists (
         select 1 from public.declaration d
          where d.commitment_id = c.id and d.for_day = p_day
       )
       and (c.auto_check_last_checked_at is null
            or (c.auto_check_last_checked_at at time zone 'Asia/Ho_Chi_Minh')::date - 1 < p_day)
       and now() < (((p_day + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh') + interval '96 hours')
  );
$$;

comment on function public.auto_check_pending(uuid, date) is
  'AD-13: true when p_commitment_id has an Auto-check attached, is not archived, is still '
  'undeclared for p_day, that check has not reached a terminal result for p_day (the same '
  'auto_check_last_checked_at day-boundary identity resolve_auto_checks computes for its '
  'own target_day), and less than 96 hours have passed since p_day closed. Past the grace '
  'window this reads false regardless of check state, bounding the settlement block '
  'instead of leaving it indefinite. Self-contained on archived_at rather than relying on '
  'callers to pre-filter it, unlike its other two callable-alone conditions which do need '
  'a p_day/commitment context only a caller has. Called only from settle_day/settle_week — '
  'never duplicated inline, never in application code.';

revoke execute on function public.auto_check_pending(uuid, date) from public, anon, authenticated;


-- settle_day: unchanged except the new guard, placed right after "nothing owed" and before
-- the existing answered-vs-deadline check, since a pending Auto-check has to block
-- regardless of whether the deadline has passed — that is exactly the case this story
-- exists to close (a day that expired only because its Auto-check never got to run).
create or replace function public.settle_day(p_day date, p_override boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  invocation text := coalesce(current_setting('app.settlement_invocation', true), '');
  account record;
  total integer;
  answered integer;
  admitted integer;
  silent integer;
  held integer;
  survivor_id uuid;
  survivor text;
  survivor_chain integer;
  suggestion text;
  past_deadline boolean;
  verdict public.day_verdict;
  inserted integer;
  new_settlement uuid;
  settled integer := 0;
begin
  if current_user in ('anon', 'authenticated') then
    raise exception 'settle_day is never callable from the application (AD-2)';
  end if;

  if invocation <> 'schedule' and not p_override then
    raise exception
      'settle_day ran outside its schedule with no override. Pass p_override => true, '
      'which is refused for the live doer account (AD-16).';
  end if;

  for account in
    select p.id, p.is_live_doer, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    if p_override and account.is_live_doer then
      raise exception
        'settle_day refuses an override against the live doer account (AD-16). '
        'Only the schedule may settle it.';
    end if;

    select count(*),
           count(o.answer),
           count(*) filter (
             where o.carries_penalty and o.answer = 'slipped' and o.cadence <> 'weekly_quota'
           ),
           count(*) filter (
             where o.carries_penalty and o.answer is null and o.cadence <> 'weekly_quota'
           ),
           count(*) filter (where o.answer = 'held')
      into total, answered, admitted, silent, held
      from public.commitments_owing(account.id, p_day) o;

    continue when total = 0;

    -- AD-13: a day cannot settle while any of its owed, unanswered, Auto-check-linked
    -- commitments still has a pending check for it — bounded by auto_check_pending's own
    -- 96-hour grace window rather than held open indefinitely. Checked ahead of
    -- past_deadline on purpose: an expired-but-Auto-check-pending day must still block,
    -- which is exactly the race this story closes. Excludes weekly_quota the same way
    -- admitted/silent above do: a Weekly Quota commitment's own Auto-check protection is
    -- settle_week's guard below, not this one — commitments_owing() does not exclude
    -- weekly_quota from its result set (only daily_hours_quota is excluded), so without
    -- this filter a stuck weekly-quota check would delay the whole day's settlement,
    -- notification and penalty freeze for every other, unrelated commitment on the
    -- account — a collateral cost this story never asked for.
    continue when exists (
      select 1 from public.commitments_owing(account.id, p_day) o
       where o.answer is null and o.cadence <> 'weekly_quota'
         and public.auto_check_pending(o.commitment_id, p_day)
    );

    past_deadline := now() >= public.declaration_deadline(p_day, account.morning_hour);
    continue when answered < total and not past_deadline;

    verdict := case
      when answered < total then 'expired'
      when admitted > 0 then 'failed'
      else 'clean'
    end;

    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (account.id, p_day, 'day', verdict, admitted + silent)
    on conflict (subject, period, kind) where supersedes is null do nothing
    returning id into new_settlement;

    get diagnostics inserted = row_count;
    settled := settled + inserted;

    continue when new_settlement is null;

    if (admitted + silent) > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (account.id, new_settlement, public.penalty_amount_dong());
    end if;

    -- What each commitment did, frozen. This happens for an expired day too, and that is
    -- the point of `unanswered` being its own outcome: the chain has to break on silence,
    -- and the history has to say *why* it broke rather than filing it as a miss.
    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    select new_settlement, account.id, o.commitment_id,
           case o.answer
             when 'held' then 'held'
             when 'slipped' then 'missed'
             else 'unanswered'
           end::public.commitment_outcome
      from public.commitments_owing(account.id, p_day) o;

    -- No summary for a day that expired. The data is there and it is tempting, but a
    -- message saying "one of five today, start with X tomorrow" about a day he never
    -- answered is the product pretending it knows how his day went. It knows he did not say.
    continue when verdict = 'expired';

    -- One commitment that held, and one to start with tomorrow. Deliberately single values
    -- rather than lists: two suggestions is a to-do list, and a list of misses is the thing
    -- this message exists to replace.
    select c.id, c.name into survivor_id, survivor
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
     where o.answer = 'held'
     order by c.created_at
     limit 1;

    select c.name into suggestion
      from public.commitments_owing(account.id, p_day) o
      join public.commitment c on c.id = o.commitment_id
     order by (o.answer = 'slipped') desc, c.created_at
     limit 1;

    continue when suggestion is null;

    -- Read after the outcomes above are written, so the number includes the day being
    -- summarised: "day 12" means it has now held twelve days, not eleven and counting.
    select ch.current_days into survivor_chain
      from public.chain_current ch
     where ch.commitment_id = survivor_id;

    perform public.outbox_enqueue(
      account.id,
      'summary-' || account.id::text || '-' || p_day::text,
      jsonb_build_object(
        'title', 'Today',
        'body', public.day_summary_body(
                  held, total, p_day,
                  case when (admitted + silent) > 0 then public.penalty_amount_dong() end,
                  survivor, suggestion, survivor_chain),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );
  end loop;

  return settled;
end;
$$;

revoke execute on function public.settle_day(date, boolean) from public, anon, authenticated;


-- settle_week: the same guard, mirrored for a whole period rather than a single day — a
-- pending check on any single day in [p_period, p_period + 6] blocks the whole period, the
-- same "whole-day block" settle_day's own guard applies. Cross-joins the identical
-- commitment selection the `quota` loop below uses (cadence = 'weekly_quota',
-- archived_at is null, week_start_day = extract(isodow from p_period), the
-- created_at < p_period + 7 existence guard) against every day in the period, and is
-- placed before total_commitments is reset so it can `continue` the whole period the same
-- way `continue when today < p_period + 8` already does.
create or replace function public.settle_week(p_period date, p_override boolean default false)
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

    -- AD-13: a period cannot settle while any of its Weekly Quota commitments has a
    -- pending Auto-check for any day inside it — mirrors settle_day's own guard, widened
    -- to the whole period the same way the `quota` loop below is. Uses the identical
    -- commitment selection that loop uses so this guard and that loop can never disagree
    -- about which commitments belong to this account/period.
    continue when exists (
      select 1
        from public.commitment c
        cross join generate_series(p_period, p_period + 6, interval '1 day') as day_series(d)
       where c.owner_id = account.id
         and c.cadence = 'weekly_quota'
         and c.archived_at is null
         and c.week_start_day = extract(isodow from p_period)::integer
         and (c.created_at at time zone 'Asia/Ho_Chi_Minh')::date < p_period + 7
         and public.auto_check_pending(c.id, day_series.d::date)
    );

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
