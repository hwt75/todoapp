-- Story 8.1 — a commitment can ask for the referee's signature.
--
-- Nothing reads the flag yet, so there is no verdict to assert against and no settlement path to
-- drive. What there is instead is a reader that later stories will judge money by, and the whole
-- point of it is a fact that must survive a change made *after* it. A test that only checked
-- "does the column store true" would pass against a live read, which is exactly the defect this
-- migration exists to prevent — the Epic 6 retrospective's item 50, where three defects in one
-- day were all that shape.
--
-- So: the reader across both its branches, the mid-day switch in each direction, the four
-- refusals, the log's own discipline, and the negative that matters most — an unflagged
-- commitment is untouched by all of it.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/8-1-a-commitment-can-ask-for-the-referee-s-signature.sql
--
-- One transaction, rolled back at the end. Nothing persists, and nothing here settles a day, so
-- it is safe against any database. No `ci-clock-window` marker is needed: every instant this file
-- compares is one it wrote itself, and nothing depends on the hour the test runs at.

begin;

-- The one grant this migration makes, asserted rather than re-issued.
--
-- Step 9 below drives has_paired_referee() through a `request.jwt.claims` session, but the whole
-- file runs as `postgres`, which may execute anything. If `grant execute … to authenticated` were
-- lost, Step 9 would still pass and every doer would see the sign-off control permanently greyed
-- with "Nobody to ask yet" — the feature dead, the suite green. Granting it here would paper over
-- exactly that, which is why this only asks. The idiom is
-- 6-6-the-reminder-lands-inside-the-window.sql:41-60's.
do $$
begin
  if not has_function_privilege('authenticated', 'public.has_paired_referee()', 'execute') then
    raise exception using message =
      '`authenticated` cannot EXECUTE public.has_paired_referee(). It is the only part of Story '
      '8.1 the client may call, and without it the sign-off control is greyed for every doer '
      'with the one sentence that is certainly wrong — re-granting it here would hide precisely '
      'that breakage.';
  end if;

  -- The other direction, because a `drop function` destroys the ACL and a bare `create` in
  -- `public` hands EXECUTE straight back to PUBLIC, `anon` included.
  if has_function_privilege('anon', 'public.has_paired_referee()', 'execute') then
    raise exception using message =
      '`anon` can EXECUTE public.has_paired_referee(). It is security definer and reads profile; '
      'a signed-out caller has no account for it to answer about.';
  end if;

  raise notice using message =
    'Precondition ok: has_paired_referee() is executable by `authenticated` and not by `anon`, '
    'and nothing is granted by this file.';
end;
$$;

do $$
declare
  -- The doer everything below belongs to, and the referee paired to him.
  v_doer     uuid := gen_random_uuid();
  v_ref      uuid := gen_random_uuid();
  -- A second doer with no referee at all, for the refusal a CHECK cannot make.
  v_lonely   uuid := gen_random_uuid();

  v_today    date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_d        date;

  v_c1       uuid;  -- switched on mid-day
  v_c2       uuid;  -- flagged since D-10, switched off today
  v_c3       uuid;  -- created flagged today, asked about a day before it existed
  v_c4       uuid;  -- never flagged, and untouched by every one of these rules
  v_c5       uuid;  -- the log's own discipline
  v_c6       uuid;  -- an entry stamped at exactly the day's first instant
  v_c7       uuid;  -- the update trigger's own refusal

  v_case     text;
  v_refused  boolean;
  v_message  text;
  v_constraint text;
  v_count    integer;
  v_answer   boolean;
begin
  v_d := v_today - 5;

  -- -------------------------------------------------------------------------------
  -- Fixture: a doer, his referee, and an unpaired doer.
  -- -------------------------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'sign-off-8-1-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_doer, v_ref, v_lonely]) as t(id);

  -- `referee_of` lives on the *referee's* row and points at the doer (20260907160000:29).
  update public.profile set role = 'referee', referee_of = v_doer where id = v_ref;

  -- =================================================================================
  -- Step 1: the reader's day-start branch, and a flag switched on mid-day.
  --
  -- The one property the whole story rests on. A flag switched on at 14:00 on day D governs
  -- nothing on D -- "turning the flag on reaches forward only", as SQL -- and governs every
  -- day after it.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo)
  values (v_doer, gen_random_uuid(), 'Thuốc', 'do', 'daily', true, true)
  returning id into v_c1;

  -- now() is transaction-stable in Postgres, not statement-stable, so two entries written in one
  -- test would tie and the reader would break that tie arbitrarily. Every entry this file cares
  -- about is therefore stamped by hand. (A fixture necessity only: two real requests never share
  -- one now().) The idiom is carries_penalty_freezes_by_day.sql:81-100's.
  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_d) - interval '10 days'
   where commitment_id = v_c1;

  if public.requires_referee_approval_as_of(v_c1, v_d) is distinct from false then
    raise exception using message = format(
      'Step 1 FAILED: an unflagged commitment read %s for a day ten days after its creation. '
      'The entry in force when the day began said false.',
      public.requires_referee_approval_as_of(v_c1, v_d));
  end if;

  -- Switched on through the real UPDATE path, so the real trigger logs it; then stamped at 14:00
  -- on D, part-way through the day.
  update public.commitment set requires_referee_approval = true where id = v_c1;
  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_d) + interval '14 hours'
   where commitment_id = v_c1 and requires_referee_approval;

  if public.requires_referee_approval_as_of(v_c1, v_d) is distinct from false then
    raise exception using message = format(
      'Step 1 FAILED: a flag switched on at 14:00 on day D governed day D itself, reading %s. '
      'The reader takes the value in force when the day BEGAN; the SPEC says turning the flag '
      'on reaches forward only, and this is that rule.',
      public.requires_referee_approval_as_of(v_c1, v_d));
  end if;

  if public.requires_referee_approval_as_of(v_c1, v_d + 1) is distinct from true then
    raise exception using message = format(
      'Step 1 FAILED: the day after the flag was switched on read %s, expected true.',
      public.requires_referee_approval_as_of(v_c1, v_d + 1));
  end if;

  if public.requires_referee_approval_as_of(v_c1, v_d - 1) is distinct from false then
    raise exception using message =
      'Step 1 FAILED: a day before the flag was ever on read true. Nothing done later may '
      'reach backward.';
  end if;

  raise notice 'Step 1 ok: the reader takes the value in force when the day began, so a flag '
    'switched on at 14:00 governs nothing until tomorrow.';

  -- =================================================================================
  -- Step 2: switched off after the fact, and the refusal to veto a day part-way through.
  --
  -- The hole decision 1 refuses. A refusal lands at 21:00 and the author switches the flag off
  -- at 22:00: under a mid-day veto the day would be judged unflagged and the refusal would
  -- evaporate. Under a day-start read with no veto it stands.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Gym', 'do', 'daily', true, true, true)
  returning id into v_c2;

  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_today - 10)
   where commitment_id = v_c2;

  -- Switched off *now*, which is part-way through today.
  update public.commitment set requires_referee_approval = false where id = v_c2;

  if public.requires_referee_approval_as_of(v_c2, v_today - 5) is distinct from true then
    raise exception using message = format(
      'Step 2 FAILED: a day flagged when it happened read %s after the flag was switched off '
      'today. A day already closed is not rewritable by anything that happens afterwards.',
      public.requires_referee_approval_as_of(v_c2, v_today - 5));
  end if;

  foreach v_case in array array['-10', '-9', '-5', '-2', '-1']
  loop
    if public.requires_referee_approval_as_of(v_c2, v_today + v_case::integer)
         is distinct from true then
      raise exception using message = format(
        'Step 2 FAILED: day %s of the ten flagged days read %s after today''s switch-off.',
        v_today + v_case::integer,
        public.requires_referee_approval_as_of(v_c2, v_today + v_case::integer));
    end if;
  end loop;

  if public.requires_referee_approval_as_of(v_c2, v_today) is distinct from true then
    raise exception using message = format(
      'Step 2 FAILED: today read %s after a mid-day switch-off. There is no mid-day veto here: '
      'the value in force when today began was true, and a refusal earned at 21:00 must not be '
      'undone by a switch flipped at 22:00.',
      public.requires_referee_approval_as_of(v_c2, v_today));
  end if;

  if public.requires_referee_approval_as_of(v_c2, v_today + 1) is distinct from false then
    raise exception using message = format(
      'Step 2 FAILED: the day after the switch-off read %s, expected false.',
      public.requires_referee_approval_as_of(v_c2, v_today + 1));
  end if;

  raise notice 'Step 2 ok: ten flagged days stay flagged after the flag is switched off, today '
    'included, and tomorrow is the first day the switch-off governs.';

  -- =================================================================================
  -- Step 3: a day at or before the commitment's own creation -- the second branch.
  --
  -- Without the migration's backfill this branch has nothing to read and the function answers
  -- NULL, which is how a boolean that decides money becomes three-valued.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Sách', 'do', 'daily', true, true, true)
  returning id into v_c3;

  if public.requires_referee_approval_as_of(v_c3, v_today - 30) is distinct from true then
    raise exception using message = format(
      'Step 3 FAILED: a day before this commitment existed read %s rather than the earliest '
      'logged value extrapolated backward. NULL here is the backfill missing.',
      public.requires_referee_approval_as_of(v_c3, v_today - 30));
  end if;

  -- The negative half of the same branch, on a commitment that was never flagged.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_doer, gen_random_uuid(), 'Chạy bộ', 'do', 'daily', true)
  returning id into v_c4;

  if public.requires_referee_approval_as_of(v_c4, v_today - 30) is distinct from false then
    raise exception using message = format(
      'Step 3 FAILED: an unflagged commitment read %s for a day before it existed, expected '
      'false.', public.requires_referee_approval_as_of(v_c4, v_today - 30));
  end if;

  -- The creation day itself, and the day after it. A commitment *created* flagged has no entry
  -- before today began, so it falls to the second branch and reads its earliest logged value --
  -- true -- from its very first day. That is not the mid-day switch-on of Step 1 and must not be
  -- confused with it: there is no earlier day here to reach backward into, and no past verdict to
  -- re-judge. The SPEC's amended matrix row 1.
  if public.requires_referee_approval_as_of(v_c3, v_today) is distinct from true then
    raise exception using message = format(
      'Step 3 FAILED: a commitment created flagged today read %s for today. Its own first day is '
      'governed by the value it was created with -- there is no earlier entry to prefer, and no '
      'day already answered that this could rewrite.',
      public.requires_referee_approval_as_of(v_c3, v_today));
  end if;

  if public.requires_referee_approval_as_of(v_c3, v_today + 1) is distinct from true then
    raise exception using message = format(
      'Step 3 FAILED: a commitment created flagged today read %s for tomorrow.',
      public.requires_referee_approval_as_of(v_c3, v_today + 1));
  end if;

  -- The boundary, asserted deliberately rather than left to a fixture to cross by accident. The
  -- reader compares `changed_at < day_begins_at(p_day)`, strictly, so an entry stamped at exactly
  -- the day's first instant did NOT govern that day: it is a change made during the day it opens,
  -- and a change made during a day never governs that day here.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo)
  values (v_doer, gen_random_uuid(), 'Đúng nửa đêm', 'do', 'daily', true, true)
  returning id into v_c6;

  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_today - 20)
   where commitment_id = v_c6;

  update public.commitment set requires_referee_approval = true where id = v_c6;
  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_d)
   where commitment_id = v_c6 and requires_referee_approval;

  if public.requires_referee_approval_as_of(v_c6, v_d) is distinct from false then
    raise exception using message = format(
      'Step 3 FAILED: an entry stamped at exactly day_begins_at(D) governed day D, reading %s. '
      'The comparison is strict `<` on purpose and the function comment says which way it falls: '
      'midnight belongs to the day it opens, and a change made during a day never governs it.',
      public.requires_referee_approval_as_of(v_c6, v_d));
  end if;

  if public.requires_referee_approval_as_of(v_c6, v_d + 1) is distinct from true then
    raise exception using message = format(
      'Step 3 FAILED: the day after a midnight-stamped entry read %s, expected true.',
      public.requires_referee_approval_as_of(v_c6, v_d + 1));
  end if;

  raise notice 'Step 3 ok: a day at or before the commitment''s own creation reads the earliest '
    'logged value, never NULL; a commitment created flagged is flagged from its first day; and '
    'an entry stamped at exactly midnight governs the day after, not the day it opens.';

  -- =================================================================================
  -- Step 4: the three refusals that are CHECK constraints.
  --
  -- Each attempted for real, and each asserted by the constraint that actually fired -- a
  -- refusal by the wrong rule is a rule that has stopped being the one documented.
  -- =================================================================================
  foreach v_case in array array[
    'an abstention',
    'an open-ended commitment',
    'a commitment a machine already answers for',
    'a commitment with no photo to look at'
  ]
  loop
    v_refused := false;
    v_constraint := null;
    begin
      insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                     carries_penalty, requires_photo,
                                     auto_check_kind, auto_check_account_ref,
                                     requires_referee_approval)
      values (
        v_doer, gen_random_uuid(), 'Refused',
        (case v_case
           when 'an abstention' then 'abstain'
           when 'an open-ended commitment' then 'open_ended'
           else 'do'
         end)::public.commitment_kind,
        'daily', true,
        v_case <> 'a commitment with no photo to look at',
        case when v_case = 'a commitment a machine already answers for'
             then 'account_elsewhere' end::public.auto_check_kind,
        case when v_case = 'a commitment a machine already answers for' then 'my-handle' end,
        true);
    exception when check_violation then
      v_refused := true;
      get stacked diagnostics v_constraint = constraint_name;
    end;

    if not v_refused then
      raise exception using message = format(
        'Step 4 FAILED: the database accepted sign-off on %s. The four refusals are what stop '
        'the flag meaning nothing, and a client mirror alone is a rule only a browser can '
        'exercise.', v_case);
    end if;

    if v_constraint is distinct from (case v_case
         when 'an abstention' then 'commitment_sign_off_needs_a_do'
         when 'an open-ended commitment' then 'commitment_sign_off_needs_a_do'
         when 'a commitment a machine already answers for'
           then 'commitment_sign_off_not_with_auto_check'
         else 'commitment_sign_off_implies_photo'
       end) then
      raise exception using message = format(
        'Step 4 FAILED: sign-off on %s was refused by `%s`, which is not the rule that names '
        'that case.', v_case, coalesce(v_constraint, 'an unnamed constraint'));
    end if;
  end loop;

  raise notice 'Step 4 ok: an abstention, an open-ended commitment, one a machine answers for '
    'and one with no photo are each refused by their own named constraint.';

  -- =================================================================================
  -- Step 5: the fourth refusal, which no CHECK could make.
  --
  -- A check cannot query `profile`, so this is a write-time trigger. It fires only when the flag
  -- is written -- and Step 6 is the other half of that sentence.
  -- =================================================================================
  v_refused := false;
  begin
    insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                   carries_penalty, requires_photo, requires_referee_approval)
    values (v_lonely, gen_random_uuid(), 'Nobody to ask', 'do', 'daily', true, true, true);
  exception when raise_exception then
    v_refused := true;
    get stacked diagnostics v_message = message_text;
  end;

  if not v_refused then
    raise exception using message =
      'Step 5 FAILED: a commitment asked for a referee''s signature on an account with no '
      'referee paired. The form disables the control, but the form is not the enforcement '
      'point.';
  end if;

  if v_message not like '%Settings%' then
    raise exception using message = format(
      'Step 5 FAILED: the refusal said "%s", which does not tell the author where to pair a '
      'referee.', v_message);
  end if;

  -- The same account may still keep commitments; only the flag is refused.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo)
  values (v_lonely, gen_random_uuid(), 'Ordinary', 'do', 'daily', true, true)
  returning id into v_c7;

  -- And the *update* arm, which the insert above does not reach. Its `when` clause is doing real
  -- work: a false -> true flip on an account with no referee is exactly the write the trigger
  -- exists to refuse, and nothing else in this file would notice if that arm were dropped.
  v_refused := false;
  begin
    update public.commitment set requires_referee_approval = true where id = v_c7;
  exception when raise_exception then
    v_refused := true;
  end;

  if not v_refused then
    raise exception using message =
      'Step 5 FAILED: an existing commitment was switched to asking for a referee''s signature '
      'on an account with no referee paired. The insert arm refuses this; the update arm must '
      'too, or the rule is one edit away from being no rule.';
  end if;

  if (select requires_referee_approval from public.commitment where id = v_c7) is distinct from false
  then
    raise exception using message =
      'Step 5 FAILED: the refused update left the flag set. A BEFORE trigger that raises must '
      'take the whole statement with it.';
  end if;

  -- No log entry for a write that never landed.
  select count(*) into v_count
    from public.commitment_requires_referee_approval_change c
   where c.commitment_id = v_c7 and c.requires_referee_approval;
  if v_count <> 0 then
    raise exception using message = format(
      'Step 5 FAILED: a refused turn-on left %s log entries claiming the flag was on.', v_count);
  end if;

  raise notice 'Step 5 ok: the flag is refused with no referee paired -- on insert and on a '
    'later false -> true flip -- with a sentence naming where to pair one, and an unflagged '
    'commitment on the same account is unaffected.';

  -- =================================================================================
  -- Step 6: a pairing revoked later refuses nothing.
  --
  -- The SPEC is explicit that a revoked pairing simply auto-approves (Story 8.2's silence). It
  -- must not become an error the author has to clear before he can rename his own commitment.
  -- =================================================================================
  update public.profile set referee_of = null where id = v_ref;

  update public.commitment set name = 'Sách cũ' where id = v_c3;
  -- The client's save writes every column by name on every edit, flag included. Re-writing the
  -- same value must not re-check a pairing the rule above says is not the author's to keep.
  update public.commitment
     set name = 'Sách', requires_referee_approval = true
   where id = v_c3;

  if (select requires_referee_approval from public.commitment where id = v_c3) is distinct from true
  then
    raise exception using message =
      'Step 6 FAILED: the flag did not survive an edit made after the pairing was revoked.';
  end if;

  update public.profile set referee_of = v_doer where id = v_ref;

  raise notice 'Step 6 ok: a pairing revoked afterwards refuses nothing, and an already-flagged '
    'commitment is still editable.';

  -- =================================================================================
  -- Step 7: the log's own discipline -- on insert, on a change, and on nothing else.
  --
  -- An entry written for an unrelated update reads as a decision the author made about his
  -- referee. The trigger's WHEN clause is what stops that, and this is what holds the WHEN
  -- clause in place.
  -- =================================================================================
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo)
  values (v_doer, gen_random_uuid(), 'Log', 'do', 'daily', true, true)
  returning id into v_c5;

  select count(*) into v_count
    from public.commitment_requires_referee_approval_change where commitment_id = v_c5;
  if v_count <> 1 then
    raise exception using message = format(
      'Step 7 FAILED: creation wrote %s log entries, expected exactly 1. Without the creation '
      'entry the reader''s second branch has nothing to extrapolate from.', v_count);
  end if;

  update public.commitment set requires_referee_approval = true where id = v_c5;

  select count(*) into v_count
    from public.commitment_requires_referee_approval_change where commitment_id = v_c5;
  if v_count <> 2 then
    raise exception using message = format(
      'Step 7 FAILED: switching the flag on left %s log entries, expected 2.', v_count);
  end if;

  update public.commitment set name = 'Log renamed' where id = v_c5;
  update public.commitment set carries_penalty = false where id = v_c5;
  update public.commitment set requires_photo = true where id = v_c5;
  -- The same value re-written, which is what every edit through the form does.
  update public.commitment set requires_referee_approval = true where id = v_c5;

  select count(*) into v_count
    from public.commitment_requires_referee_approval_change where commitment_id = v_c5;
  if v_count <> 2 then
    raise exception using message = format(
      'Step 7 FAILED: four updates that changed nothing about the flag left %s log entries, '
      'expected 2. An entry per unrelated update reads as a decision the author never made.',
      v_count);
  end if;

  raise notice 'Step 7 ok: one entry at creation, one per real change, and none for an update '
    'that left the flag where it was.';

  -- =================================================================================
  -- Step 8: an unflagged commitment is untouched by all of it.
  --
  -- CAP-1's own success criterion, and the one an implementation is most likely to break in
  -- passing.
  -- =================================================================================
  if (select requires_referee_approval from public.commitment where id = v_c4) is distinct from false
  then
    raise exception using message =
      'Step 8 FAILED: a commitment saved with no mention of the flag did not default to false.';
  end if;

  select count(*) into v_count
    from public.commitment_requires_referee_approval_change c
   where c.commitment_id = v_c4 and c.requires_referee_approval;
  if v_count <> 0 then
    raise exception using message = format(
      'Step 8 FAILED: an unflagged commitment carries %s entries claiming the flag was on.',
      v_count);
  end if;

  -- Every path an unflagged commitment has stays open with no referee anywhere near it.
  update public.commitment set name = 'Chạy bộ buổi sáng' where id = v_c4;
  update public.commitment set carries_penalty = false where id = v_c4;
  update public.commitment set archived_at = now() where id = v_c4;

  if public.requires_referee_approval_as_of(v_c4, v_today) is distinct from false then
    raise exception using message =
      'Step 8 FAILED: an unflagged commitment read true from the one door.';
  end if;

  raise notice 'Step 8 ok: an unflagged commitment defaults false, logs only false, and is '
    'saved, edited and archived exactly as it was before this migration.';

  -- =================================================================================
  -- Step 9: has_paired_referee(), which is the only part of this the client may call.
  --
  -- It answers about the *caller* and takes no argument, so there is nothing to point at
  -- somebody else's account. It reveals whether a referee exists and nothing about who he is.
  -- =================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_doer, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_answer := public.has_paired_referee();
  if v_answer is distinct from true then
    raise exception using message = format(
      'Step 9 FAILED: the paired doer''s own account read %s from has_paired_referee(). The '
      'form disables the sign-off control on that answer.', coalesce(v_answer::text, 'null'));
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_lonely, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_answer := public.has_paired_referee();
  if v_answer is distinct from false then
    raise exception using message = format(
      'Step 9 FAILED: an account with no referee read %s from has_paired_referee().',
      coalesce(v_answer::text, 'null'));
  end if;

  perform set_config('request.jwt.claims', '', true);

  raise notice 'Step 9 ok: has_paired_referee() answers true for the paired doer and false for '
    'an account with no referee.';

  raise notice 'All nine steps passed.';
end;
$$;

rollback;
