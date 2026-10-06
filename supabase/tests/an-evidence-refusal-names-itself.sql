-- An evidence refusal names itself (20261005130000).
--
-- Each refusal evidence_derive_owner() and evidence_object_must_exist() raise carries a stable
-- `hint`, which is what the client keys its own sentence off rather than the database's message.
-- Asserted for every one of the five, and that the message itself did not move -- other files
-- still read it with `ilike`.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/an-evidence-refusal-names-itself.sql
--
-- One transaction, rolled back at the end. It settles nothing.

begin;

do $$
declare
  v_doer    uuid := gen_random_uuid();
  v_c       uuid;
  v_decl    uuid;
  v_today   date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_case    text;
  v_hint    text;
  v_message text;
  v_refused boolean;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_doer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'evidence-hint-' || v_doer::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_doer, gen_random_uuid(), 'Gym', 'do', 'daily')
  returning id into v_c;
  update public.commitment set created_at = now() - interval '90 days' where id = v_c;

  -- The morning answer, inserted now: an untimed answer lands on the day before its instant, so
  -- this claim belongs to a day that has already ended -- the case `day-ended` is about.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_doer, v_c, gen_random_uuid(), 'held', now())
  returning id into v_decl;

  foreach v_case in array array[
    'evidence:no-parent',
    'evidence:day-ended',
    'evidence:not-today',
    'evidence:wrong-capture-date',
    'evidence:no-object'
  ]
  loop
    v_refused := false;
    v_hint := null;
    begin
      if v_case = 'evidence:no-parent' then
        insert into public.evidence (declaration_id, storage_path, captured_on)
        values (gen_random_uuid(), 'nowhere/a.jpg', v_today);
      elsif v_case = 'evidence:day-ended' then
        insert into public.evidence (declaration_id, storage_path, captured_on)
        values (v_decl, v_decl::text || '/a.jpg', v_today);
      elsif v_case = 'evidence:not-today' then
        insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
        values (v_c, v_today - 1, v_c::text || '/a.jpg', v_today - 1);
      elsif v_case = 'evidence:wrong-capture-date' then
        insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
        values (v_c, v_today, v_c::text || '/a.jpg', v_today - 1);
      else
        -- A good row in every way but the one this trigger checks: no object behind the path.
        insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
        values (v_c, v_today, v_c::text || '/never-uploaded.jpg', v_today);
      end if;
    exception when raise_exception then
      v_refused := true;
      get stacked diagnostics v_hint = pg_exception_hint, v_message = message_text;
    end;

    if not v_refused then
      raise exception using message = format(
        'The %s case was not refused at all, so its hint cannot be asserted.', v_case);
    end if;

    if v_hint is distinct from v_case then
      raise exception using message = format(
        'The %s refusal carried hint %s (message: %s). The client keys its sentence off the hint, '
        'so a missing or different one sends the author the database''s own words again.',
        v_case, coalesce(v_hint, '<none>'), v_message);
    end if;
  end loop;

  raise notice using message =
    'Step 1 ok: all five evidence refusals carry their own hint.';

  -- The messages did not move: other files assert them with ilike.
  begin
    insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
    values (v_c, v_today, v_c::text || '/a.jpg', v_today - 1);
  exception when raise_exception then
    get stacked diagnostics v_message = message_text;
  end;

  if v_message <> 'Evidence must be dated the day it proves.' then
    raise exception using message = format(
      'The capture-date refusal now reads "%s". Adding a hint was not meant to change a word.',
      v_message);
  end if;

  raise notice using message =
    'PASS. Every evidence refusal names itself, and no message changed.';
end $$;

rollback;
