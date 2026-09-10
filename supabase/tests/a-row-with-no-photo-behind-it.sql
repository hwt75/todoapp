-- A row with no photo behind it — Epic 6 retrospective, finding A1 (HIGH) and its gap A7.
--
-- Until `20260910090000` the `evidence` table never asked whether the object its `storage_path`
-- names exists. `commitments_owing()` holds a timed day on the bare existence of a row, so one
-- `POST /rest/v1/evidence` with a fabricated path — no upload, no photograph anywhere — settled
-- the day clean and kept the money. This file is the refusal, and the shape of it.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/a-row-with-no-photo-behind-it.sql
--
-- One transaction, rolled back at the end.
--
-- **The appeal-parented case is not here.** Building a real appeal needs a settled failed day and
-- a penalty behind it, which `4-4-contest-a-miss-the-machine-got-wrong.sql` already has — so the
-- proof that an appeal's photo passes through the same gate lives there, beside the appeal.
--
-- This file calls `settle_day` with an override, so it refuses to run against a database holding
-- the live doer account (AD-16, README.md).

begin;

grant select on table public.profile, public.commitment, public.declaration to authenticated;
grant insert on table public.declaration, public.evidence to authenticated;
grant select on table public.evidence to authenticated;

-- The bucket is `config.toml` configuration created by the CLI through the storage API, not by a
-- migration, so a database started with `-x storage-api` — which is how CI starts it — has the
-- schema but not the row. Staged here so the file runs against any database, and it rolls back
-- with everything else. The second bucket exists only for step 3: an object of the right name in
-- the wrong place.
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence'),
       ('todoapp-somewhere-else', 'todoapp-somewhere-else')
on conflict (id) do nothing;

do $$
declare
  v_doer       uuid := gen_random_uuid();
  v_timed      uuid;
  v_kept       uuid;
  v_claim      uuid;
  v_old_claim  uuid;
  v_today      date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_yesterday  date;
  v_path       text;
  v_stray      text;
  v_answer     text;
  v_verdict    text;
  v_count      integer;
  v_refused    boolean;
  v_message    text;
  v_constraint text;
  v_tap        timestamptz;
begin
  v_yesterday := v_today - 1;
  v_tap := ((v_today::timestamp + interval '10 hours 14 minutes') at time zone 'Asia/Ho_Chi_Minh');

  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override (AD-16). '
      'Run against a local or branch database instead. Never work around the guard by '
      'setting app.settlement_invocation by hand.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 0. Fixture: one doer, one timed commitment, one commitment that merely keeps photos.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_doer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'no-photo-behind-it-' || gen_random_uuid()::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_doer, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, requires_photo)
  values (v_doer, gen_random_uuid(), 'Sketchbook', 'do', 'daily', true)
  returning id into v_kept;

  -- The timed commitment has to predate the day it is judged for: `commitments_owing()` drops a
  -- day before the commitment existed, and step 5 judges yesterday. `Sketchbook` deliberately
  -- keeps today's `created_at` — it is owed nothing for yesterday, and a second commitment
  -- awaiting its own untimed deadline (morning hour + 3 days) would hold yesterday open and
  -- settle nothing at all.
  update public.commitment set created_at = now() - interval '10 days' where id = v_timed;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_doer, 'role', 'authenticated')::text, true);

  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_doer, v_timed, gen_random_uuid(), 'held', v_tap)
  returning id into v_claim;
  perform set_config('role', 'postgres', true);

  v_path := v_claim::text || '/pill.jpg';

  -- -------------------------------------------------------------------------------
  -- 1. The attack, exactly as a client can perform it: one insert, no upload.
  --
  -- Everything about this row is well-formed. The parent is real and his own, the path leads
  -- with the parent's id, the capture date matches the day. The only thing missing is the
  -- photograph — which, until this rule existed, was the one thing nothing checked.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  v_refused := false;
  begin
    insert into public.evidence (declaration_id, storage_path, captured_on)
    values (v_claim, v_path, v_today);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'An evidence row naming an object that does not exist was accepted. One REST insert with '
      'a fabricated storage_path is all a claimed day needed to hold.';
  end if;

  if v_message not like '%appeal-evidence bucket%' then
    raise exception using message = format(
      'The bare row was refused with `%s`. It has to be refused for the missing object, not '
      'for something else that happens to fire first.', v_message);
  end if;

  select count(*) into v_count from public.evidence where declaration_id = v_claim;
  if v_count <> 0 then
    raise exception using message = format(
      'The refused insert left %s row(s) behind.', v_count);
  end if;

  -- Counted as well as read: `select ... into` leaves v_answer null when the function returns no
  -- row at all, so an assertion on the value alone would pass for a commitment that had dropped
  -- out of the day entirely.
  select count(*) into v_count
    from public.commitments_owing(v_doer, v_today) o
   where o.commitment_id = v_timed;

  select o.answer into v_answer
    from public.commitments_owing(v_doer, v_today) o
   where o.commitment_id = v_timed;

  if v_count <> 1 or v_answer is not null then
    raise exception using message = format(
      'A claim whose photo was refused reads `%s` across %s owed row(s). Nothing was proved, so '
      'nothing is held -- and the commitment is still owed today.',
      coalesce(v_answer, 'nothing'), v_count);
  end if;

  raise notice using message =
    'Step 1 ok: a well-formed evidence row with no object behind it is refused, and the day it '
    'was meant to hold is not held.';

  -- -------------------------------------------------------------------------------
  -- 2. The honest path, unchanged: the object is uploaded first, then the row is filed.
  --
  -- This is the order both clients already write in (`components/today.tsx`,
  -- `components/appeal-form.tsx`), which is why the rule costs the honest path nothing.
  -- -------------------------------------------------------------------------------
  insert into storage.objects (bucket_id, name, owner) values ('appeal-evidence', v_path, v_doer);

  perform set_config('role', 'authenticated', true);
  insert into public.evidence (declaration_id, storage_path, captured_on)
  values (v_claim, v_path, v_today);
  perform set_config('role', 'postgres', true);

  select o.answer into v_answer
    from public.commitments_owing(v_doer, v_today) o
   where o.commitment_id = v_timed;

  if v_answer is distinct from 'held' then
    raise exception using message = format(
      'A claim with a real photo reads `%s`, expected `held`. The gate must refuse rows with no '
      'object, not photographs that exist.', v_answer);
  end if;

  raise notice using message =
    'Step 2 ok: object first, row second — the order both clients already write in — still holds '
    'the day.';

  -- -------------------------------------------------------------------------------
  -- 3. An object of the right name in the wrong bucket proves nothing.
  --
  -- The gate is `bucket_id` plus `name`, the same pairing `orphaned_evidence_objects()` uses
  -- from the other side. A name alone would let any writable bucket in the project stand in for
  -- the private one whose policies decide who may see a photo.
  -- -------------------------------------------------------------------------------
  insert into storage.objects (bucket_id, name, owner)
  values ('todoapp-somewhere-else', v_kept::text || '/sketch.jpg', v_doer);

  perform set_config('role', 'authenticated', true);
  v_refused := false;
  begin
    insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
    values (v_kept, v_today, v_kept::text || '/sketch.jpg', v_today);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not like '%appeal-evidence bucket%' then
    raise exception using message = format(
      'An object of the same name in another bucket was accepted as this photo (refused: %s, '
      'said: %s).', v_refused, coalesce(v_message, 'nothing'));
  end if;

  raise notice using message =
    'Step 3 ok: the object has to be in the appeal-evidence bucket, not merely somewhere.';

  -- -------------------------------------------------------------------------------
  -- 4. A photo whose bytes were swept keeps its day.
  --
  -- The retention pass (20260908180000) removes the object after thirty days and keeps the row,
  -- because the row is what `commitments_owing()` reads to decide whether a claimed day held.
  -- So this rule holds at the moment of filing and never again — a foreign key here would have
  -- the sweep delete the proof of days that were honestly proved and mint penalties for them.
  --
  -- `storage.allow_delete_query` is what Storage's own `protect_delete` trigger looks for. The
  -- sweeper removes bytes through the Storage API, which is the path that sets it; here the
  -- setting is made transaction-local to stage the same end state.
  -- -------------------------------------------------------------------------------
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects where bucket_id = 'appeal-evidence' and name = v_path;
  perform set_config('storage.allow_delete_query', 'false', true);

  -- Stamped through `mark_evidence_swept()` rather than by hand, so this step asserts against the
  -- state the sweeper really produces rather than one that merely resembles it.
  select public.mark_evidence_swept(array_agg(e.id)) into v_count
    from public.evidence e where e.storage_path = v_path;

  if v_count <> 1 then
    raise exception using message = format(
      'The retention pass stamped %s row(s) for a photo it removed, expected 1.', v_count);
  end if;

  select o.answer into v_answer
    from public.commitments_owing(v_doer, v_today) o
   where o.commitment_id = v_timed;

  if v_answer is distinct from 'held' then
    raise exception using message = format(
      'A day whose photo was swept reads `%s`, expected `held`. The bytes go at thirty days; '
      'the row decides money and stays.', v_answer);
  end if;

  raise notice using message =
    'Step 4 ok: the gate is insert-only — a swept photo still holds the day it proved.';

  -- -------------------------------------------------------------------------------
  -- 5. The fixture back door does not open it either, and the day costs what it should.
  --
  -- A photo for a day that has ended cannot be filed through the front door, so fixtures
  -- disable `evidence_derive_owner` and write `owner_id` by hand — which is how two of the three
  -- rows that certified this defect were built. This rule is a separate trigger precisely so
  -- that statement does not switch it off.
  -- -------------------------------------------------------------------------------
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_doer, v_timed, gen_random_uuid(), 'held',
          ((v_yesterday + 1)::timestamp + interval '10 hours 14 minutes')
            at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_old_claim;

  alter table public.evidence disable trigger evidence_derive_owner;
  v_refused := false;
  begin
    insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
    values (v_old_claim, v_doer, v_old_claim::text || '/pill.jpg', v_yesterday);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;
  alter table public.evidence enable trigger evidence_derive_owner;

  if not v_refused or v_message not like '%appeal-evidence bucket%' then
    raise exception using message = format(
      'A bare row planted with evidence_derive_owner disabled was accepted (refused: %s, said: '
      '%s). A rule money depends on must not switch off with a convenience.',
      v_refused, coalesce(v_message, 'nothing'));
  end if;

  select o.answer into v_answer
    from public.commitments_owing(v_doer, v_yesterday) o
   where o.commitment_id = v_timed;

  if v_answer is distinct from 'slipped' then
    raise exception using message = format(
      'A claim whose day ended with nothing but a refused row reads `%s`, expected `slipped`.',
      v_answer);
  end if;

  perform public.settle_day(v_yesterday, true);

  select verdict into v_verdict
    from public.settlement
   where subject = v_doer and period = v_yesterday and kind = 'day' and supersedes is null;

  select count(*) into v_count
    from public.penalty p
    join public.settlement s on s.id = p.settlement_id
   where s.subject = v_doer and s.period = v_yesterday;

  if v_verdict is distinct from 'failed' or v_count <> 1 then
    raise exception using message = format(
      'The day the fabricated row was meant to save settled `%s` with %s penalt(y/ies), '
      'expected `failed` and exactly one.', coalesce(v_verdict, 'nothing at all'), v_count);
  end if;

  raise notice using message =
    'Step 5 ok: the back door is shut too, and the day the fabricated row would have saved '
    'fails at midnight for exactly one penalty.';

  -- -------------------------------------------------------------------------------
  -- 6. The older rule still does its own refusing.
  --
  -- A BEFORE ROW trigger runs before the table's CHECK constraints, so a path pointing outside
  -- its parent's folder would now meet the new trigger first and be turned away for the wrong
  -- reason. With the object really there, the constraint that owns this rule is the one that
  -- fires — which is what keeps `4-4`'s and `6-8`'s assertions about it honest.
  -- -------------------------------------------------------------------------------
  v_stray := gen_random_uuid()::text || '/not-this-claims-folder.jpg';
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_stray, v_doer);

  perform set_config('role', 'authenticated', true);
  v_refused := false;
  v_constraint := null;
  begin
    insert into public.evidence (declaration_id, storage_path, captured_on)
    values (v_claim, v_stray, v_today);
  exception when others then
    v_refused := true;
    get stacked diagnostics v_constraint = constraint_name;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused or v_constraint is distinct from 'evidence_storage_path_leads_with_its_parent'
  then
    raise exception using message = format(
      'A path outside its own parent''s folder was refused by `%s`, expected '
      '`evidence_storage_path_leads_with_its_parent`. The new trigger must not take over the '
      'refusals that already had an owner.', coalesce(v_constraint, 'nothing'));
  end if;

  raise notice using message =
    'Step 6 ok: with the object present, the path rule still refuses in its own name.';

  raise notice using message =
    'PASS. An evidence row must name an object that exists in the appeal-evidence bucket — as a '
    'client and with the owner-derivation trigger disabled — while a swept photo keeps the day '
    'it proved and every older refusal still fires in its own name.';
end;
$$;

rollback;
