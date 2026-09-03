-- Story 6.8 — a photo kept against a commitment and a day, deciding nothing.
--
-- `evidence` now hangs off one of three parents: an appeal, a declaration, or a commitment and a
-- day. The three properties that make the store trustworthy have to survive the third kind
-- exactly as they survived the second (Story 6.3): the owner is derived server-side from the
-- parent row, the capture date must match the day the photo belongs to, and the object path must
-- lead with the parent's own id so the bucket's policies can derive access from it. A fourth
-- property is new here and is the one this file exists for most: the referee never sees it.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-8-a-photo-i-can-keep-against-any-commitment.sql
--
-- One transaction, rolled back at the end.
--
-- No live-doer guard here: this file calls no settlement function, so it never reaches the
-- `p_override` path that guard exists to keep away from a real account. See README.md.
--
-- **The regression that matters most is not in this file.** "A day with the flag on and no photo
-- settles exactly as it would with the flag off" is proved by `6-4-midnight-decides-the-day.sql`
-- and `6-5-today-shows-where-the-window-stands.sql` passing *unmodified* against the migrated
-- schema -- a settlement path that had learned about `requires_photo` could not do that. Step 6
-- below covers the one reader this story could plausibly have leaked into: `timed_claim_today`'s
-- `proven`, which is keyed on `declaration_id` and must stay blind to a commitment-parented row.

begin;

grant select on table public.profile, public.commitment, public.declaration to authenticated;
grant insert on table public.declaration, public.evidence to authenticated;
grant select on table public.evidence to authenticated;
grant select on public.timed_claim_today to authenticated;

-- The storage probes below need the grant so that a refusal is RLS refusing, and not a missing
-- privilege refusing for an unrelated reason. The local stack's default privileges differ from
-- the author's project (see supabase/tests/README.md), so the grant is made here rather than
-- assumed either way.
grant select, insert on table storage.objects to authenticated;

do $$
declare
  v_a          uuid := gen_random_uuid();
  v_b          uuid := gen_random_uuid();
  v_referee    uuid := gen_random_uuid();
  v_kept       uuid;
  v_abstain    uuid;
  v_timed      uuid;
  v_theirs     uuid;
  v_claim      uuid;
  v_day        date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_owner      uuid;
  v_count      integer;
  v_proven     boolean;
  v_refused    boolean;
  v_case       text;
  v_state      text;
  v_constraint text;
  v_message    text;
  v_got        text;
  v_want_state text;
  v_want_token text;
  v_at         timestamptz := (
    ((now() at time zone 'Asia/Ho_Chi_Minh')::date || ' 10:14')::timestamp
      at time zone 'Asia/Ho_Chi_Minh'
  );
begin
  foreach v_case in array array['a', 'b', 'referee']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case when 'a' then v_a when 'b' then v_b else v_referee end,
            '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            'story-6-8-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in',
            now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, requires_photo)
  values (v_a, gen_random_uuid(), 'Sketchbook', 'do', 'daily', true)
  returning id into v_kept;

  -- The whole reason this story exists: `commitment_time_needs_a_moment` refuses a due_time on
  -- an abstention, so before this migration this commitment had no path to a photo under any
  -- circumstance. The flag is not gated by kind or cadence, and this is the row that proves it.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, requires_photo)
  values (v_a, gen_random_uuid(), 'No phone in bed', 'abstain', 'daily', true)
  returning id into v_abstain;

  -- A commitment carrying both a time and the flag, and a claim on it. The claim is filed here
  -- rather than at step 6 because step 2 needs a declaration id that really exists: a malformed
  -- row must be refused by the constraint it is meant to prove, and a fake parent id would have
  -- the trigger refuse it first for an unrelated reason.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 due_time, late_window_minutes, requires_photo)
  values (v_a, gen_random_uuid(), 'Pill', 'do', 'daily', time '10:00', 30, true)
  returning id into v_timed;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, requires_photo)
  values (v_b, gen_random_uuid(), 'Their sketchbook', 'do', 'daily', true)
  returning id into v_theirs;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);

  -- Filed as the doer so it takes the same-day branch. A window fixed at 10:00 rather than
  -- around the clock this file happens to run at: the trigger compares the *tap's* time of day
  -- against the window, never `now()`.
  perform set_config('role', 'authenticated', true);
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_a, v_timed, gen_random_uuid(), 'held', v_at)
  returning id into v_claim;
  perform set_config('role', 'postgres', true);

  -- -------------------------------------------------------------------------------
  -- 1. A photo on a commitment and a day, with the owner derived rather than believed.
  --
  -- The client sends the *wrong* owner deliberately. Everything about the bucket's privacy
  -- rests on `owner_id` being the parent's own (NFR4), which only holds if a client cannot
  -- claim a different one.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  insert into public.evidence (commitment_id, for_day, owner_id, storage_path, captured_on)
  values (v_kept, v_day, v_b, v_kept::text || '/sketch.jpg', v_day);

  -- No claim, no due time, no open window was needed to reach either of these -- and the
  -- abstention is a kind that cannot carry a time at all.
  insert into public.evidence (commitment_id, for_day, owner_id, storage_path, captured_on)
  values (v_abstain, v_day, v_a, v_abstain::text || '/bedside.jpg', v_day);
  perform set_config('role', 'postgres', true);

  select owner_id into v_owner from public.evidence where commitment_id = v_kept;

  if v_owner <> v_a then
    raise exception using message = format(
      'Evidence came back owned by %s after the client sent %s. The owner is derived from '
      'the commitment it belongs to, never believed.', v_owner, v_b);
  end if;

  -- Evidence is a list, not a column: a second photo on the same commitment-day is ordinary,
  -- exactly as a second photo on one claim is.
  perform set_config('role', 'authenticated', true);
  insert into public.evidence (commitment_id, for_day, owner_id, storage_path, captured_on)
  values (v_kept, v_day, v_a, v_kept::text || '/sketch-2.jpg', v_day);
  perform set_config('role', 'postgres', true);

  select count(*) into v_count from public.evidence where commitment_id = v_kept;
  if v_count <> 2 then
    raise exception using message = format(
      'A commitment-day holds %s photo(s). Evidence is a list, and a second one is not a '
      'duplicate.', v_count);
  end if;

  raise notice using message =
    'Step 1 ok: a commitment of any kind can hold a photo for its own day with no claim and '
    'no window, the owner is derived from the commitment, and the day holds more than one.';

  -- -------------------------------------------------------------------------------
  -- 2. What the table refuses about its own shape, and which rule does the refusing.
  --
  -- Every malformed row in the story's I/O matrix. Each case asserts the SQLSTATE and the
  -- specific constraint or message it is meant to prove, rather than accepting any refusal at
  -- all: a `when others` matrix passes just as green when every row is being turned away for a
  -- reason nobody intended, and two of these cases were doing exactly that.
  --
  -- Ordering matters to how these are built. A BEFORE ROW trigger runs *before* the table's
  -- CHECK constraints, so a case meant to prove a constraint has to get past
  -- `evidence_derive_owner()` first -- which is why every parent id below is a real one and why
  -- each path leads with whichever parent `coalesce(appeal_id, declaration_id, commitment_id)`
  -- will pick. A case built with a fake id proves only that the trigger cannot find it.
  --
  -- `for_day on an appeal` is written against a *claim* rather than an appeal. The constraint is
  -- `(commitment_id is null) = (for_day is null)` -- it names no parent kind, and a declaration
  -- exercises it identically. Building a real appeal needs a settled failed day and a penalty
  -- behind it (see `4-4-*.sql`), which would be a large amount of unrelated machinery to prove
  -- the same one line.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'no parent at all',
    'two parents',
    'for_day on an appeal',
    'a commitment with no for_day',
    'a path outside the commitment',
    'no capture date',
    'captured another day',
    'a day that has already ended',
    'a day that has not arrived'
  ]
  loop
    v_refused := false;
    v_state := null;
    v_constraint := null;
    v_message := null;

    -- 23514 is check_violation; P0001 is raise_exception, which is what the trigger uses.
    --
    -- `no parent at all` is a trigger refusal rather than a constraint one, and that is the
    -- intended order rather than an accident: a BEFORE ROW trigger runs first, and with no
    -- parent at all there is no owner to derive, so it stops there and says so. The constraint
    -- is the backstop behind it and is proved on its own terms in step 2b.
    v_want_state := case v_case
      when 'no parent at all' then 'P0001'
      when 'no capture date' then 'P0001'
      when 'captured another day' then 'P0001'
      when 'a day that has already ended' then 'P0001'
      when 'a day that has not arrived' then 'P0001'
      else '23514'
    end;

    v_want_token := case v_case
      when 'no parent at all' then 'Evidence does not reference a commitment that exists.'
      when 'two parents' then 'evidence_exactly_one_parent'
      when 'for_day on an appeal' then 'evidence_for_day_belongs_to_a_commitment'
      when 'a commitment with no for_day' then 'evidence_for_day_belongs_to_a_commitment'
      when 'a path outside the commitment' then 'evidence_storage_path_leads_with_its_parent'
      when 'no capture date' then 'Evidence must be dated the day it proves.'
      when 'captured another day' then 'Evidence must be dated the day it proves.'
      else 'A photo can only be kept on the day it belongs to'
    end;

    perform set_config('role', 'authenticated', true);
    begin
      insert into public.evidence
        (commitment_id, declaration_id, for_day, owner_id, storage_path, captured_on)
      values (
        case v_case
          when 'no parent at all' then null
          when 'for_day on an appeal' then null
          else v_kept
        end,
        -- A real claim, so the trigger's declaration branch passes and the row reaches the
        -- constraints. `two parents` then trips the count; `for_day on an appeal` trips the
        -- biconditional, since `for_day` is set with no commitment beside it.
        case v_case
          when 'two parents' then v_claim
          when 'for_day on an appeal' then v_claim
        end,
        case v_case
          when 'no parent at all' then null
          when 'a commitment with no for_day' then null
          when 'a day that has already ended' then v_day - 1
          when 'a day that has not arrived' then v_day + 1
          else v_day
        end,
        v_a,
        -- Leads with whatever `coalesce(appeal_id, declaration_id, commitment_id)` will pick,
        -- so `evidence_storage_path_leads_with_its_parent` is satisfied everywhere except the
        -- one case that exists to violate it.
        case v_case
          when 'a path outside the commitment' then gen_random_uuid()::text || '/elsewhere.jpg'
          when 'two parents' then v_claim::text || '/two-parents.jpg'
          when 'for_day on an appeal' then v_claim::text || '/stray-for-day.jpg'
          else v_kept::text || '/' || replace(v_case, ' ', '-') || '.jpg'
        end,
        case v_case
          when 'no capture date' then null
          when 'captured another day' then v_day - 3
          when 'a day that has already ended' then v_day - 1
          when 'a day that has not arrived' then v_day + 1
          else v_day
        end);
    exception when others then
      v_refused := true;
      get stacked diagnostics
        v_state = returned_sqlstate,
        v_constraint = constraint_name,
        v_message = message_text;
    end;
    perform set_config('role', 'postgres', true);

    if not v_refused then
      raise exception using message = format(
        'The database accepted evidence described as "%s".', v_case);
    end if;

    v_got := coalesce(nullif(v_constraint, ''), v_message);

    if v_state <> v_want_state or position(v_want_token in v_got) = 0 then
      raise exception using message = format(
        'Evidence described as "%s" was refused, but by the wrong rule: expected SQLSTATE %s '
        'naming "%s", got SQLSTATE %s naming "%s". A refusal for an unintended reason proves '
        'nothing about the rule this case exists for.',
        v_case, v_want_state, v_want_token, v_state, v_got);
    end if;
  end loop;

  raise notice using message =
    'Step 2 ok: no parent, two parents, a stray for_day, a commitment with no for_day, a path '
    'outside the commitment, a missing capture date, a wrong one, a day already ended and a '
    'day not yet arrived are each refused by the named rule they exist to prove.';

  -- -------------------------------------------------------------------------------
  -- 2b. The zero-parent arm of the constraint itself.
  --
  -- The trigger gets there first in every reachable path, which is why step 2 asserts the
  -- trigger's own message for that case. The constraint is still the thing that makes a
  -- parentless row impossible rather than merely unreachable -- a later edit to the trigger
  -- must not be able to open that door silently -- so it is proved here with the trigger out of
  -- the way. Disabled and re-enabled inside the transaction that rolls back, touching nothing.
  -- -------------------------------------------------------------------------------
  alter table public.evidence disable trigger evidence_derive_owner;

  v_refused := false;
  v_state := null;
  v_constraint := null;
  begin
    insert into public.evidence (owner_id, storage_path, captured_on)
    values (v_a, gen_random_uuid()::text || '/orphan.jpg', v_day);
  exception when others then
    v_refused := true;
    get stacked diagnostics
      v_state = returned_sqlstate,
      v_constraint = constraint_name;
  end;

  alter table public.evidence enable trigger evidence_derive_owner;

  if not v_refused or v_state <> '23514'
     or coalesce(v_constraint, '') <> 'evidence_exactly_one_parent' then
    raise exception using message = format(
      'A parentless evidence row reached the table with the trigger out of the way (refused: '
      '%s, SQLSTATE %s, constraint %s). The three-way count is what makes it impossible.',
      v_refused, coalesce(v_state, 'none'), coalesce(v_constraint, 'none'));
  end if;

  raise notice using message =
    'Step 2b ok: with the trigger disabled, evidence_exactly_one_parent is what refuses a row '
    'with no parent at all.';

  -- -------------------------------------------------------------------------------
  -- 3. A photo cannot be kept against another account's commitment.
  --
  -- No application check is involved and none should be: the trigger derives the owner from
  -- the commitment, so the row comes out owned by account b, and `evidence: file own`'s own
  -- `auth.uid() = owner_id` refuses it on the way out (AD-7).
  -- -------------------------------------------------------------------------------
  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.evidence (commitment_id, for_day, owner_id, storage_path, captured_on)
    values (v_theirs, v_day, v_a, v_theirs::text || '/theirs.jpg', v_day);
  exception when others then
    v_refused := true;
    get stacked diagnostics v_state = returned_sqlstate;
  end;
  perform set_config('role', 'postgres', true);

  -- 42501 is insufficient_privilege, which is what an RLS `with check` failure raises.
  if not v_refused or v_state <> '42501' then
    raise exception using message = format(
      'One account kept a photo against another account''s commitment, or was stopped by '
      'something other than RLS (SQLSTATE %s). It must not exist at all, and the policy is '
      'what must say so.', coalesce(v_state, 'none'));
  end if;

  raise notice using message =
    'Step 3 ok: evidence naming another account''s commitment is refused by RLS.';

  -- -------------------------------------------------------------------------------
  -- 4. The bucket, and the folder that leads with the commitment's own id.
  --
  -- This is the half no metadata row can prove. `storage.foldername(name)[1]` is what the two
  -- object policies read to derive access, and the third `exists` branch added by this story is
  -- what makes a commitment's folder reachable at all. The positive cases are asserted alongside
  -- the refusals -- and asserted *under the authenticated role*, never as `postgres`, which
  -- bypasses RLS and would report success for a policy that grants nothing. The pair has to stay
  -- symmetrical: an object that can be uploaded and then not read is worse than neither.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_kept::text || '/sketch.jpg', v_a);

  select count(*) into v_count from storage.objects
   where bucket_id = 'appeal-evidence' and name = v_kept::text || '/sketch.jpg';
  perform set_config('role', 'postgres', true);

  if v_count <> 1 then
    raise exception using message = format(
      'The owner uploaded into his own commitment''s folder but read back %s object(s) through '
      'the SELECT policy, expected 1 -- the two "owner ... own" policies have to carry the same '
      'third `exists` branch or an object becomes uploadable and then unreadable.', v_count);
  end if;

  -- Account b, against account a's commitment folder.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b, 'role', 'authenticated')::text, true);

  v_refused := false;
  perform set_config('role', 'authenticated', true);
  begin
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_kept::text || '/stolen.jpg', v_b);
  exception when others then
    v_refused := true;
  end;

  if not v_refused then
    perform set_config('role', 'postgres', true);
    raise exception using message =
      'Another doer uploaded into a commitment folder that is not his. The bucket''s access '
      'derives from the folder''s own parent row and nothing else (NFR4).';
  end if;

  -- Re-set rather than assumed: the failed insert above aborted a subtransaction, and a
  -- transaction-local `set_config` made inside one goes back with it. Without this line the
  -- read below could run as `postgres`, which bypasses RLS and would pass for the wrong reason.
  perform set_config('role', 'authenticated', true);

  select count(*) into v_count from storage.objects
   where bucket_id = 'appeal-evidence' and name = v_kept::text || '/sketch.jpg';
  perform set_config('role', 'postgres', true);

  if v_count <> 0 then
    raise exception using message = format(
      'A doer session read %s row(s) of another account''s commitment-day evidence object -- '
      'only its own owner may ever read it (NFR4).', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: the owner uploads into his own commitment''s folder and reads it back through '
    'RLS; another doer can neither upload into it nor read what is there.';

  -- -------------------------------------------------------------------------------
  -- 5. The referee stops here.
  --
  -- `Today` promises, in the hint under this control, that the photo "is private -- only you can
  -- open it". Two policies written before this parent kind existed made that false: neither
  -- `evidence: referee reads all` nor `appeal-evidence objects: referee reads all` was scoped to
  -- a parent kind, so a referee read both the row and the object for a private record kept
  -- against an `abstain` commitment -- something no verdict of his will ever touch. Both were
  -- narrowed by this story, and this is the step that holds them narrowed.
  --
  -- The claim shape is `4-6-the-referee-rules.sql:725-727`'s own: `role_from_token()` reads
  -- `app_role` from the JWT, so a referee session is a real one here.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select count(*) into v_count from public.evidence where commitment_id is not null;
  if v_count <> 0 then
    raise exception using message = format(
      'A referee session read %s commitment-day evidence row(s). The photo answers for no '
      'verdict of his, and the screen that offered it said only the author could open it.',
      v_count);
  end if;

  select count(*) into v_count from storage.objects
   where bucket_id = 'appeal-evidence' and name = v_kept::text || '/sketch.jpg';
  if v_count <> 0 then
    raise exception using message = format(
      'A referee session read %s commitment-day evidence object(s) through storage.objects. '
      'Narrowing the table policy alone leaves the picture itself readable.', v_count);
  end if;

  -- And the half that must NOT have moved: a claim's evidence is what Story 6.7 is being built
  -- to let him object to, so narrowing to appeal-only would have broken that before it began.
  perform set_config('role', 'postgres', true);
  insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
  values (v_claim, v_a, v_claim::text || '/proof.jpg', v_day);
  insert into storage.objects (bucket_id, name, owner)
  values ('appeal-evidence', v_claim::text || '/proof.jpg', v_a);

  perform set_config('role', 'authenticated', true);

  select count(*) into v_count from public.evidence where declaration_id = v_claim;
  if v_count <> 1 then
    raise exception using message = format(
      'The referee read %s row(s) of a claim''s evidence, expected 1. This story narrows away '
      'the commitment-day kind and nothing else.', v_count);
  end if;

  select count(*) into v_count from storage.objects
   where bucket_id = 'appeal-evidence' and name = v_claim::text || '/proof.jpg';
  if v_count <> 1 then
    raise exception using message = format(
      'The referee read %s object(s) of a claim''s evidence, expected 1. An appeal-only '
      'predicate would hide exactly the timed proofs Story 6.7 exists to show him.', v_count);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 5 ok: a commitment-day photo reaches the referee as neither row nor object, and a '
    'claim''s evidence reaches him exactly as it did before.';

  -- -------------------------------------------------------------------------------
  -- 6. The photo decides nothing, at the one reader it could have leaked into.
  --
  -- `timed_claim_today.proven` is the existence of an `evidence` row keyed on `declaration_id`
  -- -- the same existence test `commitments_owing()` applies when it decides whether a timed
  -- claim reports `held` or `slipped`. A commitment-parented row carries no `declaration_id`,
  -- so it matches neither, and that is the whole reason settlement is untouched by this story.
  --
  -- Run against a *second* commitment-day photo on the timed commitment, with the claim's own
  -- proof from step 5 deleted first, so `proven` has nothing but the new kind to go on.
  -- -------------------------------------------------------------------------------
  delete from public.evidence where declaration_id = v_claim;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);

  perform set_config('role', 'authenticated', true);
  insert into public.evidence (commitment_id, for_day, owner_id, storage_path, captured_on)
  values (v_timed, v_day, v_a, v_timed::text || '/pill.jpg', v_day);

  select proven into v_proven from public.timed_claim_today where commitment_id = v_timed;
  perform set_config('role', 'postgres', true);

  if v_proven is not false then
    raise exception using message = format(
      'timed_claim_today read proven = %s for a commitment whose only photo is a '
      'commitment-day record. A photo that decides nothing must not answer a timed day (D1).',
      coalesce(v_proven::text, 'null'));
  end if;

  raise notice using message =
    'Step 6 ok: a commitment-day photo does not prove a timed claim, so no settlement path '
    'can see it.';

  raise notice using message =
    'PASS. A commitment of any kind holds a photo for its own day, its owner is derived from '
    'the commitment, every malformed shape is refused by its own rule, the folder is private '
    'to its owner, the referee cannot reach it, and nothing that decides a day can see it.';
end $$;

rollback;
