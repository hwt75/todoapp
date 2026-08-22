-- Chains that survive a bad day.
--
-- The rule the story exists for: a failed day resets the chain of the commitment that was
-- missed and touches no other. One miss out of five must not read like five out of five.
--
-- **Why the chain is derived and not counted.** A counter column would be a number that can
-- be wrong with no way to fix it — AD-8 makes settlement the only writer of derived state
-- and forbids repair paths, so a counter that drifts stays drifted. Deriving it live from
-- `commitments_owing` would be worse and less obviously so: that function reads the
-- commitment's *current* configuration, so editing a cadence would silently rewrite what
-- happened in June. A chain that changes when you edit a setting is not evidence.
--
-- So settlement freezes what each commitment did on the day it closed, and the chain is a
-- view over those frozen rows. Nothing to drift, nothing to repair, and the Chains-detail
-- calendar of held and missed days falls out of the same rows rather than needing a second
-- mechanism.

create type public.commitment_outcome as enum ('held', 'missed', 'unanswered');

comment on type public.commitment_outcome is
  'What one commitment did on one closed day. `unanswered` is its own outcome rather than a '
  'kind of miss: the money treats them the same, the history should not pretend it knows.';

create table public.settlement_commitment (
  settlement_id uuid not null references public.settlement (id) on delete cascade,
  subject uuid not null references public.profile (id) on delete cascade,
  commitment_id uuid not null references public.commitment (id) on delete cascade,
  outcome public.commitment_outcome not null,

  -- One outcome per commitment per settlement. A re-run conflicts rather than duplicating,
  -- the same way AD-5 protects the verdict itself.
  primary key (settlement_id, commitment_id)
);

comment on table public.settlement_commitment is
  'What each commitment did on a closed day, frozen at the moment it closed. The chain is '
  'derived from these; they are never recomputed from current configuration.';

create index settlement_commitment_chain_idx
  on public.settlement_commitment (commitment_id, settlement_id);

alter table public.settlement_commitment enable row level security;

create policy "settlement_commitment: read own"
  on public.settlement_commitment for select to authenticated
  using ((select auth.uid()) = subject);

-- No insert, update or delete policy, deliberately. A client that could write one of these
-- could write its own chain, which is the one number in the product that only means
-- something because he did not put it there himself.


-- ---------------------------------------------------------------------------------
-- The chain, in one place.
-- ---------------------------------------------------------------------------------

/* Current and longest chain per commitment.

   Three rules, and only one of them is arithmetic:

   - A day the commitment was not owed is **skipped**, not broken. It simply has no row —
     `commitments_owing` never returned it — so the gap costs nothing. A weekly commitment
     would otherwise reset every Tuesday.
   - A miss breaks the chain.
   - **Silence breaks it too.** Settlement already charges for an unanswered commitment that
     carries a penalty, so a chain surviving silence would mean *you paid and your chain
     held* — two numbers describing one day and disagreeing about it. More basically: a
     chain is evidence something held, and silence is not evidence of anything. A chain that
     runs through days he never answered counts days elapsed, not days held.

   Reads through `settlement_current`, so a superseded settlement's outcomes drop out and
   the chain follows the correction rather than the original (AD-9). */
create view public.chain_current
with (security_invoker = true)
as
with judged as (
  select sc.subject,
         sc.commitment_id,
         s.period,
         sc.outcome,
         -- Gaps and islands: consecutive rows of the same outcome share a value, because
         -- the two row numbers advance in step only while the outcome does not change.
         row_number() over (partition by sc.commitment_id order by s.period)
           - row_number() over (partition by sc.commitment_id, sc.outcome order by s.period)
           as island
    from public.settlement_commitment sc
    join public.settlement_current s on s.id = sc.settlement_id
),
runs as (
  select commitment_id,
         island,
         count(*)::integer as days,
         max(period) as ends_on
    from judged
   where outcome = 'held'
   group by commitment_id, island
),
last_judged as (
  select subject, commitment_id, max(period) as last_period
    from judged
   group by subject, commitment_id
)
select l.subject,
       l.commitment_id,
       -- The current chain is a run only if it is still running: its last held day has to be
       -- the last day this commitment was judged at all. Otherwise something broke it since.
       coalesce((select r.days from runs r
                  where r.commitment_id = l.commitment_id and r.ends_on = l.last_period), 0)
         as current_days,
       coalesce((select max(r.days) from runs r
                  where r.commitment_id = l.commitment_id), 0)
         as longest_days
  from last_judged l;

comment on view public.chain_current is
  'Current and longest chain per commitment, derived from frozen outcomes. The only place '
  'the chain rule is written — the client reads this rather than counting anything itself.';


-- ---------------------------------------------------------------------------------
-- Settlement writes the outcomes, and the summary can finally say `day 12`.
-- ---------------------------------------------------------------------------------

create or replace function public.day_summary_body(
  p_held integer,
  p_total integer,
  p_day date,
  p_amount bigint,
  p_survivor text,
  p_suggestion text,
  p_survivor_chain integer default null
)
returns text
language sql
immutable
set search_path = ''
as $$
  select concat_ws(' ',
    initcap((array['none','one','two','three','four','five','six','seven','eight','nine','ten'])[
      least(p_held, 10) + 1]),
    'of',
    (array['none','one','two','three','four','five','six','seven','eight','nine','ten'])[
      least(p_total, 10) + 1],
    'on ' || to_char(p_day, 'FMDay') || '.',

    case when p_amount is not null
         -- Dots, not commas: Vietnamese grouping, matching `formatDong`. Explicit rather
         -- than inherited from lc_numeric, which is what made them disagree.
         then 'That''s ' || translate(to_char(p_amount, 'FM999G999G999'), ',', '.') || '₫.'
    end,

    -- The chain clause EXPERIENCE.md specified and Story 2.8 could not yet tell the truth
    -- about. It names the chain that *survived*, never the one that broke: a reset is never
    -- a notification's headline, and on the evening of a bad day it is not a footnote either.
    case when p_survivor is not null then
      p_survivor || ' held though'
        || coalesce(' — day ' || nullif(p_survivor_chain, 0)::text, '') || '.'
    end,

    case when p_survivor is not null and p_survivor = p_suggestion
         then 'Start there tomorrow.'
         else 'Start with ' || p_suggestion || ' tomorrow.'
    end
  );
$$;

revoke execute on function
  public.day_summary_body(integer, integer, date, bigint, text, text, integer)
  from public, anon, authenticated;

drop function public.day_summary_body(integer, integer, date, bigint, text, text);


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
           count(*) filter (where o.carries_penalty and o.answer = 'slipped'),
           count(*) filter (where o.carries_penalty and o.answer is null),
           count(*) filter (where o.answer = 'held')
      into total, answered, admitted, silent, held
      from public.commitments_owing(account.id, p_day) o;

    continue when total = 0;

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
