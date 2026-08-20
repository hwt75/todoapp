-- The push half of the daily-hours prompt.
--
-- `focus_day_minutes`'s own comment names this story: "nothing recomputes it" — Story 3.1 built
-- the measurement and nothing ever read it. FR-12 needs the day's progress legible without
-- opening the app, and FR-5 needs a prompt when nothing is banked by a configured hour. Both are
-- one pipeline, because the body is the only thing that differs between them: silent once the
-- target is met, a plain sentence otherwise.
--
-- `enqueue_gate_reminders()` is the shape this copies exactly (D2): one hourly `security
-- definer` function, looped over doers, a slot count bounding how many times a day may ask, one
-- `outbox_enqueue` call per row, deduped so a retried or overlapping cron pass is a no-op.
--
-- **The hour is derived, never configured (D1).** `least(morning_hour + 3, 23)` — three hours
-- gives the morning to the Declaration and the day its own rhythm before this pipeline starts
-- asking about a different commitment. The cap means a very late `morning_hour` (say 20) is
-- still checked the same calendar day rather than wrapping into the next one, which would
-- silently be asking about the wrong day's target. Split into its own function, `focus_prompt_
-- hour`, so the derivation is one place and is checkable on its own — every account's hour is
-- a pure function of one input, not a fact only observable by watching a cron pass fire.

/* How many times a day may ask about a Put hours in commitment.

   Copied from `gate_reminder_slots()`, for the reason stated there: enough to be useful, not
   enough to become the thing he mutes. A Daily Hours Quota carries no penalty at all (Story
   3.1's own epic context), so there is nothing to escalate toward — four flat, identical
   attempts is the honest shape for a nudge with no consequence behind it. */
create function public.focus_prompt_slots()
returns integer
language sql
immutable
set search_path = ''
as $$ select 4 $$;

/* D1's derivation, on its own: three hours after the morning hour, capped at 23.

   `morning_hour` is checked 0-23 by the database (Story 3.0), so this can never read below 3
   (the earliest possible input, 0, plus three) — there is no hour of the day before 03:00 local
   at which any account's prompt can be due, which is a real product fact and not a test
   artifact. */
create function public.focus_prompt_hour(p_morning_hour integer)
returns integer
language sql
immutable
set search_path = ''
as $$ select least(p_morning_hour + 3, 23) $$;

/* A minutes count as `H:MM`, mirroring `formatDuration` in `lib/focus-session.ts` so the
   notification reads the same way the screen does — hours unpadded, minutes always two
   digits. `greatest(..., 0)`: nothing upstream should ever pass a negative count, and this is
   not the place to raise about it if one somehow does. */
create function public.minutes_as_clock(p_minutes integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select (greatest(p_minutes, 0) / 60)::text
      || ':'
      || lpad((greatest(p_minutes, 0) % 60)::text, 2, '0')
$$;

revoke execute on function public.focus_prompt_slots() from public, anon, authenticated;
revoke execute on function public.focus_prompt_hour(integer) from public, anon, authenticated;
revoke execute on function public.minutes_as_clock(integer) from public, anon, authenticated;

/* Enqueues one prompt per open, unmet Put hours in commitment, once per hourly slot past its
   account's derived prompt hour.

   Silent the moment the target is met (D2) — nothing is sent, which is this product's whole
   answer to a quota that succeeded (Story 3.1 already refused congratulatory chrome anywhere).
   The dedupe key carries the account, the commitment, the day and the slot, so a retried cron
   pass is a no-op and two commitments under one account enqueue independently of each other.

   Every `daily_hours_quota` commitment has `daily_minutes_target` by the biconditional check in
   `20260819150000_commitment.sql`, so there is no null-target branch to handle here. */
create function public.enqueue_focus_prompts()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  account record;
  commitment record;
  local_now timestamp;
  local_hour integer;
  today date;
  prompt_hour integer;
  slot integer;
  banked integer;
  body text;
  enqueued integer := 0;
begin
  local_now := now() at time zone 'Asia/Ho_Chi_Minh';
  local_hour := extract(hour from local_now)::integer;
  today := local_now::date;

  for account in
    select p.id, p.morning_hour from public.profile p where p.role = 'doer'
  loop
    prompt_hour := public.focus_prompt_hour(account.morning_hour);

    -- Before the hour this account is asked, there is nothing to say.
    continue when local_hour < prompt_hour;

    slot := local_hour - prompt_hour;
    continue when slot >= public.focus_prompt_slots();

    for commitment in
      select c.id, c.name, c.daily_minutes_target
        from public.commitment c
       where c.owner_id = account.id
         and c.cadence = 'daily_hours_quota'
         and c.archived_at is null
    loop
      -- A scalar subquery, not `select ... into` over the view: `focus_day_minutes` is a
      -- `group by` view and returns zero rows, not a null-`minutes` row, when nothing has
      -- been banked yet. `select ... into` from zero rows leaves the target null regardless
      -- of a `coalesce` inside the select list — the coalesce never gets a row to run
      -- against. Wrapping the read itself in `coalesce(...)` is what actually reaches the
      -- zero-row case.
      banked := coalesce(
        (select m.minutes
           from public.focus_day_minutes m
          where m.owner_id = account.id
            and m.commitment_id = commitment.id
            and m.for_day = today),
        0
      );

      -- The product's whole answer to a quota that succeeded: nothing is sent for it this pass.
      continue when banked >= commitment.daily_minutes_target;

      -- The body reads the screen's own `H:MM` format and dates itself, for the same reason
      -- `enqueue_gate_reminders`' bodies do — `push_body_is_sendable` refuses anything that
      -- does not, and this checks that rule *before* calling `outbox_enqueue` rather than
      -- letting the table's own check constraint raise. A commitment name is freeform text
      -- the author typed, so it can accidentally contain a banned phrase ("right now", "just
      -- now", ...); a plain `continue when` skips that one commitment the way every other
      -- disqualifying condition here already does, instead of an unhandled exception
      -- unwinding this whole function and rolling back every row already enqueued this pass,
      -- for every account processed before this one.
      body := commitment.name || ', ' || public.minutes_as_clock(banked)
              || ' of ' || public.minutes_as_clock(commitment.daily_minutes_target)
              || ', as of ' || to_char(local_now, 'HH24:MI') || '.';

      continue when not public.push_body_is_sendable(body);

      perform public.outbox_enqueue(
        account.id,
        'focus-' || account.id::text || '-' || commitment.id::text
          || '-' || today::text || '-' || slot::text,
        jsonb_build_object(
          'title', 'Today',
          'body', body,
          'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        )
      );

      enqueued := enqueued + 1;
    end loop;
  end loop;

  return enqueued;
end;
$$;

revoke execute on function public.enqueue_focus_prompts() from public, anon, authenticated;

-- Hourly, at :25 — offset from the gate reminder (:05) and settlement (:15) so no pass shares a
-- minute, matching the existing convention's own stated reason.
select cron.schedule(
  'focus-prompts',
  '25 * * * *',
  $$select public.enqueue_focus_prompts()$$
);
