-- Story 6.7 — the referee may object.
--
-- The first correction in this project that moves a day the wrong way: toward `missed`, and
-- toward money on a day that previously cost nothing. Everything asserted here is either one row
-- of the story's own I/O matrix, pinned against the specific message or constraint that produces
-- it, or one of the four properties the design rests on:
--
--   1. **With no referee action at all, nothing about this feature runs.** Account A settles its
--      proven day held, writes no objection, enqueues no `objection-*` notification, and is
--      untouched by every step below. Asserted, not assumed.
--   2. **It lands as a Failed Day with an owed Penalty, or it does not land at all.** Step 11 runs
--      all five no-recourse landings -- an expired day, a commitment carrying no penalty, a Weekly
--      Quota commitment, a penalty already waived, a penalty held under an open appeal -- and each
--      is refused in its own words, because `grace_day_validate()` would reach none of them.
--   3. **A correction freezes the whole day, from the superseded settlement's own rows.** Step 5
--      asserts the count on a two-commitment account and reads the *other* commitment's chain
--      afterwards -- narrowing the freeze to the objected commitment fails both. Step 12 objects to
--      a commitment archived before the day it names, which a live `commitments_owing()` recompute
--      cannot even see.
--   4. **The referee may only act on the account he is paired to.** Step 3.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-7-the-referee-may-object.sql
--
-- One transaction, rolled back at the end. Nothing persists.
--
-- It needs a database with **no live doer account**: `settle_day` raises rather than skipping when
-- `p_override` meets one (AD-16), so a single live profile would disable every call below. Local
-- stack or preview branch, never the author's own project.
--
-- **One account per scenario, deliberately** — the same reason `6-4-midnight-decides-the-day.sql`
-- gives: `commitments_owing()` returns every commitment an account owns, so two scenarios sharing
-- an account would share every day and neither could be read on its own. Because `object_to_day()`
-- is scoped to the account the referee is paired to, and one referee can only ever be paired to
-- one account, the fixture's single `referee_invite` row is **repointed before each scenario**.
-- That is the fixture standing in for fifteen separate installations, not a state a real
-- deployment reaches.
--
-- **A proven past day cannot be built through the front door inside one transaction.** The
-- evidence trigger refuses a claim's photo once the day it proves has ended (20260828150000),
-- which is correct and is asserted by `6-3`. So the claim is inserted as `postgres` — which takes
-- `declaration_derive_day()`'s non-doer branch and lands on the previous local day — and the
-- evidence trigger is switched off for exactly those inserts, with `owner_id` written by hand.
-- The same device `6-4` already uses.

begin;

-- The local stack's default privileges differ from the author's own project (recorded at length
-- in `2-1-roles-and-rls.sql`'s own header). `object_to_day` and `referee_day_lookup` carry their
-- own EXECUTE grants in the migration and need nothing here; the ordinary table reads and the two
-- client-side inserts (`grace_day`, `appeal`) this fixture drives through RLS still do.
grant select on table public.profile, public.commitment, public.settlement, public.penalty,
                    public.settlement_commitment, public.objection, public.chain_current
  to authenticated;
grant select, insert on table public.grace_day, public.appeal to authenticated;

do $$
declare
  -- One account per scenario.
  v_a        uuid := gen_random_uuid(); -- nobody objects; the day holds and nothing runs
  v_b        uuid := gen_random_uuid(); -- objection on a clean day: the freeze, the chain, the money
  v_c        uuid := gen_random_uuid(); -- objection on a day that already failed and already owes
  v_d        uuid := gen_random_uuid(); -- the window that has closed
  v_e        uuid := gen_random_uuid(); -- the second objection
  v_f        uuid := gen_random_uuid(); -- the penalty that has already been collected
  v_g        uuid := gen_random_uuid(); -- the doer who cannot call this at all
  v_h        uuid := gen_random_uuid(); -- the Grace Day spent on an objection's own penalty
  v_i        uuid := gen_random_uuid(); -- the day that closed on the clock -- expired
  v_j        uuid := gen_random_uuid(); -- the commitment that carries no penalty
  v_k        uuid := gen_random_uuid(); -- the Weekly Quota commitment
  v_l        uuid := gen_random_uuid(); -- the day already forgiven by a Grace Day -- waived
  v_m        uuid := gen_random_uuid(); -- the penalty held under an open appeal
  v_p        uuid := gen_random_uuid(); -- the commitment archived before the day it names
  v_referee  uuid := gen_random_uuid();

  v_a_pill   uuid;
  v_b_pill   uuid; -- objected to
  v_b_gym    uuid; -- untimed, held both days: the commitment the freeze must not lose
  v_c_pill   uuid;
  v_c_gym    uuid; -- untimed, slipped: the day already failed without the referee
  v_d_pill   uuid;
  v_e_pill   uuid;
  v_f_pill   uuid;
  v_f_gym    uuid; -- untimed, slipped: the penalty that then gets collected
  v_g_pill   uuid;
  v_h_pill   uuid;
  v_i_pill   uuid;
  v_i_gym    uuid; -- untimed, never answered: what makes the day expired
  v_j_pill   uuid; -- carries_penalty false
  v_k_quota  uuid; -- weekly_quota, timed, carries_penalty
  v_l_pill   uuid;
  v_l_gym    uuid; -- untimed, slipped: the penalty the Grace Day then waives
  v_m_pill   uuid;
  v_m_auto   uuid; -- untimed, Auto-check: the machine-filed miss behind the appeal
  v_p_pill   uuid; -- archived before v_d1
  v_p_gym    uuid;

  v_d1       date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  v_d2       date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 2;

  v_s_a      uuid;
  v_s_b1     uuid;
  v_s_c      uuid;
  v_s_d      uuid;
  v_s_e      uuid;
  v_s_f      uuid;
  v_s_g      uuid;
  v_s_h      uuid;
  v_s_i      uuid;
  v_s_j      uuid;
  v_s_k      uuid;
  v_s_l      uuid;
  v_s_m      uuid;
  v_s_p      uuid;
  v_s_week   uuid;

  v_correction uuid;
  v_penalty    uuid;
  v_appeal     uuid;
  v_claim      uuid;
  v_claimrow   record;

  -- Observed
  v_verdict  public.day_verdict;
  v_outcome  public.commitment_outcome;
  v_state    public.penalty_state;
  v_amount   bigint;
  v_count    integer;
  v_current  integer;
  v_longest  integer;
  v_body     text;
  v_message  text;
  v_refused  boolean;
  v_flag     boolean;
  v_deadline timestamptz;
begin
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override (AD-16). '
      'Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 0. Fixture: fourteen doer accounts, one referee, and a proven day each.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'story-6-7-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_a, v_b, v_c, v_d, v_e, v_f, v_g, v_h, v_i, v_j, v_k, v_l, v_m, v_p,
                      v_referee]) as t(id);

  update public.profile set role = 'referee' where id = v_referee;

  -- The pairing record `paired_doer_id()` reads. One accepted invitation, repointed before each
  -- scenario -- see the header: one referee is only ever paired to one account, and this file
  -- is fifteen installations wearing one database.
  insert into public.referee_invite
    (email, token_hash, created_by, expires_at, accepted_at, accepted_by)
  values ('story-6-7-referee@example.test', 'story-6-7-token-hash', v_a,
          now() + interval '1 day', now(), v_referee);

  -- The timed commitment each account is judged on. 10:00 with a 30-minute window, the same
  -- shape 6-1/6-2/6-4 use, so a claim at 10:14 is inside it.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_a_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_b_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_b, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_b_gym;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_c, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_c_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_c, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_c_gym;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_d, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_d_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_e, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_e_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_f, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_f_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_f, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_f_gym;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_g, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_g_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_h, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_h_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_i, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_i_pill;

  -- Timed, and never claimed. Timed on purpose: an *untimed* commitment with no answer holds its
  -- day open until D+3 (declaration_deadline), so it would not have settled at all inside this
  -- transaction. A timed one's question dies at its own midnight (Story 6.4), which is what makes
  -- the day read `expired` today rather than in three days.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_i, gen_random_uuid(), 'Gym', 'do', 'daily', true, time '10:00', 30)
  returning id into v_i_gym;

  -- carries_penalty false: proving the day cost nothing is exactly the point.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_j, gen_random_uuid(), 'Pill', 'do', 'daily', false, time '10:00', 30)
  returning id into v_j_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, weekly_target, week_start_day,
                                 due_time, late_window_minutes)
  values (v_k, gen_random_uuid(), 'Call home', 'do', 'weekly_quota', true, 3, 1,
          time '10:00', 30)
  returning id into v_k_quota;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_l, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_l_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_l, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_l_gym;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_m, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_m_pill;

  -- A timed commitment may not carry an Auto-check (Story 6.4, decision 3), so the machine-filed
  -- miss an appeal needs has to live on an untimed one.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref)
  values (v_m, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'story-6-7-m')
  returning id into v_m_auto;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, due_time, late_window_minutes)
  values (v_p, gen_random_uuid(), 'Pill', 'do', 'daily', true, time '10:00', 30)
  returning id into v_p_pill;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_p, gen_random_uuid(), 'Gym', 'do', 'daily', true)
  returning id into v_p_gym;

  -- Nothing is judged for a day it did not exist on (Story 6.4), so every fixture commitment has
  -- to predate the days below or it would simply drop out of them.
  update public.commitment set created_at = created_at - interval '90 days'
   where owner_id in (v_a, v_b, v_c, v_d, v_e, v_f, v_g, v_h, v_i, v_j, v_k, v_l, v_m, v_p);

  -- Every proved day, claim and photo together. Inserted as postgres, so
  -- declaration_derive_day() takes its non-doer branch and lands the claim on the previous local
  -- day -- 10:14 on the morning after the day it proves -- and the evidence trigger is off,
  -- because it refuses a claim's photo once the day it proves has ended (20260828150000).
  alter table public.evidence disable trigger evidence_derive_owner;

  for v_claimrow in
    select * from (values
      (v_a, v_a_pill, v_d1),
      (v_b, v_b_pill, v_d2),
      (v_b, v_b_pill, v_d1),
      (v_c, v_c_pill, v_d1),
      (v_d, v_d_pill, v_d1),
      (v_e, v_e_pill, v_d1),
      (v_f, v_f_pill, v_d1),
      (v_g, v_g_pill, v_d1),
      (v_h, v_h_pill, v_d1),
      (v_i, v_i_pill, v_d1),
      (v_j, v_j_pill, v_d1),
      (v_k, v_k_quota, v_d1),
      (v_l, v_l_pill, v_d1),
      (v_m, v_m_pill, v_d1),
      (v_p, v_p_pill, v_d1)
    ) as t(owner_id, commitment_id, for_day)
  loop
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_claimrow.owner_id, v_claimrow.commitment_id, gen_random_uuid(), 'held',
            ((v_claimrow.for_day + 1)::timestamp + interval '10 hours 14 minutes')
              at time zone 'Asia/Ho_Chi_Minh')
    returning id into v_claim;

    insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
    values (v_claim, v_claimrow.owner_id, v_claim::text || '/pill.jpg', v_claimrow.for_day);
  end loop;

  alter table public.evidence enable trigger evidence_derive_owner;

  -- The untimed commitments that held. No photo: only a timed commitment's `held` is earned by
  -- evidence (Story 6.4).
  for v_claimrow in
    select * from (values
      (v_b, v_b_gym, v_d2),
      (v_b, v_b_gym, v_d1),
      (v_p, v_p_gym, v_d1)
    ) as t(owner_id, commitment_id, for_day)
  loop
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_claimrow.owner_id, v_claimrow.commitment_id, gen_random_uuid(), 'held',
            ((v_claimrow.for_day + 1)::timestamp + interval '8 hours')
              at time zone 'Asia/Ho_Chi_Minh');
  end loop;

  -- The honest slips, on the same day the timed commitment was proved.
  for v_claimrow in
    select * from (values
      (v_c, v_c_gym, v_d1),
      (v_f, v_f_gym, v_d1),
      (v_l, v_l_gym, v_d1)
    ) as t(owner_id, commitment_id, for_day)
  loop
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_claimrow.owner_id, v_claimrow.commitment_id, gen_random_uuid(), 'slipped',
            ((v_claimrow.for_day + 1)::timestamp + interval '8 hours')
              at time zone 'Asia/Ho_Chi_Minh');
  end loop;

  -- Account M's machine-filed miss, which is what an appeal needs. file_auto_check_result() is
  -- security definer, so its declaration lands on the previous local day exactly as above.
  perform public.file_auto_check_result(v_m_auto, v_m, 'missed');

  -- Account I's gym commitment answers nothing at all: that is what makes its day `expired`.

  perform public.settle_day(v_d2, true);
  perform public.settle_day(v_d1, true);

  select id into v_s_a from public.settlement
   where subject = v_a and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_b1 from public.settlement
   where subject = v_b and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_c from public.settlement
   where subject = v_c and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_d from public.settlement
   where subject = v_d and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_e from public.settlement
   where subject = v_e and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_f from public.settlement
   where subject = v_f and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_g from public.settlement
   where subject = v_g and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_h from public.settlement
   where subject = v_h and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_i from public.settlement
   where subject = v_i and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_j from public.settlement
   where subject = v_j and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_k from public.settlement
   where subject = v_k and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_l from public.settlement
   where subject = v_l and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_m from public.settlement
   where subject = v_m and period = v_d1 and kind = 'day' and supersedes is null;
  select id into v_s_p from public.settlement
   where subject = v_p and period = v_d1 and kind = 'day' and supersedes is null;

  if v_s_a is null or v_s_b1 is null or v_s_c is null or v_s_d is null or v_s_e is null
     or v_s_f is null or v_s_g is null or v_s_h is null or v_s_i is null or v_s_j is null
     or v_s_k is null or v_s_l is null or v_s_m is null or v_s_p is null then
    raise exception using message =
      'Fixture setup failed: not every account''s day settled.';
  end if;

  raise notice using message =
    'Fixture ok: fourteen accounts with a photo-proven day, and a referee who has been asked for '
    'nothing.';

  -- -------------------------------------------------------------------------------
  -- 1. Nobody objects. Every proven day holds, and nothing about this feature has run.
  --    The Acceptance Criterion that is easiest to assume and cheapest to assert.
  -- -------------------------------------------------------------------------------
  select verdict into v_verdict from public.settlement where id = v_s_a;
  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s_a and commitment_id = v_a_pill;

  if v_verdict <> 'clean' or v_outcome is distinct from 'held' then
    raise exception using message = format(
      'Account A''s proven day reads `%s` / `%s`, expected `clean` / `held` -- a photo holds a '
      'timed day by itself and no referee is involved.', v_verdict, v_outcome);
  end if;

  select count(*) into v_count from public.penalty_current
   where subject = v_a and period = v_d1 and kind = 'day';
  if v_count <> 0 then
    raise exception using message = format(
      'Account A''s proven day carries %s penalty row(s) in penalty_current, expected 0.',
      v_count);
  end if;

  select count(*) into v_count from public.objection;
  if v_count <> 0 then
    raise exception using message = format(
      '%s objection row(s) exist after settlement alone, expected 0 -- nothing in this feature '
      'may run without the referee calling it.', v_count);
  end if;

  select count(*) into v_count from public.outbox where dedupe_key like 'objection-%';
  if v_count <> 0 then
    raise exception using message = format(
      '%s objection notification(s) were enqueued by settlement alone, expected 0.', v_count);
  end if;

  raise notice using message =
    'Step 1 ok: with no referee action at all, a proven day settles held, owes nothing, writes '
    'no objection and enqueues nothing.';

  -- -------------------------------------------------------------------------------
  -- 2. Not the referee. Refused before any row is read -- proven against a real settlement AND
  --    a bogus id, so the message itself pins the ordering rather than the final state alone.
  --    `anon` cannot reach the function at all.
  -- -------------------------------------------------------------------------------
  if has_function_privilege('anon', 'public.object_to_day(uuid, uuid, text)', 'execute') then
    raise exception using message =
      '`anon` can execute object_to_day(), so an unauthenticated caller can reach '
      '/rest/v1/rpc/object_to_day.';
  end if;

  update public.referee_invite set created_by = v_g;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_g, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_g, v_g_pill, 'I say so.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%referee%' then
    raise exception using message = format(
      'A doer objecting to his own day was not refused with a referee-specific message. '
      'refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.object_to_day(gen_random_uuid(), gen_random_uuid(), 'I say so.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%referee%'
     or v_message ilike '%no such settled day%' then
    raise exception using message = format(
      'A doer objecting to a bogus settlement id read "%s" -- the role check must refuse before '
      'the settlement is ever looked up, so this must read the same referee-only message as a '
      'real day, never "No such settled day."', coalesce(v_message, '<null>'));
  end if;

  -- And he reads nothing through the lookup either: role_from_table() filters it to zero rows
  -- rather than raising (AD-7's read convention).
  select count(*) into v_count from public.referee_day_lookup(v_s_g);
  if v_count <> 0 then
    raise exception using message = format(
      'A doer session read %s row(s) from referee_day_lookup(), expected 0.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  select verdict into v_verdict from public.settlement where id = v_s_g;
  select count(*) into v_count from public.settlement where supersedes = v_s_g;
  if v_verdict <> 'clean' or v_count <> 0 then
    raise exception using message = format(
      'Account G''s day reads `%s` with %s correction(s) after two refused doer calls, expected '
      '`clean` with none -- untouched.', v_verdict, v_count);
  end if;

  raise notice using message =
    'Step 2 ok: anon cannot execute object_to_day() at all, and a doer session is refused before '
    'any row is read -- real settlement or bogus id alike -- while reading nothing through the '
    'lookup.';

  -- -------------------------------------------------------------------------------
  -- 3. An account he is not paired to. The role check says who is calling; it says nothing
  --    about whose money this is, and profile_single_referee makes the referee global --
  --    20260824160000 accepted that unscoped reach explicitly *because it was read-only*.
  -- -------------------------------------------------------------------------------
  update public.referee_invite set created_by = v_b;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_a, v_a_pill, 'A day that is none of my business.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%not paired%' then
    raise exception using message = format(
      'The referee objecting to an account he is not paired to read "%s", expected the '
      '"not paired to" refusal.', coalesce(v_message, '<null>'));
  end if;

  -- The lookup is scoped the same way, so he cannot even read that account's day.
  select count(*) into v_count from public.referee_day_lookup(v_s_a);
  if v_count <> 0 then
    raise exception using message = format(
      'referee_day_lookup() returned %s row(s) for an account the referee is not paired to, '
      'expected 0.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  select count(*) into v_count from public.objection where subject = v_a;
  if v_count <> 0 then
    raise exception using message = format(
      'A refused cross-account objection still wrote %s row(s), expected none.', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: the referee may neither object to nor look up a day on an account he is not '
    'paired to -- the role check alone is not scoping.';

  -- -------------------------------------------------------------------------------
  -- 4. The lookup, as the referee: what one named day recorded, when its window closes, and
  --    that it has not been objected to yet. A week settlement answers nothing.
  -- -------------------------------------------------------------------------------
  -- A week-kind settlement with a synthetic per-commitment row. settle_week() never writes one
  -- (Week Close freezes no per-commitment outcome -- lib/ledger.ts's own "Never"), so this row
  -- exists only to prove referee_day_lookup()'s own `s.kind = 'day'` filter does the work, rather
  -- than the absence of rows doing it for free.
  insert into public.settlement (subject, period, kind, verdict, missed_count)
  values (v_b, v_d1, 'week', 'clean', 0)
  returning id into v_s_week;

  insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
  values (v_s_week, v_b, v_b_pill, 'held');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select l.outcome, l.objection_deadline, l.already_objected
    into v_outcome, v_deadline, v_flag
    from public.referee_day_lookup(v_s_b1) l
   where l.commitment_id = v_b_pill;

  select count(*) into v_count from public.referee_day_lookup(v_s_week);

  perform set_config('role', 'postgres', true);

  if v_outcome is distinct from 'held' or v_flag is distinct from false then
    raise exception using message = format(
      'referee_day_lookup() reads outcome `%s` / already_objected %s for account B''s proven '
      'day, expected `held` / false.', v_outcome, v_flag);
  end if;

  if v_deadline is null or v_deadline <= now() then
    raise exception using message = format(
      'referee_day_lookup() reports an objection window closing at %s, which is not in the '
      'future -- the day settled moments ago and has 48 hours on it.', v_deadline);
  end if;

  if v_count <> 0 then
    raise exception using message = format(
      'referee_day_lookup() answered %s row(s) for a week-kind settlement, expected 0 -- an '
      'objection names one commitment on one settled *day*.', v_count);
  end if;

  -- Removed the moment it has done its job. It is a row settle_week() never writes, and leaving
  -- it in place would give b_pill two judged rows for the same period -- chain_current's own
  -- gaps-and-islands query then finds two runs ending on the same day and raises, which would be
  -- this fixture breaking a view rather than the story breaking anything.
  delete from public.settlement_commitment where settlement_id = v_s_week;
  delete from public.settlement where id = v_s_week;

  raise notice using message =
    'Step 4 ok: the referee looks up one settlement he named and reads the commitment, its '
    'frozen outcome, when the window closes and that nobody has objected yet; a week-kind '
    'settlement answers nothing.';

  -- -------------------------------------------------------------------------------
  -- 5. Objection on a clean day (account B). The day is superseded with a freeze of the WHOLE
  --    day -- account B owns two commitments and both must appear -- the objected commitment
  --    reads `missed`, the other keeps `held` and keeps its chain, the day carries exactly one
  --    penalty, and the author is told.
  -- -------------------------------------------------------------------------------
  select current_days into v_current from public.chain_current where commitment_id = v_b_pill;
  if v_current <> 2 then
    raise exception using message = format(
      'Fixture setup failed: account B''s pill chain reads %s before any objection, expected 2 '
      '-- two consecutive proven days.', v_current);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.object_to_day(v_s_b1, v_b_pill, 'That photo is of my kitchen, not the gym.');

  perform set_config('role', 'postgres', true);

  select id, verdict into v_correction, v_verdict
    from public.settlement where supersedes = v_s_b1;
  if v_correction is null or v_verdict <> 'failed' then
    raise exception using message = format(
      'Account B''s day is %s / `%s` after the objection, expected a correction reading '
      '`failed`.', v_correction, v_verdict);
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction and commitment_id = v_b_pill;
  -- `is distinct from`, never `<>`: with no row at all `v_outcome` is NULL and `NULL <> 'missed'`
  -- evaluates NULL, which `if` treats as false -- the assertion would silently never fire, which
  -- is exactly how a narrowed freeze passed this file once.
  if v_outcome is distinct from 'missed' then
    raise exception using message = format(
      'The objected commitment reads `%s` on the correction, expected `missed` -- that is the '
      'entire content of the objection.', coalesce(v_outcome::text, '<no row at all>'));
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction and commitment_id = v_b_gym;
  if v_outcome is distinct from 'held' then
    raise exception using message = format(
      'The commitment that was NOT objected to reads `%s` on the correction, expected `held` -- '
      'a correction freezes the whole day (20260820102000), and one that carried only the '
      'objected row would vanish this commitment''s day from its chain rather than leave it '
      'alone.', coalesce(v_outcome::text, '<no row at all>'));
  end if;

  select count(*) into v_count from public.settlement_commitment
   where settlement_id = v_correction;
  if v_count <> 2 then
    raise exception using message = format(
      'The correction froze %s commitment outcome(s), expected 2 -- account B owns two '
      'commitments and both were owed an answer that day.', v_count);
  end if;

  select count(*), min(state), min(amount_dong) into v_count, v_state, v_amount
    from public.penalty_current
   where subject = v_b and period = v_d1 and kind = 'day';
  if v_count <> 1 or v_state <> 'owed' or v_amount <> public.penalty_amount_dong() then
    raise exception using message = format(
      'Account B''s objected day carries %s live penalty row(s) reading `%s` / %s, expected '
      'exactly 1 `owed` at %s.', v_count, v_state, v_amount, public.penalty_amount_dong());
  end if;

  select reason into v_message from public.objection
   where subject = v_b and for_day = v_d1;
  if v_message is distinct from 'That photo is of my kitchen, not the gym.' then
    raise exception using message = format(
      'The stored objection reason reads "%s", expected the referee''s own words verbatim.',
      coalesce(v_message, '<none>'));
  end if;

  select count(*) into v_count from public.objection
   where subject = v_b and for_day = v_d1 and referee_id = v_referee;
  if v_count <> 1 then
    raise exception using message =
      'The objection does not record which referee made it. A revoked and re-paired slot would '
      'leave an irreversible, money-creating statement attributed to nobody.';
  end if;

  select payload ->> 'body' into v_body from public.outbox
   where owner_id = v_b and dedupe_key like 'objection-%';
  if v_body is null or v_body not ilike '%does not hold%' or v_body not ilike '%owed%' then
    raise exception using message = format(
      'Account B''s objection notification reads "%s", expected it to say the day does not hold '
      'and that the amount is owed.', coalesce(v_body, '<none enqueued>'));
  end if;

  -- The body must be sendable, and it must not carry the referee's own free text -- a reason
  -- containing "currently" would otherwise abort the objection at the outbox insert.
  if not public.push_body_is_sendable(v_body) then
    raise exception using message = format(
      'The objection notification body "%s" would not pass push_body_is_sendable.', v_body);
  end if;

  select current_days, longest_days into v_current, v_longest
    from public.chain_current where commitment_id = v_b_pill;
  if v_current <> 0 or v_longest <> 1 then
    raise exception using message = format(
      'Account B''s pill chain reads %s current / %s longest after the objection, expected 0 / 1 '
      '-- the day must break the chain, not disappear from it.', v_current, v_longest);
  end if;

  select current_days into v_current from public.chain_current where commitment_id = v_b_gym;
  if v_current <> 2 then
    raise exception using message = format(
      'The chain of the commitment that was NOT objected to reads %s after the objection, '
      'expected 2 -- an objection about one commitment must leave every other commitment''s own '
      'history exactly as it was. A correction that froze only the objected row would drop this '
      'day out of settlement_current for it and read 1.', v_current);
  end if;

  raise notice using message =
    'Step 5 ok: an objection inside the window supersedes the day with a freeze of the whole day, '
    'the objected commitment reads missed and its chain breaks, the other commitment keeps its '
    'outcome and its chain, the day carries exactly one owed penalty, the reason and the acting '
    'referee are recorded, and the author is notified with a sendable body carrying no free text.';

  -- -------------------------------------------------------------------------------
  -- 6. Objection on a day that already failed and already owes (account C). The commitment
  --    freezes `missed`, the honest slip keeps its own `missed`, and the day still carries the
  --    same one penalty -- no second charge (FR-13). Also: the refusals that are about the call
  --    rather than the landing.
  -- -------------------------------------------------------------------------------
  update public.referee_invite set created_by = v_c;

  select verdict into v_verdict from public.settlement where id = v_s_c;
  select id, state into v_penalty, v_state from public.penalty where settlement_id = v_s_c;
  if v_verdict <> 'failed' or v_penalty is null or v_state <> 'owed' then
    raise exception using message = format(
      'Fixture setup failed: account C''s day reads `%s` with penalty %s / `%s`, expected '
      '`failed` with an owed penalty before any objection.', v_verdict, v_penalty, v_state);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  -- Objecting to a commitment the day already recorded as missed is refused: there is no `held`
  -- to overturn, and a correction identical to the row it supersedes is a link in the chain and
  -- a notification about nothing.
  v_refused := false;
  begin
    perform public.object_to_day(v_s_c, v_c_gym, 'He did not do that one either.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%not held%' then
    raise exception using message = format(
      'Objecting to a commitment the day already recorded as missed read "%s", expected the '
      '"not held" refusal.', coalesce(v_message, '<null>'));
  end if;

  -- And a commitment that was never part of that day at all.
  v_refused := false;
  begin
    perform public.object_to_day(v_s_c, v_a_pill, 'Wrong account entirely.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%not part of that day%' then
    raise exception using message = format(
      'Objecting with another account''s commitment read "%s", expected the "not part of that '
      'day" refusal.', coalesce(v_message, '<null>'));
  end if;

  -- A reason that says nothing is refused before anything is read.
  v_refused := false;
  begin
    perform public.object_to_day(v_s_c, v_c_pill, '   ');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%reason%' then
    raise exception using message = format(
      'An objection with a blank reason read "%s", expected the "give a reason" refusal.',
      coalesce(v_message, '<null>'));
  end if;

  -- And one longer than the column will take, in words rather than a raw 23514. The referee
  -- reads every one of these refusals; a constraint-violation string is not one he can act on.
  v_refused := false;
  begin
    perform public.object_to_day(v_s_c, v_c_pill, repeat('x', 2001));
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%2000 or fewer%' then
    raise exception using message = format(
      'An over-long objection reason read "%s", expected a worded refusal naming the bound, '
      'never a raw objection_reason_is_said violation.', coalesce(v_message, '<null>'));
  end if;

  perform public.object_to_day(v_s_c, v_c_pill, 'I was with him. He never took it.');

  perform set_config('role', 'postgres', true);

  select id, verdict, missed_count into v_correction, v_verdict, v_count
    from public.settlement where supersedes = v_s_c;
  if v_correction is null or v_verdict <> 'failed' or v_count <> 2 then
    raise exception using message = format(
      'Account C''s correction is %s / `%s` / missed_count %s, expected `failed` with 2 -- the '
      'honest slip and the objected claim both count.', v_correction, v_verdict, v_count);
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction and commitment_id = v_c_gym;
  if v_outcome is distinct from 'missed' then
    raise exception using message = format(
      'The honest slip reads `%s` on account C''s correction, expected `missed` -- an objection '
      'about a different commitment must not rewrite it.',
      coalesce(v_outcome::text, '<no row at all>'));
  end if;

  select count(*), min(state), min(amount_dong) into v_count, v_state, v_amount
    from public.penalty_current
   where subject = v_c and period = v_d1 and kind = 'day';
  if v_count <> 1 or v_state <> 'owed' or v_amount <> public.penalty_amount_dong() then
    raise exception using message = format(
      'Account C''s objected day carries %s live penalty row(s) reading `%s` / %s, expected '
      'exactly 1 `owed` at %s -- one penalty per failed day, in any state (FR-13).',
      v_count, v_state, v_amount, public.penalty_amount_dong());
  end if;

  -- The notification must not name an amount: nothing changed hands, and a sentence naming
  -- 500.000₫ would read as a second charge. It must still be sendable.
  select payload ->> 'body' into v_body from public.outbox
   where owner_id = v_c and dedupe_key like 'objection-%';
  if v_body is null or v_body ilike '%₫%' or v_body not ilike '%already cost%' then
    raise exception using message = format(
      'Account C''s objection notification reads "%s", expected it to say the day already cost '
      'what it costs and to name no amount.', coalesce(v_body, '<none enqueued>'));
  end if;

  if not public.push_body_is_sendable(v_body) then
    raise exception using message = format(
      'The no-amount objection body "%s" would not pass push_body_is_sendable -- the branch that '
      'names no money still has to date itself.', v_body);
  end if;

  raise notice using message =
    'Step 6 ok: an objection on a day that already failed freezes the objected commitment as '
    'missed, leaves the honest slip''s own outcome alone, keeps exactly one live penalty at the '
    'same amount, and tells the author nothing further is owed in a sendable body. A commitment '
    'that is not held, one that was never part of the day, a blank reason and an over-long one '
    'are each refused in their own words.';

  -- -------------------------------------------------------------------------------
  -- 7. The window has closed (account D). Measured from the superseded settlement's own
  --    settled_at, so ageing that column by 49 hours is the whole scenario.
  -- -------------------------------------------------------------------------------
  update public.referee_invite set created_by = v_d;
  update public.settlement set settled_at = now() - interval '49 hours' where id = v_s_d;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_d, v_d_pill, 'I only just heard about this.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%48 hours%' then
    raise exception using message = format(
      'An objection 49 hours after the day settled read "%s", expected the closed-window '
      'refusal.', coalesce(v_message, '<null>'));
  end if;

  select count(*) into v_count from public.settlement where supersedes = v_s_d;
  if v_count <> 0 then
    raise exception using message = format(
      'A refused, out-of-window objection still wrote %s correction(s), expected none.', v_count);
  end if;

  select count(*) into v_count from public.objection where subject = v_d;
  if v_count <> 0 then
    raise exception using message = format(
      'A refused, out-of-window objection still wrote %s objection row(s), expected none.',
      v_count);
  end if;

  raise notice using message =
    'Step 7 ok: an objection more than 48 hours after that settlement was written is refused in '
    'the referee''s own words, and writes nothing at all.';

  -- -------------------------------------------------------------------------------
  -- 8. A second objection (account E). AD-15's guarded transition from both directions: the
  --    stale settlement id he originally read, and the correction his own first call produced.
  -- -------------------------------------------------------------------------------
  update public.referee_invite set created_by = v_e;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.object_to_day(v_s_e, v_e_pill, 'He was at my house all morning.');

  select id into v_correction from public.settlement where supersedes = v_s_e;

  -- (a) the same id again -- the settlement now carries a correction.
  v_refused := false;
  begin
    perform public.object_to_day(v_s_e, v_e_pill, 'Saying it twice.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%already been resolved%' then
    raise exception using message = format(
      'A second objection against the settlement already superseded read "%s", expected the '
      '"already been resolved" refusal.', coalesce(v_message, '<null>'));
  end if;

  -- (b) the correction itself -- current, inside its own window, and still refused, because the
  --     day already carries an objection.
  v_refused := false;
  begin
    perform public.object_to_day(v_correction, v_e_pill, 'Saying it a third time.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  if not v_refused or v_message not ilike '%already been objected to%' then
    raise exception using message = format(
      'A second objection against the correction the first one wrote read "%s", expected the '
      '"already been objected to" refusal from the guarded transition.',
      coalesce(v_message, '<null>'));
  end if;

  -- The lookup now says so, which is what keeps the referee's own surface from offering a
  -- control that can only ever be refused.
  select l.already_objected into v_flag
    from public.referee_day_lookup(v_correction) l
   where l.commitment_id = v_e_pill;

  perform set_config('role', 'postgres', true);

  if v_flag is distinct from true then
    raise exception using message = format(
      'referee_day_lookup() reports already_objected %s for a day that has been objected to, '
      'expected true.', v_flag);
  end if;

  select count(*) into v_count from public.objection where subject = v_e and for_day = v_d1;
  if v_count <> 1 then
    raise exception using message = format(
      'Account E carries %s objection row(s) after three calls, expected exactly 1.', v_count);
  end if;

  select count(*) into v_count from public.settlement
   where subject = v_e and period = v_d1 and kind = 'day';
  if v_count <> 2 then
    raise exception using message = format(
      'Account E''s day carries %s settlement row(s) after three objection calls, expected 2 -- '
      'the original and one correction. A forked chain is what settlement_once_correction '
      'exists to refuse.', v_count);
  end if;

  select count(*) into v_count from public.outbox
   where owner_id = v_e and dedupe_key like 'objection-%';
  if v_count <> 1 then
    raise exception using message = format(
      'Account E was notified %s time(s) across three objection calls, expected exactly 1.',
      v_count);
  end if;

  raise notice using message =
    'Step 8 ok: a second objection is refused from both directions -- the stale id and the '
    'correction alike -- leaves exactly one objection, one correction and one notification, and '
    'the lookup says the day is already spoken for.';

  -- -------------------------------------------------------------------------------
  -- 9. The penalty has already been collected (account F). Refused rather than charging twice
  --    for one day: superseding would drop a paid debt out of penalty_current.
  -- -------------------------------------------------------------------------------
  update public.referee_invite set created_by = v_f;

  select id into v_penalty from public.penalty where settlement_id = v_s_f;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.mark_penalty_collected(v_penalty);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_f, v_f_pill, 'Objecting after being paid.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%collected%' then
    raise exception using message = format(
      'An objection against a day whose penalty is already collected read "%s", expected the '
      'collected refusal.', coalesce(v_message, '<null>'));
  end if;

  select state into v_state from public.penalty where id = v_penalty;
  select count(*) into v_count from public.settlement where supersedes = v_s_f;
  if v_state <> 'collected' or v_count <> 0 then
    raise exception using message = format(
      'Account F''s collected penalty reads `%s` with %s correction(s) on its day after a '
      'refused objection, expected `collected` with none -- a collected penalty is terminal and '
      'this feature never writes one.', v_state, v_count);
  end if;

  select count(*) into v_count from public.objection where subject = v_f;
  if v_count <> 0 then
    raise exception using message = format(
      'A refused objection against a collected day still wrote %s objection row(s), expected '
      'none.', v_count);
  end if;

  raise notice using message =
    'Step 9 ok: an objection against a day already paid for is refused, and the collected '
    'penalty is neither superseded nor rewritten.';

  -- -------------------------------------------------------------------------------
  -- 10. The author's whole recourse (account H). An objection's penalty is an ordinary Failed
  --     Day penalty: a Grace Day voids it through the existing path, with no special case. This
  --     is the assertion the landing guard in step 11 exists to make true everywhere.
  -- -------------------------------------------------------------------------------
  update public.referee_invite set created_by = v_h;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.object_to_day(v_s_h, v_h_pill, 'That is last week''s photo.');

  -- The author, spending a Grace Day on the day the objection just made cost money -- his own
  -- client insert through RLS, exactly as components/ledger.tsx makes it.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_h, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.grace_day (owner_id, for_day) values (v_h, v_d1);

  perform set_config('role', 'postgres', true);

  perform public.apply_grace_days();

  select count(*), min(state) into v_count, v_state
    from public.penalty_current
   where subject = v_h and period = v_d1 and kind = 'day';
  if v_count <> 1 or v_state <> 'waived' then
    raise exception using message = format(
      'Account H''s day carries %s live penalty row(s) reading `%s` after a Grace Day, expected '
      'exactly 1 `waived` -- an objection''s penalty is an ordinary Failed Day penalty and the '
      'Grace Day is the author''s whole recourse.', v_count, v_state);
  end if;

  select verdict into v_verdict from public.settlement
   where subject = v_h and period = v_d1 and kind = 'day'
     and not exists (select 1 from public.settlement c where c.supersedes = settlement.id);
  if v_verdict <> 'clean' then
    raise exception using message = format(
      'Account H''s day reads `%s` after the Grace Day, expected `clean` -- apply_grace_days() '
      'forgives the day whole, over an objection''s correction exactly as over any other.',
      v_verdict);
  end if;

  -- The objection row itself survives. It is what he was told, and forgiving the money does not
  -- unsay it.
  select count(*) into v_count from public.objection where subject = v_h and for_day = v_d1;
  if v_count <> 1 then
    raise exception using message = format(
      'Account H carries %s objection row(s) after the Grace Day, expected 1 -- a Grace Day '
      'forgives the money, it does not delete the referee''s words.', v_count);
  end if;

  raise notice using message =
    'Step 10 ok: a Grace Day spent on an objection''s penalty waives it through the existing '
    'path, corrects the day to clean, and leaves the objection itself on the record.';

  -- -------------------------------------------------------------------------------
  -- 11. The landing guard: failed and owed, or nothing. Five ways an objection could otherwise
  --     leave the author a broken chain with no Grace Day able to reach it --
  --     grace_day_validate() (20260825110000) requires `failed` AND `owed`, and an appeal is no
  --     substitute (it needs filed_by = 'auto_check'). Each refused in its own words.
  -- -------------------------------------------------------------------------------

  -- (a) A day that closed on the clock. Account I never answered its gym commitment, so the day
  --     settled `expired` -- and correcting it would produce another expired day. This is also
  --     what keeps supersede_expiries() away from an objection forever: it loops over
  --     `settlement_current` rows reading `expired`, and no correction written here can be one.
  update public.referee_invite set created_by = v_i;

  select verdict into v_verdict from public.settlement where id = v_s_i;
  if v_verdict <> 'expired' then
    raise exception using message = format(
      'Fixture setup failed: account I''s day reads `%s`, expected `expired` -- its gym '
      'commitment answered nothing.', v_verdict);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_i, v_i_pill, 'He did not take it.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%expired%' then
    raise exception using message = format(
      'An objection on a day that closed on the clock read "%s", expected the expired-landing '
      'refusal -- a Grace Day cannot reach an expired day.', coalesce(v_message, '<null>'));
  end if;

  -- (b) A commitment that carried no penalty that day: the corrected day would read `clean` and
  --     cost nothing, so there would be no Grace Day to spend on it.
  update public.referee_invite set created_by = v_j;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_j, v_j_pill, 'He did not take it.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%carried no penalty%' then
    raise exception using message = format(
      'An objection on a commitment carrying no penalty read "%s", expected the '
      '"carried no penalty" refusal.', coalesce(v_message, '<null>'));
  end if;

  -- (c) A Weekly Quota commitment. Its money is decided at week close and never by a day, so an
  --     objection to one day breaks the chain and costs nothing -- the same landing as (b),
  --     reached a different way, and the reason settle_day()/rule_appeal() both exclude the
  --     cadence from their own admitted counts.
  update public.referee_invite set created_by = v_k;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_k, v_k_quota, 'He never called.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%weekly quota%' then
    raise exception using message = format(
      'An objection on a Weekly Quota commitment read "%s", expected the Weekly Quota refusal.',
      coalesce(v_message, '<null>'));
  end if;

  -- (d) A day the author has already spent a Grace Day on. Its penalty reads `waived`, so
  --     objecting would break the chain of a day he has already answered, with no second Grace
  --     Day able to reach it. This is also what closes the reopened-window hole: a Grace Day
  --     correction restamps settled_at and reopens 48 hours, onto a day this refuses.
  update public.referee_invite set created_by = v_l;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_l, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.grace_day (owner_id, for_day) values (v_l, v_d1);

  perform set_config('role', 'postgres', true);
  perform public.apply_grace_days();

  select id into v_correction from public.settlement where supersedes = v_s_l;
  select state into v_state from public.penalty where settlement_id = v_correction;
  if v_correction is null or v_state <> 'waived' then
    raise exception using message = format(
      'Fixture setup failed: account L''s Grace Day left correction %s with penalty `%s`, '
      'expected a correction carrying a waived penalty.', v_correction, v_state);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.object_to_day(v_correction, v_l_pill, 'He did not take it.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%already spent a grace day%' then
    raise exception using message = format(
      'An objection on a day already forgiven by a Grace Day read "%s", expected the waived '
      'refusal.', coalesce(v_message, '<null>'));
  end if;

  -- (e) A penalty held under an open appeal. `appeal.penalty_id` points at that exact row, and
  --     void_expired_appeals() (20260824140000) updates only the row the appeal points at -- so
  --     superseding it would strand the appeal on a penalty penalty_current can no longer see,
  --     held forever, never dropping in the author's favour.
  update public.referee_invite set created_by = v_m;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_m, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
  values (v_m, v_m_auto, gen_random_uuid(), v_d1)
  returning id into v_appeal;

  perform set_config('role', 'postgres', true);

  select state into v_state from public.penalty where settlement_id = v_s_m;
  if v_state <> 'held' then
    raise exception using message = format(
      'Fixture setup failed: account M''s penalty reads `%s` after an appeal was filed, expected '
      '`held`.', v_state);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s_m, v_m_pill, 'He did not take it.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused or v_message not ilike '%open appeal%' then
    raise exception using message = format(
      'An objection on a day whose penalty is held under an open appeal read "%s", expected the '
      'open-appeal refusal.', coalesce(v_message, '<null>'));
  end if;

  -- And the appeal is still answerable, which is the whole reason for that refusal.
  update public.appeal set deadline = now() - interval '1 hour' where id = v_appeal;
  perform public.void_expired_appeals();

  select state into v_state from public.penalty where settlement_id = v_s_m;
  if v_state <> 'dropped' then
    raise exception using message = format(
      'Account M''s appealed penalty reads `%s` after its deadline passed, expected `dropped` -- '
      'an objection must never leave an in-flight appeal pointing at a superseded penalty that '
      'the timeout can no longer reach.', v_state);
  end if;

  select count(*) into v_count from public.objection
   where subject in (v_i, v_j, v_k, v_l, v_m);
  if v_count <> 0 then
    raise exception using message = format(
      'The five no-recourse landings wrote %s objection row(s) between them, expected none.',
      v_count);
  end if;

  raise notice using message =
    'Step 11 ok: an expired day, a commitment carrying no penalty, a Weekly Quota commitment, a '
    'day already forgiven by a Grace Day and a penalty held under an open appeal are each '
    'refused in their own words and write nothing -- and the open appeal still times out in the '
    'author''s favour afterwards.';

  -- -------------------------------------------------------------------------------
  -- 12. A commitment archived before the day it names (account P) still carries its objection.
  --
  --     The correction's outcomes come from the superseded settlement's own frozen rows, never
  --     from a live commitments_owing() recompute -- that function excludes a commitment archived
  --     on or before the day, so a recompute would produce a correction that simply did not
  --     contain the row the objection is about. An enforcement mechanism the person being
  --     enforced against can switch off is not one.
  --
  --     `archived_at` is set into the past here rather than to now(): archiving today never
  --     removes a *past* day from commitments_owing(), so this is a constructed state that pins
  --     down which source the freeze reads, not a reachable exploit. It fails outright against a
  --     recompute-based implementation, which is the point.
  -- -------------------------------------------------------------------------------
  update public.referee_invite set created_by = v_p;
  update public.commitment set archived_at = public.day_begins_at(v_d1) where id = v_p_pill;

  select count(*) into v_count
    from public.commitments_owing(v_p, v_d1) o where o.commitment_id = v_p_pill;
  if v_count <> 0 then
    raise exception using message = format(
      'Fixture setup failed: commitments_owing() still returns the archived commitment %s '
      'time(s) for that day, so this step would prove nothing.', v_count);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  perform public.object_to_day(v_s_p, v_p_pill, 'Archiving it does not make it true.');

  perform set_config('role', 'postgres', true);

  select id, verdict, missed_count into v_correction, v_verdict, v_count
    from public.settlement where supersedes = v_s_p;
  if v_correction is null or v_verdict <> 'failed' or v_count <> 1 then
    raise exception using message = format(
      'Account P''s correction is %s / `%s` / missed_count %s, expected `failed` with 1 -- the '
      'objection must land on the outcome frozen that day, whatever the commitment looks like '
      'now.', v_correction, v_verdict, v_count);
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_correction and commitment_id = v_p_pill;
  if v_outcome is distinct from 'missed' then
    raise exception using message = format(
      'The archived commitment reads `%s` on account P''s correction, expected `missed` -- a '
      'live commitments_owing() recompute would not contain it at all.',
      coalesce(v_outcome::text, '<no row at all>'));
  end if;

  select count(*) into v_count from public.settlement_commitment
   where settlement_id = v_correction;
  if v_count <> 2 then
    raise exception using message = format(
      'Account P''s correction froze %s outcome(s), expected 2 -- the archived commitment and '
      'the one that is still live.', v_count);
  end if;

  raise notice using message =
    'Step 12 ok: a commitment archived before the day it names still takes its objection, on the '
    'outcome frozen that day, and the whole day is still frozen alongside it.';

  -- -------------------------------------------------------------------------------
  -- 13. Who may read and write the objection table at all. A catalog assertion in the shape
  --     `2-5-settlement.sql` step 8 already uses, because the failure mode is a future migration
  --     adding a policy in good faith -- and every comment in this feature leans on there being
  --     exactly one writer.
  -- -------------------------------------------------------------------------------
  select count(*) into v_count
    from pg_policies
   where schemaname = 'public' and tablename = 'objection' and cmd <> 'SELECT';
  if v_count <> 0 then
    raise exception using message = format(
      '%s write policies exist on public.objection. object_to_day() is the only writer by '
      'design: a client that could insert one could decide its own day, and one that could '
      'update one could rewrite what the referee said.', v_count);
  end if;

  select count(*) into v_count
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'objection' and not c.relrowsecurity;
  if v_count <> 0 then
    raise exception using message =
      'Row-level security is disabled on public.objection.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select count(*) into v_count from public.objection;
  if v_count <> 1 then
    raise exception using message = format(
      'Account B reads %s objection row(s), expected exactly 1 -- his own day, and no other '
      'account''s.', v_count);
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select count(*) into v_count from public.objection;

  perform set_config('role', 'postgres', true);

  if v_count <> 0 then
    raise exception using message = format(
      'The referee reads %s objection row(s) directly off the table, expected 0 -- a policy '
      'granting him that would hand him every account''s objection history, which is the feed '
      'this story exists not to build.', v_count);
  end if;

  raise notice using message =
    'Step 13 ok: public.objection has RLS on and no write policy for anyone; the author reads '
    'the objection against his own day and no other; the referee reads none of the table at all.';

  raise notice using message =
    'PASS. With no referee action every proven day holds and nothing runs. An objection inside '
    'the window supersedes the day with a freeze of the whole day taken from its own frozen '
    'rows, forces the objected commitment to missed, charges the day exactly once whatever it '
    'already owed, records who said it and why, notifies the author with a sendable body '
    'carrying no free text, and breaks one chain while leaving every other alone. It lands as a '
    'failed day with an owed penalty or it does not land: an expired day, a commitment carrying '
    'no penalty, a Weekly Quota, a waived penalty and one held under an open appeal are all '
    'refused. So are a closed window, a second objection, a day corrected since it was read, a '
    'collected penalty, an outcome that is not held, a commitment that was not there, a blank '
    'reason and an over-long one. A doer cannot call it, the referee cannot reach an account he '
    'is not paired to, archiving cannot defeat it, and a Grace Day voids what it charged.';
end $$;

rollback;
