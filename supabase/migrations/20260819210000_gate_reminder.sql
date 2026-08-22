-- The push half of the morning gate.
--
-- `EXPERIENCE.md`: the gate is a persistent Web Push *plus* a launch modal, and neither
-- alone is sufficient. The push reaches him at 07:30 when he is not thinking about the
-- app; the modal is what remains when the push was swiped away. Story 2.4a built the
-- delivery; this decides when there is something to deliver.
--
-- It enqueues. It never sends — AD-3 keeps every outbound effect behind the outbox, and
-- the worker on its own schedule is what turns a row into a notification.

/* How many times a morning may ask.

   A number that needs the author's judgement rather than mine. Too few and the gate is a
   thing he swipes away once; too many and the app becomes something he mutes, which costs
   far more than a missed reminder. Four hourly attempts is defensible and deliberately
   conservative — it stops well before the 48-hour expiry in FR-9 and leaves the modal to
   do the rest.

   Changing it changes the dedupe keys' meaning, not their shape, so it is safe to revisit. */
create function public.gate_reminder_slots()
returns integer
language sql
immutable
set search_path = ''
as $$ select 4 $$;

/* Enqueues one reminder per account with an unanswered declaration, once per hourly slot.

   The dedupe key carries the account, the day in question and the slot, so a morning
   produces one notification per slot and never a queue of identical ones. Running this
   twice in the same hour is a no-op, which matters because a cron schedule is not a
   promise to run exactly once. */
create function public.enqueue_gate_reminders()
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
  enqueued integer := 0;
begin
  local_now := now() at time zone 'Asia/Ho_Chi_Minh';
  local_hour := extract(hour from local_now)::integer;
  asked_day := local_now::date - 1;

  for account in
    select p.id, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    -- Before the hour he agreed to, there is nothing to ask.
    continue when local_hour < account.morning_hour;

    slot := local_hour - account.morning_hour;
    continue when slot >= public.gate_reminder_slots();

    -- A commitment owes an answer when its cadence is settled by his word, it was not
    -- already archived before the day in question, and nothing has been filed for it.
    -- `daily_hours_quota` is excluded: FR-2 judges it against measured minutes, not a
    -- statement, and asking would invite a softer second answer.
    select count(*) into outstanding
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

    -- The body states the time it was sent and describes a state as of that time. A push
    -- can arrive minutes late — Story 2.4a's payload rules exist for exactly this, and the
    -- outbox refuses a payload without its own timestamp.
    perform public.outbox_enqueue(
      account.id,
      'gate-' || account.id::text || '-' || asked_day::text || '-' || slot::text,
      jsonb_build_object(
        'title', 'Yesterday',
        'body', outstanding::text
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

revoke execute on function public.gate_reminder_slots() from public, anon, authenticated;
revoke execute on function public.enqueue_gate_reminders() from public, anon, authenticated;

-- Hourly, at five past. Separate from the outbox worker's schedule on purpose: this
-- decides what to say, the worker decides nothing and only delivers (AD-3).
select cron.schedule(
  'gate-reminders',
  '5 * * * *',
  $$select public.enqueue_gate_reminders()$$
);
