-- Story 4.3 — when money rides on it, the machine's word stands (FR-2a precedence).
--
-- `file_auto_check_result`'s new `missed` branch (20260824110000) is what turns FR-2a's
-- precedence rule into a structural fact rather than a hope: filing a `slipped`
-- declaration on a Penalty-carrying commitment relies entirely on `declaration`'s own
-- pre-existing per-day uniqueness (`declaration_one_per_commitment_day`, 20260819200000)
-- to make that filed row uncorrectable afterwards. This file proves both halves —
-- `missed` files (or doesn't) exactly as FR-2a requires, and once it has filed, a second
-- insert attempt for that same day — simulating the author's own contradicting tap — is
-- refused by the database itself, not merely discouraged by application code.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/4-3-the-machines-word-stands.sql
--
-- One transaction, rolled back at the end. Nothing persists.

begin;

do $$
declare
  v_user       uuid := gen_random_uuid();
  v_penalty    uuid; -- carries_penalty = true, linked, undeclared
  v_no_penalty uuid; -- carries_penalty = false, linked, undeclared
  v_already    uuid; -- carries_penalty = true, but already declared for the day

  v_yesterday  date;
  v_count      integer;
  v_answer     public.declaration_answer;
  v_for_day    date;
  v_refused    boolean;
  v_sqlstate   text;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-4-3-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  v_yesterday := ((now() at time zone 'Asia/Ho_Chi_Minh')::date - 1);

  -- -------------------------------------------------------------------------------
  -- 1. missed, Penalty-carrying: files declaration(answer='slipped').
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_user, gen_random_uuid(), 'TryHackMe', 'do', 'daily', true,
          'account_elsewhere', 'handle-penalty', v_yesterday - 1)
  returning id into v_penalty;

  perform public.file_auto_check_result(v_penalty, v_user, 'missed');

  select answer, for_day into v_answer, v_for_day
    from public.declaration where commitment_id = v_penalty and for_day = v_yesterday;

  if v_answer is distinct from 'slipped' then
    raise exception using message =
      'file_auto_check_result(missed) on a Penalty-carrying commitment did not file '
      'declaration(answer=slipped). FR-2a: a machine miss on money must become the '
      'authoritative record.';
  end if;

  if v_for_day <> v_yesterday then
    raise exception using message = format(
      'The filed declaration''s for_day is %s, expected %s.', v_for_day, v_yesterday);
  end if;

  -- Already-declared day (this same call, retried): on conflict do nothing, unchanged.
  perform public.file_auto_check_result(v_penalty, v_user, 'missed');

  select count(*) into v_count
    from public.declaration where commitment_id = v_penalty and for_day = v_yesterday;
  if v_count <> 1 then
    raise exception using message = format(
      'A second file_auto_check_result(missed) call for an already-declared day produced '
      '%s rows, expected exactly 1.', v_count);
  end if;

  select count(*) into v_count from public.outbox where owner_id = v_user;
  if v_count <> 0 then
    raise exception using message = format(
      'file_auto_check_result(missed) enqueued %s outbox row(s). Machine confirmation is '
      'silent (UX-DR29) even when what it confirms is a miss.', v_count);
  end if;

  raise notice using message =
    'Step 1 ok: missed on a Penalty-carrying commitment files declaration(answer=slipped), '
    'a repeat is a no-op, and no outbox row is enqueued.';

  -- -------------------------------------------------------------------------------
  -- 2. missed, no Penalty: files nothing. The author's own Declaration is what settles
  --    the day, with no other involvement (AC2) — Story 4.1's own fall-through already
  --    produces this; asserted here as a test, per the spec's own change log.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_user, gen_random_uuid(), 'Side project', 'do', 'daily', false,
          'account_elsewhere', 'handle-no-penalty', v_yesterday - 1)
  returning id into v_no_penalty;

  perform public.file_auto_check_result(v_no_penalty, v_user, 'missed');

  select count(*) into v_count
    from public.declaration where commitment_id = v_no_penalty and for_day = v_yesterday;
  if v_count <> 0 then
    raise exception using message = format(
      'file_auto_check_result(missed) filed %s row(s) for a commitment carrying no '
      'Penalty. With no Penalty, a machine miss must never be filed — only the author''s '
      'own Declaration settles the day.', v_count);
  end if;

  raise notice using message =
    'Step 2 ok: missed on a commitment with no Penalty files nothing.';

  -- -------------------------------------------------------------------------------
  -- 3. Once the machine has filed, a second insert for the same day — simulating the
  --    author's own contradicting tap, a different idempotency_key, exactly what
  --    morning-gate.tsx sends — is refused by the database itself: the unique constraint
  --    this whole story leans on, exercised directly rather than only through the filer.
  -- -------------------------------------------------------------------------------
  v_refused := false;
  begin
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_user, v_penalty, gen_random_uuid(), 'held',
            (v_yesterday + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');
  exception when unique_violation then
    v_refused := true;
    get stacked diagnostics v_sqlstate = returned_sqlstate;
  end;

  if not v_refused then
    raise exception using message =
      'A human declare attempt for a day the machine already filed (missed, Penalty-'
      'carrying) was accepted rather than refused. FR-2a: a filed machine result on money '
      'must be structurally uncorrectable, not merely discouraged.';
  end if;

  if v_sqlstate <> '23505' then
    raise exception using message = format(
      'The refusal carried SQLSTATE %s, expected 23505 (unique_violation) — '
      'classifyConflict on the client depends on exactly this code to tell a genuine '
      'conflict apart from an unrelated rejection.', v_sqlstate);
  end if;

  select count(*) into v_count
    from public.declaration where commitment_id = v_penalty and for_day = v_yesterday;
  if v_count <> 1 then
    raise exception using message = format(
      'The refused human attempt still changed row count to %s, expected 1 — the machine''s '
      'own row must be the one and only record of that day.', v_count);
  end if;

  select answer into v_answer
    from public.declaration where commitment_id = v_penalty and for_day = v_yesterday;
  if v_answer is distinct from 'slipped' then
    raise exception using message =
      'The machine''s filed answer changed after the refused human attempt. It must stand '
      'exactly as filed.';
  end if;

  raise notice using message =
    'Step 3 ok: once the machine has filed missed->slipped on a Penalty-carrying '
    'commitment, a second insert for that same day (a different idempotency_key, the '
    'author''s own contradicting tap) is refused with 23505, and the machine''s row is '
    'the one that stands.';

  -- -------------------------------------------------------------------------------
  -- 4. The same refusal on the no-Penalty commitment's day would be a real bug (nothing
  --    was ever filed to conflict with) -- confirm the author's own declaration is
  --    accepted there, the mirror image of Step 3.
  -- -------------------------------------------------------------------------------
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_no_penalty, gen_random_uuid(), 'slipped',
          (v_yesterday + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  select answer into v_answer
    from public.declaration where commitment_id = v_no_penalty and for_day = v_yesterday;
  if v_answer is distinct from 'slipped' then
    raise exception using message =
      'The author''s own declaration for a no-Penalty commitment was not accepted, though '
      'nothing was ever filed by the machine to conflict with it.';
  end if;

  raise notice using message =
    'Step 4 ok: with nothing filed by the machine (no Penalty), the author''s own '
    'declaration is accepted normally.';

  -- -------------------------------------------------------------------------------
  -- 5. A distinct, already-declared commitment: file_auto_check_result(missed) does not
  --    overwrite an existing human answer that beat it to the day.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, auto_check_kind, auto_check_account_ref,
                                 created_at)
  values (v_user, gen_random_uuid(), 'Already declared first', 'do', 'daily', true,
          'account_elsewhere', 'handle-already', v_yesterday - 1)
  returning id into v_already;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_user, v_already, gen_random_uuid(), 'held',
          (v_yesterday + 1 + time '07:00') at time zone 'Asia/Ho_Chi_Minh');

  perform public.file_auto_check_result(v_already, v_user, 'missed');

  select answer, count(*) over () into v_answer, v_count
    from public.declaration where commitment_id = v_already and for_day = v_yesterday;
  if v_answer is distinct from 'held' or v_count <> 1 then
    raise exception using message =
      'file_auto_check_result(missed) overwrote or duplicated a human answer that had '
      'already been filed for the day. on conflict do nothing must leave it untouched.';
  end if;

  raise notice using message =
    'Step 5 ok: missed on a Penalty-carrying commitment already declared by the author '
    'leaves that declaration untouched.';

  raise notice using message =
    'PASS. missed files declaration(answer=slipped) on a Penalty-carrying commitment and '
    'nothing on one carrying no Penalty; once filed, a contradicting human insert for the '
    'same day is refused with 23505 rather than silently accepted; and an existing human '
    'answer is never overwritten by a later missed result.';
end $$;

rollback;
