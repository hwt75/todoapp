-- A photo does not outlive its usefulness.
--
-- The retention pass removes a photograph's bytes after 30 days. The row stays, and that is the
-- part worth proving: `commitments_owing()` and `weekly_held_count()` read whether an `evidence`
-- row exists to decide whether a claimed day held, and `apply_grace_days()` re-reads the former
-- when correcting an old day. A sweep that deleted rows would turn held days into slipped days and
-- mint penalties nobody earned.
--
-- So this file asserts two things that pull in opposite directions: the photo is named for removal,
-- and the verdict does not move when it is.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/a-photo-does-not-outlive-its-usefulness.sql
--
-- One transaction, rolled back at the end.

begin;

-- The bucket both photos below belong to. It is `config.toml` configuration created by the CLI
-- through the storage API, not by a migration, so a database started with `-x storage-api` --
-- which is how CI starts it -- has the schema but not the row. Staged here so the file still runs
-- against any database, and it rolls back with everything else.
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;

do $$
declare
  v_doer    uuid := gen_random_uuid();
  v_c       uuid;
  v_decl    uuid;
  v_day     date;
  v_ev      uuid := gen_random_uuid();
  v_fresh   uuid := gen_random_uuid();

  v_named   integer;
  v_owing   public.declaration_answer;
  v_after   public.declaration_answer;
  v_stamped integer;
  v_swept   timestamptz;

  v_now_min integer := floor(extract(epoch from (now() at time zone 'Asia/Ho_Chi_Minh')::time) / 60)::int;
  v_due_min integer := greatest(0, v_now_min + 1 - 240);
  v_win     integer;
begin
  v_win := greatest(5, v_now_min + 1 - v_due_min);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_doer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'retention-' || gen_random_uuid()::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  -- A timed commitment, so the claim lands on the day it was made rather than the previous one.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 due_time, late_window_minutes)
  values (v_doer, gen_random_uuid(), 'Gym', 'do', 'daily', true,
          (v_due_min * interval '1 minute')::time, v_win)
  returning id into v_c;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_doer, 'role', 'authenticated',
                                       'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at,
                                  claimed_timed)
  values (v_doer, v_c, gen_random_uuid(), 'held', now(), true)
  returning id, for_day into v_decl, v_day;

  -- The object first: since `20260910090000` an evidence row must name a photo that was really
  -- uploaded. Filed as postgres, ahead of the row the doer session then files -- what this file
  -- is about is what happens to the bytes at thirty days, not who may put them there.
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_decl::text || '/' || v_ev::text || '/proof.jpg', v_doer);
  perform set_config('role', 'authenticated', true);

  insert into public.evidence (id, declaration_id, storage_path, captured_on)
  values (v_ev, v_decl, v_decl::text || '/' || v_ev::text || '/proof.jpg', v_day);

  perform set_config('role', 'postgres', true);

  -- The claim reads `held` only because that row exists. Recorded before anything is swept, so
  -- the comparison afterwards is against a real reading rather than an assumption.
  select answer into v_owing
    from public.commitments_owing(v_doer, v_day) where commitment_id = v_c;

  if v_owing is distinct from 'held' then
    raise exception 'Fixture is wrong: the proved claim should read held, got %.', v_owing;
  end if;

  -- ------------------------------------------------------------------ nothing is due yet

  select count(*) into v_named from public.expired_evidence_objects(interval '30 days', 100);
  if v_named <> 0 then
    raise exception 'A photo stored moments ago must not be named for removal. Named %.', v_named;
  end if;

  -- ------------------------------------------------------------------ past the period

  -- Age the row rather than waiting thirty days. `created_at` is what retention measures, on
  -- purpose: it is how long the bytes have been *stored*, which is what costs.
  update public.evidence set created_at = now() - interval '31 days' where id = v_ev;

  select count(*) into v_named from public.expired_evidence_objects(interval '30 days', 100);
  if v_named <> 1 then
    raise exception 'A photo past the retention period must be named exactly once. Named %.',
      v_named;
  end if;

  -- A second, still-fresh photo must not be swept alongside it.
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_decl::text || '/' || v_fresh::text || '/fresh.jpg', v_doer);

  insert into public.evidence (id, declaration_id, storage_path, captured_on)
  values (v_fresh, v_decl, v_decl::text || '/' || v_fresh::text || '/fresh.jpg', v_day);

  if exists (select 1 from public.expired_evidence_objects(interval '30 days', 100)
              where evidence_id = v_fresh) then
    raise exception 'A photo inside the retention period was named for removal.';
  end if;

  -- ------------------------------------------------------------------ stamping

  select public.mark_evidence_swept(array[v_ev]) into v_stamped;
  if v_stamped <> 1 then
    raise exception 'Stamping the swept photo should have touched one row, touched %.', v_stamped;
  end if;

  select swept_at into v_swept from public.evidence where id = v_ev;
  if v_swept is null then
    raise exception 'swept_at was not set.';
  end if;

  -- Never named twice: the column has to keep the instant of the real removal, not the last time
  -- a job looked at the row.
  if exists (select 1 from public.expired_evidence_objects(interval '30 days', 100)
              where evidence_id = v_ev) then
    raise exception 'An already-swept photo was named again.';
  end if;

  select public.mark_evidence_swept(array[v_ev]) into v_stamped;
  if v_stamped <> 0 then
    raise exception 'Re-stamping an already-swept row must touch nothing, touched %.', v_stamped;
  end if;

  -- ------------------------------------------------------------------ the verdict does not move

  -- The whole reason the row survives. If this ever fails, the sweep is minting penalties.
  select answer into v_after
    from public.commitments_owing(v_doer, v_day) where commitment_id = v_c;

  if v_after is distinct from v_owing then
    raise exception
      'Sweeping a photo changed what the day owes: was %, now %. The evidence row must survive '
      'the sweep -- commitments_owing() reads its existence to decide whether the claim held.',
      v_owing, v_after;
  end if;

  if not exists (select 1 from public.evidence where id = v_ev) then
    raise exception 'The evidence row was deleted. It decides whether the day held.';
  end if;

  -- ------------------------------------------------------------------ not for clients

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_doer, 'role', 'authenticated',
                                       'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  begin
    perform public.expired_evidence_objects(interval '30 days', 100);
    raise exception 'A client must not be able to list every account''s storage paths.';
  exception
    when insufficient_privilege then null;
  end;

  begin
    perform public.mark_evidence_swept(array[v_fresh]);
    raise exception 'A client must not be able to stamp evidence rows.';
  exception
    when insufficient_privilege then null;
  end;

  perform set_config('role', 'postgres', true);

  raise notice 'a photo does not outlive its usefulness: all assertions passed';
end $$;

rollback;
