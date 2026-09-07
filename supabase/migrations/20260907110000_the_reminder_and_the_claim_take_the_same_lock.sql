-- Epic 6 retrospective item 40: the reminder and the claim take the same lock.
--
-- Two writers decide the same fact -- whether a due-time reminder should exist for one
-- commitment on one day -- and neither could see the other mid-flight.
--
-- `enqueue_due_time_reminder()` refuses a day that already carries a declaration
-- (20260903090000:226-232) and then inserts the outbox row (:275). `declaration_cancels_due_time_
-- reminder()` deletes that row after a claim is filed (:629-659). A claim committing between the
-- check and the insert satisfies neither guard: the enqueuer looked before the declaration
-- existed, and the canceller looked before the outbox row did. The author is then reminded, at
-- the moment his window opens, to do a thing he has already done and told the app about -- on
-- the one screen this product asks him to trust.
--
-- Both paths now take the same per-commitment-day transaction advisory lock, so the two possible
-- orderings are the only two outcomes: the claim commits first and the enqueuer sees it, or the
-- reminder is queued first and the canceller deletes it.
--
-- The key is the commitment and the day, not the account (the shape `grace_day_validate()` and
-- `mark_penalty_collected()` use, 20260825110000:156). It is the narrowest key that covers the
-- fact being decided, and it deliberately does not serialize two different commitments' claims
-- against each other -- a doer answering several rows at once has no reason to wait on himself.
--
-- No path takes both this lock and the per-account one, so there is no ordering between them to
-- deadlock on. If one ever does, it must take the account lock first, matching every existing
-- caller.


create or replace function public.enqueue_due_time_reminder(
  p_commitment_id uuid,
  p_day date,
  p_now timestamptz default now()
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner    uuid;
  v_name     text;
  v_cadence  public.commitment_cadence;
  v_live_due time;
  v_window   integer;
  v_archived timestamptz;
  v_role     public.app_role;
  v_due      time;
  v_opens_at timestamptz;
  v_shuts    text;
  v_body     text;
  v_queued   uuid;
begin
  select c.owner_id, c.name, c.cadence, c.due_time, c.late_window_minutes, c.archived_at, p.role
    into v_owner, v_name, v_cadence, v_live_due, v_window, v_archived, v_role
    from public.commitment c
    join public.profile p on p.id = c.owner_id
   where c.id = p_commitment_id;

  -- Gone, archived, or never timed. An archived commitment is one the author has just deleted as
  -- far as he is concerned, and an untimed one is the morning gate's to ask about.
  if not found then
    return false;
  end if;
  if v_archived is not null then
    return false;
  end if;
  if v_live_due is null or v_window is null then
    return false;
  end if;

  -- A referee has no commitments to be reminded of, and nothing here should be the one place
  -- that discovers otherwise.
  if v_role is distinct from 'doer' then
    return false;
  end if;

  -- The one read. Null means p_day is judged untimed (Story 6.4) and cannot fail for a missing
  -- photo, so there is nothing honest to say about it at any hour.
  v_due := public.due_time_as_of(p_commitment_id, p_day);
  if v_due is null then
    return false;
  end if;

  v_opens_at := public.due_time_instant(p_day, v_due);

  -- Half-open `[p_now, p_now + 90 minutes)`. The lower edge is what refuses a window that has
  -- already opened: a reminder arriving at minute four of a five-minute window is technically
  -- inside it and practically useless. The upper edge is what keeps a trigger from queueing a
  -- window fourteen or twenty-four hours out -- a row that would then sit in the outbox all day
  -- outliving every fact it was built from. Ninety minutes against an hourly run is deliberate
  -- overlap: the unique dedupe key makes a repeat free, and a slow or missed run self-heals on
  -- the next one.
  if v_opens_at < p_now or v_opens_at >= p_now + interval '90 minutes' then
    return false;
  end if;

  -- Epic 6 retrospective item 40. From here to the enqueue is one decision -- "nothing has been
  -- claimed for this commitment-day, so offer the reminder" -- and it was two statements with a
  -- gap between them. A claim committing inside that gap left a reminder for a day that had
  -- already been answered: this check saw no declaration, and the trigger that cancels found no
  -- row to cancel, because the row it would have cancelled was not inserted yet.
  --
  -- The same key `declaration_cancels_due_time_reminder()` takes, so the two orderings are the
  -- only two outcomes. Taken here rather than at the top: everything above is a cheap refusal no
  -- claim can change, and an hourly pass over every commitment should not hold a lock for each
  -- one it was never going to queue.
  perform pg_advisory_xact_lock(hashtext(p_commitment_id::text || ':' || p_day::text));

  -- Already claimed. The declaration trigger below cancels a row for exactly this reason, and
  -- this is the same rule stated where every caller meets it.
  if exists (
    select 1 from public.declaration d
     where d.commitment_id = p_commitment_id and d.for_day = p_day
  ) then
    return false;
  end if;

  -- Computed on the local timestamp, never as `v_due + make_interval(...)`: Postgres time
  -- arithmetic wraps, so a window closing at midnight would read `00:30` rather than past the end
  -- of the day (the trap `commitment_window_within_the_day` avoids, 20260828130000:48). Built
  -- this way, a window ending at exactly midnight reads `00:00`, which is what it is.
  v_shuts := to_char((p_day + v_due)::timestamp + make_interval(mins => v_window), 'HH24:MI');

  -- Both cadences get an explicit arm and anything else returns false rather than inheriting
  -- either sentence. A `weekly_quota` day is judged at week close and cannot fail for a missing
  -- photo (FR-2), so the daily sentence would be a lie about money; its second sentence says what
  -- the photo is worth instead. A cadence added later must show up as a silent commitment, not as
  -- copy that guesses.
  v_body := case v_cadence
              when 'daily' then
                v_name || ' — window open until ' || v_shuts
                  || '. A photo today or the day fails.'
              when 'weekly_quota' then
                v_name || ' — window open until ' || v_shuts
                  || '. A photo counts this day toward the week.'
            end;

  if v_body is null then
    return false;
  end if;

  -- A commitment name is freeform text the author typed, so it can accidentally contain a banned
  -- phrase. Checked rather than left to the table's own check constraint, because an unhandled
  -- exception here unwinds the whole pass and rolls back every row already queued this run.
  if not public.push_body_is_sendable(v_body) then
    return false;
  end if;

  -- `sent_at` is the instant this row is *scheduled* for, not the instant it was queued. The
  -- payload rule exists because a push is read at a time the sender cannot know (20260820101000),
  -- and a row queued at 19:50 for a 20:30 window that dated itself 19:50 would be lying by forty
  -- minutes about the one thing the rule is for.
  --
  -- It is not a promise of when the push actually left. A backed-up, retrying or down worker
  -- delivers later while this still reads `v_opens_at`, so the payload can under-state the real
  -- send by however long the queue was behind. That is the same direction of error every other
  -- caller already accepts -- `now()` at enqueue time is not the send instant either -- and it is
  -- the honest half of the claim: this is the minute the window opens, which is what the sentence
  -- is about.
  v_queued := public.outbox_enqueue(
    v_owner,
    'due-' || p_commitment_id::text || '-' || p_day::text,
    jsonb_build_object(
      'title', to_char(v_due, 'HH24:MI'),
      'body', v_body,
      'sent_at', to_char(v_opens_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ),
    'push',
    v_opens_at
  );

  return v_queued is not null;
end;
$$;
comment on function public.enqueue_due_time_reminder(uuid, date, timestamptz) is
  'Story 6.6: offers one reminder for one commitment on one day, and answers whether it queued. '
  'The only place the rules live -- the half-open [p_now, p_now + 90 minutes) lookahead, the '
  'due_time_as_of() governing time that decides both the refusal and the copy, the claimed day, '
  'the archived commitment, the doer role, the sendable body. Callers name a commitment and a '
  'day; they never decide whether. Returns false rather than raising for every refusal: one '
  'caller is a trigger inside the author''s own write, the other a pass whose earlier rows would '
  'roll back with it. p_now defaults to now() and production never passes it. Since Epic 6 '
  'retrospective item 40 the claimed-day check and the enqueue are one decision under a '
  'per-commitment-day advisory lock, the same key declaration_cancels_due_time_reminder() takes, '
  'so a claim can no longer commit between them.';


-- ---------------------------------------------------------------------------------
-- The other side of the same lock.
-- ---------------------------------------------------------------------------------

create or replace function public.declaration_cancels_due_time_reminder()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    -- Taken before the delete and held to commit, so an enqueue that arrives while this claim is
    -- still in flight waits here and then reads a declaration that exists, rather than queueing a
    -- reminder this cancel has already looked for and not found.
    --
    -- Inside the same swallowing block as the cancel itself, and for the same reason: this runs
    -- inside the author's own claim, and nothing here may ever fail the claim. A lock this
    -- transaction cannot take is a reminder that may survive -- an annoyance -- while a raised
    -- exception here would lose the claim itself, which is the thing that costs money.
    perform pg_advisory_xact_lock(hashtext(new.commitment_id::text || ':' || new.for_day::text));

    perform public.cancel_due_time_reminders(new.commitment_id, new.for_day);
  exception when others then
    raise warning 'declaration_cancels_due_time_reminder: commitment % on day % failed: %',
      new.commitment_id, new.for_day, sqlerrm;
  end;

  return null;
end;
$$;

comment on function public.declaration_cancels_due_time_reminder() is
  'after insert trigger on public.declaration (Story 6.6). Cancels the queued due-time reminder '
  'for the day the declaration names, and only that day -- a claim filed late tonight must not '
  'delete tomorrow''s reminder, and a backdated one must not delete today''s. Warns and swallows: '
  'it can never fail the claim. Since Epic 6 retrospective item 40 it first takes the '
  'per-commitment-day advisory lock enqueue_due_time_reminder() takes, so the claim and the '
  'reminder cannot each miss the other.';

revoke execute on function public.declaration_cancels_due_time_reminder()
  from public, anon, authenticated;
