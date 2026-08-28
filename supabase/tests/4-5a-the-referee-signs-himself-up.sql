-- Story 4.5a — The referee signs himself up, from an invitation the doer minted.
--
-- Covers everything `20260828120000_the_referee_signs_himself_up.sql` claims and the Edge
-- Functions then lean on: that at most one invitation can be outstanding at a time whatever
-- the timing, that `outstanding` actually follows the two columns it is generated from, that
-- a doer reads his own invitations and nobody else's, and that an `authenticated` session
-- cannot write this table at all — which is what makes "every write is an Edge Function
-- holding the service role" a fact about the database rather than a convention in prose.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/4-5a-the-referee-signs-himself-up.sql
--
-- One transaction, rolled back at the end. Nothing persists.
--
-- Unlike every other file in this directory, this one grants `authenticated` nothing before
-- it starts. It does not need to: the migration under test grants `select` and revokes the
-- rest explicitly, precisely so that a refusal here means the same thing on the local stack
-- and on the live project. `4-5`'s own header records why the other files cannot assume that
-- — they test tables whose privileges come from whatever Supabase provisioned.

begin;

do $$
declare
  -- The live doer: the only account `invite-referee` will mint for. Its liveness is not
  -- exercised here (that check lives in the Edge Function, which this file does not run);
  -- what matters below is that it is the account whose id lands in `created_by`.
  v_doer        uuid := gen_random_uuid();
  -- A second, ordinary doer. Exists to prove the read policy is a filter on `created_by` and
  -- not merely "any authenticated session sees the invitations table".
  v_other       uuid := gen_random_uuid();

  v_first       uuid;
  v_second      uuid;
  v_count       integer;
  v_outstanding boolean;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'invite-4-5a-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_doer, v_other]) as t(id);

  -- `on_auth_user_created` has already created both profiles as `doer`.

  -- -------------------------------------------------------------------------------
  -- 1. One outstanding invitation at a time. The index, not the Edge Function's own
  --    check-then-act, is what makes this true against concurrency -- so it is proven by
  --    attempting the second insert directly, with no application code in the way.
  -- -------------------------------------------------------------------------------
  insert into public.referee_invite (email, token_hash, created_by, expires_at)
  values ('ref@example.test', repeat('a', 64), v_doer, now() + interval '72 hours')
  returning id into v_first;

  begin
    insert into public.referee_invite (email, token_hash, created_by, expires_at)
    values ('other@example.test', repeat('b', 64), v_doer, now() + interval '72 hours');

    raise exception using message =
      'A second outstanding invitation was accepted. referee_invite_single_outstanding is '
      'not doing its job, and two live links to one unrepeatable referee slot can exist.';
  exception when unique_violation then
    null; -- Exactly what the index promises.
  end;

  raise notice using message =
    'Step 1 ok: a second outstanding invitation is refused by the index outright.';

  -- -------------------------------------------------------------------------------
  -- 2. Revoking frees the slot, and `outstanding` follows the columns it is generated
  --    from. This is the sequence `invite-referee` performs on every re-mint, so if the
  --    generated column were wrong in either direction the doer would be permanently
  --    unable to replace a link he had already sent.
  -- -------------------------------------------------------------------------------
  select outstanding into v_outstanding from public.referee_invite where id = v_first;
  if v_outstanding is not true then
    raise exception using message =
      'A fresh invitation is not outstanding. Nothing would ever occupy the slot, and the '
      'single-outstanding guarantee would be vacuous.';
  end if;

  update public.referee_invite set revoked_at = now() where id = v_first;

  select outstanding into v_outstanding from public.referee_invite where id = v_first;
  if v_outstanding is not false then
    raise exception using message =
      'A revoked invitation still reads as outstanding. The doer could never mint a '
      'replacement for a link already in someone else''s hands.';
  end if;

  insert into public.referee_invite (email, token_hash, created_by, expires_at)
  values ('other@example.test', repeat('b', 64), v_doer, now() + interval '72 hours')
  returning id into v_second;

  -- And an accepted one vacates the slot on the same terms as a revoked one, through the
  -- other half of the generated expression.
  update public.referee_invite
     set accepted_at = now(), accepted_by = v_other
   where id = v_second;

  select outstanding into v_outstanding from public.referee_invite where id = v_second;
  if v_outstanding is not false then
    raise exception using message =
      'An accepted invitation still reads as outstanding.';
  end if;

  raise notice using message =
    'Step 2 ok: revoking and accepting both vacate the slot, and a replacement mints.';

  -- -------------------------------------------------------------------------------
  -- 3. Expiry is deliberately NOT part of `outstanding`. An expired-but-unspent invitation
  --    keeps occupying the slot until something revokes it, because the index predicate has
  --    to be immutable and `now()` is not. Asserted rather than left implicit: a future
  --    reader who "fixes" this by folding expiry in would silently allow two live links
  --    the moment one of them aged out.
  -- -------------------------------------------------------------------------------
  update public.referee_invite
     set accepted_at = null, accepted_by = null, expires_at = now() - interval '1 hour'
   where id = v_second;

  select outstanding into v_outstanding from public.referee_invite where id = v_second;
  if v_outstanding is not true then
    raise exception using message =
      'An expired invitation stopped being outstanding on its own. The single-outstanding '
      'index predicate would then depend on the clock, which it cannot.';
  end if;

  raise notice using message =
    'Step 3 ok: expiry does not vacate the slot -- only revoking or accepting does.';

  -- -------------------------------------------------------------------------------
  -- 4. RLS: a doer reads the invitations he minted, and no others read them at all.
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_doer, 'role', 'authenticated', 'app_role', 'doer')::text,
    true);

  select count(*) into v_count from public.referee_invite;
  if v_count <> 2 then
    raise exception using message = format(
      'The minting doer read %s of his own 2 invitation rows. Settings cannot tell him what '
      'is already outstanding.', v_count);
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other, 'role', 'authenticated', 'app_role', 'doer')::text,
    true);

  select count(*) into v_count from public.referee_invite;
  if v_count <> 0 then
    raise exception using message = format(
      'A second doer read %s invitation row(s) minted by someone else. The token hash and '
      'the invited address are both readable to an account that has no business with '
      'either.', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: `referee_invite: read own` filters to the minting account.';

  -- -------------------------------------------------------------------------------
  -- 5. No `authenticated` session writes this table, by privilege rather than by policy.
  --    Proven by attempt on all three verbs, still as the second doer -- an account that
  --    could insert here could mint itself an invitation and take the referee slot the
  --    live-doer check exists to protect.
  -- -------------------------------------------------------------------------------
  begin
    insert into public.referee_invite (email, token_hash, created_by, expires_at)
    values ('self@example.test', repeat('c', 64), v_other, now() + interval '72 hours');

    raise exception using message =
      'An authenticated session inserted an invitation. Any self-registered doer could mint '
      'itself the referee slot, which is the whole escalation the live-doer check prevents.';
  exception when insufficient_privilege or check_violation then
    null;
  end;

  begin
    update public.referee_invite set expires_at = now() + interval '1 year';

    raise exception using message =
      'An authenticated session updated an invitation -- an expired or revoked link could be '
      'brought back to life by its holder.';
  exception when insufficient_privilege then
    null;
  end;

  begin
    delete from public.referee_invite;

    raise exception using message =
      'An authenticated session deleted invitations -- the record of what was minted, and '
      'the row that occupies the single outstanding slot, are both removable by a client.';
  exception when insufficient_privilege then
    null;
  end;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 5 ok: insert, update and delete are all refused to an authenticated session.';

  -- -------------------------------------------------------------------------------
  -- 6. The acceptance still cannot produce a second referee. `accept-referee-invite`
  --    promotes with a plain update and treats 23505 as a refusal; this is the constraint
  --    that makes that refusal real, restated here in the invitation's own context because
  --    an invite flow is a second door into the slot `4-5` proved single for the first.
  -- -------------------------------------------------------------------------------
  update public.profile set role = 'referee' where id = v_other;

  begin
    update public.profile set role = 'referee' where id = v_doer;

    raise exception using message =
      'A second profile reached role = referee through the invitation path. The invite flow '
      'has opened a hole profile_single_referee closed for pairing.';
  exception when unique_violation then
    null;
  end;

  raise notice using message =
    'Step 6 ok: profile_single_referee still refuses a second referee, invitation or not.';

  raise notice using message =
    'All steps passed: one outstanding invitation at a time, a slot vacated only by revoking '
    'or accepting, reads scoped to the minting doer, no client writes at all, and still at '
    'most one referee.';
end;
$$;

rollback;
