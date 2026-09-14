-- The referee can see what the day was proved with.
--
-- Epic 6 retrospective item 43 / defect A2. He could already *read* a claim's evidence row and sign
-- the object behind it; what he had no way to do was the join, because no `declaration: referee`
-- policy exists and an evidence row reaches him carrying a `declaration_id` he cannot resolve. The
-- join moved into `referee_day_lookup()` rather than into a new policy, so what this file has to
-- prove is two things at once: that he now gets the paths, and that his raw reach did not widen to
-- give them to him.
--
-- **Amended by Story 8.3, which made one of its assertions half wrong.** Step 2 said a Story 6.8
-- kept photograph "must not reach the referee" and tested that `referee_day_lookup()` does not
-- name it -- two different claims wearing one sentence. Story 8.3 widened his *reach* for a
-- commitment flagged as of the day, and deliberately did not widen his *list*: Story 8.4 owns what
-- he is shown. So the sentence is split rather than deleted. Step 2 is now about the list and
-- holds for both; Step 2c asserts that an **unflagged** kept photograph still reaches him as
-- neither row nor object, which is the half that was always the point; Step 2d asserts that a
-- **flagged** one now reaches him both ways and is *still* absent from this lookup, which is what
-- keeps the not-widened-here decision from being undone by accident.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/the-referee-can-see-what-the-day-was-proved-with.sql
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

grant select on table public.profile, public.commitment, public.evidence, public.settlement,
                      public.declaration to authenticated;

do $$
declare
  v_mine    uuid := gen_random_uuid();  -- the doer this referee is paired to
  v_theirs  uuid := gen_random_uuid();  -- an unrelated account
  v_ref     uuid := gen_random_uuid();

  -- Read back from the declaration rather than assumed. `declaration.for_day` is trigger-derived
  -- (AD-6: no client ever sends a date) and the boundary is not plain midnight, so computing it
  -- here would put the fixture a day off the product's own answer -- and the evidence trigger
  -- refuses a claim's proof once the day it was made has ended, which is how that shows up.
  v_day     date;

  v_case    text;
  v_owner   uuid;
  v_c       uuid;
  v_c2      uuid;
  -- **v_mine's** unflagged commitment and its kept photograph, held apart from `v_c2` on
  -- purpose. `v_c2` is assigned inside the loop below and ends it holding *theirs*, so an
  -- assertion pointed at it is refused by the pairing conjunct before the flag arm is ever
  -- reached — it would pass unchanged if the widening had reached every unflagged
  -- commitment-day photograph in the database. Step 2c is about the flag, so it needs a
  -- commitment of the account this referee is actually paired to.
  v_mine_c2 uuid;
  v_mine_kept text;
  -- Story 8.3: v_mine's flagged commitment, whose kept photograph he may now open.
  v_c3      uuid;
  v_kept    text;
  v_decl    uuid;
  v_s       uuid;
  v_ev      uuid := gen_random_uuid();
  v_ev2     uuid := gen_random_uuid();

  v_path    text;
  v_paths   text[];
  v_rows    integer;
  v_seen    integer;

  -- A window that contains this instant, whatever hour the file is run at, and that still obeys
  -- both commitment constraints: 5..240 minutes long, and ending no later than 24:00.
  v_now_min integer := floor(extract(epoch from (now() at time zone 'Asia/Ho_Chi_Minh')::time) / 60)::int;
  v_due_min integer := greatest(0, v_now_min + 1 - 240);
  v_win     integer;
begin
  v_win := greatest(5, v_now_min + 1 - v_due_min);
  foreach v_case in array array['mine', 'theirs', 'ref']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case when 'mine' then v_mine when 'theirs' then v_theirs else v_ref end,
            '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'proved-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  update public.profile set role = 'referee' where id = v_ref;
  update public.profile set referee_of = v_mine where id = v_ref;

  -- Identical days for both doers, so anything of `theirs` that shows up is scoping failing rather
  -- than a fixture difference.
  foreach v_case in array array['mine', 'theirs']
  loop
    v_owner := case v_case when 'mine' then v_mine else v_theirs end;

    -- A *timed* commitment, and the window is computed from the clock rather than hard-coded.
    -- `declaration_derive_day` lands a claim on the day it was made only for a commitment whose
    -- time governed that day, and only for a tap inside the window; everything else answers for
    -- the previous day, which the evidence trigger then refuses as a day already ended. A fixed
    -- window would make this file pass or fail depending on the hour it was run.
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                   due_time, late_window_minutes)
    values (v_owner, gen_random_uuid(), 'Gym', 'do', 'daily', true,
            (v_due_min * interval '1 minute')::time, v_win)
    returning id into v_c;

    -- As the doer himself: `declaration_derive_day` reads `current_user` to tell a client-filed
    -- statement from a machine-filed one, and only the former can land on today.
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_owner, 'role', 'authenticated',
                                         'app_role', 'doer')::text, true);
    perform set_config('role', 'authenticated', true);

    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at,
                                    claimed_timed)
    values (v_owner, v_c, gen_random_uuid(), 'held', now(), true)
    returning id, for_day into v_decl, v_day;

    -- The object first, then the row -- since `20260910090000` an evidence row must name a photo
    -- that was really uploaded. Staged as postgres, because who may upload into the folder is
    -- `6-8`'s subject, not this file's.
    v_path := v_decl::text || '/' || case v_case when 'mine' then v_ev else v_ev2 end::text
                          || '/proof.jpg';

    perform set_config('role', 'postgres', true);
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_path, v_owner);
    perform set_config('role', 'authenticated', true);

    insert into public.evidence (id, declaration_id, storage_path, captured_on)
    values (case v_case when 'mine' then v_ev else v_ev2 end, v_decl, v_path, v_day);

    perform set_config('role', 'postgres', true);

    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (v_owner, v_day, 'day', 'clean', 0)
    returning id into v_s;

    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    values (v_s, v_owner, v_c, 'held');

    -- A second commitment on the same day with no proof at all, so the empty case is exercised
    -- beside the populated one rather than in a test of its own that could drift from it.
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
    values (v_owner, gen_random_uuid(), 'Reading', 'do', 'daily', true)
    returning id into v_c2;

    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    values (v_s, v_owner, v_c2, 'held');

    -- Story 6.8: a photo the author keeps against the commitment itself. It answers for no verdict
    -- and both referee evidence policies exclude it. It must not appear here either.
    v_path := v_c2::text || '/' || gen_random_uuid()::text || '/kept.jpg';

    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_path, v_owner);

    insert into public.evidence (commitment_id, storage_path, for_day, captured_on)
    values (v_c2, v_path, v_day, v_day);

    -- Kept for Step 2c, before the next iteration overwrites both.
    if v_case = 'mine' then
      v_mine_c2 := v_c2;
      v_mine_kept := v_path;
    end if;
  end loop;

  -- Story 8.3: the same kind of photograph on a commitment that asked for the referee's
  -- signature. Added to `mine` only, and outside the loop for that reason --
  -- `commitment_sign_off_needs_a_referee` (20260911090000:263) refuses a flagged commitment on an
  -- account no referee is paired to, and no referee is paired to `theirs`.
  --
  -- Created today with the flag on, so `requires_referee_approval_as_of(v_c3, v_day)` takes the
  -- reader's backward-extrapolation branch and answers true for v_day. The as-of read is
  -- exercised in both directions in `8-3-the-photograph-reaches-the-referee.sql`; what this file
  -- needs is only a flagged day to look at.
  select s.id into v_s
    from public.settlement s where s.subject = v_mine and s.period = v_day and s.kind = 'day';

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Thuoc', 'do', 'daily', true, true, true)
  returning id into v_c3;

  insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
  values (v_s, v_mine, v_c3, 'held');

  v_kept := v_c3::text || '/' || gen_random_uuid()::text || '/kept.jpg';

  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_kept, v_mine);

  insert into public.evidence (commitment_id, storage_path, for_day, captured_on)
  values (v_c3, v_kept, v_day, v_day);

  -- ---------------------------------------------------------------- as the referee

  -- `app_role` is the claim `role_from_token()` reads; `role` is Postgres's own. Both are needed,
  -- and they are not the same thing.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  select s.id into v_s
    from public.settlement s where s.subject = v_mine and s.period = v_day and s.kind = 'day';

  -- 1. The proof reaches him, on the commitment it belongs to.
  select evidence_paths into v_paths
    from public.referee_day_lookup(v_s) where commitment_name = 'Gym';

  if v_paths is null or array_length(v_paths, 1) is distinct from 1 then
    raise exception
      'The referee must see the photo his doer''s claim was proved with. Got: %', v_paths;
  end if;

  if v_paths[1] not like '%/proof.jpg' then
    raise exception 'Expected the claim''s own storage path, got: %', v_paths[1];
  end if;

  -- 2. A commitment with no proof comes back as an empty array, never null -- so nothing
  --    downstream has to test for two shapes of "none".
  select evidence_paths into v_paths
    from public.referee_day_lookup(v_s) where commitment_name = 'Reading';

  if v_paths is null then
    raise exception 'A commitment with no proof must return an empty array, not null.';
  end if;

  if array_length(v_paths, 1) is not null then
    raise exception
      'Story 6.8''s kept photo answers for no verdict and this lookup must not name it. Got: %',
      v_paths;
  end if;

  -- 2c. And on an **unflagged** commitment it does not reach him at all -- not as a row and not
  --     as an object. This is what Step 2's sentence used to claim while testing only the lookup.
  --     Story 8.3 widened both referee policies for a *flagged* commitment-day and for no other,
  --     so this is the half of Story 6.8's narrowing that had to survive it, and it is asserted
  --     here against the same fixture rather than in a file of its own that could drift from it.
  --     `v_mine_c2`, never `v_c2`: the latter holds *theirs* by the time the loop above ends, and
  --     a count of zero against another account's commitment says only that the pairing conjunct
  --     works. It is the flag arm that has to be doing the refusing here.
  select count(*) into v_seen from public.evidence e where e.commitment_id = v_mine_c2;
  if v_seen <> 0 then
    raise exception
      'An unflagged commitment-day photograph must reach the referee as no row at all. He read '
      '% of them.', v_seen;
  end if;

  select count(*) into v_seen from storage.objects o
   where o.bucket_id = 'appeal-evidence' and o.name = v_mine_kept;
  if v_seen <> 0 then
    raise exception
      'An unflagged commitment-day photograph must reach the referee as no object either. He '
      'read % of them.', v_seen;
  end if;

  -- 2d. On a **flagged** commitment it reaches him both ways -- and is still absent from this
  --     lookup. Both halves matter. The first is Story 8.3's whole point; the second is Story
  --     8.3's deliberate omission, because Story 8.4 owns what the referee is *shown* and
  --     `referee_day_lookup()` was left narrowed on purpose. If 8.4 later widens the list, delete
  --     the second half knowingly rather than discovering it here.
  select count(*) into v_seen from public.evidence e where e.commitment_id = v_c3;
  if v_seen <> 1 then
    raise exception
      'A flagged commitment-day photograph must reach the referee as a row (Story 8.3). He read '
      '% of them.', v_seen;
  end if;

  select count(*) into v_seen from storage.objects o
   where o.bucket_id = 'appeal-evidence' and o.name = v_kept;
  if v_seen <> 1 then
    raise exception
      'A flagged commitment-day photograph must reach the referee as an object too -- widening '
      'one arm and not the other is the failure Story 8.3 exists to avoid. He read % of them.',
      v_seen;
  end if;

  select evidence_paths into v_paths
    from public.referee_day_lookup(v_s) where commitment_name = 'Thuoc';

  if v_paths is null or array_length(v_paths, 1) is not null then
    raise exception
      'referee_day_lookup() has started naming a commitment-day photograph. Story 8.3 widened '
      'the referee''s reach and deliberately not his list. Got: %', v_paths;
  end if;

  -- 2b. A swept photo is not offered to him at all (20260908180000). The row survives, because
  --     commitments_owing() reads it to decide the day held -- but naming a path whose bytes are
  --     gone would put a photo on his screen that cannot load, and the screen would call that a
  --     failure rather than what it is.
  perform set_config('role', 'postgres', true);
  update public.evidence set swept_at = now() where id = v_ev;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  select evidence_paths into v_paths
    from public.referee_day_lookup(v_s) where commitment_name = 'Gym';

  if v_paths is null or array_length(v_paths, 1) is not null then
    raise exception
      'A photo whose bytes were swept must not be named to the referee. Got: %', v_paths;
  end if;

  perform set_config('role', 'postgres', true);
  update public.evidence set swept_at = null where id = v_ev;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  -- 3. His raw reach did not widen. The join moved inside a security definer function precisely so
  --    that this stays true: he still has no route to the author''s claim rows themselves.
  select count(*) into v_seen from public.declaration;
  if v_seen <> 0 then
    raise exception
      'The referee must not be able to read declaration rows. He read % of them.', v_seen;
  end if;

  -- 4. Another doer's day is not his to look up, evidence included.
  select s.id into v_s
    from public.settlement s where s.subject = v_theirs and s.period = v_day and s.kind = 'day';

  select count(*) into v_rows from public.referee_day_lookup(v_s);
  if v_rows <> 0 then
    raise exception
      'referee_day_lookup() answered for an account he is not paired to: % rows.', v_rows;
  end if;

  -- ---------------------------------------------------------------- as the doer himself

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_mine, 'role', 'authenticated',
                                       'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  select s.id into v_s
    from public.settlement s where s.subject = v_mine and s.period = v_day and s.kind = 'day';

  -- 5. Widening the return type must not have turned this into a door for anyone else. The role
  --    filter is a plain row filter, so a non-referee gets zero rows rather than an error.
  select count(*) into v_rows from public.referee_day_lookup(v_s);
  if v_rows <> 0 then
    raise exception 'A doer must get nothing from referee_day_lookup(). Got % rows.', v_rows;
  end if;

  perform set_config('role', 'postgres', true);

  raise notice 'the referee can see what the day was proved with: all assertions passed';
end $$;

rollback;
