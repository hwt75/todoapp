-- A photo that proves nothing does not stay forever.
--
-- Attaching a photo is two writes: the object into Storage, then the `evidence` row that gives it
-- meaning. Every refusal `evidence_derive_owner()` can raise happens between them -- a capture date
-- that does not match the day, a day that has already ended, a parent the caller does not own -- so
-- the object exists, proves nothing, and until now nothing in the product could remove it.
--
-- What is asserted here is the *decision*, which is the dangerous half. The deletion itself belongs
-- to the Edge Function, because the Storage API is the only path that removes the stored bytes as
-- well as the row; a database that could delete the row would be able to half-delete an object
-- without ever being able to finish. So this file proves exactly one thing, in both directions:
-- which objects the sweeper is allowed to name.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/evidence-orphan-sweeper.sql
--
-- One transaction, rolled back at the end. Safe against any database.

begin;

grant select on table public.profile, public.commitment to authenticated;

-- The bucket is `config.toml` configuration created by the CLI through the storage API, not by a
-- migration, so a database started with `-x storage-api` -- which is how CI starts it -- has the
-- schema but not the row. Staged here for the same reason 4-6 and 6-8 stage it.
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;

-- A second bucket, so "this sweeper owns one bucket" is asserted against a real neighbour rather
-- than assumed. Rolled back with everything else, exactly like the one above.
insert into storage.buckets (id, name)
values ('not-evidence', 'not-evidence')
on conflict (id) do nothing;

do $$
declare
  v_owner      uuid := gen_random_uuid();
  v_commitment uuid;
  v_today      date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  v_orphan     text;
  v_in_grace   text;
  v_referenced text;
  v_elsewhere  text;

  v_named      text[];
  v_refused    boolean;
  v_count      integer;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'orphan-sweeper-' || gen_random_uuid()::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, requires_photo)
  values (v_owner, gen_random_uuid(), 'Sketchbook', 'do', 'daily', true)
  returning id into v_commitment;

  v_orphan     := v_commitment::text || '/' || gen_random_uuid()::text || '.jpg';
  v_in_grace   := v_commitment::text || '/' || gen_random_uuid()::text || '.jpg';
  v_referenced := v_commitment::text || '/' || gen_random_uuid()::text || '.jpg';
  v_elsewhere  := v_commitment::text || '/' || gen_random_uuid()::text || '.jpg';

  -- 1. A real orphan: old enough that its second write is never coming, and nothing points at it.
  insert into storage.objects (bucket_id, name, owner, created_at)
  values ('appeal-evidence', v_orphan, v_owner, now() - interval '3 hours');

  -- 2. An upload whose `evidence` row has not been written *yet*. Indistinguishable from an orphan
  --    except by age, which is the entire reason the grace period exists.
  insert into storage.objects (bucket_id, name, owner, created_at)
  values ('appeal-evidence', v_in_grace, v_owner, now() - interval '2 minutes');

  -- 3. A photo doing its job. Old, and pointed at.
  insert into storage.objects (bucket_id, name, owner, created_at)
  values ('appeal-evidence', v_referenced, v_owner, now() - interval '3 hours');

  insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
  values (v_commitment, v_today, v_referenced, v_today);

  -- 4. Someone else's bucket. Old and unreferenced, and none of this sweeper's business.
  insert into storage.objects (bucket_id, name, owner, created_at)
  values ('not-evidence', v_elsewhere, v_owner, now() - interval '3 hours');

  -- -------------------------------------------------------------------------------
  -- The decision.
  -- -------------------------------------------------------------------------------
  select array_agg(o order by o) into v_named
    from public.orphaned_evidence_objects() o;

  if v_named is distinct from array[v_orphan] then
    raise exception using message = format(
      'The sweeper named %s, expected exactly the one orphan. Everything it names is deleted '
      'from Storage, bytes and all, so naming one object too many is the only mistake here that '
      'cannot be undone.', coalesce(array_to_string(v_named, ', '), 'nothing at all'));
  end if;

  -- Each exclusion again, one at a time, so a failure says which rule broke rather than only that
  -- the array did not match.
  if v_in_grace = any (v_named) then
    raise exception using message =
      'An object two minutes old was named. Its `evidence` row may still be on its way -- that is '
      'the ordinary shape of an upload, not an abandoned one.';
  end if;

  if v_referenced = any (v_named) then
    raise exception using message =
      'An object an `evidence` row points at was named. It is proving a day right now.';
  end if;

  if v_elsewhere = any (v_named) then
    raise exception using message =
      'An object in another bucket was named. This sweeper owns `appeal-evidence` and nothing '
      'else, and a bucket it does not own is one it knows nothing about.';
  end if;

  raise notice using message =
    'Step 1 ok: only the aged, unreferenced object in this sweeper''s own bucket is named.';

  -- -------------------------------------------------------------------------------
  -- The grace period is a parameter, and it is the boundary that matters.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count
    from public.orphaned_evidence_objects(interval '1 minute') o
   where o = v_in_grace;

  if v_count <> 1 then
    raise exception using message =
      'With a one-minute grace period the two-minute-old object was still not named, so the '
      'default is not what is excluding it and this file proves less than it appears to.';
  end if;

  select count(*) into v_count
    from public.orphaned_evidence_objects(interval '1 minute') o
   where o = v_referenced;

  if v_count <> 0 then
    raise exception using message =
      'Shortening the grace period exposed a referenced object. Age and reference are two '
      'independent guards, and neither may stand in for the other.';
  end if;

  raise notice using message =
    'Step 2 ok: the grace period is what withholds a young object, and shortening it never '
    'exposes a referenced one.';

  -- -------------------------------------------------------------------------------
  -- The batch is real.
  -- -------------------------------------------------------------------------------
  insert into storage.objects (bucket_id, name, owner, created_at)
  select 'appeal-evidence',
         v_commitment::text || '/' || gen_random_uuid()::text || '.jpg',
         v_owner,
         now() - interval '3 hours'
    from generate_series(1, 5);

  select count(*) into v_count from public.orphaned_evidence_objects(interval '1 hour', 3) o;

  if v_count <> 3 then
    raise exception using message = format(
      'A batch of 3 returned %s names. One pass has to be bounded, or a backlog is one statement '
      'that runs for as long as it takes.', v_count);
  end if;

  raise notice using message = 'Step 3 ok: the batch bounds one pass.';

  -- -------------------------------------------------------------------------------
  -- No client may ask.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    perform 1 from public.orphaned_evidence_objects();
  exception when others then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A doer session listed every unreferenced object in the bucket. The answer is a list of '
      'storage paths belonging to whoever owns them, and the only caller that needs it is the '
      'worker.';
  end if;

  raise notice using message = 'Step 4 ok: a client session cannot ask which objects are orphans.';

  raise notice using message =
    'PASS. The sweeper names an aged, unreferenced object in its own bucket and nothing else: not '
    'one still inside the grace period, not one an `evidence` row points at, not one in another '
    'bucket. Its batch bounds a pass, and no client may ask it anything.';
end $$;

rollback;
