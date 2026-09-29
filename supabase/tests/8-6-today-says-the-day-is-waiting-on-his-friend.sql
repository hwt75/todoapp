-- Story 8.6 — Today says the day is waiting on his friend.
--
-- `waiting_on_my_referee()` names the author's commitments that are waiting on his referee today,
-- and it names **exactly the rows his referee's list names** -- because both read one definition,
-- `commitment_days_waiting_on_referee()`. That equality is the acceptance criterion this file is
-- built around; every other assertion is a row of the matrix.
--
-- What is proved, in order:
--
--   0.  The ACLs: the author's read is executable by `authenticated` and not `anon`; the definition
--       by neither. Both security definer with search_path pinned empty.
--   1.  The author reads exactly the waiting rows -- both parentages, and the flag switched off
--       this morning -- each stamped with today, and none of: no photo, approved, refused,
--       unflagged, switched on this morning, archived, yesterday's photo, another doer's day.
--   2.  His referee's list names the same commitments; the referee asking the author's read gets
--       nothing of anyone's.
--   3.  Nobody to wait on, two ways: the pairing row's role moved off `referee`, and the pairing
--       revoked. In both the author reads nothing -- and so does the referee's side.

begin;

-- CI's database has the storage schema and not the bucket row -- README.md.
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;

-- =================================================================================
-- Step 0: the doors.
-- =================================================================================
do $$
declare
  f        text;
  v_config text[];
begin
  if not has_function_privilege('authenticated', 'public.waiting_on_my_referee()', 'execute')
     or has_function_privilege('anon', 'public.waiting_on_my_referee()', 'execute') then
    raise exception
      'waiting_on_my_referee() must be executable by `authenticated` and not by `anon`: it is the '
      'author''s own Today, and a signed-out caller has no account for it to answer about.';
  end if;

  foreach f in array array['anon', 'authenticated'] loop
    if has_function_privilege(f,
         'public.commitment_days_waiting_on_referee(uuid, date)', 'execute') then
      raise exception using message = format(
        '`%s` can EXECUTE commitment_days_waiting_on_referee(uuid, date). It takes an owner as an '
        'argument, so a client could ask it about any account.', f);
    end if;
  end loop;

  foreach f in array array[
    'public.waiting_on_my_referee()',
    'public.commitment_days_waiting_on_referee(uuid, date)'
  ]
  loop
    select p.proconfig into v_config from pg_proc p where p.oid = f::regprocedure;
    if v_config is null
       or not exists (select 1 from unnest(v_config) as c
                       where c like 'search_path=%' and btrim(split_part(c, '=', 2), '"') = '')
       or not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception '`%` must be security definer with search_path pinned empty.', f;
    end if;
  end loop;

  raise notice using message =
    'Step 0 ok: the author''s read is granted to `authenticated` and withheld from `anon`; the '
    'definition is withheld from both; both are security definer with an empty search_path.';
end $$;


do $$
declare
  v_doer    uuid := gen_random_uuid();
  v_ref     uuid := gen_random_uuid();
  v_today   date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  -- Waiting.
  v_day      uuid;  -- untimed, kept photo
  v_claim    uuid;  -- timed, claim-parented photo
  v_off      uuid;  -- flagged when today began, switched off since
  -- Not waiting.
  v_bare     uuid;  -- flagged, no photo
  v_ok       uuid;  -- approved
  v_no       uuid;  -- refused
  v_plain    uuid;  -- never flagged, photo kept
  v_on       uuid;  -- unflagged when today began, switched on since
  v_archived uuid;  -- archived
  v_old      uuid;  -- flagged, photo on yesterday only
  v_theirs   uuid := gen_random_uuid();  -- another doer
  v_ref2     uuid := gen_random_uuid();  -- his referee
  v_t_day    uuid;  -- his flagged, photographed day

  v_decl  uuid;
  v_id    uuid;
  v_got   uuid[];
  v_want  uuid[];
  v_ref_s uuid[];
  v_days  date[];
begin
  foreach v_id in array array[v_doer, v_ref, v_theirs, v_ref2] loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'waiting-on-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  update public.profile set role = 'referee', referee_of = v_doer where id = v_ref;
  update public.profile set role = 'referee', referee_of = v_theirs where id = v_ref2;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Day', 'do', 'daily', true, true, true) returning id into v_day;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_doer, gen_random_uuid(), 'Claim', 'do', 'daily', true, true, true, time '10:00', 30)
  returning id into v_claim;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Off', 'do', 'daily', true, true, true) returning id into v_off;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Bare', 'do', 'daily', true, true, true) returning id into v_bare;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Ok', 'do', 'daily', true, true, true) returning id into v_ok;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'No', 'do', 'daily', true, true, true) returning id into v_no;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Plain', 'do', 'daily', true, true, false)
  returning id into v_plain;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'On', 'do', 'daily', true, true, false) returning id into v_on;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Archived', 'do', 'daily', true, true, true)
  returning id into v_archived;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Old', 'do', 'daily', true, true, true) returning id into v_old;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_theirs, gen_random_uuid(), 'Day', 'do', 'daily', true, true, true)
  returning id into v_t_day;

  -- The two switch cases need the reader's day-start branch: made to predate today, their log
  -- entries with them, then moved (`8-3-...sql:320-330` says why the order matters).
  update public.commitment set created_at = now() - interval '90 days'
   where id in (v_off, v_on, v_old);
  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_today) - interval '10 days'
   where commitment_id in (v_off, v_on, v_old);
  update public.commitment set requires_referee_approval = false where id = v_off;
  update public.commitment set requires_referee_approval = true  where id = v_on;

  -- Kept photos on every untimed row but v_bare.
  foreach v_id in array array[v_day, v_off, v_ok, v_no, v_plain, v_on, v_archived, v_old] loop
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_id::text || '/' || v_today::text || '.jpg', v_doer);
    insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
    values (v_id, v_today, v_id::text || '/' || v_today::text || '.jpg', v_today);
  end loop;

  -- Yesterday's photograph: filed today and moved back, because evidence_derive_owner() refuses a
  -- commitment-day row for any day but today and fires on insert only (`8-4-...sql`'s idiom).
  update public.evidence set for_day = v_today - 1 where commitment_id = v_old;

  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_t_day::text || '/' || v_today::text || '.jpg', v_theirs);
  insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
  values (v_t_day, v_today, v_t_day::text || '/' || v_today::text || '.jpg', v_today);

  -- The claim-parented proof (`8-3-...sql:380-384`'s idiom).
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_doer, v_claim, gen_random_uuid(), 'held',
          ((v_today + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_decl;
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_decl::text || '/proof.jpg', v_doer);
  insert into public.evidence (declaration_id, storage_path, captured_on)
  values (v_decl, v_decl::text || '/proof.jpg', v_today);

  update public.commitment set archived_at = now() where id = v_archived;

  -- The two decisions, through sign_off_day() as the referee.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ref, 'role', 'authenticated', 'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.sign_off_day(v_ok, v_today, true, null);
  perform public.sign_off_day(v_no, v_today, false, 'Not today''s.');

  -- The referee's list, while we are him.
  select array_agg(w.commitment_id order by w.commitment_id) into v_ref_s
    from public.referee_waiting_today() w;

  -- And the author's read, asked by the referee: a referee owns no flagged commitments, and this
  -- read is about the caller's own account, so he gets nothing -- of his doer's or anyone's.
  if exists (select 1 from public.waiting_on_my_referee()) then
    raise exception 'A referee session read rows from waiting_on_my_referee(). It answers only '
                    'about the caller''s own account.';
  end if;

  -- =================================================================================
  -- Step 1: the author.
  -- =================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_doer, 'role', 'authenticated')::text, true);

  select array_agg(w.commitment_id order by w.commitment_id), array_agg(distinct w.for_day)
    into v_got, v_days
    from public.waiting_on_my_referee() w;
  select array_agg(x order by x) into v_want from unnest(array[v_day, v_claim, v_off]) x;

  if v_got is distinct from v_want then
    raise exception using message = format(
      'The author read %s as waiting, wanted exactly %s. Not waiting by design: no photo %s, '
      'approved %s, refused %s, unflagged %s, switched on today %s, archived %s, yesterday''s '
      'photo %s, another doer''s %s.',
      v_got, v_want, v_bare, v_ok, v_no, v_plain, v_on, v_archived, v_old, v_t_day);
  end if;

  -- Stamped with the server's day. Today discards an answer for any other, so this is what
  -- keeps yesterday's rows off a screen left open across midnight.
  if v_days is distinct from array[v_today] then
    raise exception 'The author''s read was stamped %, wanted today (%).', v_days, v_today;
  end if;

  raise notice using message =
    'Step 1 ok: the author reads exactly the three waiting rows -- a kept photo, a claim''s photo, '
    'and a flag switched off this morning -- stamped with today, and nothing photo-less, decided, '
    'unflagged, flagged since this morning, archived, yesterday''s or another doer''s.';

  -- =================================================================================
  -- Step 2: the same set as his referee's list.
  -- =================================================================================
  if v_got is distinct from v_ref_s then
    raise exception using message = format(
      'The author is told %s is waiting; his referee is shown %s. One definition should make '
      'these the same set.', v_got, v_ref_s);
  end if;

  raise notice using message =
    'Step 2 ok: the author and his referee name the same commitments, and the referee asking the '
    'author''s read gets nothing.';

  -- =================================================================================
  -- Step 3: nobody to wait on.
  -- =================================================================================

  -- (a) The pairing row's role moved off `referee`. The referee's side admits nobody --
  -- role_from_table() is what it asks -- so the author's side must say nothing either, or the two
  -- disagree about the same account.
  perform set_config('role', 'postgres', true);
  update public.profile set role = 'doer' where id = v_ref;
  perform set_config('role', 'authenticated', true);

  if exists (select 1 from public.waiting_on_my_referee()) then
    raise exception 'With the pairing row no longer a referee, the author was still told his '
                    'referee has not looked -- while the referee''s side lists nothing.';
  end if;

  -- (b) The pairing revoked outright.
  perform set_config('role', 'postgres', true);
  update public.profile set role = 'referee', referee_of = null where id = v_ref;
  perform set_config('role', 'authenticated', true);

  if exists (select 1 from public.waiting_on_my_referee()) then
    raise exception 'With no referee paired the author was still told something is waiting.';
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 3 ok: with the pairing row''s role moved, and with the pairing revoked, the author reads '
    'nothing -- a flagged day auto-approves and is waiting on nobody.';
  raise notice using message =
    'PASS. The author is told his referee has not looked exactly where his referee has not.';
end $$;

rollback;
