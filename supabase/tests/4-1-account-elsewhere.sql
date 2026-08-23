-- Story 4.1 — an Account-elsewhere Auto-check is attached, not read.
--
-- FR-8 was resolved NEGATIVE for the one concrete service considered (TryHackMe, Story
-- 1.3): its completion history is not readable from outside. So what is tested here is the
-- generic attach/resolve/file mechanism, not a real integration — `resolve_account_elsewhere`
-- has no live data source and always reads `unavailable`, which is asserted directly rather
-- than worked around.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -v ON_ERROR_STOP=1 < supabase/tests/4-1-account-elsewhere.sql
--
-- One transaction, rolled back at the end. Nothing persists.

begin;

do $$
declare
  v_user      uuid := gen_random_uuid();
  v_linked      uuid; -- account_elsewhere attached, cadence daily, kind 'do'
  v_undeclared  uuid; -- linked, undeclared — resolve_auto_checks() must actually resolve this one
  v_unlinked    uuid; -- no Auto-check at all — resolve_auto_checks() must never touch it

  v_key       uuid := gen_random_uuid();
  v_yesterday date;
  v_case      text;
  v_refused   boolean;
  v_count     integer;
  v_answer    public.declaration_answer;
  v_for_day   date;
  v_checked_1 timestamptz;
  v_checked_2 timestamptz;
  v_kind      public.auto_check_kind;
  v_ref       text;
  v_result    public.auto_check_result;
  v_processed integer;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-4-1-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  v_yesterday := ((now() at time zone 'Asia/Ho_Chi_Minh')::date - 1);

  -- -------------------------------------------------------------------------------
  -- 1. A half-linked or wrongly-linked Auto-check is refused by constraints.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'kind with no ref',
    'ref with no kind',
    'last_checked with no kind',
    'blank ref',
    'whitespace-only ref',
    'attached to an abstention'
  ]
  loop
    v_refused := false;
    begin
      insert into public.commitment (
        owner_id, idempotency_key, name, kind, cadence,
        auto_check_kind, auto_check_account_ref, auto_check_last_checked_at
      )
      values (
        v_user, gen_random_uuid(), 'Gym',
        case v_case when 'attached to an abstention' then 'abstain' else 'do' end::public.commitment_kind,
        'daily',
        case v_case
          when 'ref with no kind' then null
          when 'last_checked with no kind' then null
          else 'account_elsewhere'
        end::public.auto_check_kind,
        case v_case
          when 'kind with no ref' then null
          when 'last_checked with no kind' then null
          when 'blank ref' then ''
          when 'whitespace-only ref' then '   '
          else 'my-handle'
        end,
        case v_case
          when 'last_checked with no kind' then now()
        end
      );
    exception when check_violation then
      v_refused := true;
    end;

    if not v_refused then
      raise exception using message = format(
        'The database accepted a commitment described as "%s". An Auto-check attach is '
        'either fully filled in or absent — never half of one.', v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 1 ok: six malformed Auto-check attaches were all refused by constraints.';

  -- -------------------------------------------------------------------------------
  -- 2. Link, then unlink, round trip.
  -- -------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref)
  values (v_user, v_key, 'TryHackMe', 'do', 'daily', 'account_elsewhere', 'my-handle')
  returning id into v_linked;

  select auto_check_kind, auto_check_account_ref, auto_check_last_checked_at
    into v_kind, v_ref, v_checked_1
    from public.commitment where id = v_linked;

  if v_kind is distinct from 'account_elsewhere' or v_ref is distinct from 'my-handle' then
    raise exception using message =
      'A freshly linked commitment does not read auto_check_kind/auto_check_account_ref back '
      'as saved.';
  end if;

  if v_checked_1 is not null then
    raise exception using message =
      'A freshly linked commitment already carries a last-checked timestamp. It must start '
      'null: no fetch happens at link time.';
  end if;

  update public.commitment
     set auto_check_kind = null, auto_check_account_ref = null, auto_check_last_checked_at = null
   where id = v_linked;

  select count(*) into v_count
    from public.commitment
   where id = v_linked
     and auto_check_kind is null and auto_check_account_ref is null
     and auto_check_last_checked_at is null;
  if v_count <> 1 then
    raise exception using message = 'Unlinking left at least one of the three columns non-null.';
  end if;

  -- Re-link for the rest of the file.
  update public.commitment
     set auto_check_kind = 'account_elsewhere', auto_check_account_ref = 'my-handle'
   where id = v_linked;

  raise notice using message =
    'Step 2 ok: link and unlink round-trip, and unlink clears all three columns.';

  -- -------------------------------------------------------------------------------
  -- 3. resolve_account_elsewhere has no live data source in v1 — always unavailable.
  -- -------------------------------------------------------------------------------
  v_result := public.resolve_account_elsewhere(v_linked);
  if v_result <> 'unavailable' then
    raise exception using message = format(
      'resolve_account_elsewhere returned `%s`. FR-8 was resolved negative for the only '
      'concrete service considered — v1 has no live data source, so it must always read '
      'unavailable.', v_result);
  end if;

  raise notice using message = 'Step 3 ok: resolve_account_elsewhere always reads unavailable.';

  -- -------------------------------------------------------------------------------
  -- 4. file_auto_check_result files on `held` only, and only once per day.
  -- -------------------------------------------------------------------------------
  perform public.file_auto_check_result(v_linked, v_user, 'missed');
  perform public.file_auto_check_result(v_linked, v_user, 'unavailable');
  -- Code review, 2026-08-23: a plain `<>` against a null result reads null, which `if`
  -- treats as false and falls through to the insert — `is distinct from` is what makes a
  -- null result (an unmatched auto_check_kind in the dispatcher's own case, which has no
  -- else) file nothing too, same as missed/unavailable.
  perform public.file_auto_check_result(v_linked, v_user, null);

  select count(*) into v_count
    from public.declaration where commitment_id = v_linked and for_day = v_yesterday;
  if v_count <> 0 then
    raise exception using message = format(
      'file_auto_check_result wrote %s row(s) for a missed/unavailable/null result. FR-8b: '
      'all three must file nothing.', v_count);
  end if;

  perform public.file_auto_check_result(v_linked, v_user, 'held');

  select answer, for_day into v_answer, v_for_day
    from public.declaration where commitment_id = v_linked and for_day = v_yesterday;

  if v_answer is distinct from 'held' then
    raise exception using message =
      'file_auto_check_result(held) did not file a declaration(answer=held) for the '
      'undeclared day.';
  end if;

  if v_for_day <> v_yesterday then
    raise exception using message = format(
      'The filed declaration''s for_day is %s, expected %s (declaration_derive_day reads '
      'answered_at=now() as yesterday, same as every other declaration).',
      v_for_day, v_yesterday);
  end if;

  -- A second `held` call the same day is a no-op, not a second row or an error — the day
  -- is now declared, and the unique constraint plus `on conflict do nothing` is what a
  -- retried or overlapped pass relies on.
  perform public.file_auto_check_result(v_linked, v_user, 'held');

  select count(*) into v_count
    from public.declaration where commitment_id = v_linked and for_day = v_yesterday;
  if v_count <> 1 then
    raise exception using message = format(
      'A second file_auto_check_result(held) call for an already-declared day produced %s '
      'rows, expected exactly 1.', v_count);
  end if;

  select count(*) into v_count from public.outbox where owner_id = v_user;
  if v_count <> 0 then
    raise exception using message = format(
      'file_auto_check_result enqueued %s outbox row(s). Machine confirmation is silent '
      '(UX-DR29) — it must never call outbox_enqueue.', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: file_auto_check_result files exactly one declaration on held, nothing on '
    'missed/unavailable or a repeat, and enqueues no outbox row.';

  -- -------------------------------------------------------------------------------
  -- 5. resolve_auto_checks(): skips an already-declared commitment untouched, and bumps
  --    auto_check_last_checked_at with zero rows filed on an undeclared one (the only
  --    case v1's stub resolver can ever produce).
  -- -------------------------------------------------------------------------------

  -- v_linked is already declared for yesterday (step 4). Give it a second commitment that
  -- is linked but undeclared, on the same account.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 auto_check_kind, auto_check_account_ref)
  values (v_user, gen_random_uuid(), 'Side project', 'do', 'daily',
          'account_elsewhere', 'my-other-handle')
  returning id into v_undeclared;

  -- And a third, not linked at all, to prove the pass never touches an unlinked row.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence)
  values (v_user, gen_random_uuid(), 'Morning exercise', 'do', 'daily')
  returning id into v_unlinked;

  v_processed := public.resolve_auto_checks();

  if v_processed <> 1 then
    raise exception using message = format(
      'resolve_auto_checks() processed %s commitment(s), expected exactly 1 — the '
      'already-declared one must never be queried at all, and the unlinked one is not its '
      'concern.', v_processed);
  end if;

  -- The already-declared commitment: untouched. Never queried, never overwritten.
  select auto_check_last_checked_at into v_checked_1
    from public.commitment where id = v_linked;
  if v_checked_1 is not null then
    raise exception using message =
      'resolve_auto_checks() bumped auto_check_last_checked_at on an already-declared '
      'commitment. It must be skipped before its resolver is ever called.';
  end if;

  select answer into v_answer
    from public.declaration where commitment_id = v_linked and for_day = v_yesterday;
  if v_answer is distinct from 'held' then
    raise exception using message =
      'The already-declared commitment''s declaration changed. resolve_auto_checks() must '
      'never overwrite an existing answer.';
  end if;

  -- The undeclared linked commitment: last_checked_at bumped, but nothing filed (v1's
  -- resolver only ever reads unavailable).
  select auto_check_last_checked_at into v_checked_2
    from public.commitment where id = v_undeclared;
  if v_checked_2 is null then
    raise exception using message =
      'resolve_auto_checks() left auto_check_last_checked_at null on an undeclared linked '
      'commitment. A pass that looked and found nothing is still a pass that looked.';
  end if;

  select count(*) into v_count
    from public.declaration where commitment_id = v_undeclared;
  if v_count <> 0 then
    raise exception using message = format(
      '%s declaration(s) were filed for a commitment whose resolver reads unavailable. '
      'Nothing should ever be filed while v1''s stub resolver is the only one in play.',
      v_count);
  end if;

  -- The unlinked commitment: no Auto-check at all, so the pass has nothing to do with it.
  select auto_check_last_checked_at into v_checked_2
    from public.commitment where id = v_unlinked;
  if v_checked_2 is not null then
    raise exception using message =
      'resolve_auto_checks() stamped auto_check_last_checked_at on a commitment with no '
      'Auto-check attached at all.';
  end if;

  -- AD-5-style: a second pass changes nothing further for either commitment.
  perform public.resolve_auto_checks();

  select count(*) into v_count
    from public.declaration where commitment_id = v_linked and for_day = v_yesterday;
  if v_count <> 1 then
    raise exception using message = 'A second resolve_auto_checks() pass duplicated a filed declaration.';
  end if;

  select count(*) into v_count from public.outbox where owner_id = v_user;
  if v_count <> 0 then
    raise exception using message = format(
      'resolve_auto_checks() enqueued %s outbox row(s) across every pass in this test. '
      'Silent throughout, per UX-DR29.', v_count);
  end if;

  raise notice using message =
    'Step 5 ok: resolve_auto_checks() skips an already-declared commitment untouched, '
    'bumps auto_check_last_checked_at with zero rows filed on an undeclared one, is '
    'idempotent on a second pass, and enqueues no outbox row throughout.';

  raise notice using message =
    'PASS. An Auto-check attach is refused when half-filled or attached to an abstention, '
    'link/unlink round-trips cleanly, file_auto_check_result files on held only, and '
    'resolve_auto_checks() resolves the right set exactly once and stays silent.';
end $$;

rollback;
