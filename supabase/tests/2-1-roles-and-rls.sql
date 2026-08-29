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
                   public.settlement, public.settlement_commitment,
                   public.appeal, public.evidence
  to authenticated;

-- Steps 5c/5d are the first things in this file that need a genuinely *successful* client
-- insert rather than only a refused one -- every earlier step either inserts as postgres
-- and only reads back as authenticated, or expects the insert itself to fail either way.
-- On the author's own project `authenticated` already carries INSERT from Supabase's own
-- platform defaults; this fixture grants it explicitly for the same reason it grants
-- SELECT above -- to give `appeal: file own`'s policy, and `declaration_derive_day()`'s
-- own `filed_by` guard (5d), something real to be tested through, never widened beyond
-- the tables this file's own steps need it for.
grant insert on table public.appeal, public.evidence, public.declaration to authenticated;

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

  -- -------------------------------------------------------------------------------
  -- 5b. `declaration: read own` covers a machine-filed row exactly like a human-typed
  --     one — nothing distinguishes them at the RLS layer, which is exactly the layer
  --     `morning-gate.tsx`'s FR-2a conflict check (Story 4.3) depends on to read back
  --     whichever row won a 23505 race. Filed here via file_auto_check_result() itself
  --     (not a hand-built insert), so this proves the same path the app actually takes.
  -- -------------------------------------------------------------------------------
  declare
    v_c uuid;
    v_key uuid;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   carries_penalty, auto_check_kind, auto_check_account_ref)
    values (v_a, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
            'account_elsewhere', 'handle-rls')
    returning id into v_c;

    perform public.file_auto_check_result(v_c, v_a, 'missed');

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a, 'role', 'authenticated', 'app_role', 'doer')::text, true);

    select idempotency_key into v_key from public.declaration where commitment_id = v_c;

    if v_key is null then
      perform set_config('role', 'postgres', true);
      raise exception using message =
        'The owning account could not read back a machine-filed declaration through '
        '`declaration: read own` -- the exact read morning-gate.tsx''s conflict check '
        '(Story 4.3) depends on to tell its own retry from someone else''s row.';
    end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_b, 'role', 'authenticated', 'app_role', 'doer')::text, true);

    select count(*) into v_count from public.declaration where commitment_id = v_c;
    perform set_config('role', 'postgres', true);

    if v_count <> 0 then
      raise exception using message = format(
        'A different account read %s row(s) of another account''s declaration -- '
        '`declaration: read own` leaked a machine-filed row across accounts.', v_count);
    end if;
  end;

  raise notice using message =
    'Step 5b ok: the owning account reads a machine-filed declaration through '
    '`declaration: read own` exactly like its own; a different account sees nothing.';

  -- -------------------------------------------------------------------------------
  -- 5c. `appeal`/`evidence` (Story 4.4): read-own and file-own RLS, and a
  --     cross-account attempt at either is refused. Filed against the exact machine-
  --     filed miss 5b just proved is readable -- settled here for the first time in
  --     this file, so `appeal_hold_penalty()`'s own eligibility join has something
  --     real to find.
  -- -------------------------------------------------------------------------------
  declare
    v_c        uuid; -- 5b's own scope ended at its `end;` above; re-fetched rather than shared.
    v_no_fap   uuid; -- step 4's own commitment for v_a, still undeclared until now.
    v_day      date;
    v_appeal   uuid;
    v_evidence uuid;
  begin
    perform set_config('role', 'postgres', true);
    select id into v_c from public.commitment where owner_id = v_a and name = 'TryHackMe';
    select id into v_no_fap from public.commitment where owner_id = v_a and name = 'No fap';
    v_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;

    -- Step 4 left "No fap" undeclared for v_a. settle_day refuses to close a day any of
    -- its commitments are still silent on, deadline or not (FR-10) -- so it has to be
    -- answered here too, or the day this step needs settled never closes.
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_a, v_no_fap, gen_random_uuid(), 'held', now());

    -- Story 6.4: commitments_owing() no longer judges a commitment for a day before it existed.
    -- This fixture creates its commitments moments before judging days that predate them, which is
    -- a state no real account can reach — so it now says when they began. Order-preserving, so
    -- every created_at comparison downstream reads the same way, and idempotent, so a second call
    -- further down this file does not age them twice.
    update public.commitment set created_at = created_at - interval '90 days'
     where created_at > now() - interval '30 days';

    perform public.settle_day(v_day, true);

    -- v_a: the owning account files the appeal on its own eligible miss.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a, 'role', 'authenticated', 'app_role', 'doer')::text, true);

    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
    values (v_a, v_c, gen_random_uuid(), v_day)
    returning id into v_appeal;

    select count(*) into v_count from public.appeal where id = v_appeal;
    if v_count <> 1 then
      perform set_config('role', 'postgres', true);
      raise exception using message =
        '`appeal: read own` did not let the owning account read back its own appeal.';
    end if;

    insert into public.evidence (appeal_id, storage_path, captured_on)
    values (v_appeal, v_appeal::text || '/one.jpg', v_day)
    returning id into v_evidence;

    select count(*) into v_count from public.evidence where id = v_evidence;
    if v_count <> 1 then
      perform set_config('role', 'postgres', true);
      raise exception using message =
        '`evidence: read own` did not let the owning account read back its own evidence.';
    end if;

    -- v_b: a different account reads neither row.
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_b, 'role', 'authenticated', 'app_role', 'doer')::text, true);

    select count(*) into v_count from public.appeal where id = v_appeal;
    if v_count <> 0 then
      perform set_config('role', 'postgres', true);
      raise exception using message = format(
        'A different account read %s row(s) of another account''s appeal.', v_count);
    end if;

    select count(*) into v_count from public.evidence where id = v_evidence;
    if v_count <> 0 then
      perform set_config('role', 'postgres', true);
      raise exception using message = format(
        'A different account read %s row(s) of another account''s evidence -- NFR4 '
        'requires evidence visible only to the submitting account (and, once Story 4.5/4.6 '
        'exist, the ruling referee).', v_count);
    end if;

    -- v_b cannot attach evidence to v_a's appeal either: `evidence_derive_owner()`
    -- overwrites owner_id with the appeal's own (v_a), so v_b's `with check
    -- (auth.uid() = owner_id)` fails even though v_b never claimed to be anyone else.
    v_refused := false;
    begin
      -- captured_on = v_day (the appeal's own for_day) so the Epic 4 retrospective's
      -- captured_on guard (2026-08-27, finding A3) never fires here — this step is about
      -- ownership (v_b cannot claim v_a's appeal), not evidence dating.
      insert into public.evidence (appeal_id, storage_path, captured_on)
      values (v_appeal, v_appeal::text || '/planted.jpg', v_day);
    exception when others then
      v_refused := true;
    end;

    if not v_refused then
      perform set_config('role', 'postgres', true);
      raise exception using message =
        'A different account inserted evidence against another account''s appeal -- '
        'NFR4''s owner-derivation should have refused it.';
    end if;

    -- v_b cannot appeal v_a's own commitment either -- refused by
    -- `appeal_hold_penalty()`'s own ownership check (mirroring `focus_session_derive_day`),
    -- the same defence-in-depth step 5b already exercises for `declaration`.
    v_refused := false;
    begin
      insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day)
      values (v_b, v_c, gen_random_uuid(), v_day - 1);
    exception when others then
      v_refused := true;
    end;

    perform set_config('role', 'postgres', true);

    if not v_refused then
      raise exception using message =
        'A session authenticated as one account inserted an appeal against another '
        'account''s commitment -- appeal_hold_penalty()''s ownership check is the only '
        'thing standing between two accounts here.';
    end if;
  end;

  raise notice using message =
    'Step 5c ok: appeal/evidence are readable and writable only by their own '
    'account -- a different account reads neither and cannot write into either.';

  -- -------------------------------------------------------------------------------
  -- 5d. `declaration.filed_by` cannot be forged by a client insert (Story 4.4). The
  --     table's own INSERT grant to `authenticated` is table-wide, not scoped to a
  --     column allowlist the way `profile.morning_hour`'s own grant already is -- a
  --     `default` alone would not have stopped a client from sending
  --     `filed_by: 'auto_check'` explicitly and appealing (then out-waiting the
  --     timeout on) a Penalty for a miss he genuinely admitted to himself. This is
  --     exactly the exploit `declaration_derive_day()`'s own `current_user in
  --     ('anon', 'authenticated')` guard (20260824120000) exists to close.
  -- -------------------------------------------------------------------------------
  declare
    v_forge_c uuid;
    v_filed   public.declaration_filed_by;
  begin
    perform set_config('role', 'postgres', true);
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
    values (v_a, gen_random_uuid(), 'Forged filed_by target', 'do', 'daily', true)
    returning id into v_forge_c;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a, 'role', 'authenticated', 'app_role', 'doer')::text, true);

    -- A hostile-but-otherwise-legitimate insert: v_a's own account, v_a's own commitment,
    -- an honest-looking `slipped` answer -- except this client explicitly claims the
    -- machine wrote it, which nothing about this insert makes true.
    insert into public.declaration
      (owner_id, commitment_id, idempotency_key, answer, answered_at, filed_by)
    values
      (v_a, v_forge_c, gen_random_uuid(), 'slipped', now(), 'auto_check');

    select filed_by into v_filed
      from public.declaration where commitment_id = v_forge_c;

    perform set_config('role', 'postgres', true);

    if v_filed is distinct from 'doer' then
      raise exception using message = format(
        'A client insert that explicitly sent filed_by=''auto_check'' produced a row '
        'reading `%s`. declaration_derive_day() must force every client-originated row '
        'back to ''doer'' regardless of what the client sent -- otherwise any account can '
        'self-declare a slip, appeal it, and let Story 4.4''s timeout drop a Penalty that '
        'was never actually the machine''s call.', v_filed);
    end if;
  end;

  raise notice using message =
    'Step 5d ok: a client insert cannot forge declaration.filed_by -- an explicit '
    '''auto_check'' claim from an authenticated session is forced back to ''doer''.';
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
    'public.settle_week(date, boolean)',
    'public.settle_due_weeks()',
    'public.week_summary_body(integer, integer, date, bigint, integer, text)',
    'public.supersede_expiries()',
    'public.commitments_owing(uuid, date)',
    'public.declaration_deadline(date, integer)',
    'public.commitment_deadline(date, integer, time)',
    'public.day_begins_at(date)',
    'public.day_ends_at(date)',
    'public.commitment_log_due_time_change()',
    'public.penalty_amount_dong()',
    'public.handle_new_user()',
    'public.outbox_enqueue(uuid, text, jsonb, public.outbox_channel)',
    'public.enqueue_gate_reminders()',
    'public.resolve_account_elsewhere(uuid)',
    'public.file_auto_check_result(uuid, uuid, public.auto_check_result)',
    'public.resolve_auto_checks()',
    'public.auto_check_pending(uuid, date)',
    'public.appeal_hold_penalty()',
    'public.appeal_deadline(timestamptz)',
    'public.evidence_derive_owner()',
    'public.void_expired_appeals()'
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
    'Step 6 ok: twenty-four deciding functions and the outbox are all out of reach of anon '
    'and authenticated.';
  raise notice using message =
    'PASS. A role is chosen server-side, cannot be raised from a session, and does not leak '
    'across accounts.';
end $$;

rollback;
