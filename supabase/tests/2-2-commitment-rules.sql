-- Story 2.2 — what a commitment may be, and what "delete" means here.
--
-- Every constraint below was exercised once by hand when the story was built, and the record
-- of it is a paragraph in the spec. This is the same set, in a file, plus the two rules that
-- are easiest to break by accident later: an archived commitment is still judged for the days
-- that predate its archiving, and a delete does not delete.
--
-- The second is not a detail. A commitment is referenced by every declaration, failed day and
-- penalty that ever touched it. Removing the row would break those references or silently
-- rewrite the author's own history — and a ledger that cannot explain itself is worse than a
-- stale row. So the UI says delete, the database sets `archived_at`, and there is no delete
-- policy at all.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-2-commitment-rules.sql
--
-- One transaction, rolled back at the end. It settles nothing and is safe against any
-- database.
--
-- The fixture grants `authenticated` SELECT, UPDATE and DELETE on `commitment`, and SELECT on
-- `profile`, for the same reason `2-1-roles-and-rls.sql` does: on a local stack those grants do not exist, the
-- product inherits them from how the author's project was provisioned, and no migration in
-- this repository creates them (recorded in deferred-work.md). The grants are what let RLS be
-- the thing under test rather than the missing privilege.

begin;

grant select, update, delete on table public.commitment to authenticated;
-- And SELECT on `profile`, because every write policy calls `role_from_table()`, which reads
-- the caller's own row through the same policy any other read uses.
grant select on table public.profile to authenticated;

do $$
declare
  v_user     uuid := gen_random_uuid();
  v_daily    uuid;
  v_archived uuid;
  v_key      uuid := gen_random_uuid();
  v_day      date;
  v_count    integer;
  v_updated  timestamptz;
  v_updated2 timestamptz;
  v_refused  boolean;
  v_case     text;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-2-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  -- -------------------------------------------------------------------------------
  -- 1. A half-filled form is not a commitment.
  --
  -- Each case is attempted for real. The `=` in the cadence constraints is a biconditional
  -- on purpose: a weekly quota must carry a target, and a daily commitment must not — a
  -- leftover target from an edited cadence is a number that would later be counted.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'weekly quota with no target',
    'weekly quota with no week start',
    'daily with a leftover weekly target',
    'hours quota with no minutes',
    'blank name',
    'weekly target out of range',
    'week start out of range',
    'zero minutes'
  ]
  loop
    v_refused := false;
    begin
      insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                     weekly_target, week_start_day, daily_minutes_target)
      values (
        v_user, gen_random_uuid(),
        case v_case when 'blank name' then '   ' else 'Gym' end,
        'do',
        (case v_case
           when 'weekly quota with no target' then 'weekly_quota'
           when 'weekly quota with no week start' then 'weekly_quota'
           when 'hours quota with no minutes' then 'daily_hours_quota'
           when 'weekly target out of range' then 'weekly_quota'
           when 'week start out of range' then 'weekly_quota'
           when 'zero minutes' then 'daily_hours_quota'
           else 'daily'
         end)::public.commitment_cadence,
        case v_case
          when 'weekly quota with no week start' then 3
          when 'daily with a leftover weekly target' then 3
          when 'weekly target out of range' then 9
          when 'week start out of range' then 3
        end,
        case v_case
          when 'weekly quota with no target' then 1
          when 'weekly target out of range' then 1
          when 'week start out of range' then 9
        end,
        case v_case
          when 'zero minutes' then 0
        end);
    exception when check_violation then
      v_refused := true;
    end;

    if not v_refused then
      raise exception using message = format(
        'The database accepted a commitment described as "%s". Which fields must be '
        'present is a constraint, not a thing the form is trusted to remember.', v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 1 ok: eight malformed commitments were all refused by constraints.';

  -- -------------------------------------------------------------------------------
  -- 2. A retried write lands once (AD-4).
  --
  -- The key is generated by the client at the moment of the action and reused by every
  -- retry, so a double tap or a replayed offline write cannot create two commitments.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty)
  values (v_user, v_key, 'No fap', 'abstain', 'daily', true)
  returning id into v_daily;

  v_refused := false;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   carries_penalty)
    values (v_user, v_key, 'No fap', 'abstain', 'daily', true);
  exception when unique_violation then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'The same idempotency key created a second commitment. A double tap on a slow '
      'connection is the ordinary case, not the exotic one (AD-4).';
  end if;

  select count(*) into v_count from public.commitment where owner_id = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'The account holds %s commitments after one create and one retry.', v_count);
  end if;

  raise notice using message = 'Step 2 ok: a replayed create is refused by the key.';

  -- -------------------------------------------------------------------------------
  -- 3. `updated_at` is stamped by the database, not sent by the client.
  --
  -- Asserted this way round because "the timestamp moved" cannot be shown inside one
  -- transaction — `now()` is the transaction's start and does not advance, so an edit here
  -- writes the same instant it already held. What *can* be shown is the property that
  -- matters: a client sending its own `updated_at` is a client deciding when it edited
  -- something, and the trigger overwrites whatever it sends.
  -- -------------------------------------------------------------------------------
  select updated_at into v_updated from public.commitment where id = v_daily;

  update public.commitment
     set name = 'No fap (renamed)',
         updated_at = timestamptz '2020-01-01 00:00:00+07'
   where id = v_daily;

  select updated_at into v_updated2 from public.commitment where id = v_daily;

  if v_updated2 = timestamptz '2020-01-01 00:00:00+07' then
    raise exception using message =
      'A client-sent updated_at survived the write. `touch_updated_at` is what keeps the '
      'column honest; without it an edit can claim to be six years old.';
  end if;

  if v_updated2 <> v_updated then
    raise exception using message = format(
      'updated_at reads %s after an edit in the same transaction that created the row, '
      'expected the transaction instant %s.', v_updated2, v_updated);
  end if;

  -- -------------------------------------------------------------------------------
  -- 4. Delete does not delete, and RLS is what says so.
  --
  -- There is no delete policy for `authenticated`, so the statement affects zero rows
  -- rather than raising — the row survives and the history keeps its referent. The UI
  -- still calls it delete, and archiving is the update that carries it out.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text,
    true);
  perform set_config('role', 'authenticated', true);

  delete from public.commitment where id = v_daily;
  get diagnostics v_count = row_count;

  update public.commitment set archived_at = now() where id = v_daily;

  perform set_config('role', 'postgres', true);

  if v_count <> 0 then
    raise exception using message = format(
      'A session deleted %s commitment rows. Every declaration, failed day and penalty '
      'that ever referenced this commitment points at a row that is now gone.', v_count);
  end if;

  select count(*) into v_count from public.commitment where id = v_daily;
  if v_count <> 1 then
    raise exception using message = 'The commitment is gone after a delete that reported nothing.';
  end if;

  raise notice using message =
    'Step 3-4 ok: a client-sent updated_at is overwritten, and a delete removes nothing.';

  -- -------------------------------------------------------------------------------
  -- 5. Archiving is not retroactive.
  --
  -- A commitment archived today is still owed an answer for yesterday: the day predates
  -- the archive, and a hole in the ledger is worse than one extra judgement. For tomorrow
  -- it is owed nothing.
  -- -------------------------------------------------------------------------------
  v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  select count(*) into v_count
    from public.commitments_owing(v_user, v_day - 1) o where o.commitment_id = v_daily;
  if v_count <> 1 then
    raise exception using message =
      'A commitment archived today is not owed an answer for yesterday. The day predates '
      'the archive, and dropping it rewrites what he was asked.';
  end if;

  select count(*) into v_count
    from public.commitments_owing(v_user, v_day + 1) o where o.commitment_id = v_daily;
  if v_count <> 0 then
    raise exception using message =
      'An archived commitment is still being asked about days after it was archived.';
  end if;

  -- And an hours quota is never declared at all: FR-2 judges it against measured minutes,
  -- and asking for a declaration invites a softer second answer to a question the timer
  -- already answers.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 daily_minutes_target)
  values (v_user, gen_random_uuid(), 'Deep work', 'do', 'daily_hours_quota', 120)
  returning id into v_archived;

  select count(*) into v_count
    from public.commitments_owing(v_user, v_day - 1) o where o.commitment_id = v_archived;
  if v_count <> 0 then
    raise exception using message =
      'An hours-quota commitment is being asked for a declaration. It is judged on '
      'measured minutes (FR-2), and a second, softer answer must not exist.';
  end if;

  raise notice using message =
    'Step 5 ok: archiving is not retroactive, and an hours quota is never declared.';
  raise notice using message =
    'PASS. Constraints refuse a half-filled form, a retry lands once, and nothing is ever '
    'really deleted.';
end $$;

rollback;
