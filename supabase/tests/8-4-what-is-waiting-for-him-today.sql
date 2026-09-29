-- Story 8.4 — what is waiting for him today.
--
-- `referee_waiting_today()` names the flagged commitment-days of his paired doer, for today, that
-- have a photograph and no decision -- and nothing else. **Most of what this file asserts is an
-- absence**: every row of the matrix but four is a commitment-day that must *not* come back,
-- because a list that names one day too many is a queue with a history in it.
--
-- What is proved, in order:
--
--   0.  The ACLs. The list is executable by `authenticated` and not by `anon`; the helper that
--       now holds the parentage union is executable by neither. Both `security definer` with
--       `search_path` pinned empty.
--   1.  The referee on the account he is paired to: exactly the four waiting rows, with the day,
--       the facts and the paths each should carry -- and every excluded row absent by name.
--   2.  Everyone else gets nothing, never an error: the author himself, a referee paired to
--       nobody, and a referee paired to a different doer (who sees only his own).
--   3.  One rule, one expression of it: the parentage union is written once, in the helper, and
--       the predicate and the list both reach it.
--
-- `8-3-the-photograph-reaches-the-referee.sql` running **unmodified** is what proves the
-- predicate decides exactly what it did before this story moved its union into the helper.

begin;

-- The bucket is `config.toml` configuration created through the storage API, not by a migration,
-- so CI's database (started with `-x storage-api`) has the schema and not the row. README.md,
-- "A fixture that writes `evidence` also writes its photograph".
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;

-- =================================================================================
-- Step 0: the doors, in both directions.
-- =================================================================================
do $$
declare
  f        text;
  v_config text[];
begin
  if not has_function_privilege('authenticated', 'public.referee_waiting_today()', 'execute') then
    raise exception
      '`authenticated` cannot EXECUTE public.referee_waiting_today(). It is the only read behind '
      'the referee''s waiting list, and without it his home screen fails while every test stays '
      'green -- this file otherwise runs as `postgres`.';
  end if;

  if has_function_privilege('anon', 'public.referee_waiting_today()', 'execute') then
    raise exception
      '`anon` can EXECUTE public.referee_waiting_today(). A drop-and-create in `public` is how '
      'referee_day_lookup() lost exactly this revoke (20260914140000).';
  end if;

  foreach f in array array['anon', 'authenticated'] loop
    if has_function_privilege(f, 'public.commitment_day_photographs(uuid, date)', 'execute') then
      raise exception using message = format(
        '`%s` can EXECUTE public.commitment_day_photographs(uuid, date). It lists storage paths '
        'for any commitment uuid it is handed, and its only callers are security definer.', f);
    end if;
  end loop;

  foreach f in array array[
    'public.referee_waiting_today()',
    'public.commitment_day_photographs(uuid, date)',
    'public.photograph_reaches_the_referee(uuid, date)'
  ]
  loop
    select p.proconfig into v_config from pg_proc p where p.oid = f::regprocedure;

    if v_config is null
       or not exists (
         select 1 from unnest(v_config) as c
          where c like 'search_path=%'
            and btrim(split_part(c, '=', 2), '"') = ''
       ) then
      raise exception using message = format(
        '`%s` does not pin `search_path` to empty (proconfig reads %s).', f,
        coalesce(v_config::text, 'null'));
    end if;

    if not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception using message = format(
        '`%s` is no longer `security definer`. Run as the referee it could read neither the '
        'flag''s change log nor a commitment-day evidence row, and would answer nothing, '
        'silently.', f);
    end if;
  end loop;

  raise notice using message =
    'Step 0 ok: the list is granted to `authenticated` and withheld from `anon`, the helper is '
    'withheld from both, and all three are security definer with search_path pinned empty.';
end $$;


do $$
declare
  v_mine    uuid := gen_random_uuid();  -- the doer this referee is paired to
  v_theirs  uuid := gen_random_uuid();  -- an unrelated doer, with an identical waiting day
  v_ref     uuid := gen_random_uuid();  -- paired to v_mine
  v_ref2    uuid := gen_random_uuid();  -- a referee paired to nobody
  v_ref3    uuid := gen_random_uuid();  -- paired to v_theirs

  v_today   date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  -- Listed.
  v_day      uuid;  -- flagged, untimed, commitment-day photograph
  v_claim    uuid;  -- flagged, timed, claim-parented photograph
  v_off      uuid;  -- flagged when today began, switched off since
  v_free     uuid;  -- flagged, carries no penalty: listed, and says so
  -- Not listed.
  v_plain    uuid;  -- never flagged, photograph kept
  v_on       uuid;  -- unflagged when today began, switched on since
  v_bare     uuid;  -- flagged, no photograph yet
  v_ok       uuid;  -- flagged, photograph, approved today
  v_no       uuid;  -- flagged, photograph, refused today
  v_old      uuid;  -- flagged, photograph on yesterday only
  v_archived uuid;  -- flagged, photograph, archived
  v_t_day    uuid;  -- v_theirs', flagged, photograph

  v_decl    uuid;
  v_case    text;
  v_id      uuid;
  v_row     record;
  v_got     uuid[];
  v_want    uuid[];
  v_rows    integer;
begin
  -- ---------------------------------------------------------------- the five accounts

  foreach v_case in array array['mine', 'theirs', 'ref', 'ref2', 'ref3']
  loop
    v_id := case v_case
              when 'mine'   then v_mine
              when 'theirs' then v_theirs
              when 'ref'    then v_ref
              when 'ref2'   then v_ref2
              else v_ref3
            end;

    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'waiting-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  -- Pairings before any flagged commitment: `commitment_sign_off_needs_a_referee` refuses the
  -- flag on an account no referee is paired to.
  update public.profile set role = 'referee' where id in (v_ref, v_ref2, v_ref3);
  update public.profile set referee_of = v_mine   where id = v_ref;
  update public.profile set referee_of = v_theirs where id = v_ref3;

  -- ---------------------------------------------------------------- the commitments

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'A: Thuoc', 'do', 'daily', true, true, true)
  returning id into v_day;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_mine, gen_random_uuid(), 'B: Gym (timed)', 'do', 'daily', true, true, true,
          time '10:00', 30)
  returning id into v_claim;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'C: Switched off today', 'do', 'daily', true, true, true)
  returning id into v_off;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'D: No money on it', 'do', 'daily', false, true, true)
  returning id into v_free;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Plain', 'do', 'daily', true, true, false)
  returning id into v_plain;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Switched on today', 'do', 'daily', true, true, false)
  returning id into v_on;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'No photo yet', 'do', 'daily', true, true, true)
  returning id into v_bare;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Approved', 'do', 'daily', true, true, true)
  returning id into v_ok;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Refused', 'do', 'daily', true, true, true)
  returning id into v_no;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Yesterday', 'do', 'daily', true, true, true)
  returning id into v_old;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Archived', 'do', 'daily', true, true, true)
  returning id into v_archived;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_theirs, gen_random_uuid(), 'A: Thuoc', 'do', 'daily', true, true, true)
  returning id into v_t_day;

  -- ---------------------------------------------------------------- the histories
  --
  -- Every commitment whose flag must be read at a day's *start* is made to predate that day, its
  -- log entries with it, before anything moves -- `8-3-...sql:320-330` says why the order matters.
  -- `v_old` needs it for yesterday; the two switch cases need it for today.

  update public.commitment set created_at = now() - interval '90 days'
   where id in (v_off, v_on, v_old);

  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_today) - interval '10 days'
   where commitment_id in (v_off, v_on, v_old);

  update public.commitment set requires_referee_approval = false where id = v_off;
  update public.commitment set requires_referee_approval = true  where id = v_on;

  if public.requires_referee_approval_as_of(v_off, v_today) is not true
     or public.requires_referee_approval_as_of(v_on, v_today) is not false
     or public.requires_referee_approval_as_of(v_old, v_today - 1) is not true then
    raise exception
      'Fixture is not exercising what it claims: as-of reads % (switched off today), % '
      '(switched on today), % (yesterday), wanted true, false, true.',
      public.requires_referee_approval_as_of(v_off, v_today),
      public.requires_referee_approval_as_of(v_on, v_today),
      public.requires_referee_approval_as_of(v_old, v_today - 1);
  end if;

  -- ---------------------------------------------------------------- the photographs
  --
  -- Object first, row second: `evidence_object_must_exist()` refuses a path naming no object.

  for v_row in
    select * from (values
      (v_mine, v_day), (v_mine, v_off), (v_mine, v_free), (v_mine, v_plain), (v_mine, v_on),
      (v_mine, v_ok), (v_mine, v_no), (v_mine, v_old), (v_mine, v_archived),
      (v_theirs, v_t_day)
    ) as t(owner_id, commitment_id)
  loop
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence',
            v_row.commitment_id::text || '/' || v_today::text || '.jpg', v_row.owner_id);

    insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
    values (v_row.commitment_id, v_today,
            v_row.commitment_id::text || '/' || v_today::text || '.jpg', v_today);
  end loop;

  -- A second photograph on v_day, swept. The row survives and the bytes do not; the list must
  -- carry the first path and not this one, while the day stays listed on the first.
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_day::text || '/second.jpg', v_mine);

  insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
  values (v_day, v_today, v_day::text || '/second.jpg', v_today);

  update public.evidence set swept_at = now() where storage_path = v_day::text || '/second.jpg';

  -- Yesterday's photograph. `evidence_derive_owner()` refuses a commitment-day row for any day
  -- but today, and it fires on insert only -- so the row is filed today and moved back, which
  -- is the state a real photograph kept yesterday is in.
  update public.evidence set for_day = v_today - 1 where commitment_id = v_old;

  -- The claim-parented one, filed as `postgres` with tomorrow-morning's answer instant so that
  -- `declaration_derive_day()` lands it on today (`8-3-...sql:380-384`'s idiom).
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_mine, v_claim, gen_random_uuid(), 'held',
          ((v_today + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_decl;

  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_decl::text || '/proof.jpg', v_mine);

  insert into public.evidence (declaration_id, storage_path, captured_on)
  values (v_decl, v_decl::text || '/proof.jpg', v_today);

  update public.commitment set archived_at = now() where id = v_archived;

  -- =================================================================================
  -- Step 1: the referee, on the account he is paired to.
  --
  -- The two decisions go through sign_off_day() itself, as the screen does, in his session.
  -- =================================================================================
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  perform public.sign_off_day(v_ok, v_today, true, null);
  perform public.sign_off_day(v_no, v_today, false, 'I was there. He never took it.');

  select array_agg(w.commitment_id order by w.commitment_id) into v_got
    from public.referee_waiting_today() w;

  select array_agg(x order by x) into v_want
    from unnest(array[v_day, v_claim, v_off, v_free]) as x;

  if v_got is distinct from v_want then
    raise exception using message = format(
      'The referee''s list named %s, wanted exactly the four waiting rows %s. Absent by design: '
      'plain %s, switched-on-today %s, no-photo %s, approved %s, refused %s, yesterday %s, '
      'archived %s, and the other doer''s %s.',
      v_got, v_want, v_plain, v_on, v_bare, v_ok, v_no, v_old, v_archived, v_t_day);
  end if;

  for v_row in select * from public.referee_waiting_today() loop
    if v_row.for_day is distinct from v_today then
      raise exception using message = format(
        '%s came back for %s, wanted today (%s). The screen passes this date to sign_off_day() '
        'unchanged, so it is the one date the client ever uses.',
        v_row.commitment_name, v_row.for_day, v_today);
    end if;

    if v_row.cadence is distinct from 'daily' then
      raise exception using message = format(
        '%s came back with cadence %s, wanted daily.', v_row.commitment_name, v_row.cadence);
    end if;

    if v_row.carries_penalty is distinct from (v_row.commitment_id <> v_free) then
      raise exception using message = format(
        '%s came back with carries_penalty %s. Only "D: No money on it" carries none, and that '
        'fact is what keeps the refuse control off the one row a refusal would cost nothing on.',
        v_row.commitment_name, v_row.carries_penalty);
    end if;

    if v_row.commitment_id = v_day
       and v_row.evidence_paths is distinct from array[v_day::text || '/' || v_today::text || '.jpg'] then
      raise exception using message = format(
        'The untimed row carried %s. Wanted its kept photograph and not the swept one: naming a '
        'swept path puts a photo on his screen that can never load.', v_row.evidence_paths);
    end if;

    if v_row.commitment_id = v_claim
       and v_row.evidence_paths is distinct from array[v_decl::text || '/proof.jpg'] then
      raise exception using message = format(
        'The timed row carried %s. Wanted its claim-parented photograph -- the parentage a '
        'commitment with a due_time is proved by.', v_row.evidence_paths);
    end if;
  end loop;

  raise notice using message =
    'Step 1 ok: exactly the four waiting rows, both parentages, today''s date, the facts the '
    'refuse control mirrors, and no swept path. Unflagged, flagged-since, photo-less, decided, '
    'yesterday''s, archived and another doer''s days are all absent.';

  -- =================================================================================
  -- Step 2: everyone else gets nothing, never an error.
  -- =================================================================================

  -- The author himself. He has a doer session and the function names his own days -- but the
  -- list is the referee's, and `role_from_table()` is what says so.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_mine, 'role', 'authenticated')::text, true);

  select count(*) into v_rows from public.referee_waiting_today();
  if v_rows <> 0 then
    raise exception 'The author read % row(s) of his referee''s waiting list, wanted none.', v_rows;
  end if;

  -- A referee paired to nobody.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref2, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);

  select count(*) into v_rows from public.referee_waiting_today();
  if v_rows <> 0 then
    raise exception 'An unpaired referee read % row(s), wanted none.', v_rows;
  end if;

  -- A referee paired to the other doer: his own doer's row and nothing of v_mine's.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref3, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);

  select array_agg(w.commitment_id) into v_got from public.referee_waiting_today() w;
  if v_got is distinct from array[v_t_day] then
    raise exception using message = format(
      'The other doer''s referee read %s, wanted only his own doer''s %s.', v_got, v_t_day);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 2 ok: the author, an unpaired referee and another doer''s referee each read nothing of '
    'this list that is not theirs.';
end $$;


-- =================================================================================
-- Step 3: one rule, one expression of it.
--
-- Asserted against the catalog, so it survives a later `create or replace` that quietly
-- re-derives the union somewhere new. `8-3-...sql` step 7 covers sign_off_day() and both
-- policies; this covers the two functions this story touched.
-- =================================================================================
do $$
declare
  v_names text[];
begin
  select array_agg(p.proname::text order by p.proname) into v_names
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosrc like '%join public.declaration d on d.id = e.declaration_id%';

  if v_names is distinct from array['commitment_day_photographs'] then
    raise exception using message = format(
      'The parentage union is written in %s, wanted only commitment_day_photographs(). A second '
      'copy is how the referee''s list and the referee''s reach come to disagree -- Epic 6 '
      'retrospective item 50.', coalesce(v_names::text, 'no function at all'));
  end if;

  if pg_get_functiondef('public.photograph_reaches_the_referee(uuid, date)'::regprocedure)
       not like '%commitment_day_photographs%' then
    raise exception
      'photograph_reaches_the_referee() no longer reads commitment_day_photographs(), so the '
      'predicate and the list can answer "which photographs" differently.';
  end if;

  if pg_get_functiondef('public.referee_waiting_today()'::regprocedure)
       not like '%photograph_reaches_the_referee%' then
    raise exception
      'referee_waiting_today() is no longer gated by photograph_reaches_the_referee(). A row it '
      'lists could then be one he cannot open, or cannot decide.';
  end if;

  raise notice using message =
    'Step 3 ok: the parentage union lives only in commitment_day_photographs(), and both the '
    'predicate and the list reach it.';
  raise notice using message =
    'PASS. The referee is shown today''s waiting days of his own doer and nothing else.';
end $$;

rollback;
