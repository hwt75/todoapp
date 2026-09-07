-- A referee belongs to one doer.
--
-- Seven RLS policies grant the referee reads with no owner comparison at all -- `appeal`,
-- `evidence`, `settlement`, `penalty`, `commitment`, `silence_episode` and the evidence bucket,
-- every one of them `using (role_from_token() = 'referee')`. That was deliberate and documented:
-- `profile_single_referee` makes exactly one referee exist system-wide, authorised by the one real
-- account, and `20260824160000` accepted the unscoped reach explicitly because it was read-only.
--
-- The moment a second referee can exist, that argument is gone and every one of those policies is
-- a hole. So the scoping lands first, on its own, and this file is what says it landed: one paired
-- referee, two doers with identical data, and the referee sees exactly one of them.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/a-referee-belongs-to-one-doer.sql
--
-- One transaction, rolled back at the end.

begin;

grant select on table public.profile, public.commitment, public.appeal, public.evidence,
                      public.settlement, public.penalty, public.silence_episode to authenticated;
grant select on table storage.objects to authenticated;

insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;

do $$
declare
  v_mine     uuid := gen_random_uuid();  -- the doer this referee was invited by
  v_theirs   uuid := gen_random_uuid();  -- an unrelated account, whose data must stay invisible
  v_ref      uuid := gen_random_uuid();
  v_unpaired uuid := gen_random_uuid();  -- a referee whose pairing was never recorded

  v_day      date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 3;

  v_c        uuid;
  v_s        uuid;
  v_p        uuid;
  v_appeal   uuid;
  v_owner    uuid;
  v_case     text;
  v_seen     integer;
  v_path     text;
begin
  foreach v_case in array array['mine', 'theirs', 'ref']
  loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (case v_case when 'mine' then v_mine when 'theirs' then v_theirs
                        else v_ref end,
            '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'one-doer-' || v_case || '-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  update public.profile set role = 'referee' where id = v_ref;

  -- Identical data for both doers, so anything the referee can see of `theirs` is scoping failing
  -- rather than a fixture difference.
  foreach v_case in array array['mine', 'theirs']
  loop
    v_owner := case v_case when 'mine' then v_mine else v_theirs end;

    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
    values (v_owner, gen_random_uuid(), 'Gym', 'do', 'daily', true)
    returning id into v_c;

    insert into public.settlement (subject, period, kind, verdict, missed_count)
    values (v_owner, v_day, 'day', 'failed', 1)
    returning id into v_s;

    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    values (v_s, v_owner, v_c, 'missed');

    insert into public.penalty (subject, settlement_id, amount_dong, state)
    values (v_owner, v_s, 500000, 'owed')
    returning id into v_p;

    -- The miss the appeal contests has to be the machine's, and machine-filed rows derive the
    -- previous day -- hence answering on v_day + 1 to land on v_day.
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer,
                                    answered_at, filed_by)
    values (v_owner, v_c, gen_random_uuid(), 'slipped',
            ((v_day + 1)::timestamp + interval '3 hours') at time zone 'Asia/Ho_Chi_Minh',
            'auto_check');

    insert into public.appeal (owner_id, commitment_id, idempotency_key, for_day, settlement_id,
                               penalty_id, deadline)
    values (v_owner, v_c, gen_random_uuid(), v_day, v_s, v_p, now() + interval '2 days')
    returning id into v_appeal;

    insert into public.silence_episode (owner_id, started_day, escalated_at)
    values (v_owner, v_day, now());

    -- An appeal's own evidence: the parent kind the referee exists to read. A commitment-day row
    -- is already hidden from him by 6.8, and a claim's row for a day this old is refused outright
    -- by `evidence_derive_owner()` -- neither would measure scoping.
    v_path := v_appeal::text || '/proof.jpg';

    insert into public.evidence (appeal_id, storage_path, captured_on)
    values (v_appeal, v_path, v_day);

    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_path, v_owner);
  end loop;

  -- The pairing itself: an invitation `mine` minted and this referee accepted.
  insert into public.referee_invite (email, token_hash, expires_at, created_by,
                                     accepted_at, accepted_by)
  values ('ref@example.test', encode(digest(gen_random_uuid()::text, 'sha256'), 'hex'),
          now() + interval '3 days', v_mine, now(), v_ref);

  -- The pairing as a record, which is what every policy now reads. Stage 2 makes
  -- `accept-referee-invite` write this; here it is the input the reads are measured against.
  update public.profile set referee_of = v_mine where id = v_ref;

  -- -------------------------------------------------------------------------------
  -- The paired referee sees his own doer, and only his own doer.
  -- -------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ref, 'role', 'authenticated', 'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  foreach v_case in array array[
    'commitment', 'appeal', 'settlement', 'penalty', 'silence_episode', 'evidence', 'object'
  ]
  loop
    v_seen := case v_case
                when 'commitment' then (select count(*) from public.commitment where owner_id = v_theirs)
                when 'appeal' then (select count(*) from public.appeal where owner_id = v_theirs)
                when 'settlement' then (select count(*) from public.settlement where subject = v_theirs)
                when 'penalty' then (select count(*) from public.penalty where subject = v_theirs)
                when 'silence_episode' then (select count(*) from public.silence_episode where owner_id = v_theirs)
                when 'evidence' then (select count(*) from public.evidence where owner_id = v_theirs)
                else (select count(*) from storage.objects
                       where bucket_id = 'appeal-evidence' and owner = v_theirs)
              end;

    if v_seen <> 0 then
      raise exception using message = format(
        'The referee read %s row(s) of `%s` belonging to an account he was never paired to. '
        'Every one of these policies is `role_from_token() = ''referee''` with no owner '
        'comparison, which was only ever safe because exactly one referee could exist; the '
        'product is about to allow more.', v_seen, v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 1 ok: a paired referee sees nothing belonging to an account he was not paired to, '
    'across all seven surfaces.';

  -- -------------------------------------------------------------------------------
  -- And still sees everything of his own doer, which is the half that must not break.
  -- -------------------------------------------------------------------------------
  foreach v_case in array array[
    'commitment', 'appeal', 'settlement', 'penalty', 'silence_episode', 'evidence', 'object'
  ]
  loop
    v_seen := case v_case
                when 'commitment' then (select count(*) from public.commitment where owner_id = v_mine)
                when 'appeal' then (select count(*) from public.appeal where owner_id = v_mine)
                when 'settlement' then (select count(*) from public.settlement where subject = v_mine)
                when 'penalty' then (select count(*) from public.penalty where subject = v_mine)
                when 'silence_episode' then (select count(*) from public.silence_episode where owner_id = v_mine)
                when 'evidence' then (select count(*) from public.evidence where owner_id = v_mine)
                else (select count(*) from storage.objects
                       where bucket_id = 'appeal-evidence' and owner = v_mine)
              end;

    if v_seen <> 1 then
      raise exception using message = format(
        'The referee read %s row(s) of `%s` belonging to the doer who invited him, expected 1. '
        'Scoping must narrow what he sees of other accounts, never take away the account he '
        'exists to rule on.', v_seen, v_case);
    end if;
  end loop;

  raise notice using message =
    'Step 2 ok: the paired referee still reads every surface of his own doer.';

  -- -------------------------------------------------------------------------------
  -- A referee with no recorded pairing sees nothing at all, rather than everything.
  --
  -- The direction of failure is the whole safety argument. Every policy compares an owner
  -- against `profile.referee_of`, and a null on either side matches nothing -- so a pairing that
  -- was never written, or could not be resolved, costs a referee his own account's rows and
  -- costs nobody else theirs. A second referee row is possible here only because Stage 2 dropped
  -- `profile_single_referee`.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_unpaired, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'one-doer-unpaired-' || gen_random_uuid()::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  update public.profile set role = 'referee' where id = v_unpaired;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_unpaired, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);
  perform set_config('role', 'authenticated', true);

  v_seen := (select count(*) from public.appeal)
          + (select count(*) from public.settlement)
          + (select count(*) from public.penalty)
          + (select count(*) from public.commitment)
          + (select count(*) from public.silence_episode)
          + (select count(*) from public.evidence)
          + (select count(*) from storage.objects where bucket_id = 'appeal-evidence');

  if v_seen <> 0 then
    raise exception using message = format(
      'A referee with no recorded pairing read %s row(s). An unresolved pairing has to fail '
      'closed: seeing nothing is a visible, harmless bug, and seeing everything is the hole '
      'this whole change exists to close.', v_seen);
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 3 ok: an unpaired referee reads nothing, rather than everything.';

  raise notice using message =
    'PASS. A referee reads exactly the account that invited him -- every appeal, photo, '
    'settlement, penalty, commitment and silence episode of that doer, and none of anyone '
    'else''s -- and a referee with no pairing at all reads nothing.';
end $$;

rollback;
