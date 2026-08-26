-- Story 5.2 — The app notices I have gone quiet (FR-16).
--
-- Every row of the spec's own I/O & Edge-Case Matrix: two consecutive quiet asked-days with
-- no active episode open one and enqueue exactly one push; re-running the pass before the
-- next asked-day advances is a no-op on both the episode and the push; any Declaration filed
-- ends the active episode immediately; a routine gate-reminder push is skipped entirely, every
-- slot, while an episode stays active, and resumes once it is satisfied; and a satisfied
-- episode never blocks a later, separate one from opening (the partial unique index only ever
-- blocks a second *active* row for the same account).
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/5-2-the-app-notices-i-have-gone-quiet.sql
--
-- Mirrors `5-1-a-countable-way-to-be-forgiven.sql`'s own structure: `enqueue_gate_reminders()`
-- is called directly inside the test transaction (no `pg_cron` fires in a SQL test), never a
-- synchronous RPC-and-assert pattern. One transaction, rolled back at the end. Nothing
-- persists, and a crash mid-run leaves the database exactly as it was.
--
-- `asked_day` is always real "yesterday" (`enqueue_gate_reminders()` derives it from its own
-- `now()`, never a value this test can hand it) so the two quiet days under test are the real
-- calendar dates at run time, not a chosen fixture date — mirroring how every other file in
-- this directory that cannot freeze time (2-5-settlement.sql, 5-1's own five Failed Days)
-- works entirely in `now() at time zone 'Asia/Ho_Chi_Minh'`-relative offsets. `morning_hour`
-- is set to the *current* local hour for every fixture account, for the same reason: it pins
-- `slot` at 0 (well inside `gate_reminder_slots()`'s own bound of 4) regardless of the wall
-- clock the test happens to run against, so a routine push this test expects to fire is never
-- silently skipped by the slot window closing.

begin;

grant select on table public.profile to authenticated;
-- insert/update granted here too, deliberately, mirroring 5-1's own identical note: the local
-- stack's default privileges differ from the author's real project (`authenticated` already
-- holds them there), and RLS -- no insert or update policy on silence_episode at all -- is the
-- only thing actually stopping a client write. Without the grant, step 6 below would fail on
-- "permission denied for table silence_episode" and never reach the RLS layer this story's own
-- boundary is about.
grant select, insert, update on table public.silence_episode to authenticated;
grant select, insert on table public.declaration to authenticated;

do $$
declare
  -- Fixture
  v_user        uuid := gen_random_uuid(); -- the primary account under test
  v_other       uuid := gen_random_uuid(); -- RLS cross-account check only
  v_fourth      uuid := gen_random_uuid(); -- isolated: step 8's own "new episode after
                                            -- satisfaction" sequence

  v_local_hour  integer;
  v_asked_day   date; -- the more recent of the two quiet days
  v_day_before  date; -- the earlier one -- the episode's own started_day

  v_ca          uuid; -- v_user's first commitment
  v_cb          uuid; -- v_user's second, left unanswered through step 5
  v_cd          uuid; -- v_fourth's own commitment

  -- Observed
  v_count       integer;
  v_episode1    uuid;
  v_episode_id  uuid;
  v_started_day date;
  v_satisfied   timestamptz;
  v_refused     boolean;
  v_message     text;
begin
  -- -------------------------------------------------------------------------------
  -- 0. Refuse to run anywhere a live doer account would make the result meaningless --
  --    enqueue_gate_reminders() carries no AD-16 override of its own, but a real account's
  --    real commitments would otherwise leak into every count this test asserts.
  -- -------------------------------------------------------------------------------
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so its own commitments would leak into every '
      'count this test asserts. Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. Fixture: three doer accounts, each morning_hour pinned to the current local hour so
  --    `slot` reads 0 regardless of the wall clock, two commitments for v_user (both quiet on
  --    both days under test), one for v_fourth (step 8 only).
  -- -------------------------------------------------------------------------------
  v_local_hour := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh')::integer;
  v_asked_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  v_day_before := v_asked_day - 1;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'story-5-2-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user, v_other, v_fourth]) as t(id);

  update public.profile set morning_hour = v_local_hour
   where id in (v_user, v_other, v_fourth);

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user, gen_random_uuid(), 'No fap', 'abstain', 'daily', true)
  returning id into v_ca;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_user, gen_random_uuid(), 'Gym', 'do', 'daily', false)
  returning id into v_cb;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_fourth, gen_random_uuid(), 'Read', 'do', 'daily', false)
  returning id into v_cd;

  raise notice using message = format(
    'Fixture ok: asked_day=%s, day_before=%s, morning_hour pinned to the current local hour '
    '(%s) for every account.', v_asked_day, v_day_before, v_local_hour);

  -- -------------------------------------------------------------------------------
  -- 2. Second quiet morning: neither of v_user's two commitments has a Declaration for
  --    either day, no active episode exists -- the pass opens exactly one, enqueues exactly
  --    one push, and suppresses the routine gate- push for the same account in the same pass
  --    even though both commitments are, in isolation, "outstanding".
  -- -------------------------------------------------------------------------------
  perform public.enqueue_gate_reminders();

  select count(*) into v_count from public.silence_episode where owner_id = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected exactly 1 silence_episode row for v_user after a genuine 2-day quiet streak, '
      'found %s.', v_count);
  end if;

  select id, started_day, satisfied_at into v_episode1, v_started_day, v_satisfied
    from public.silence_episode where owner_id = v_user;

  if v_started_day <> v_day_before then
    raise exception using message = format(
      'started_day must be the earlier of the two quiet days (%s), reads %s.',
      v_day_before, v_started_day);
  end if;
  if v_satisfied is not null then
    raise exception using message = 'A freshly opened episode must not already carry satisfied_at.';
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'silence-' || v_user::text || '-' || v_day_before::text;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected exactly 1 outbox row at the silence- dedupe key, found %s.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where owner_id = v_user and dedupe_key like 'gate-%';
  if v_count <> 0 then
    raise exception using message = format(
      'The routine gate- push must be suppressed the very morning the episode opens, found '
      '%s gate- row(s).', v_count);
  end if;

  raise notice using message =
    'Step 2 ok: silence_episode opened (started_day = day_before), exactly one silence- push '
    'enqueued, and the routine gate- push was suppressed in the same pass.';

  -- -------------------------------------------------------------------------------
  -- 3. Re-run, same hour: detection re-runs before the next asked-day advances. The same
  --    dedupe key means outbox_enqueue() no-ops, and the episode's own partial unique index
  --    means the insert attempt itself no-ops too -- no duplicate row, no duplicate push, and
  --    the routine push stays suppressed.
  -- -------------------------------------------------------------------------------
  perform public.enqueue_gate_reminders();

  select count(*) into v_count from public.silence_episode where owner_id = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'A re-run before the next asked-day advances must not open a second episode, found %s.',
      v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'silence-' || v_user::text || '-' || v_day_before::text;
  if v_count <> 1 then
    raise exception using message = format(
      'A re-run must not enqueue a second push at the same dedupe key, found %s.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where owner_id = v_user and dedupe_key like 'gate-%';
  if v_count <> 0 then
    raise exception using message =
      'The routine gate- push must still be suppressed on a same-hour re-run.';
  end if;

  raise notice using message =
    'Step 3 ok: a same-hour re-run opened no second episode, enqueued no second push, and '
    'left the routine push suppressed.';

  -- -------------------------------------------------------------------------------
  -- 4. Declaration answered mid-episode: v_ca is declared for asked_day (any Declaration,
  --    not necessarily one naming a day the episode itself opened on) -- the after-insert
  --    trigger ends the episode immediately, synchronously, not on the next scheduled pass.
  -- -------------------------------------------------------------------------------
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_ca, gen_random_uuid(), 'held',
    ((v_asked_day + 1)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  select satisfied_at into v_satisfied from public.silence_episode where id = v_episode1;
  if v_satisfied is null then
    raise exception using message =
      'declaration_satisfies_silence() must set satisfied_at the instant a Declaration lands '
      'while the episode is active -- it still reads null.';
  end if;

  raise notice using message = format(
    'Step 4 ok: the episode''s own satisfied_at is set (%s), immediately, by the Declaration '
    'insert alone.', v_satisfied);

  -- -------------------------------------------------------------------------------
  -- 5. Routine notifications resume: v_cb is still undeclared for asked_day, so the very next
  --    pass, with the episode no longer active, both re-derives that the 2-day streak is
  --    broken (v_ca now carries an answer, so asked_day no longer reads quiet) and enqueues
  --    the routine gate- push for the one commitment still genuinely outstanding.
  -- -------------------------------------------------------------------------------
  perform public.enqueue_gate_reminders();

  select count(*) into v_count from public.silence_episode where owner_id = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'Answering breaks the 2-day streak (asked_day no longer reads quiet), so no second '
      'episode should open -- found %s row(s).', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where dedupe_key = 'gate-' || v_user::text || '-' || v_asked_day::text || '-0';
  if v_count <> 1 then
    raise exception using message = format(
      'The routine gate- push for v_cb (still genuinely outstanding) must resume once the '
      'episode is satisfied, found %s row(s) at its dedupe key.', v_count);
  end if;

  raise notice using message =
    'Step 5 ok: routine gate-reminder pushes resume once the episode is satisfied, and no '
    'second episode opened from the same, now-broken, streak.';

  -- -------------------------------------------------------------------------------
  -- 6. RLS: v_other can read only its own silence_episode rows, and no client session --
  --    not even the episode's own owner -- may insert or update one directly.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select count(*) into v_count from public.silence_episode where owner_id = v_user;
  if v_count <> 0 then
    raise exception using message = format(
      'v_other can read %s of v_user''s own silence_episode row(s) -- "silence_episode: read '
      'own" did not hold.', v_count);
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select count(*) into v_count from public.silence_episode where owner_id = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'v_user must read its own 1 silence_episode row, found %s.', v_count);
  end if;

  v_refused := false;
  begin
    insert into public.silence_episode (owner_id, started_day) values (v_user, v_day_before);
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;
  if not v_refused then
    raise exception using message =
      'A client session inserted a silence_episode row directly -- there must be no insert '
      'policy at all, not even for the episode''s own owner.';
  end if;

  update public.silence_episode set satisfied_at = null where id = v_episode1;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'A client session updated %s silence_episode row(s) -- there must be no update policy.',
      v_count);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message = format(
    'Step 6 ok: RLS filters v_other away from v_user''s own row (%s), a direct client insert '
    'is refused (%s), and a direct client update reaches nothing.', v_count, v_message);

  -- -------------------------------------------------------------------------------
  -- 7. New episode after satisfaction: a satisfied episode never blocks a later, genuinely
  --    separate one for the same account -- the partial unique index only ever blocks a
  --    second *active* row. v_fourth's own commitment is quiet on the same two real days;
  --    detection opens episode1, an unrelated Declaration (a different day entirely, so it
  --    never touches the streak's own two days) satisfies it, and a second pass opens a
  --    genuinely new, second row -- both rows on file, only the newer one active.
  -- -------------------------------------------------------------------------------
  perform public.enqueue_gate_reminders();

  select count(*) into v_count from public.silence_episode where owner_id = v_fourth;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected v_fourth''s own first episode to open, found %s row(s).', v_count);
  end if;

  -- A Declaration for a day well outside the streak -- it satisfies the episode without
  -- touching either of asked_day/day_before's own quiet status for v_cd.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_fourth, v_cd, gen_random_uuid(), 'held',
    ((v_asked_day - 99)::timestamp + interval '7 hours') at time zone 'Asia/Ho_Chi_Minh');

  select count(*) into v_count from public.silence_episode
   where owner_id = v_fourth and satisfied_at is null;
  if v_count <> 0 then
    raise exception using message =
      'An unrelated Declaration must still satisfy the active episode (any Declaration, any '
      'day) -- v_fourth still shows an active row.';
  end if;

  perform public.enqueue_gate_reminders();

  select count(*) into v_count from public.silence_episode where owner_id = v_fourth;
  if v_count <> 2 then
    raise exception using message = format(
      'A satisfied episode must not block a later, separate streak from opening its own new '
      'row -- expected 2 silence_episode rows for v_fourth (one satisfied, one active), found '
      '%s.', v_count);
  end if;

  select count(*) into v_count from public.silence_episode
   where owner_id = v_fourth and satisfied_at is null;
  if v_count <> 1 then
    raise exception using message = format(
      'Expected exactly 1 active row for v_fourth after the second episode opens, found %s.',
      v_count);
  end if;

  raise notice using message =
    'Step 7 ok: the satisfied episode did not block a second, genuinely new row from opening '
    '-- silence_episode_one_active only ever constrains active rows.';

  raise notice using message =
    'PASS. Every I/O Matrix row holds: a genuine 2-day streak opens exactly one episode and '
    'enqueues exactly one push while suppressing the routine one in the same pass; a same-hour '
    're-run duplicates neither; any Declaration ends the active episode immediately and '
    'routine pushes resume; the RLS/no-write boundaries hold; and a satisfied episode never '
    'blocks a later, separate one.';
end $$;

rollback;
