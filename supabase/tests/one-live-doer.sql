-- At most one live doer.
--
-- `is_live_doer` is the flag AD-16 rests on: `settle_day()` raises rather than skipping when
-- `p_override` meets a live doer, so one live account disables the override for the entire call.
-- Until 2026-09-07 it also decided who could hand out the referee slot.
--
-- Nothing enforced that there was only one of them, and on that date the live project carried two
-- -- an empty account flagged by hand during testing beside the real one. Neither the schema nor
-- any test said so, which is the whole reason this file exists: a flag several rules lean on, held
-- true by habit rather than by the database.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/one-live-doer.sql
--
-- One transaction, rolled back at the end.

begin;

do $$
declare
  v_first  uuid := gen_random_uuid();
  v_second uuid := gen_random_uuid();
  v_case   text;
  v_refused boolean;
begin
  foreach v_case in array array['first', 'second']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case when 'first' then v_first else v_second end,
            '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'one-live-doer-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  -- The first is ordinary: a database with no live doer gets one.
  update public.profile set is_live_doer = true where id = v_first;

  if not exists (select 1 from public.profile where id = v_first and is_live_doer) then
    raise exception using message =
      'The first account could not be marked the live doer at all. The index is meant to cap the '
      'flag at one, not to forbid it.';
  end if;

  -- The second is the case that reached production.
  v_refused := false;
  begin
    update public.profile set is_live_doer = true where id = v_second;
  exception when unique_violation then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'A second account was marked the live doer. AD-16 reads this flag to decide whose days may '
      'be settled with an override, and it was carried by two accounts on the live project on '
      '2026-09-07 with nothing to say so.';
  end if;

  -- And clearing the first frees the slot, so the flag can be moved rather than only set once.
  update public.profile set is_live_doer = false where id = v_first;
  update public.profile set is_live_doer = true where id = v_second;

  if not exists (select 1 from public.profile where id = v_second and is_live_doer) then
    raise exception using message =
      'The flag could not be moved to another account once the first released it. A cap of one is '
      'not the same as a one-way door.';
  end if;

  raise notice using message =
    'PASS. One account may carry is_live_doer, a second is refused by the index rather than by '
    'anyone remembering, and the flag can still be moved.';
end $$;

rollback;
