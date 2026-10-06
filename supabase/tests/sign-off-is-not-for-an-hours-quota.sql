-- An hours quota cannot ask for the referee's signature (20261005120000).
--
-- `commitment_sign_off_not_on_hours_quota` (20261005120000) closes the row half of Story 8.1's deferred entry. What
-- is asserted, in both directions so the check is neither missing nor too wide:
--
--   1. Inserting `do` + `daily_hours_quota` + the flag is refused.
--   2. Moving a flagged daily commitment to an hours quota is refused while the flag stays on.
--   3. The same move with the flag switched off in the same update is accepted -- the one path
--      sign_off_day()'s own hours-quota refusal still guards, which
--      8-2-the-referee-s-decision-and-what-a-refusal-costs.sql drives.
--   4. The flag on a daily Do-it commitment is still accepted, so the check refuses the cadence
--      and nothing else.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/sign-off-is-not-for-an-hours-quota.sql
--
-- One transaction, rolled back at the end. It settles nothing and is safe against any database.

begin;

do $$
declare
  v_doer    uuid := gen_random_uuid();
  v_referee uuid := gen_random_uuid();
  v_daily   uuid;
  v_refused boolean;
  v_cadence public.commitment_cadence;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'hours-sign-off-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_doer, v_referee]) as t(id);

  -- The pairing first: commitment_sign_off_needs_a_referee() refuses a flag with nobody to ask,
  -- and that is a different refusal from the one under test.
  update public.profile set role = 'referee', referee_of = v_doer where id = v_referee;

  -- 1. The combination, inserted outright.
  v_refused := false;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   carries_penalty, requires_photo, requires_referee_approval,
                                   daily_minutes_target)
    values (v_doer, gen_random_uuid(), 'Deep work', 'do', 'daily_hours_quota',
            true, true, true, 60);
  exception when check_violation then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'An hours-quota commitment asking for the referee''s signature was stored. No day of it can '
      'ever be signed off, and the setup warning would promise the author that one can.';
  end if;

  raise notice using message = 'Step 1 ok: the flag on an hours quota is refused at insert.';

  -- 4, first, because 2 and 3 need it: the flag on a daily Do-it commitment is still fine.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Gym', 'do', 'daily', true, true, true)
  returning id into v_daily;

  raise notice using message = 'Step 4 ok: the flag on a daily Do-it commitment is accepted.';

  -- 2. Moved to an hours quota with the flag left on.
  v_refused := false;
  begin
    update public.commitment
       set cadence = 'daily_hours_quota', daily_minutes_target = 60
     where id = v_daily;
  exception when check_violation then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'A flagged commitment was moved to an hours quota with the flag still on. The check has to '
      'hold on update as well as insert, or the combination is one edit away.';
  end if;

  raise notice using message =
    'Step 2 ok: moving a flagged commitment to an hours quota is refused while the flag is on.';

  -- 3. The same move with the flag switched off in the same statement.
  update public.commitment
     set cadence = 'daily_hours_quota', daily_minutes_target = 60,
         requires_referee_approval = false
   where id = v_daily;

  select cadence into v_cadence from public.commitment where id = v_daily;
  if v_cadence is distinct from 'daily_hours_quota' then
    raise exception using message =
      'Moving a commitment to an hours quota while switching the flag off was refused. The check '
      'refuses the combination, not the move.';
  end if;

  raise notice using message =
    'Step 3 ok: the move is accepted once the flag comes off in the same update.';
  raise notice using message =
    'PASS. An hours quota cannot carry the flag, and nothing else about the flag changed.';
end $$;

rollback;
