-- Story 2.1 — who a session is, and what that lets it touch.
--
-- Two privilege defects shipped in Epic 2 and were closed inside it. Both applied cleanly.
-- Both were found by *trying something*, not by reading:
--
--   `20260819121500_close_function_exposure.sql` — `handle_new_user` was reachable at
--   /rest/v1/rpc/handle_new_user, and it is the function that decides an account's role.
--
--   `20260819201000_close_role_self_promotion.sql` — "a signed-in account promoted itself to
--   `referee` on the first attempt … The Supabase security advisor did not flag it."
--
-- A referee rules on appeals, so an account that can promote itself can rule on its own. That
-- is the mechanism this product sells, and until now nothing re-checked it. Spec 2.9 counted
-- the pattern: **applying is not passing.** This file is the third attempt at the same rules,
-- made by a machine that can run them again.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-1-roles-and-rls.sql
--
-- One transaction, rolled back at the end. It settles nothing, so it is safe against any
-- database — including the author's own project, where it is arguably the most useful.
--
-- **On the two grants this file makes.** `authenticated` needs SELECT on a table before RLS
-- has anything to filter, and on the local stack that grant does not exist: the product
-- inherits it from how the author's project was provisioned, and no migration in this
-- repository creates it (recorded in deferred-work.md). So the fixture grants SELECT — and
-- nothing else — to give the policies something to be tested through. It never grants UPDATE
-- on `profile`, because that grant is the thing the self-promotion defect turned on.

begin;

-- The environment's part, made explicit rather than assumed. Rolled back with everything else.
grant select on table public.profile, public.commitment, public.declaration,
                   public.settlement, public.settlement_commitment
  to authenticated;

do $$
declare
  v_a       uuid := gen_random_uuid();   -- the author
  v_b       uuid := gen_random_uuid();   -- somebody else with an account
  v_role    public.app_role;
  v_token   public.app_role;
  v_count   integer;
  v_refused boolean;
  v_state   text;
begin
  -- -------------------------------------------------------------------------------
  -- 1. A profile exists for every account, created server-side, as a doer.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'retro-2-1-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_a, v_b]) as t(id);

  select role into v_role from public.profile where id = v_a;
  if v_role is distinct from 'doer' then
    raise exception using message = format(
      'A new account''s profile reads `%s`. The trigger creates it server-side precisely '
      'so nothing client-side chooses a role (AD-12).', coalesce(v_role::text, 'no row'));
  end if;

  raise notice using message = 'Step 1 ok: the trigger created a profile, role `doer`.';

  -- -------------------------------------------------------------------------------
  -- 2. The two role functions disagree on purpose, and each is right about its own
  --    question.
  --
  -- `role_from_token` reads a claim stamped at sign-in and is STALE until the token
  -- refreshes; `role_from_table` reads the row and is always current. A revoked referee
  -- must stop being able to write immediately, which is why every `with check` calls the
  -- second. Here the claim says `referee` while the table says `doer` — the exact shape of
  -- a session whose role was changed after it signed in.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);
  perform set_config('role', 'authenticated', true);

  select public.role_from_token(), public.role_from_table() into v_token, v_role;

  perform set_config('role', 'postgres', true);

  if v_token is distinct from 'referee' then
    raise exception using message = format(
      'role_from_token() returned `%s` for a token claiming `referee`.',
      coalesce(v_token::text, 'null'));
  end if;

  if v_role is distinct from 'doer' then
    raise exception using message = format(
      'role_from_table() returned `%s` while the profile row says `doer`. If the table '
      'function can be fooled by a claim, revoking a referee stops biting and the two '
      'functions are one function with two names.', coalesce(v_role::text, 'null'));
  end if;

  raise notice using message =
    'Step 2 ok: the token says `referee`, the table says `doer`, and each function says its own.';

  -- -------------------------------------------------------------------------------
  -- 3. The escalation itself, attempted rather than reasoned about.
  --
  -- This is the defect that shipped. It is attempted the way it succeeded: as a signed-in
  -- session updating its own row — the row the "set own morning hour" policy explicitly
  -- allows it to update.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated', 'app_role', 'doer')::text, true);
  perform set_config('role', 'authenticated', true);

  v_refused := false;
  begin
    update public.profile set role = 'referee' where id = v_a;
  exception when insufficient_privilege then
    v_refused := true;
  end;

  -- The morning hour, through the same policy, must still work — a revoke that took the
  -- column with it would be a silent regression of Story 2.4's configurable gate.
  begin
    update public.profile set morning_hour = 6 where id = v_a;
  exception when others then
    perform set_config('role', 'postgres', true);
    raise exception using message = format(
      'A session could not set its own morning hour: %s. The column grant is what makes '
      'the policy usable at all.', sqlerrm);
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused then
    select role::text into v_state from public.profile where id = v_a;
    raise exception using message = format(
      'A signed-in session promoted itself — the profile now reads `%s`. This is the '
      'defect 20260819201000 closed: a column grant only constrains when no table-wide '
      'UPDATE sits behind it, and an account that can make itself referee can rule on its '
      'own appeals (AD-12).', v_state);
  end if;

  select morning_hour into v_count from public.profile where id = v_a;
  if v_count <> 6 then
    raise exception using message = format(
      'The morning hour reads %s after being set to 6.', v_count);
  end if;

  raise notice using message =
    'Step 3 ok: self-promotion refused, morning hour set — the column grant does both jobs.';

  -- -------------------------------------------------------------------------------
  -- 4. RLS filters rather than refuses, and it filters to one account.
  --
  -- Both accounts own a commitment. A session reads its own and does not learn that the
  -- other exists — zero rows rather than a 403, because a refusal confirms the row is
  -- there.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_a, gen_random_uuid(), 'No fap', 'abstain', 'daily'),
         (v_b, gen_random_uuid(), 'Somebody else''s business', 'do', 'daily');

  perform set_config('role', 'authenticated', true);
  select count(*) into v_count from public.commitment;
  perform set_config('role', 'postgres', true);

  if v_count <> 1 then
    raise exception using message = format(
      'A session sees %s commitments, expected exactly its own 1. Two accounts exist and '
      'one of them is not his.', v_count);
  end if;

  raise notice using message = 'Step 4 ok: a session sees one commitment — its own.';

  -- -------------------------------------------------------------------------------
  -- 5. And it cannot write into somebody else's account.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);

  v_refused := false;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
    values (v_b, gen_random_uuid(), 'Planted', 'do', 'daily');
  exception when insufficient_privilege then
    v_refused := true;
  end;

  perform set_config('role', 'postgres', true);

  if not v_refused then
    raise exception using message =
      'A session inserted a commitment owned by another account. `with check` on the '
      'insert policy is the only thing standing between two accounts.';
  end if;

  raise notice using message = 'Step 5 ok: a cross-account write is refused.';
end $$;

-- ---------------------------------------------------------------------------------
-- 6. Nothing that decides anything is callable from the application.
--
-- Kept out of the block above because it reads catalogs rather than driving a session, and
-- because the list is the point: every function here either decides a day, moves money, or
-- creates the row that carries a role. AD-2 says none of them crosses an HTTP boundary, and
-- an EXECUTE grant is exactly how one would.
-- ---------------------------------------------------------------------------------
do $$
declare
  f text;
  r text;
begin
  foreach f in array array[
    'public.settle_day(date, boolean)',
    'public.settle_due_days()',
    'public.supersede_expiries()',
    'public.commitments_owing(uuid, date)',
    'public.declaration_deadline(date, integer)',
    'public.penalty_amount_dong()',
    'public.handle_new_user()',
    'public.outbox_enqueue(uuid, text, jsonb)',
    'public.enqueue_gate_reminders()'
  ]
  loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception using message = format(
          '`%s` is executable by `%s`, so it is reachable at /rest/v1/rpc/. That is how '
          '`handle_new_user` was exposed in 20260819121500 — and it decides a role.', f, r);
      end if;
    end loop;
  end loop;

  -- The outbox is the other half of the same rule: no client may read or write it at all.
  foreach r in array array['anon', 'authenticated'] loop
    if has_table_privilege(r, 'public.outbox', 'select')
       or has_table_privilege(r, 'public.outbox', 'insert')
       or has_table_privilege(r, 'public.outbox', 'update')
       or has_table_privilege(r, 'public.outbox', 'delete') then
      raise exception using message = format(
        '`%s` can reach public.outbox. Effects are enqueued by settlement and drained by '
        'the worker; a client that could write one could send itself a notification, and '
        'one that could read them knows every account''s schedule.', r);
    end if;
  end loop;

  raise notice using message =
    'Step 6 ok: nine deciding functions and the outbox are all out of reach of anon and authenticated.';
  raise notice using message =
    'PASS. A role is chosen server-side, cannot be raised from a session, and does not leak '
    'across accounts.';
end $$;

rollback;
