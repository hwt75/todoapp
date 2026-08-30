-- Story 6.5 — the view Today reads to know where a window stands.
--
-- The clock half of that question is `lib/timed-window.ts` and is driven to the second by its
-- own tests. What cannot be answered in a browser is the half this file covers: which rows the
-- view returns at all, and whether one account can see another's claim through it. The view is
-- `security_invoker`, so RLS on `commitment`, `declaration` and `evidence` is the only thing
-- standing between the two accounts below.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-5-today-shows-where-the-window-stands.sql
--
-- One transaction, rolled back at the end.

begin;

grant select on table public.profile, public.commitment, public.declaration to authenticated;
grant insert on table public.declaration, public.evidence to authenticated;
grant select on table public.evidence to authenticated;

do $$
declare
  v_a         uuid := gen_random_uuid();
  v_b         uuid := gen_random_uuid();
  v_timed     uuid;
  v_untimed   uuid;
  v_archived  uuid;
  v_stale     uuid;
  v_theirs    uuid;
  v_claim     uuid;
  v_day       date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_count     integer;
  v_declared  uuid;
  v_proven    boolean;
  v_case      text;
  -- A window fixed at 10:00, and a tap at 10:14 inside it. The trigger compares the tap's own
  -- time of day against the window and never `now()`, so this file passes whatever hour it is
  -- actually run at — the same fixture 6-3 uses, for the same reason.
  v_at        timestamptz := (
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
            'story-6-5-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill', 'do', 'daily', time '10:00', 30)
  returning id into v_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_a, gen_random_uuid(), 'Gym', 'do', 'daily')
  returning id into v_untimed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes, archived_at)
  values (v_a, gen_random_uuid(), 'Old pill', 'do', 'daily', time '10:00', 30, now())
  returning id into v_archived;

  -- Timed, and claimed for a day that has already ended. Today has nothing on it.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Walk', 'do', 'daily', time '10:00', 30)
  returning id into v_stale;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Their pill', 'do', 'daily', time '10:00', 30)
  returning id into v_theirs;

  -- Inserted as postgres on purpose: that takes the machine branch, which still derives the
  -- previous day. Yesterday's claim is exactly what step 3 needs.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_stale, gen_random_uuid(), 'held', v_at);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- -------------------------------------------------------------------------------
  -- 1. Every open timed commitment appears, unclaimed, and nothing else does.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count from public.timed_claim_today;
  if v_count <> 2 then
    raise exception using message = format(
      'The view returned %s row(s) for an account with two open timed commitments, one '
      'untimed one and one archived. An untimed commitment has no window to stand anywhere, '
      'and an archived one is not on the screen at all.', v_count);
  end if;

  select declaration_id, proven into v_declared, v_proven
    from public.timed_claim_today where commitment_id = v_timed;

  if v_declared is not null or v_proven then
    raise exception using message =
      'An unclaimed window came back claimed or proven. Both facts are about today, and '
      'nothing has happened today.';
  end if;

  raise notice using message =
    'Step 1 ok: both open timed commitments appear unclaimed; the untimed and the archived '
    'one do not appear at all.';

  -- -------------------------------------------------------------------------------
  -- 2. A claim shows up, and a photo on it turns proven true.
  -- -------------------------------------------------------------------------------
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_timed, gen_random_uuid(), 'held', v_at)
  returning id into v_claim;

  select declaration_id, proven into v_declared, v_proven
    from public.timed_claim_today where commitment_id = v_timed;

  -- The id is not decoration: it is what a photo attaches to, and it is the only thing that
  -- lets an author who claimed and then closed the app reach the upload control again.
  if v_declared is distinct from v_claim then
    raise exception using message = format(
      'The view named %s as today''s claim; the claim is %s.', v_declared, v_claim);
  end if;

  if v_proven then
    raise exception using message =
      'A claim with no photo came back proven. The photo is what holds a timed day, not the tap.';
  end if;

  insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
  values (v_claim, v_a, v_claim::text || '/pill.jpg', v_day);

  select proven into v_proven
    from public.timed_claim_today where commitment_id = v_timed;

  if not v_proven then
    raise exception using message =
      'A claim with a photo on it came back unproven. The existence of an evidence row is '
      'acceptance -- the capture-date and frozen-day rules ran before it was allowed to exist.';
  end if;

  raise notice using message =
    'Step 2 ok: today''s claim is named, and proven follows the photo rather than the tap.';

  -- -------------------------------------------------------------------------------
  -- 3. Yesterday's claim is not today's.
  -- -------------------------------------------------------------------------------
  select declaration_id, proven into v_declared, v_proven
    from public.timed_claim_today where commitment_id = v_stale;

  if v_declared is not null or v_proven then
    raise exception using message =
      'A claim filed for a day that has already ended came back as today''s. Today''s window '
      'would read claimed, the control to claim it would never be offered, and the day would '
      'fail at midnight for a claim that was never made.';
  end if;

  raise notice using message =
    'Step 3 ok: a claim for an earlier day says nothing about today''s window.';

  -- -------------------------------------------------------------------------------
  -- 4. One account never sees another's window through this view.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.timed_claim_today;
  if v_count <> 1 then
    raise exception using message = format(
      'The other account saw %s row(s) where it owns exactly one timed commitment. The view '
      'is security_invoker precisely so RLS decides this.', v_count);
  end if;

  select count(*) into v_count
    from public.timed_claim_today where commitment_id = v_timed;
  if v_count <> 0 then
    raise exception using message =
      'One account read another account''s window through timed_claim_today.';
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 4 ok: each account sees its own windows and no others.';

  raise notice using message =
    'PASS. The view names today''s claim and its proof for every open timed commitment, says '
    'nothing about untimed, archived or earlier days, and is scoped by RLS alone.';
end $$;

rollback;
