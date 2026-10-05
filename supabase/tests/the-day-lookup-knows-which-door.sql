-- The referee's day lookup says which door a commitment-day belonged to (20261005100000).
--
-- object_to_day() refuses a commitment that asked for the referee's signature on the day it names
-- (Story 8.2). referee_day_lookup() now reports that same fact, read through the same door, so
-- the screen stops offering a control the database refuses every time. Asserted here:
--
--   1. The ACL survived the drop: `authenticated` may execute it, `anon` may not.
--   2. A flagged commitment's row reads asked_for_signature = true, as of the day looked up --
--      the flag is switched off afterwards and the row still reads true, because object_to_day()
--      still refuses it.
--   3. An unflagged commitment's row on the same day reads false, so the column is a fact about
--      the commitment and not a constant.
--   4. The two agree: object_to_day() refuses the row the lookup marks, in its own words.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/the-day-lookup-knows-which-door.sql
--
-- One transaction, rolled back at the end. Needs a database with no live doer (AD-16).

begin;

do $$
begin
  if not has_function_privilege('authenticated', 'public.referee_day_lookup(uuid)', 'execute') then
    raise exception using message =
      '`authenticated` cannot EXECUTE referee_day_lookup(uuid). The drop in 20261005100000 '
      'destroyed the grant and nothing re-issued it -- the referee''s lookup is dead.';
  end if;

  if has_function_privilege('anon', 'public.referee_day_lookup(uuid)', 'execute') then
    raise exception using message =
      '`anon` can EXECUTE referee_day_lookup(uuid) again. The drop in 20261005100000 handed it '
      'back through default privileges -- the accident 20260914140000 repaired once already.';
  end if;

  raise notice using message =
    'Step 1 ok: referee_day_lookup() is executable by `authenticated` and not by `anon`.';
end $$;

do $$
declare
  v_doer      uuid := gen_random_uuid();
  v_referee   uuid := gen_random_uuid();
  v_flagged   uuid;
  v_plain     uuid;
  v_day       date;
  v_s         uuid;
  v_verdict   public.day_verdict;

  v_flag_row  boolean;
  v_plain_row boolean;
  v_rows      integer;
  v_refused   boolean := false;
  v_message   text;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override '
      '(AD-16). Run against a local or branch database instead.';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'day-lookup-door-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_doer, v_referee]) as t(id);

  -- `referee_of` lives on the referee's row and points at the doer. It has to exist before the
  -- flagged commitment does: commitment_sign_off_needs_a_referee() fires at write time.
  update public.profile set role = 'referee', referee_of = v_doer where id = v_referee;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_flagged;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_doer, gen_random_uuid(), 'No sugar', 'abstain', 'daily', true)
  returning id into v_plain;

  -- Two days back, so the morning the claims are stamped is in the past at any hour this runs.
  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 2;

  -- Both commitments predate the day, and so does the flag's log -- otherwise
  -- requires_referee_approval_as_of() would answer from its backward extrapolation rather than the
  -- day-start branch (8-2-the-referee-s-decision-and-what-a-refusal-costs.sql, Account J).
  update public.commitment set created_at = now() - interval '90 days'
   where id in (v_flagged, v_plain);
  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_day) - interval '10 days'
   where commitment_id = v_flagged;

  -- Both held, answered the morning after. Nobody decided the flagged one, so silence approved it.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values
    (v_doer, v_flagged, gen_random_uuid(), 'held',
     ((v_day + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh'),
    (v_doer, v_plain, gen_random_uuid(), 'held',
     ((v_day + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  perform public.settle_day(v_day, true);

  select id, verdict into v_s, v_verdict from public.settlement
   where subject = v_doer and period = v_day and kind = 'day' and supersedes is null;

  if v_s is null or v_verdict <> 'clean' then
    raise exception using message = format(
      'Fixture setup failed: the day settled `%s`, expected `clean`.',
      coalesce(v_verdict::text, '<none>'));
  end if;

  -- Switched off today. The day looked up still belonged to the signature door.
  update public.commitment set requires_referee_approval = false where id = v_flagged;

  if public.requires_referee_approval_as_of(v_flagged, v_day) is not true then
    raise exception using message =
      'Fixture setup failed: the flagged commitment must still read flagged as of the day, or '
      'step 2 would prove nothing about the historical read.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select count(*) into v_rows from public.referee_day_lookup(v_s);
  select l.asked_for_signature into v_flag_row
    from public.referee_day_lookup(v_s) l where l.commitment_id = v_flagged;
  select l.asked_for_signature into v_plain_row
    from public.referee_day_lookup(v_s) l where l.commitment_id = v_plain;

  begin
    perform public.object_to_day(v_s, v_flagged, 'I did not see him there.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  if v_rows <> 2 then
    raise exception using message = format(
      'The paired referee read %s row(s) for the day, expected 2.', v_rows);
  end if;

  if v_flag_row is not true then
    raise exception using message = format(
      'The flagged commitment''s row reads asked_for_signature = %s, expected true. The screen '
      'would offer the Object control on a row object_to_day() always refuses.',
      coalesce(v_flag_row::text, '<null>'));
  end if;

  raise notice using message =
    'Step 2 ok: the flagged row reads asked_for_signature, as of the day, after the flag went off.';

  if v_plain_row is not false then
    raise exception using message = format(
      'The unflagged commitment''s row reads asked_for_signature = %s, expected false -- the '
      'objection is the only door that row has.', coalesce(v_plain_row::text, '<null>'));
  end if;

  raise notice using message = 'Step 3 ok: the unflagged row on the same day reads false.';

  if not v_refused or v_message not ilike '%signature on the day itself%' then
    raise exception using message = format(
      'object_to_day() and the lookup disagree about the flagged row: refused=%s, message=%s.',
      v_refused, coalesce(v_message, '<null>'));
  end if;

  raise notice using message =
    'Step 4 ok: object_to_day() refuses exactly the row the lookup marks.';
  raise notice using message =
    'PASS. The lookup and the objection read one door, so the screen offers only what is allowed.';
end $$;

rollback;
