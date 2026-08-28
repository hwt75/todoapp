-- Story 6.3 — a photo that proves a claim, in the same store that proves an appeal.
--
-- `evidence` (renamed from `appeal_evidence` by this story) now hangs off either an appeal or a
-- declaration, and the three properties that make it trustworthy have to survive that: the
-- owner is derived server-side from the parent row, the capture date must match the day being
-- proven, and the object path must lead with the parent's own id so the bucket's policies can
-- derive access from it.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-3-evidence-detaches-from-an-appeal.sql
--
-- One transaction, rolled back at the end.
--
-- **The appeal side is not rebuilt here.** `4-4`, `4-5`, `4-6` and `epic-4-retro-2026-08-27-fixes`
-- already drive it end to end and all four still pass against the renamed table, which is the
-- assertion that matters: this story changed nothing about how an appeal's evidence behaves. The
-- last of those is also what proves the midnight rule does *not* apply to an appeal -- it attaches
-- evidence to an appeal for a day that has already ended, and that insert is still accepted.

begin;

grant select on table public.profile, public.commitment, public.declaration to authenticated;
grant insert on table public.declaration, public.evidence to authenticated;
grant select on table public.evidence to authenticated;

do $$
declare
  v_a        uuid := gen_random_uuid();
  v_b        uuid := gen_random_uuid();
  v_today    uuid;
  v_stale    uuid;
  v_theirs   uuid;
  v_claim    uuid;
  v_old      uuid;
  v_hers     uuid;
  v_day      date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_owner    uuid;
  v_count    integer;
  v_refused  boolean;
  v_case     text;
  v_at       timestamptz := (
    ((now() at time zone 'Asia/Ho_Chi_Minh')::date || ' 10:14')::timestamp
      at time zone 'Asia/Ho_Chi_Minh'
  );
begin
  foreach v_case in array array['a', 'b']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case when 'a' then v_a else v_b end,
            '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'story-6-3-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  -- A window fixed at 10:00 rather than around the clock this file happens to run at: the
  -- trigger compares the *tap's* time of day against the window, never `now()`, so a tap at
  -- 10:14 is inside it whatever the hour actually is when someone runs this.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill', 'do', 'daily', time '10:00', 30)
  returning id into v_today;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Walk', 'do', 'daily', time '10:00', 30)
  returning id into v_stale;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Their pill', 'do', 'daily', time '10:00', 30)
  returning id into v_theirs;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);

  -- Today's claim, filed as the doer so it takes the same-day branch.
  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_today, gen_random_uuid(), 'held', v_at)
  returning id into v_claim;
  perform set_config('role', 'postgres', true);

  -- A claim for a day that has already ended. Inserted as postgres on purpose: that takes the
  -- machine branch, which still derives the previous day, and yesterday is exactly what step 4
  -- needs. Nothing else about it matters.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_stale, gen_random_uuid(), 'held', v_at)
  returning id into v_old;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_b, v_theirs, gen_random_uuid(), 'held', v_at)
  returning id into v_hers;

  -- -------------------------------------------------------------------------------
  -- 1. A photo on today's claim, with the owner derived rather than believed.
  --
  -- The client sends the *wrong* owner deliberately. Everything about the bucket's privacy
  -- rests on `owner_id` being the parent's own (NFR4), which only holds if a client cannot
  -- claim a different one.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
  values (v_claim, v_b, v_claim::text || '/pill.jpg', v_day);
  perform set_config('role', 'postgres', true);

  select owner_id into v_owner from public.evidence where declaration_id = v_claim;

  if v_owner <> v_a then
    raise exception using message = format(
      'Evidence came back owned by %s after the client sent %s. The owner is derived from '
      'the claim it proves, never believed.', v_owner, v_b);
  end if;

  -- Evidence is a list, not a column: a second photo on the same claim is ordinary.
  perform set_config('role', 'authenticated', true);
  insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
  values (v_claim, v_a, v_claim::text || '/pill-2.jpg', v_day);
  perform set_config('role', 'postgres', true);

  select count(*) into v_count from public.evidence where declaration_id = v_claim;
  if v_count <> 2 then
    raise exception using message = format(
      'A claim holds %s photo(s). Evidence is a list, and a second one is not a duplicate.',
      v_count);
  end if;

  raise notice using message =
    'Step 1 ok: a claim can be proved, the owner is derived from it, and it holds more than one.';

  -- -------------------------------------------------------------------------------
  -- 2. What the table refuses about its own shape.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'neither parent',
    'both parents',
    'a path outside the claim',
    'no capture date',
    'captured another day'
  ]
  loop
    v_refused := false;
    perform set_config('role', 'authenticated', true);
    begin
      insert into public.evidence (declaration_id, appeal_id, owner_id, storage_path, captured_on)
      values (
        case v_case when 'neither parent' then null else v_claim end,
        -- `both parents` needs an appeal id that need not exist: the exactly-one check is a
        -- table constraint and fires before the trigger ever reads a parent.
        case v_case when 'both parents' then gen_random_uuid() end,
        v_a,
        case v_case
          when 'a path outside the claim' then gen_random_uuid()::text || '/elsewhere.jpg'
          else v_claim::text || '/' || replace(v_case, ' ', '-') || '.jpg'
        end,
        case v_case
          when 'no capture date' then null
          when 'captured another day' then v_day - 3
          else v_day
        end);
    exception when others then
      v_refused := true;
    end;
    perform set_config('role', 'postgres', true);

    if not v_refused then
      raise exception using message = format(
        'The database accepted evidence described as "%s".', v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 2 ok: neither parent, both parents, a path outside the claim, a missing capture '
    'date and a wrong one are all refused.';

  -- -------------------------------------------------------------------------------
  -- 3. A photo cannot be attached to another account's claim.
  -- -------------------------------------------------------------------------------
  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
    values (v_hers, v_a, v_hers::text || '/theirs.jpg', v_day);
  exception when others then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'One account attached a photo to another account''s claim. The trigger derives the '
      'owner from the claim, so the row would have been readable only by its real owner -- '
      'but it must not exist at all.';
  end if;

  raise notice using message =
    'Step 3 ok: evidence naming another account''s claim is refused.';

  -- -------------------------------------------------------------------------------
  -- 4. Midnight is the deadline, and there is nothing after it.
  --
  -- The rule that makes a timed commitment mean anything (SPEC.md), enforced at the upload
  -- rather than left for settlement to discover -- the same call Story 6.2 made about a late
  -- tap. `v_old` is a claim for yesterday; today's upload is too late for it.
  -- -------------------------------------------------------------------------------
  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
    values (v_old, v_a, v_old::text || '/yesterday.jpg', v_day - 1);
  exception when others then
    v_refused := true;
  end;
  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A claim for yesterday accepted a photo today. Midnight is the deadline, and a photo '
      'arriving after it would either mean nothing or reopen a day that has closed.';
  end if;

  raise notice using message =
    'Step 4 ok: a claim cannot be proved once the day it was made has ended.';

  raise notice using message =
    'PASS. Evidence proves a claim as well as an appeal, its owner is derived from whichever '
    'parent it names, and a claim''s photo dies with the day it belongs to.';
end $$;

rollback;
