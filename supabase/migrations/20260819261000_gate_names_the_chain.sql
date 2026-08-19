-- The morning gate names what is at stake to protect, before it asks.
--
-- `EXPERIENCE.md` § Notification Copy specifies *"Morning. Day 5 is waiting."* — and the
-- rationale beside it is the whole reason the gate is allowed to say anything at all beyond
-- the question: it names the chain, never the money. Story 2.4 shipped without it because
-- nothing counted chains. Story 2.9 makes the number true.
--
-- **Only when exactly one commitment is being asked about.** The gate can be asking about
-- three at once, and there is no honest composite of three different chains — not a sum, not
-- the longest, not "your chains". An invented number in the one place he is asked to answer
-- honestly is a bad trade for a slightly warmer sentence. With more than one outstanding, the
-- body stays exactly as it was.
--
-- And only when the chain is actually running. A commitment at zero has nothing waiting, and
-- "Day 0 is waiting" would be the product manufacturing stakes it does not have.

create or replace function public.enqueue_gate_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  account record;
  local_now timestamp;
  local_hour integer;
  asked_day date;
  slot integer;
  outstanding integer;
  lone_commitment uuid;
  lone_chain integer;
  stake text;
  enqueued integer := 0;
begin
  local_now := now() at time zone 'Asia/Ho_Chi_Minh';
  local_hour := extract(hour from local_now)::integer;
  asked_day := local_now::date - 1;

  for account in
    select p.id, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    continue when local_hour < account.morning_hour;

    slot := local_hour - account.morning_hour;
    continue when slot >= public.gate_reminder_slots();

    -- `array_agg(...)[1]`, not `min(c.id)`: Postgres has no `min` for uuid, and the
    -- migration applies cleanly either way — it would have failed for the first time inside
    -- a cron run at 07:30, which is the one place nobody is watching.
    select count(*), (array_agg(c.id))[1] into outstanding, lone_commitment
      from public.commitment c
     where c.owner_id = account.id
       and c.cadence <> 'daily_hours_quota'
       and (c.archived_at is null
            or (c.archived_at at time zone 'Asia/Ho_Chi_Minh')::date > asked_day)
       and not exists (
         select 1 from public.declaration d
          where d.commitment_id = c.id and d.for_day = asked_day
       );

    continue when outstanding = 0;

    -- The chain clause, and the two conditions on it. The aggregated id is the commitment
    -- only when there is exactly one; with more it is an arbitrary row and must not be used.
    stake := '';
    if outstanding = 1 then
      select ch.current_days into lone_chain
        from public.chain_current ch
       where ch.commitment_id = lone_commitment;

      if coalesce(lone_chain, 0) > 0 then
        stake := 'Day ' || lone_chain::text || ' is waiting. ';
      end if;
    end if;

    perform public.outbox_enqueue(
      account.id,
      'gate-' || account.id::text || '-' || asked_day::text || '-' || slot::text,
      jsonb_build_object(
        'title', 'Yesterday',
        'body', stake
                || outstanding::text
                || case when outstanding = 1 then ' commitment is' else ' commitments are' end
                || ' unanswered for ' || asked_day::text
                || ', as of ' || to_char(local_now, 'HH24:MI') || '.',
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );

    enqueued := enqueued + 1;
  end loop;

  return enqueued;
end;
$$;

revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;
