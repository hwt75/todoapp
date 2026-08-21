-- Story 3.2 — the prompt that reads `focus_day_minutes`, and the hour it starts asking.
--
-- Everything measured by Story 3.1 sat unread until now: `focus_day_minutes` had "nothing
-- recomputes it" written into its own comment, and nothing read it. This is what does — one
-- hourly pass, one push per open, unmet `daily_hours_quota` commitment, silent the moment the
-- target is met.
--
-- The matrix under test:
--
--   * before the derived prompt hour, nothing is enqueued;
--   * past it with nothing banked, the body states zero against the target;
--   * past it with something banked, the body states the real fraction;
--   * the target met that day silences the commitment, but not its account-mate;
--   * the four-slot bound stops the day going quiet only after four attempts, not before;
--   * two commitments under one account enqueue independently, each its own dedupe key;
--   * a retried pass is a no-op;
--   * an archived commitment is excluded throughout;
--   * a commitment named with a phrase `push_body_is_sendable` bans cannot abort the whole
--     pass and take every other account's already-enqueued row down with it.
--
-- `morning_hour + 3` is checked directly, as `focus_prompt_hour(integer)`, a pure function of
-- one input — see `supabase/migrations/20260820120000_a_prompt_reads_the_view_it_was_promised.sql`.
-- Everything else here depends on the wall clock the way `enqueue_gate_reminders` already does
-- (see `2-4a-outbox-body-rule.sql`, step 4): `enqueue_focus_prompts()` reads `now()` and takes
-- no hour of its own to be told otherwise. `now()` is constant for the whole transaction, so a
-- single captured hour is stable across every step below — but it is still today's real hour,
-- which is why this file refuses to run outside a window wide enough to build every slot it
-- needs.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/3-2-focus-prompt.sql
--
-- One transaction, rolled back at the end. It loops over every doer account by role, the same
-- as `enqueue_gate_reminders`, so it carries the live-doer guard: run against a local or branch
-- database, never one with the author's own account in it.

begin;

grant select on table public.profile to authenticated;
grant select, insert on table public.focus_session to authenticated;

do $$
declare
  v_user       uuid := gen_random_uuid();
  v_c1         uuid;  -- 'Company work', target 180 — banked minutes progress across this
  v_c3         uuid;  -- 'Reading', target 60 — stays unmet, carries the slot-bound test
  v_c4         uuid;  -- archived from the start, must never appear
  v_hour       integer;
  v_clock      text;
  v_today      date;
  v_body       text;
  v_dedupe     text;
  v_count      integer;
  v_queued     integer;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account. `enqueue_focus_prompts()` loops over every '
      'doer by role and would enqueue real outbox rows for it, off this file''s made-up '
      'timing. Run against a local or branch database instead.';
  end if;

  v_hour := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh')::integer;
  v_clock := to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI');
  v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  -- Every step below subtracts up to 7 from this hour to build slots 0 through 4, and needs
  -- room above it too so the "before the prompt hour" step is unambiguously before rather than
  -- accidentally landing on the 23:00 cap. 07:00-20:00 local leaves headroom on both sides.
  if v_hour < 7 or v_hour > 20 then
    raise exception using message = format(
      'This suite depends on the wall clock to exercise the hourly gate deterministically, '
      'and the local hour is %s. Run it between 07:00 and 20:00 Asia/Ho_Chi_Minh.', v_hour);
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-3-2-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  update public.profile set role = 'doer' where id = v_user;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 daily_minutes_target)
  values (v_user, gen_random_uuid(), 'Company work', 'open_ended', 'daily_hours_quota', 180)
  returning id into v_c1;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 daily_minutes_target)
  values (v_user, gen_random_uuid(), 'Reading', 'open_ended', 'daily_hours_quota', 60)
  returning id into v_c3;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 daily_minutes_target, archived_at)
  values (v_user, gen_random_uuid(), 'Archived one', 'open_ended', 'daily_hours_quota', 45, now())
  returning id into v_c4;

  -- -------------------------------------------------------------------------------
  -- 1. Before the prompt hour: nothing is enqueued, for either open commitment.
  -- -------------------------------------------------------------------------------
  update public.profile set morning_hour = v_hour where id = v_user;

  v_queued := public.enqueue_focus_prompts();

  select count(*) into v_count
    from public.outbox
   where dedupe_key like 'focus-' || v_user::text || '-%';

  if v_count <> 0 then
    raise exception using message = format(
      'Before the prompt hour, %s rows were queued rather than none. morning_hour %s puts the '
      'hour at %s, and the local hour is %s.',
      v_count, v_hour, public.focus_prompt_hour(v_hour), v_hour);
  end if;

  raise notice using message = 'Step 1 ok: before the prompt hour, nothing is enqueued.';

  -- -------------------------------------------------------------------------------
  -- 2. Past the prompt hour with nothing banked: both open commitments fire, each with its
  --    own dedupe key, and the archived one never does. This is also the "two commitments,
  --    one account" row of the matrix.
  -- -------------------------------------------------------------------------------
  update public.profile set morning_hour = v_hour - 3 where id = v_user;  -- prompt hour = v_hour

  v_queued := public.enqueue_focus_prompts();

  if v_queued <> 2 then
    raise exception using message = format(
      'Slot 0 queued %s rows rather than 2 — one per open commitment.', v_queued);
  end if;

  v_dedupe := format('focus-%s-%s-%s-0', v_user, v_c1, v_today);
  select payload ->> 'body' into v_body from public.outbox where dedupe_key = v_dedupe;

  if v_body is distinct from format('Company work, 0:00 of 3:00, as of %s.', v_clock) then
    raise exception using message = format(
      'The nothing-banked body reads "%s" rather than the template — name, 0:00 of the '
      'target, self-dated.', v_body);
  end if;

  v_dedupe := format('focus-%s-%s-%s-0', v_user, v_c3, v_today);
  select payload ->> 'body' into v_body from public.outbox where dedupe_key = v_dedupe;

  if v_body is distinct from format('Reading, 0:00 of 1:00, as of %s.', v_clock) then
    raise exception using message = format(
      'The second commitment''s body reads "%s". Two commitments under one account must '
      'enqueue independently, each against its own target.', v_body);
  end if;

  select count(*) into v_count
    from public.outbox
   where dedupe_key like 'focus-' || v_user::text || '-' || v_c4::text || '%';

  if v_count <> 0 then
    raise exception using message =
      'The archived commitment was enqueued. archived_at is not null must exclude it from '
      'the loop, at any hour.';
  end if;

  raise notice using message =
    'Step 2 ok: both open commitments fire independently with 0:00 bodies; the archived one '
    'never does.';

  -- -------------------------------------------------------------------------------
  -- 3. Same pass runs twice: a retried cron pass is a no-op.
  -- -------------------------------------------------------------------------------
  v_queued := public.enqueue_focus_prompts();

  select count(*) into v_count
    from public.outbox
   where dedupe_key like 'focus-' || v_user::text || '-%-0';

  if v_count <> 2 then
    raise exception using message = format(
      'Running slot 0 twice left %s rows rather than 2. `outbox_enqueue`''s `on conflict do '
      'nothing` is what makes a retried or overlapping cron pass safe.', v_count);
  end if;

  raise notice using message = 'Step 3 ok: the retried pass added nothing.';

  -- -------------------------------------------------------------------------------
  -- 4. Some banked, target not yet met: the body states the real fraction. A fresh slot
  --    (1) gives this pass its own dedupe key rather than colliding with slot 0's.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                    started_at, stopped_at)
  values (v_user, v_c1, gen_random_uuid(),
          (v_today + time '00:00') at time zone 'Asia/Ho_Chi_Minh',
          (v_today + time '01:20') at time zone 'Asia/Ho_Chi_Minh');  -- 80 minutes

  perform set_config('role', 'postgres', true);

  update public.profile set morning_hour = v_hour - 4 where id = v_user;  -- prompt hour, slot 1

  v_queued := public.enqueue_focus_prompts();

  v_dedupe := format('focus-%s-%s-%s-1', v_user, v_c1, v_today);
  select payload ->> 'body' into v_body from public.outbox where dedupe_key = v_dedupe;

  if v_body is distinct from format('Company work, 1:20 of 3:00, as of %s.', v_clock) then
    raise exception using message = format(
      'Eighty minutes banked against a 180-minute target reads "%s" rather than 1:20 of '
      '3:00.', v_body);
  end if;

  raise notice using message = 'Step 4 ok: the partial total reads 1:20 of 3:00.';

  -- -------------------------------------------------------------------------------
  -- 5. Target met: nothing is sent for that commitment, but its account-mate — still
  --    unmet — fires in the same pass. A quota that succeeded gets silence, not chrome.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                    started_at, stopped_at)
  values (v_user, v_c1, gen_random_uuid(),
          (v_today + time '02:00') at time zone 'Asia/Ho_Chi_Minh',
          (v_today + time '03:40') at time zone 'Asia/Ho_Chi_Minh');  -- another 100 minutes: 180

  perform set_config('role', 'postgres', true);

  update public.profile set morning_hour = v_hour - 5 where id = v_user;  -- prompt hour, slot 2

  v_queued := public.enqueue_focus_prompts();

  select count(*) into v_count
    from public.outbox
   where dedupe_key = format('focus-%s-%s-%s-2', v_user, v_c1, v_today);

  if v_count <> 0 then
    raise exception using message =
      'A commitment banked exactly its target was still enqueued. Meeting the target must '
      'silence it — this is the product''s whole answer to a quota that succeeded.';
  end if;

  select count(*) into v_count
    from public.outbox
   where dedupe_key = format('focus-%s-%s-%s-2', v_user, v_c3, v_today);

  if v_count <> 1 then
    raise exception using message = format(
      'The still-unmet commitment produced %s rows in the same pass its account-mate went '
      'quiet in, rather than 1. Silence belongs to the commitment that met its target, not '
      'to the whole pass.', v_count);
  end if;

  raise notice using message =
    'Step 5 ok: the met commitment goes quiet; the unmet one in the same account still fires.';

  -- -------------------------------------------------------------------------------
  -- 6. The four-slot bound: slot 3 still fires, slot 4 does not.
  -- -------------------------------------------------------------------------------
  update public.profile set morning_hour = v_hour - 6 where id = v_user;  -- prompt hour, slot 3

  v_queued := public.enqueue_focus_prompts();

  select count(*) into v_count
    from public.outbox
   where dedupe_key = format('focus-%s-%s-%s-3', v_user, v_c3, v_today);

  if v_count <> 1 then
    raise exception using message =
      'Slot 3 — the fourth attempt — did not fire for a commitment still unmet. '
      'focus_prompt_slots() bounds attempts to four, and this is the last of them.';
  end if;

  update public.profile set morning_hour = v_hour - 7 where id = v_user;  -- prompt hour, slot 4

  v_queued := public.enqueue_focus_prompts();

  select count(*) into v_count
    from public.outbox
   where dedupe_key like format('focus-%s-%%-%s-4', v_user, v_today);

  if v_count <> 0 then
    raise exception using message = format(
      'The fifth hourly pass (slot 4) queued %s rows. The day must stay quiet after four.',
      v_count);
  end if;

  raise notice using message =
    'Step 6 ok: the fourth attempt (slot 3) still fires, and the fifth (slot 4) does not.';

  -- -------------------------------------------------------------------------------
  -- 7. D1's cap, checked directly: 22 and 20 both derive 23, never 24 or 25.
  -- -------------------------------------------------------------------------------
  if public.focus_prompt_hour(22) <> 23 then
    raise exception using message = format(
      'focus_prompt_hour(22) reads %s rather than 23. least(22 + 3, 23) caps it so a late '
      'morning hour is still checked the same calendar day rather than wrapping into the '
      'next one.', public.focus_prompt_hour(22));
  end if;

  if public.focus_prompt_hour(20) <> 23 then
    raise exception using message = format(
      'focus_prompt_hour(20) reads %s rather than 23. 20 + 3 = 23 exactly, so this is the '
      'boundary at which the cap starts mattering at all.', public.focus_prompt_hour(20));
  end if;

  if public.focus_prompt_hour(19) <> 22 then
    raise exception using message = format(
      'focus_prompt_hour(19) reads %s rather than 22 — below the boundary, the cap must not '
      'engage and change an hour that did not need capping.', public.focus_prompt_hour(19));
  end if;

  if public.focus_prompt_hour(0) <> 3 then
    raise exception using message = format(
      'focus_prompt_hour(0) reads %s rather than 3. No account can be prompted before 03:00 '
      'local, since morning_hour never reads below 0.', public.focus_prompt_hour(0));
  end if;

  raise notice using message =
    'Step 7 ok: 22 and 20 both cap to 23; 19 does not; the earliest possible hour is 3.';

  -- -------------------------------------------------------------------------------
  -- 8. A commitment named with a banned phrase does not poison the pass.
  --
  -- `push_body_is_sendable` refuses a body containing "right now", among other present-tense
  -- phrases — and a commitment name is freeform text the author typed, so it can collide with
  -- that rule by accident. Unguarded, that body would have reached `outbox_enqueue` and the
  -- table's own check constraint would have raised, unwinding the whole call to
  -- `enqueue_focus_prompts()` in one statement: every row already enqueued that pass, for
  -- every account processed before the poisoned one, rolls back with it. This proves the
  -- opposite — the poisoned commitment is skipped, and a second account processed in the very
  -- same call still gets its row.
  -- -------------------------------------------------------------------------------
  declare
    v_poisoned uuid;
    v_other    uuid := gen_random_uuid();
    v_c5       uuid;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   daily_minutes_target)
    values (v_user, gen_random_uuid(), 'Reading right now', 'open_ended',
            'daily_hours_quota', 30)
    returning id into v_poisoned;

    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_other, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'retro-3-2-other-' || v_other::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

    update public.profile set role = 'doer', morning_hour = v_hour - 3 where id = v_other;

    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   daily_minutes_target)
    values (v_other, gen_random_uuid(), 'Stretch', 'open_ended', 'daily_hours_quota', 30)
    returning id into v_c5;

    -- Back to slot 0 for the account that carries the poisoned commitment. C1 and C3 already
    -- hold slot-0 rows from step 2; this only adds one for the brand-new commitment, under its
    -- own dedupe key.
    update public.profile set morning_hour = v_hour - 3 where id = v_user;

    v_queued := public.enqueue_focus_prompts();

    select count(*) into v_count
      from public.outbox
     where dedupe_key = format('focus-%s-%s-%s-0', v_user, v_poisoned, v_today);

    if v_count <> 0 then
      raise exception using message =
        'A commitment named with a banned phrase was still enqueued. push_body_is_sendable '
        'exists precisely to refuse this, before the table''s own check constraint has to.';
    end if;

    select count(*) into v_count
      from public.outbox
     where dedupe_key = format('focus-%s-%s-%s-0', v_other, v_c5, v_today);

    if v_count <> 1 then
      raise exception using message = format(
        'A second account processed in the same call as the poisoned commitment produced %s '
        'rows rather than 1. One badly-named commitment must not roll back every row already '
        'enqueued this pass for accounts processed before or after it.', v_count);
    end if;
  end;

  raise notice using message =
    'Step 8 ok: a poisoned commitment name is skipped, and another account processed in the '
    'same call still gets its row.';

  -- -------------------------------------------------------------------------------
  -- 9. Cadence exclusion, proven rather than only read: a weekly_quota commitment under
  --    an otherwise-eligible account is never enqueued by this pipeline. Scoped to a fresh
  --    account's own dedupe-key prefix, since by this point in the file other accounts'
  --    still-unmet commitments (`v_c3`, `v_c5`) remain eligible every pass and would make
  --    the function's own return value meaningless as a global "nothing fired" signal.
  -- -------------------------------------------------------------------------------
  declare
    v_cadence_user uuid := gen_random_uuid();
    v_weekly       uuid;
  begin
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_cadence_user, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'retro-3-2-cadence-' || v_cadence_user::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

    update public.profile set role = 'doer', morning_hour = v_hour - 3
     where id = v_cadence_user;  -- prompt hour = v_hour, slot 0

    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   weekly_target, week_start_day)
    values (v_cadence_user, gen_random_uuid(), 'Gym', 'do', 'weekly_quota', 3, 1)
    returning id into v_weekly;

    perform public.enqueue_focus_prompts();

    select count(*) into v_count
      from public.outbox
     where dedupe_key like 'focus-' || v_cadence_user::text || '-%';

    if v_count <> 0 then
      raise exception using message = format(
        'A weekly_quota commitment was enqueued by the daily-hours prompt pipeline (%s rows). '
        'enqueue_focus_prompts() filters c.cadence = ''daily_hours_quota'' and this must '
        'actually exclude every other cadence, not merely never have been asked to include '
        'one.', v_count);
    end if;
  end;

  raise notice using message =
    'Step 9 ok: a weekly_quota commitment under an otherwise-eligible account is never '
    'enqueued by the daily-hours prompt pipeline.';

  -- -------------------------------------------------------------------------------
  -- 10. Role exclusion: a referee account with an otherwise fully-eligible
  --     daily_hours_quota commitment is never enqueued. `enqueue_focus_prompts()` loops
  --     `where p.role = 'doer'`, the same filter `enqueue_gate_reminders()` uses, and
  --     this proves it against a counter-example rather than only against absence.
  -- -------------------------------------------------------------------------------
  declare
    v_referee     uuid := gen_random_uuid();
    v_referee_com uuid;
  begin
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_referee, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'retro-3-2-referee-' || v_referee::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

    update public.profile set role = 'referee', morning_hour = v_hour - 3
     where id = v_referee;  -- prompt hour = v_hour, slot 0 — fully eligible but for role

    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   daily_minutes_target)
    values (v_referee, gen_random_uuid(), 'Reading', 'open_ended', 'daily_hours_quota', 30)
    returning id into v_referee_com;

    perform public.enqueue_focus_prompts();

    select count(*) into v_count
      from public.outbox
     where dedupe_key like 'focus-' || v_referee::text || '-%';

    if v_count <> 0 then
      raise exception using message = format(
        'A referee account''s otherwise-eligible commitment was enqueued (%s rows). This '
        'pipeline asks only doers where they stand — the morning question and now this one '
        'both belong to the person doing the work, not the one refereeing it.', v_count);
    end if;
  end;

  raise notice using message =
    'Step 10 ok: a referee account with an otherwise fully-eligible commitment is never '
    'enqueued — the role filter excludes it, not merely coincidence.';

  -- -------------------------------------------------------------------------------
  -- 11. The fully-silent account: every one of an account's daily_hours_quota
  --     commitments already at target produces zero rows, asserted directly rather than
  --     only through the mixed one-met-one-unmet scenario step 5 already covers.
  -- -------------------------------------------------------------------------------
  declare
    v_silent_user uuid := gen_random_uuid();
    v_silent_com  uuid;
  begin
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_silent_user, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'retro-3-2-silent-' || v_silent_user::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

    update public.profile set role = 'doer', morning_hour = v_hour - 3
     where id = v_silent_user;  -- prompt hour = v_hour, slot 0

    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   daily_minutes_target)
    values (v_silent_user, gen_random_uuid(), 'Reading', 'open_ended',
            'daily_hours_quota', 30)
    returning id into v_silent_com;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_silent_user, 'role', 'authenticated',
                         'app_role', 'doer')::text, true);
    perform set_config('role', 'authenticated', true);

    insert into public.focus_session (owner_id, commitment_id, idempotency_key,
                                      started_at, stopped_at)
    values (v_silent_user, v_silent_com, gen_random_uuid(),
            (v_today + time '00:00') at time zone 'Asia/Ho_Chi_Minh',
            (v_today + time '00:30') at time zone 'Asia/Ho_Chi_Minh');  -- exactly the target

    perform set_config('role', 'postgres', true);

    perform public.enqueue_focus_prompts();

    select count(*) into v_count
      from public.outbox
     where dedupe_key like 'focus-' || v_silent_user::text || '-%';

    if v_count <> 0 then
      raise exception using message = format(
        'An account whose every commitment is already at target was still enqueued (%s '
        'rows). The whole product answer to a quota that succeeded is silence, for every '
        'commitment an account has, not only whichever one a mixed test happened to leave '
        'unmet.', v_count);
    end if;
  end;

  raise notice using message =
    'Step 11 ok: an account whose every commitment is already at target produces zero rows.';

  raise notice using message =
    'PASS. The prompt is silent before its hour, states the real fraction once it has passed, '
    'goes quiet the moment a target is met without silencing its account-mate, stops after '
    'four attempts, never repeats a pass, never speaks for an archived commitment, its hour '
    'caps at 23 rather than wrapping into the next day, a single badly-named commitment '
    'cannot take the whole pass down with it, a weekly_quota commitment and a non-doer '
    'account are both excluded outright, and an account whose every commitment is already '
    'met is silent in full, not only in the one commitment a mixed test happened to leave '
    'unmet.';
end $$;

rollback;
