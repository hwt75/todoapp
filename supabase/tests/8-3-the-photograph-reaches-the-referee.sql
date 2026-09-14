-- Story 8.3 — the photograph reaches the referee.
--
-- Story 6.8 narrowed **two** policies at once so a commitment-day photograph reached the referee
-- as neither row nor object. Story 8.2 then asked him to refuse days proved by exactly such a
-- photograph. This widens both policies again, for a commitment flagged **as of the day the
-- photograph belongs to** and for no other.
--
-- **The row arm and the object arm are asserted separately, every time.** Widening one and not
-- the other is the specific failure this story exists to avoid: a photograph that is listable and
-- unopenable proves nothing, and one that is openable and unlistable is a reach nothing can find.
-- So no assertion here checks "the referee can see it" -- each checks `public.evidence` and
-- `storage.objects` as two independent questions that must answer the same way.
--
-- What is proved, in order:
--
--   0.  Three functions executable by `authenticated` and not by `anon` -- the two new helpers,
--       without which every policy arm below silently answers false in production while this file
--       stays green (the whole file otherwise runs as `postgres`), and
--       `requires_referee_approval_as_of()`, which hwt75 granted as an Ask First so the author's
--       own copy reads the flag the same way the policy does. Plus the line that grant must not
--       cross: no policy predicate may call it.
--   1.  The flag is read as of the day, never live, in **both** directions: a flag switched off
--       after the day still reaches back into it, and a flag switched on after it does not reach
--       forward. Both cases are built the only way they can be built -- a commitment older than
--       today whose log entry predates today -- because a commitment created today falls into
--       the reader's backward-extrapolation branch instead.
--   2.  Story 6.8's narrowing survives wherever the flag is off.
--   3.  An orphaned object under a commitment id is not reachable: the predicate resolves through
--       the `evidence` row, and an object with no row fails closed.
--   4.  A swept row still reaches him -- the policy does not filter `swept_at`, which is the
--       fourth behaviour this story deliberately did not invent.
--   5.  Scoping, twice over: a referee paired to another doer, and a referee paired to nobody.
--   6.  The author's own reach is unchanged, and a claim-parented photograph still reaches the
--       referee flagged or not -- that arm has been his since Story 4.6 and is not what moved.
--   7.  The schema holds **one** expression of the rule: `sign_off_day()` and both policies all
--       name the same predicate, and the union of parentages is spelled out in exactly one place.
--
-- `referee_day_lookup()` is deliberately NOT widened -- Story 8.4 owns what he is shown -- and
-- `the-referee-can-see-what-the-day-was-proved-with.sql` is where that is asserted, beside the
-- kept-photo assertion this story had to split.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/8-3-the-photograph-reaches-the-referee.sql
--
-- One transaction, rolled back at the end. Nothing persists, nothing settles, and no clock is
-- moved: `now()` is transaction-start time and this file is one transaction, so a run beginning
-- at 23:59:59 cannot cross midnight mid-assertion.
--
-- **Every commitment-day photograph here is today's, and it has to be.** `evidence_derive_owner()`
-- (20260903120000:170-177) refuses a commitment-parented row whose `for_day` is not the local day
-- of the insert, in either direction. So the day is fixed and the *flag history* is what varies.

begin;

-- The local stack's default privileges differ from the author's own project (recorded at length
-- in `2-1-roles-and-rls.sql`'s own header). The two new helpers carry their own grants in the
-- migration and are asserted rather than re-issued in Step 0; the ordinary table reads this file
-- drives through RLS still need these.
grant select on table public.profile, public.commitment, public.evidence to authenticated;

-- The bucket every photograph below belongs to. It is `config.toml` configuration created by the
-- CLI through the storage API, not by a migration, so a database started with `-x storage-api` --
-- which is how CI starts it -- has the schema but not the row. Staged here so the file runs
-- against any database, and it rolls back with everything else.
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;


-- =================================================================================
-- Step 0: the two grants this migration makes, asserted rather than re-issued.
--
-- This whole file runs as `postgres`, which may execute anything, so every widened policy arm
-- below would answer correctly here with the grants lost and the feature dead in production --
-- a policy calling a function the caller cannot execute raises at query time for a real session
-- and never for this one. Granting them here would paper over exactly that, which is why this
-- only asks. The idiom is `8-1-a-commitment-can-ask-for-the-referee-s-signature.sql:31-53`'s.
-- =================================================================================
do $$
declare
  f text;
  v_config text[];
begin
  foreach f in array array[
    'public.photograph_reaches_the_referee(uuid, date)',
    'public.commitment_day_object_reaches_the_referee(text)'
  ]
  loop
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception using message = format(
        '`authenticated` cannot EXECUTE %s. It is called from a policy evaluated as the caller, '
        'so without the grant the referee''s every read of a flagged photograph fails at the API '
        'with a permission error while this file stays green -- re-granting it here would hide '
        'precisely that breakage.', f);
    end if;

    -- The other direction, because `drop function` destroys the ACL and a bare `create` in
    -- `public` hands EXECUTE straight back to PUBLIC, `anon` included.
    if has_function_privilege('anon', f, 'execute') then
      raise exception using message = format(
        '`anon` can EXECUTE %s. A signed-out caller has no business asking anything about '
        'somebody else''s commitment.', f);
    end if;
  end loop;

  -- The third grant, answered as an Ask First by hwt75 on 2026-09-14 and asserted here in both
  -- directions for the reason the two above are. **It is the author's copy that reads this**, so
  -- that Today's photo control can tell him who opens the photograph using the same as-of
  -- reading the policies make; leaving the client on the live column re-created Epic 6
  -- retrospective A2 inside the story that exists to answer A2.
  if not has_function_privilege(
       'authenticated', 'public.requires_referee_approval_as_of(uuid, date)', 'execute') then
    raise exception using message =
      '`authenticated` cannot EXECUTE public.requires_referee_approval_as_of(uuid, date). '
      'Without it Today''s all-day photo control has nothing to read but the live column, and on '
      'any day the author moves the flag the screen and the policy disagree -- saying "Only you '
      'can open it" about a photograph his referee can still open.';
  end if;

  if has_function_privilege(
       'anon', 'public.requires_referee_approval_as_of(uuid, date)', 'execute') then
    raise exception using message =
      '`anon` can EXECUTE public.requires_referee_approval_as_of(uuid, date). The grant rests on '
      'the caller already holding a commitment uuid, which a signed-out session never does.';
  end if;

  -- And the distinction the grant must not blur: **no policy predicate calls it.** The widened
  -- referee policies go through photograph_reaches_the_referee(), which is `security definer`
  -- and needs no caller privilege, so no policy's correctness depends on an ACL -- the thing
  -- `drop function` destroys and a bare `create` in `public` hands back to PUBLIC. Asserted
  -- against the catalog because a comment cannot hold a line and this can.
  if exists (
    select 1 from pg_policy p
     where pg_get_expr(p.polqual, p.polrelid) like '%requires_referee_approval_as_of%'
        or pg_get_expr(p.polwithcheck, p.polrelid) like '%requires_referee_approval_as_of%'
  ) then
    raise exception using message =
      'A policy predicate now calls requires_referee_approval_as_of() directly. The grant made '
      'for the author''s copy is not a licence for that: a policy resting on a client EXECUTE '
      'grant is a policy whose correctness depends on an ACL. Go through '
      'photograph_reaches_the_referee(), which is security definer and needs no privilege.';
  end if;

  -- The other half of the same lock, and the one no grant can state. `2-1-roles-and-rls.sql`
  -- asserts this for the eight functions Story 6.6 touched and for nothing else, so a later
  -- `create or replace` that dropped `set search_path = ''` from either of these definer
  -- functions would pass every guard this story adds. A definer function in `public` that
  -- inherits the caller's search_path is the classic escalation: the caller creates
  -- `pg_temp.evidence`, prepends `pg_temp`, and the function reads his table with the owner's
  -- rights -- which here would let a session decide for itself which photographs reach a referee.
  --
  -- The granted reader is in the list too. It was `security definer` before this story and is
  -- still, and a client can now call it, which is exactly when an unpinned search_path stops
  -- being theoretical.
  foreach f in array array[
    'public.photograph_reaches_the_referee(uuid, date)',
    'public.commitment_day_object_reaches_the_referee(text)',
    'public.requires_referee_approval_as_of(uuid, date)'
  ]
  loop
    select p.proconfig into v_config from pg_proc p where p.oid = f::regprocedure;

    -- `proconfig` stores the setting as `search_path=""` -- the value is quoted, so a plain
    -- equality against `search_path=` matches nothing and would pass for every function alike.
    -- The idiom is `2-1-roles-and-rls.sql`'s own.
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
        '`%s` is no longer `security definer`. The policies that call it would then be evaluated '
        'with the referee''s own privileges, and he can read neither the flag''s change log nor '
        'a commitment-day evidence row -- so every widened arm would answer false, silently.', f);
    end if;

    -- A null `proacl` means "default privileges", which for a function in `public` is EXECUTE to
    -- PUBLIC. Every one of these three was explicitly revoked and re-granted, so a null here is
    -- the signature of a `drop function` + bare `create` that handed `anon` the function back --
    -- the failure `20260819121500` is named for. The `anon` checks above catch it too; this
    -- catches it on a stack where `anon` does not exist.
    if (select p.proacl from pg_proc p where p.oid = f::regprocedure) is null then
      raise exception using message = format(
        '`%s` carries no explicit ACL, so it has been re-created with default privileges -- '
        'EXECUTE to PUBLIC.', f);
    end if;
  end loop;

  raise notice using message =
    'Step 0 ok: all three functions are granted to `authenticated`, withheld from `anon`, still '
    '`security definer` with `search_path` pinned empty and an explicit ACL -- and no policy '
    'predicate rests on the granted one.';
end $$;


do $$
declare
  v_mine    uuid := gen_random_uuid();  -- the doer this referee is paired to
  v_theirs  uuid := gen_random_uuid();  -- an unrelated doer, with an identical flagged day
  v_ref     uuid := gen_random_uuid();  -- paired to v_mine
  v_ref2    uuid := gen_random_uuid();  -- a referee paired to nobody at all
  v_ref3    uuid := gen_random_uuid();  -- paired to v_theirs, so their flagged row can exist

  v_today   date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  -- One commitment per matrix row. All untimed and all `do`, except v_claim's, which carries the
  -- other parentage.
  v_flag    uuid;  -- flagged as of today
  v_plain   uuid;  -- never flagged
  v_off     uuid;  -- flagged on the day, switched off since
  v_on      uuid;  -- unflagged on the day, switched on since
  v_orphan  uuid;  -- flagged, with an object and no evidence row
  v_swept   uuid;  -- flagged, with the row swept
  v_claim   uuid;  -- flagged, proved by a claim-parented photograph
  v_claim2  uuid;  -- its unflagged twin, so "flagged or not" is asserted and not merely claimed
  v_t_flag  uuid;  -- v_theirs', flagged, identical in every other way

  v_decl    uuid;
  v_decl2   uuid;
  v_case    text;
  v_id      uuid;
  v_row     record;
  v_rows    integer;
  v_objs    integer;
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
            'reaches-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  -- The pairings come first: `commitment_sign_off_needs_a_referee` (20260911090000:263) refuses a
  -- flagged commitment on an account no referee is paired to, and every commitment below but one
  -- is flagged at some point in its life. v_ref2 is left pointing at nobody on purpose.
  update public.profile set role = 'referee' where id in (v_ref, v_ref2, v_ref3);
  update public.profile set referee_of = v_mine   where id = v_ref;
  update public.profile set referee_of = v_theirs where id = v_ref3;

  -- ---------------------------------------------------------------- the commitments

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Thuoc (signed off)', 'do', 'daily', true, true, true)
  returning id into v_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Sketchbook (his own record)', 'do', 'daily', true,
          true, false)
  returning id into v_plain;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Switched off since', 'do', 'daily', true, true, true)
  returning id into v_off;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Switched on since', 'do', 'daily', true, true, false)
  returning id into v_on;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Upload that never filed', 'do', 'daily', true, true, true)
  returning id into v_orphan;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_mine, gen_random_uuid(), 'Swept', 'do', 'daily', true, true, true)
  returning id into v_swept;

  -- Timed, so its proof is the claim-parented photograph of Story 6.3 rather than Story 6.8's
  -- kept record. Flagged, because the arm this exercises must stay exactly as wide as it was --
  -- `commitment_id is null` has reached him since Story 4.6, and narrowing it while widening the
  -- other would be this story trading one gap for another.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_mine, gen_random_uuid(), 'Gym (signed off, timed)', 'do', 'daily', true, true, true,
          time '10:00', 30)
  returning id into v_claim;

  -- The unflagged twin, and it exists because the header claims a claim-parented photograph
  -- reaches him "flagged or not" and one flagged fixture cannot say the second half. This is the
  -- arm Story 6.8 deliberately left alone: `commitment_id is null` has nothing to do with the
  -- sign-off flag, so widening the *other* arm must not have made this one conditional on it.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_mine, gen_random_uuid(), 'Gym (plain, timed)', 'do', 'daily', true, true, false,
          time '10:00', 30)
  returning id into v_claim2;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_theirs, gen_random_uuid(), 'Thuoc (signed off)', 'do', 'daily', true, true, true)
  returning id into v_t_flag;

  -- ---------------------------------------------------------------- the two flag histories
  --
  -- Both switch cases need the reader's **first** branch -- the entry in force when the day
  -- began -- and a commitment created today cannot reach it: with no entry before
  -- day_begins_at(today) the reader falls to backward extrapolation and answers the earliest
  -- logged value, which is the live one. So both commitments are made to predate today, their
  -- creation entry is backdated with them, and only then is the flag moved. The idiom is
  -- `8-2-the-referee-s-decision-and-what-a-refusal-costs.sql:365-375`'s, and it is also why the
  -- backdate happens before the update rather than after: one `update ... set changed_at` after
  -- both entries existed would move them both.

  update public.commitment set created_at = now() - interval '90 days'
   where id in (v_off, v_on);

  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_today) - interval '10 days'
   where commitment_id in (v_off, v_on);

  -- Switched off today. Live column false, as-of-today true -- he still reaches back.
  update public.commitment set requires_referee_approval = false where id = v_off;

  -- Switched on today. Live column true, as-of-today false -- the flag reaches forward only, and
  -- a day already lived is not re-judged. This is the row that fails *open* if anything ever
  -- reads the column instead of the door.
  update public.commitment set requires_referee_approval = true where id = v_on;

  if public.requires_referee_approval_as_of(v_off, v_today) is not true
     or public.requires_referee_approval_as_of(v_on, v_today) is not false then
    raise exception
      'Fixture is not exercising what it claims: as-of today reads % for the switched-off '
      'commitment and % for the switched-on one, wanted true and false.',
      public.requires_referee_approval_as_of(v_off, v_today),
      public.requires_referee_approval_as_of(v_on, v_today);
  end if;

  -- ---------------------------------------------------------------- the photographs
  --
  -- The object first and the row second, in the order the client really writes it:
  -- `evidence_object_must_exist()` (20260910090000) refuses a `storage_path` naming no object.

  for v_row in
    select * from (values
      (v_mine, v_flag), (v_mine, v_plain), (v_mine, v_off), (v_mine, v_on), (v_mine, v_swept),
      (v_theirs, v_t_flag)
    ) as t(owner_id, commitment_id)
  loop
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence',
            v_row.commitment_id::text || '/' || v_today::text || '.jpg', v_row.owner_id);

    insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
    values (v_row.commitment_id, v_today,
            v_row.commitment_id::text || '/' || v_today::text || '.jpg', v_today);
  end loop;

  -- The orphan: the upload landed, the row that names it never did. Real, and reachable by the
  -- ordinary client path -- `components/today.tsx` uploads first and files second, so a failed
  -- second step leaves exactly this.
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_orphan::text || '/' || v_today::text || '.jpg', v_mine);

  -- The claim-parented one. Filed as `postgres` with tomorrow-morning's answer instant, which is
  -- how `declaration_derive_day()` lands a machine-filed statement on today (the idiom
  -- `8-2-...:545-547` uses) -- so this file needs no clock window of its own.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_mine, v_claim, gen_random_uuid(), 'held',
          ((v_today + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_decl;

  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_decl::text || '/proof.jpg', v_mine);

  insert into public.evidence (declaration_id, storage_path, captured_on)
  values (v_decl, v_decl::text || '/proof.jpg', v_today);

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_mine, v_claim2, gen_random_uuid(), 'held',
          ((v_today + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh')
  returning id into v_decl2;

  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_decl2::text || '/proof.jpg', v_mine);

  insert into public.evidence (declaration_id, storage_path, captured_on)
  values (v_decl2, v_decl2::text || '/proof.jpg', v_today);

  -- Swept: the row survives because `commitments_owing()` reads it to decide the day held, and
  -- the bytes are what the sweeper takes. The object is left in place here so that what is being
  -- asserted below is the *policy*, not the absence -- see Step 4 for the other half.
  update public.evidence set swept_at = now() where commitment_id = v_swept;


  -- =================================================================================
  -- Steps 1-4: the referee, on the account he is paired to.
  --
  -- One loop, two questions per row, because the two arms drifting apart is the failure this
  -- story exists to avoid and a loop is the only shape in which they cannot be asserted with
  -- different fixtures.
  -- =================================================================================
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  for v_row in
    select * from (values
      -- label, commitment, the path, and what each arm must answer
      ('flagged as of that day',        v_flag,   1, 1),
      ('never flagged',                 v_plain,  0, 0),
      ('flagged then switched off',     v_off,    1, 1),
      ('switched on after the day',     v_on,     0, 0),
      ('flagged, and swept',            v_swept,  1, 1),
      ('flagged, but another account''s', v_t_flag, 0, 0),
      ('flagged, upload with no row',   v_orphan, 0, 0)
    ) as t(label, commitment_id, want_rows, want_objs)
  loop
    select count(*) into v_rows from public.evidence e
     where e.commitment_id = v_row.commitment_id and e.for_day = v_today;

    select count(*) into v_objs from storage.objects o
     where o.bucket_id = 'appeal-evidence'
       and o.name = v_row.commitment_id::text || '/' || v_today::text || '.jpg';

    if v_rows <> v_row.want_rows then
      raise exception
        'Row arm, "%": the referee read % evidence row(s), wanted %.',
        v_row.label, v_rows, v_row.want_rows;
    end if;

    if v_objs <> v_row.want_objs then
      raise exception
        'Object arm, "%": the referee read % storage.objects row(s), wanted %. The row arm '
        'answered % -- a photograph listable and unopenable, or openable and unlistable, is '
        'exactly the failure this story exists to avoid.',
        v_row.label, v_objs, v_row.want_objs, v_rows;
    end if;
  end loop;

  raise notice using message =
    'Steps 1-4 ok: a flagged commitment-day reaches the referee by row and by object; an '
    'unflagged one reaches him by neither; the flag is read as of the day in both directions; '
    'an orphaned object and another account''s day reach him not at all; a swept row still does.';

  -- Step 4, second half. The sweeper takes the bytes as well as stamping the row, and the row
  -- staying reachable afterwards is the point: the policy filters no `swept_at`, so what the
  -- referee meets is an object that is simply not there -- the same thing the author meets, and
  -- the caller reports it cleared rather than as a failure. Deleted here rather than in the
  -- fixture so the assertion above is about the policy and this one is about the absence.
  perform set_config('role', 'postgres', true);
  -- `storage.protect_delete` refuses a direct DELETE from `storage.objects` outright; the real
  -- sweeper goes through the Storage API, which is what this GUC exists for. Set `local`, so it
  -- rolls back with everything else and no later statement in this file inherits it.
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects
   where bucket_id = 'appeal-evidence'
     and name = v_swept::text || '/' || v_today::text || '.jpg';
  perform set_config('storage.allow_delete_query', 'false', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  select count(*) into v_rows from public.evidence e
   where e.commitment_id = v_swept and e.for_day = v_today;

  if v_rows <> 1 then
    raise exception
      'A swept row must still reach the referee once its bytes are gone -- the row is metadata '
      'and the policy filters no swept_at. He read % row(s).', v_rows;
  end if;

  if public.commitment_day_object_reaches_the_referee(
       v_swept::text || '/' || v_today::text || '.jpg') is not true then
    raise exception
      'The predicate must still answer true for a swept photograph. If it ever stops, the '
      'policy has grown a fourth swept_at behaviour and the row above is reachable for a '
      'different reason than the one that is documented.';
  end if;

  raise notice using message =
    'Step 4b ok: a swept photograph''s row still reaches the referee and its object is absent '
    'rather than refused.';

  -- =================================================================================
  -- Step 5: scoping. Two ways to be the wrong referee, and the second one is the one a
  -- `referee_of` that was never recorded produces -- which makes every policy conjunct compare
  -- against NULL and match nothing, the intended direction of failure.
  -- =================================================================================
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref2, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);

  select count(*) into v_rows from public.evidence;
  select count(*) into v_objs from storage.objects where bucket_id = 'appeal-evidence';

  if v_rows <> 0 or v_objs <> 0 then
    raise exception
      'A referee paired to nobody read % evidence row(s) and % object(s). Both must be zero.',
      v_rows, v_objs;
  end if;

  -- And the paired referee of the *other* account reads his own doer's flagged day and nothing
  -- of v_mine's -- the widening must not have become a door out of the pairing.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref3, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);

  select count(*) into v_rows from public.evidence e where e.commitment_id = v_t_flag;
  if v_rows <> 1 then
    raise exception
      'The referee paired to the other doer must reach his own flagged day. He read % row(s).',
      v_rows;
  end if;

  select count(*) into v_rows from public.evidence e where e.owner_id = v_mine;
  select count(*) into v_objs from storage.objects o
   where o.bucket_id = 'appeal-evidence' and o.owner = v_mine;

  if v_rows <> 0 or v_objs <> 0 then
    raise exception
      'A referee paired to another doer read % of v_mine''s evidence row(s) and % object(s). '
      'Both must be zero.', v_rows, v_objs;
  end if;

  raise notice using message =
    'Step 5 ok: an unpaired referee reaches nothing at all, and a paired one reaches his own '
    'doer''s flagged day and none of the other account''s.';

  -- =================================================================================
  -- Step 6: the two things that must not have moved.
  -- =================================================================================

  -- The claim-parented photograph, read by the referee this account is paired to. Reachable
  -- since Story 4.6 through `commitment_id is null`, and this story's job was to leave it alone.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);

  select count(*) into v_rows from public.evidence e where e.declaration_id = v_decl;
  select count(*) into v_objs from storage.objects o
   where o.bucket_id = 'appeal-evidence' and o.name = v_decl::text || '/proof.jpg';

  if v_rows <> 1 or v_objs <> 1 then
    raise exception
      'A flagged commitment''s claim-parented photograph must reach the referee exactly as it '
      'did before this story: % row(s), % object(s), both wanted 1.', v_rows, v_objs;
  end if;

  -- And the unflagged twin, which is the half "flagged or not" was asserting on one fixture.
  -- `commitment_id is null` is not a statement about sign-off, so a widening that made this arm
  -- conditional on the flag would have traded one gap for another -- taking away a reach Story
  -- 4.6 gave him and Story 6.7 needs, in a story whose whole job was to add one.
  select count(*) into v_rows from public.evidence e where e.declaration_id = v_decl2;
  select count(*) into v_objs from storage.objects o
   where o.bucket_id = 'appeal-evidence' and o.name = v_decl2::text || '/proof.jpg';

  if v_rows <> 1 or v_objs <> 1 then
    raise exception
      'An UNflagged commitment''s claim-parented photograph must still reach the referee -- the '
      'flag has never governed that arm. % row(s), % object(s), both wanted 1.', v_rows, v_objs;
  end if;

  -- The predicate's **second** branch, called directly, because nothing else here reaches it.
  -- Both policies short-circuit on `commitment_id is null` before ever asking, so the
  -- `join public.declaration` arm is exercised only through `sign_off_day()` -- in another file,
  -- for another story. It is half of the union this story moved, and an edit that broke it would
  -- show up as a refusal the referee cannot explain rather than as a failing policy test.
  --
  -- `v_claim` has no commitment-parented row at all, asserted first so the `true` below cannot be
  -- the first branch answering by accident.
  select count(*) into v_rows from public.evidence e
   where e.commitment_id = v_claim and e.for_day = v_today;

  if v_rows <> 0 then
    raise exception
      'The timed fixture has grown a commitment-day photograph, so the assertion below would no '
      'longer be about the declaration branch. Got % row(s).', v_rows;
  end if;

  if public.photograph_reaches_the_referee(v_claim, v_today) is not true then
    raise exception
      'photograph_reaches_the_referee() must answer true for a flagged commitment proved by a '
      'CLAIM-parented photograph. A commitment carrying a due_time proves itself that way '
      '(20260903120000:51-53), and sign_off_day() refuses a refusal on a false answer -- so a '
      'broken join arm reads to the referee as "there is no photograph on that day yet" about a '
      'day he is looking at one for.';
  end if;

  -- And false for its unflagged twin, so the `true` above is the flag and the union agreeing
  -- rather than the union alone.
  if public.photograph_reaches_the_referee(v_claim2, v_today) is not false then
    raise exception
      'photograph_reaches_the_referee() must answer false for an unflagged commitment, whichever '
      'parentage proves it.';
  end if;

  -- The author, reading his own. Five commitment-day rows of **his** survive the fixture: flagged,
  -- plain, switched-off, switched-on and swept. The sixth commitment-day row the loop inserts
  -- belongs to v_theirs and is not his to read; the orphan filed no row at all, and the claim's
  -- is parented to a declaration. Every one of the five is his whether he flagged it or not --
  -- his own policies were not this story's to touch.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_mine, 'role', 'authenticated',
                                       'app_role', 'doer')::text, true);

  select count(*) into v_rows from public.evidence e
   where e.commitment_id is not null and e.for_day = v_today;

  if v_rows <> 5 then
    raise exception
      'The author must read every commitment-day photograph he kept today, flagged or not. He '
      'read %, wanted 5.', v_rows;
  end if;

  select count(*) into v_objs from storage.objects o
   where o.bucket_id = 'appeal-evidence'
     and o.name = v_plain::text || '/' || v_today::text || '.jpg';

  if v_objs <> 1 then
    raise exception
      'The author must still open his own unflagged record. He read % object(s).', v_objs;
  end if;

  -- And he reaches nothing of the other account's, which is what makes the count above a
  -- statement about ownership rather than about RLS being off.
  select count(*) into v_rows from public.evidence e where e.commitment_id = v_t_flag;
  if v_rows <> 0 then
    raise exception 'The author read % row(s) of another account''s evidence.', v_rows;
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 6 ok: a claim-parented photograph still reaches the referee, and the author''s own '
    'reach is unchanged in both directions.';
end $$;


-- =================================================================================
-- Step 7: one rule, one expression of it.
--
-- The acceptance criterion this story was written around: change the predicate and all three
-- askers change, because there is only one. Asserted against the catalog rather than by reading
-- the migration, so it survives a later `create or replace` that quietly re-derives the union.
-- =================================================================================
do $$
declare
  v_def   text;
  v_count integer;
begin
  v_def := pg_get_functiondef('public.sign_off_day(uuid, date, boolean, text)'::regprocedure);

  if v_def not like '%photograph_reaches_the_referee%' then
    raise exception
      'sign_off_day() no longer reads photograph_reaches_the_referee(). Its own comment asked '
      'for the single door -- "Story 8.4''s list must ask this same question; the two must not '
      'be able to disagree" -- and a second copy of the union is how they come to.';
  end if;

  if v_def like '%join public.declaration d on d.id = e.declaration_id%' then
    raise exception
      'sign_off_day() has grown its own copy of the parentage union again. That is four askers '
      'of one money-deciding rule, which is Epic 6 retrospective item 50''s shape exactly.';
  end if;

  -- Both policies, and they are asserted together because they must move together.
  select count(*) into v_count
    from pg_policy p
   where p.polname = 'evidence: referee reads his own doer''s'
     and pg_get_expr(p.polqual, p.polrelid) like '%photograph_reaches_the_referee%';

  if v_count <> 1 then
    raise exception
      'The `evidence` referee policy does not read photograph_reaches_the_referee().';
  end if;

  select count(*) into v_count
    from pg_policy p
   where p.polname = 'appeal-evidence objects: referee reads his own doer''s'
     and pg_get_expr(p.polqual, p.polrelid) like '%commitment_day_object_reaches_the_referee%';

  if v_count <> 1 then
    raise exception
      'The storage.objects referee policy does not read commitment_day_object_reaches_the_referee(), '
      'so the object arm and the row arm are free to disagree about one photograph.';
  end if;

  -- `referee_day_lookup()` is the one that deliberately did NOT widen. Story 8.4 owns what the
  -- referee is shown; asserted here so the next reader knows the omission was a decision.
  if pg_get_functiondef('public.referee_day_lookup(uuid)'::regprocedure)
       not like '%e.commitment_id is null%' then
    raise exception
      'referee_day_lookup() has stopped excluding commitment-day photographs. Story 8.3 widened '
      'his *reach* and deliberately not his *list*; if 8.4 has now widened the list, delete this '
      'assertion on purpose rather than discovering it here.';
  end if;

  raise notice using message =
    'Step 7 ok: sign_off_day() and both referee policies rest on one predicate, and '
    'referee_day_lookup() is still narrowed.';
end $$;

rollback;
