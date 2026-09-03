-- Story 6.6 — the reminder lands inside the window.
--
-- Every reminder in this product is enqueued by an hourly cron job on its own minute --
-- gate-reminders at `:05`, settle-days at `:15`, and so on down to `:55`. A commitment due at
-- 20:30 with the default 30-minute window would first be reminded at 21:05, after the window it
-- names has already shut. The smallest legal window is five minutes (20260828130000), which no
-- `NN * * * *` schedule can reach. CAP-6 says the author is reminded at the time he chose.
--
-- **The mechanism is `outbox.not_before`, not a per-minute enqueuer.** A `* * * * *` job would
-- collide with the outbox worker on every minute and re-derive, sixty times an hour, an answer
-- that does not change. The outbox already separates *what to send* from *when to send it*:
-- `not_before` is the column `outbox_claim()` has always filtered on (20260819180000:162), built
-- for a deferred send and never once used for one. This story is its first caller. The worker,
-- its batch size and its every-minute schedule are untouched, so the precision the author sees is
-- the worker's minute -- the reminder lands at the due minute or the one after it, inside every
-- legal window.
--
-- **One chokepoint, one bound.** Every refusal lives in `enqueue_due_time_reminder()`: the
-- ninety-minute lookahead, the governing time, the claimed day, the archived commitment, the
-- role, the unsendable body. The pass and both triggers say which commitment and which day; they
-- never say whether. A caller that repeats a rule is a caller that will get it wrong for the case
-- it was not thinking about.
--
-- **A queued row is cancelled, never allowed to go stale.** A row now sits in the outbox for up
-- to ninety minutes, which no previous caller did. Deferral makes the row outlive the facts it
-- was built from, so every write that can invalidate it deletes it. Deleting a pending, unheld
-- row is safe and needs no change to `outbox_claim()` -- which is what re-checking at claim time
-- would have cost: a predicate serving one kind, evaluated for all of them.


-- ---------------------------------------------------------------------------------
-- outbox_enqueue gains p_not_before.
--
-- Drop-and-recreate, not `create or replace`: adding a parameter changes the argument list, and
-- `create or replace` would define a second, overloaded function rather than replace this one --
-- which would make every existing 3- and 4-argument call ambiguous. The same convention
-- 20260826100000 established when it added `p_channel`, for the same reason.
--
-- All 35 existing call sites keep their behaviour through the default: `now()` is what the column
-- already defaults to, so a caller that says nothing still queues a row the next worker minute
-- takes.
--
-- **The revoke and the comment are re-issued deliberately.** `drop function` destroys the ACL
-- 20260826100000:91 established, and a bare `create` in `public` hands EXECUTE back to PUBLIC --
-- `/rest/v1/rpc/outbox_enqueue` open to any signed-in account, able to queue a push against any
-- `owner_id`. `2-1-roles-and-rls.sql` does catch that, and the invariant is stated here anyway:
-- it is the invariant, not the test, that has to hold.
-- ---------------------------------------------------------------------------------

drop function public.outbox_enqueue(uuid, text, jsonb, public.outbox_channel);

/* Called by settlement and by every reminder pass, inside the caller's own transaction. Returns
   null when the dedupe key has already been seen, which is the point: an effect enqueued twice
   happens once.

   `p_not_before` is when the row becomes claimable. Left alone it is `now()` -- send on the next
   worker minute, which is what every caller before Story 6.6 meant. Passed an instant, the row
   sits in the queue until that instant arrives and `outbox_claim()`'s own `not_before <= now()`
   predicate lets it through. */
create function public.outbox_enqueue(
  p_owner uuid,
  p_dedupe_key text,
  p_payload jsonb,
  p_channel public.outbox_channel default 'push',
  p_not_before timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
begin
  insert into public.outbox (owner_id, dedupe_key, payload, channel, not_before)
  values (p_owner, p_dedupe_key, p_payload, p_channel, p_not_before)
  on conflict (dedupe_key) do nothing
  returning id into new_id;

  return new_id;
end;
$$;

comment on function public.outbox_enqueue(uuid, text, jsonb, public.outbox_channel, timestamptz) is
  'The one door into the outbox (AD-3). Returns null when the dedupe key already exists, so a '
  'retried or overlapped pass enqueues once. p_not_before defers the row: Story 6.6 uses it to '
  'queue a reminder ahead of the hour and let the every-minute worker deliver it at the instant '
  'the window opens. No client may execute it.';

revoke execute on function
  public.outbox_enqueue(uuid, text, jsonb, public.outbox_channel, timestamptz)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- A wall-clock time on a named day, as an instant.
-- ---------------------------------------------------------------------------------

/* AD-6: both boundaries resolve in Asia/Ho_Chi_Minh by explicit conversion, and no interval is
   ever added to a `timestamptz` to find a wall-clock time. `p_day + p_due_time` builds the local
   timestamp first; `at time zone` is what turns it into the instant.

   Written as its own function rather than inline for the reason `day_begins_at()`/`day_ends_at()`
   are (20260829090000:39): it is read three times below -- the delivery instant, the lookahead
   comparison, and the payload's own `sent_at` -- and three copies of "when does this window open"
   is how they would eventually disagree by an hour. */
create function public.due_time_instant(p_day date, p_due_time time)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (p_day + p_due_time) at time zone 'Asia/Ho_Chi_Minh';
$$;

comment on function public.due_time_instant(date, time) is
  'The instant p_due_time falls on p_day in Asia/Ho_Chi_Minh (AD-6). Constructs the local '
  'timestamp and converts it -- never adds an interval to a timestamptz, which is the arithmetic '
  'that silently disagrees with the wall clock. Paired with day_begins_at()/day_ends_at().';

revoke execute on function public.due_time_instant(date, time) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The chokepoint: one commitment, one day, every rule.
-- ---------------------------------------------------------------------------------

/* Offers a reminder for `p_commitment_id` on `p_day` and answers whether one was queued.

   **Callers say which commitment and which day. They never say whether.** Three callers exist --
   the hourly pass, the commitment trigger and (through cancellation only) the declaration
   trigger -- and each of them knows a different amount about the world. The bound, the governing
   time and every other refusal live here so there is one answer rather than three.

   **`p_now` is a parameter, and it is not a frozen clock.** Production never passes it: the cron
   job calls the pass with no argument and the triggers call this with none, so both read the real
   clock. It exists because two branches are otherwise unreachable by the suite's own "move the
   fixture, never the clock" idiom -- tomorrow's earliest window is inside a ninety-minute
   lookahead only after 22:30 local, so a behavioural assertion about it is a tautology for most
   of the day. Three review loops failed to pin those branches; the last did it with a `prosrc`
   substring that a reviewer defeated in one edit. `settle_day(p_day, p_override)` already carries
   a parameter that exists for the same reason.

   **The governing time is read once.** `due_time_as_of()` (20260829090000:216) decides both
   whether the day is governed at all and what the copy says, from the same value -- otherwise the
   reminder can announce a time the day is not judged by. A `due_time` written part-way through a
   day governs neither the window already passed nor a whole day, so that day is judged untimed,
   falls back to the morning gate, and cannot fail for a missing photo: a push saying otherwise
   would name a cost the day cannot incur.

   **`role = 'doer'` is checked here, not in the pass.** The pass filtered on it and the triggers
   did not, which is one rule with two answers.

   **Returns false rather than raising, for every refusal, `push_body_is_sendable` included.** One
   caller is a trigger inside the author's own write, which must never fail because a reminder
   could not be built. The other is a pass whose earlier rows would roll back with it -- the
   defect Story 3.2's review found and 20260822090000:85 has guarded against ever since. */
create function public.enqueue_due_time_reminder(
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
  'roll back with it. p_now defaults to now() and production never passes it.';

revoke execute on function public.enqueue_due_time_reminder(uuid, date, timestamptz)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Which days one commitment is offered for.
-- ---------------------------------------------------------------------------------

/* One commitment, offered for **both today and tomorrow** relative to `p_now`.

   Both dates, because a `due_time` of `00:10` is otherwise unreachable: the run before it (23:50
   local) resolves the previous local date, and by the time the date rolls over the window has
   already opened. This states which days exist, not which are near -- the bound lives in the
   chokepoint.

   **Its own function rather than a loop written twice.** The pass and the commitment trigger both
   offer exactly these two days, and two copies is how they would eventually disagree about which.
   `p_now` is what makes the second date *testable*: the pass already took one, but the trigger
   reads the real clock, so tomorrow's arm inside the trigger was only exercisable during the one
   hour of the day when tomorrow's earliest window falls inside a ninety-minute lookahead. Pulled
   out here it is pinned behaviourally at any hour, and the trigger inherits the proof.

   Each day is its own subtransaction, warning before it swallows. One day failing must not roll
   back the other, nor the rows a pass already queued for earlier commitments. */
create function public.offer_due_time_reminders(
  p_commitment_id uuid,
  p_now timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today    date;
  v_day      date;
  v_enqueued integer := 0;
begin
  v_today := (p_now at time zone 'Asia/Ho_Chi_Minh')::date;

  foreach v_day in array array[v_today, v_today + 1]
  loop
    begin
      if public.enqueue_due_time_reminder(p_commitment_id, v_day, p_now) then
        v_enqueued := v_enqueued + 1;
      end if;
    exception when others then
      raise warning 'offer_due_time_reminders: commitment % on day % failed: %',
        p_commitment_id, v_day, sqlerrm;
    end;
  end loop;

  return v_enqueued;
end;
$$;

comment on function public.offer_due_time_reminders(uuid, timestamptz) is
  'Story 6.6: offers one commitment for today and tomorrow local and returns how many queued. The '
  'one place the second date is written -- the hourly pass and the commitment trigger both come '
  'through here, so they cannot disagree about which days exist. Tomorrow because a due_time of '
  '00:10 is unreachable from the run before it otherwise. Per-day subtransactions, warning before '
  'they swallow. p_now defaults to now() and production never passes it.';

revoke execute on function public.offer_due_time_reminders(uuid, timestamptz)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The hourly pass.
-- ---------------------------------------------------------------------------------

/* Every timed, unarchived commitment of every doer, handed to the offer above.

   Each commitment is its own subtransaction on top of the per-day ones inside it: one commitment
   failing must not roll back the rows already queued in the same pass.

   **The pass says how it went, at the end, once.** The cron command is
   `select public.enqueue_due_time_reminders()` and throws the result away, so a systemic failure
   that queues nothing for anybody -- a dropped grant, a broken chokepoint -- produces no row, no
   error and no counter, and looks exactly like a healthy hour in which no window happened to be
   near. The per-commitment warnings above cover the case where something raised; this covers the
   case where nothing did. */
create function public.enqueue_due_time_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_commitment record;
  v_seen       integer := 0;
  v_enqueued   integer := 0;
begin
  for v_commitment in
    select c.id
      from public.commitment c
      join public.profile p on p.id = c.owner_id and p.role = 'doer'
     where c.due_time is not null
       and c.archived_at is null
  loop
    v_seen := v_seen + 1;

    begin
      v_enqueued := v_enqueued + public.offer_due_time_reminders(v_commitment.id, p_now);
    exception when others then
      raise warning 'enqueue_due_time_reminders: commitment % failed: %',
        v_commitment.id, sqlerrm;
    end;
  end loop;

  raise log 'enqueue_due_time_reminders: % reminder(s) queued from % timed commitment(s), as of %',
    v_enqueued, v_seen, p_now;

  return v_enqueued;
end;
$$;

comment on function public.enqueue_due_time_reminders(timestamptz) is
  'Story 6.6: the hourly pass. Hands every timed, unarchived commitment of every doer to '
  'offer_due_time_reminders(), which decides the days, and enqueue_due_time_reminder(), which '
  'decides whether. Per-commitment subtransactions so one failure cannot roll back the rows '
  'already queued. Writes one `raise log` naming the count, because the cron job discards the '
  'return value and a pass that silently queues nothing for everyone would otherwise look exactly '
  'like a healthy one. p_now defaults to now() and production never passes it.';

revoke execute on function public.enqueue_due_time_reminders(timestamptz)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Its schedule.
--
-- `:00` resolve-auto-checks, `:05` gate-reminders, `:15` settle-days, `:25` focus-prompts,
-- `:35` weekly-quota-reminders, `:45` settle-weeks, `:55` void-expired-appeals and email-worker.
-- `:50` is free, and far enough from `:45` that settle-weeks has committed before this runs.
-- outbox-worker keeps `* * * * *` and is not touched by this story -- it is what delivers these
-- rows, at the minute each one names.
-- ---------------------------------------------------------------------------------

select cron.schedule(
  'due-time-reminders',
  '50 * * * *',
  $$select public.enqueue_due_time_reminders()$$
);


-- ---------------------------------------------------------------------------------
-- Cancellation.
-- ---------------------------------------------------------------------------------

/* Deletes the not-yet-sent, not-currently-held reminder for `p_commitment_id` on `p_day`, or on
   both today and tomorrow when no day is named. One function, because the same deletion is wanted
   from a commitment edit, an archive and a filed claim.

   **The guard is `status = 'pending'` and "no live worker holds it", not `claimed_at is null`.**
   `outbox_claim()` leaves a claimed row `pending` and pushes `not_before` a minute out
   (20260819180000:162), so `claimed_at is null` alone would make a row whose worker died
   uncancellable forever -- the exact stale send this story exists to prevent. A row a live worker
   is holding right now has both `claimed_at` set *and* `not_before` in the future; one whose
   worker died has `claimed_at` set and `not_before` already past. Only the first is spared.

   `status = 'pending'` is the other half and is not decoration: deleting a `sent` row frees the
   dedupe key that enforces one reminder per commitment-day, and destroys the record that the push
   went out. */
create function public.cancel_due_time_reminders(
  p_commitment_id uuid,
  p_day date default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today   date;
  v_days    date[];
  v_keys    text[];
  v_deleted integer;
begin
  if p_day is not null then
    v_days := array[p_day];
  else
    v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
    v_days := array[v_today, v_today + 1];
  end if;

  v_keys := array(
    select 'due-' || p_commitment_id::text || '-' || d::text from unnest(v_days) as d
  );

  delete from public.outbox o
   where o.dedupe_key = any (v_keys)
     and o.status = 'pending'
     and (o.claimed_at is null or o.not_before <= now());

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function public.cancel_due_time_reminders(uuid, date) is
  'Story 6.6: removes a queued due-time reminder that has outlived the facts it was built from. '
  'p_day names one day; omitted, it clears today and tomorrow. Spares a row a live worker is '
  'holding (claimed and not_before still ahead) and a row already sent -- deleting a sent row '
  'would free the dedupe key that enforces one reminder per commitment-day.';

revoke execute on function public.cancel_due_time_reminders(uuid, date)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- A commitment's own write offers its own reminder.
-- ---------------------------------------------------------------------------------

/* The gap the hourly pass cannot close on its own: a commitment created at 20:15 carrying a
   `due_time` of 20:40 is a window the 19:50 pass could not have seen, and the 20:50 pass would
   reach after it opened.

   **INSERT offers today *and* tomorrow.** The row's own creation entry is the one
   `due_time_as_of()` excepts (20260829090000:136), so a commitment created at 20:15 for 20:40
   genuinely owns that window -- and one created at 23:51 for `00:10` owns tomorrow's, which no
   pass reaches in time either. The chokepoint's own bound is what keeps a window fourteen hours
   out from being queued now.

   **UPDATE cancels, then re-offers both days, and lets the chokepoint decide.** It is tempting to
   encode Story 6.4's rule here by skipping today when the time moved. Do not: `due_time_as_of()`
   already returns null in exactly that case, and this trigger fires on four columns for which
   today is still perfectly governed. A rename, a widened `late_window_minutes` or an unarchive
   writes no `commitment_due_time_change` row at all -- cancelling without re-offering would lose
   that day's reminder outright whenever the window opens before the next `:50` pass. A rename at
   20:00 against a window opening at 20:30 would cost the reminder entirely.

   **Which columns fire it.** Any write that can invalidate a queued row, not only a moved time:
   `due_time` and `late_window_minutes` change the instant and the copy; `name` leaves a body
   naming a commitment that no longer exists under that name; `cadence` is what the body's second
   sentence is built from, so a `daily -> weekly_quota` change leaves a queued push asserting a
   failed day the week will never charge; `archived_at` leaves a push for a commitment the author
   has just deleted. The `when` clause guards against an unchanged resubmission of every column
   cancelling a correct row, and deliberately cannot be written as `new.due_time is not null` --
   clearing the time is exactly a case this must fire on.

   **It can never fail the author's write.** Every call, the delete included, is its own
   subtransaction that warns and swallows. A reminder that could not be built is not a reason to
   refuse a commitment. */
create function public.commitment_due_time_written()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    begin
      perform public.cancel_due_time_reminders(new.id);
    exception when others then
      raise warning 'commitment_due_time_written: cancel for commitment % failed: %',
        new.id, sqlerrm;
    end;
  end if;

  -- Both days, through the one function that says which two they are. Written as a call rather
  -- than as its own loop so the trigger cannot drift from the pass about the second date, and so
  -- that date is provable at any hour rather than only during the one when tomorrow's earliest
  -- window happens to fall inside the lookahead.
  begin
    perform public.offer_due_time_reminders(new.id);
  exception when others then
    raise warning 'commitment_due_time_written: offering commitment % failed: %',
      new.id, sqlerrm;
  end;

  return null;
end;
$$;

comment on function public.commitment_due_time_written() is
  'after insert/update trigger on public.commitment (Story 6.6). On INSERT, offers the new '
  'commitment''s own reminder for today and tomorrow -- its creation entry is the one '
  'due_time_as_of() excepts, so it genuinely owns its own first window. On UPDATE, cancels any '
  'queued row and re-offers both days, letting enqueue_due_time_reminder() apply Story 6.4''s '
  'rule rather than restating it here. Every call warns and swallows: it can never fail the '
  'author''s own write.';

revoke execute on function public.commitment_due_time_written()
  from public, anon, authenticated;

-- Two trigger objects rather than one, because a `when` clause referencing `old` is illegal on an
-- INSERT trigger.
--
-- Both names sort **after** `commitment_log_due_time_change_*` (20260829090000), and that is
-- load-bearing rather than incidental: triggers of the same timing fire in name order, and
-- `due_time_as_of()` below reads exactly what that log trigger has just written. Renamed to sort
-- earlier, the INSERT arm would find no history at all and refuse the commitment's own first
-- window.

create trigger commitment_queue_due_time_reminder_on_insert
  after insert on public.commitment
  for each row
  when (new.due_time is not null)
  execute function public.commitment_due_time_written();

create trigger commitment_queue_due_time_reminder_on_update
  after update of due_time, late_window_minutes, name, cadence, archived_at
  on public.commitment
  for each row
  when (
    old.due_time is distinct from new.due_time
    or old.late_window_minutes is distinct from new.late_window_minutes
    or old.name is distinct from new.name
    or old.cadence is distinct from new.cadence
    or old.archived_at is distinct from new.archived_at
  )
  execute function public.commitment_due_time_written();


-- ---------------------------------------------------------------------------------
-- A filed claim cancels the reminder for the day it names.
-- ---------------------------------------------------------------------------------

/* The chokepoint already refuses a day that carries a declaration. Deferral is what lets a row
   outlive that rule, and this is the commonest way it happens: he claims at 20:00 for a window
   that opens at 20:30, and the row queued at 19:50 is still sitting there.

   **`new.for_day` only, never both days.** Cancelling both is wrong in both directions: a claim
   filed for today at 23:56 would delete a queued `00:10` reminder for tomorrow that nothing can
   re-queue in time, and a machine-filed or backdated declaration for an earlier day would delete
   today's still-valid one. */
create function public.declaration_cancels_due_time_reminder()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
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
  'it can never fail the claim.';

revoke execute on function public.declaration_cancels_due_time_reminder()
  from public, anon, authenticated;

create trigger declaration_cancels_due_time_reminder
  after insert on public.declaration
  for each row
  execute function public.declaration_cancels_due_time_reminder();
