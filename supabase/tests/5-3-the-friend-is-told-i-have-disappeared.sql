-- Story 5.3 — The friend is told I have disappeared (FR-18).
--
-- Every row of the spec's own I/O & Edge-Case Matrix that is server-side behavior:
-- an episode reaching exactly 4 consecutive quiet days is escalated once (escalated_at set,
-- one email-channel outbox row enqueued, naming the actual elapsed day count); a same-hour
-- re-run enqueues no second email and leaves escalated_at unchanged; an episode satisfied
-- before reaching the threshold never escalates at all; an episode satisfied *after*
-- escalation stops matching the referee's own read (the state "clears") and never escalates
-- a second time; the referee session's new RLS grant reads exactly the escalated, still-open
-- episodes, nothing more, nothing scoped by which account they belong to; and outbox_claim's
-- own p_channel filter keeps the push and email queues isolated, so the two workers can
-- never claim each other's rows.
--
-- Two matrix rows are deliberately not exercised here, the same way `2-4a-outbox-claim.sql`
-- reads rather than runs the property two real sessions would need: "No referee paired" and
-- "Resend API failure" are both `email-worker`'s own behavior (a Deno Edge Function, not SQL)
-- -- `supabase/functions/email-worker/index.ts`'s own `resolveRefereeEmail()` and
-- `retryOrFail()` are what those two rows are proven by, mirroring `outbox-worker`'s own
-- `dead`/`failed` shape exactly. What this file proves is everything upstream of that: the
-- row `email-worker` will eventually claim exists, at most once, with the right payload and
-- the right channel, exactly when the Boundaries say it should.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/5-3-the-friend-is-told-i-have-disappeared.sql
--
-- One transaction, rolled back at the end. `enqueue_gate_reminders()` is called directly
-- inside the test transaction (no `pg_cron` fires in a SQL test), mirroring 5-1's and 5-2's
-- own structure. Every `silence_episode` fixture row is inserted directly, as `postgres`,
-- rather than produced through 5-2's own two-quiet-days detection path: the escalation block
-- under test reads an episode's own started_day and current state, and does not care how it
-- got there (this story's own Never boundary -- "no second silence-detection re-derivation").

begin;

grant select on table public.profile to authenticated;
grant select on table public.silence_episode to authenticated;

do $$
declare
  -- Escalates today: started_day is exactly 3 days before asked_day (4 consecutive quiet
  -- days inclusive).
  v_user            uuid := gen_random_uuid();
  -- One day short of the threshold: started_day is 2 days before asked_day (3 consecutive
  -- quiet days) -- must not escalate.
  v_notyet          uuid := gen_random_uuid();
  -- Already satisfied before ever reaching the threshold -- "Declaration lands before
  -- threshold" (I/O Matrix). Its own started_day is old enough that it *would* have
  -- escalated had it still been open.
  v_satisfied_before uuid := gen_random_uuid();
  -- Escalates on the first pass, then is satisfied afterward -- "Declaration lands after
  -- escalation" (I/O Matrix): the referee's own read must clear, and no second email must
  -- ever follow.
  v_after           uuid := gen_random_uuid();
  -- The one referee account -- paired exactly as `pair-referee` leaves one (4-5's own test
  -- fixture shape): a real auth.users row, a profile the trigger defaulted to `doer`, then a
  -- second, separate write promoting it.
  v_referee         uuid := gen_random_uuid();

  v_local_hour      integer;
  v_asked_day       date;

  v_episode_user       uuid;
  v_episode_notyet     uuid;
  v_episode_satisfied  uuid;
  v_episode_after      uuid;
  v_commit_after        uuid;

  v_count           integer;
  v_escalated_at    timestamptz;
  v_escalated_at2   timestamptz;
  v_payload         jsonb;
  v_channel         public.outbox_channel;
  v_dedupe          text;
  v_claimed_dedupe  text[];
begin
  -- -------------------------------------------------------------------------------
  -- 0. Refuse to run anywhere a live doer account would make the result meaningless --
  --    enqueue_gate_reminders() loops every `role = 'doer'` profile, and a real account's
  --    real commitments/episodes would leak into every count this test asserts.
  -- -------------------------------------------------------------------------------
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so its own commitments/episodes would leak '
      'into every count this test asserts. Run against a local or branch database instead.';
  end if;

  -- -------------------------------------------------------------------------------
  -- 1. Fixture: four doer accounts (morning_hour pinned to the current local hour, same as
  --    5-2's own fixture, so nothing here is skipped by the slot window), one referee, and a
  --    silence_episode row planted directly for each doer account at the day-offset its own
  --    step needs.
  -- -------------------------------------------------------------------------------
  v_local_hour := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh')::integer;
  v_asked_day := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'story-5-3-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_user, v_notyet, v_satisfied_before, v_after, v_referee]) as t(id);

  update public.profile set morning_hour = v_local_hour
   where id in (v_user, v_notyet, v_satisfied_before, v_after);

  update public.profile set role = 'referee' where id = v_referee;

  -- v_after needs one real commitment so a real Declaration can be inserted against it in
  -- Step 4 -- declaration_satisfies_silence() fires on any Declaration, but a Declaration
  -- still needs a commitment_id that exists.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_after, gen_random_uuid(), 'Read', 'do', 'daily', false)
  returning id into v_commit_after;

  -- v_user: exactly 4 consecutive quiet days as of today (asked_day - started_day = 3).
  insert into public.silence_episode (owner_id, started_day, notified_at)
  values (v_user, v_asked_day - 3, now() - interval '3 days')
  returning id into v_episode_user;

  -- v_notyet: exactly 3 consecutive quiet days (asked_day - started_day = 2) -- one short.
  insert into public.silence_episode (owner_id, started_day, notified_at)
  values (v_notyet, v_asked_day - 2, now() - interval '2 days')
  returning id into v_episode_notyet;

  -- v_satisfied_before: old enough to have reached the threshold, but already satisfied --
  -- simulates a Declaration landing before escalation ever ran.
  insert into public.silence_episode (owner_id, started_day, notified_at, satisfied_at)
  values (v_satisfied_before, v_asked_day - 5, now() - interval '5 days', now())
  returning id into v_episode_satisfied;

  -- v_after: same shape as v_user -- escalates on the first pass below, then gets satisfied
  -- afterward in Step 4.
  insert into public.silence_episode (owner_id, started_day, notified_at)
  values (v_after, v_asked_day - 3, now() - interval '3 days')
  returning id into v_episode_after;

  raise notice using message = format(
    'Fixture ok: asked_day=%s, v_user/v_after started_day=%s (4 quiet days), v_notyet '
    'started_day=%s (3 quiet days), v_satisfied_before already satisfied, referee paired.',
    v_asked_day, v_asked_day - 3, v_asked_day - 2);

  -- -------------------------------------------------------------------------------
  -- 2. Threshold reached: the pass escalates v_user and v_after exactly once each, leaves
  --    v_notyet and v_satisfied_before untouched, and enqueues exactly one email-channel
  --    outbox row per escalated episode, naming the real elapsed day count (4).
  -- -------------------------------------------------------------------------------
  perform public.enqueue_gate_reminders();

  select escalated_at into v_escalated_at from public.silence_episode where id = v_episode_user;
  if v_escalated_at is null then
    raise exception using message =
      'v_user reached exactly 4 consecutive quiet days but escalated_at still reads null.';
  end if;

  select escalated_at into v_escalated_at from public.silence_episode where id = v_episode_after;
  if v_escalated_at is null then
    raise exception using message = 'v_after (same shape as v_user) did not escalate either.';
  end if;

  select escalated_at into v_escalated_at from public.silence_episode where id = v_episode_notyet;
  if v_escalated_at is not null then
    raise exception using message =
      'v_notyet reached only 3 consecutive quiet days, one short of the threshold, but '
      'escalated_at was stamped anyway -- the >= 3 comparison must be off by one.';
  end if;

  select escalated_at into v_escalated_at
    from public.silence_episode where id = v_episode_satisfied;
  if v_escalated_at is not null then
    raise exception using message =
      'v_satisfied_before was already satisfied before this pass ran, but escalated_at was '
      'stamped anyway -- the escalation read must filter satisfied_at is null.';
  end if;

  select dedupe_key, payload, channel into v_dedupe, v_payload, v_channel
    from public.outbox
   where dedupe_key = 'silence-escalate-' || v_user::text || '-' || (v_asked_day - 3)::text;

  if v_dedupe is null then
    raise exception using message =
      'No outbox row exists at v_user''s own silence-escalate- dedupe key.';
  end if;

  if v_channel <> 'email' then
    raise exception using message = format(
      'v_user''s escalation row carries channel = %s, expected ''email'' -- the push worker '
      'must never be able to claim this row.', v_channel);
  end if;

  if v_payload ->> 'title' is null or v_payload ->> 'body' is null or v_payload ->> 'sent_at' is null then
    raise exception using message = 'The escalation payload is missing title/body/sent_at.';
  end if;

  if (v_payload ->> 'body') !~ '4 days' then
    raise exception using message = format(
      'The escalation body reads "%s" -- it must state the real elapsed day count (4), not '
      'a hardcoded figure or something else entirely.', v_payload ->> 'body');
  end if;

  if (v_payload ->> 'body') ~* '(right now|just now|currently|at the moment)'
     or (v_payload ->> 'body') !~ '[0-9]{1,2}:[0-9]{2}' then
    raise exception using message =
      'The escalation body is not self-dating (no HH:MM) or claims the present -- it would '
      'fail push_body_is_sendable() the same way any other outbox row would.';
  end if;

  if (v_payload ->> 'body') ~* '(đồng|₫)'
     or (v_payload ->> 'body') ~ '[0-9]{1,3}(,[0-9]{3})+'
     or (v_payload ->> 'body') ilike '%missed%' then
    raise exception using message = format(
      'The escalation body reads "%s" -- FR-18 names only the day count, never an amount or '
      'a missed commitment.', v_payload ->> 'body');
  end if;

  select count(*) into v_count
   from public.outbox where owner_id = v_user and dedupe_key like 'silence-escalate-%';
  if v_count <> 1 then
    raise exception using message = format(
      'Expected exactly 1 escalation email for v_user, found %s.', v_count);
  end if;

  select count(*) into v_count
   from public.outbox where owner_id = v_notyet and dedupe_key like 'silence-escalate-%';
  if v_count <> 0 then
    raise exception using message = format(
      'v_notyet is one day short of the threshold, but %s escalation email(s) were '
      'enqueued anyway.', v_count);
  end if;

  select count(*) into v_count
   from public.outbox
   where owner_id = v_satisfied_before and dedupe_key like 'silence-escalate-%';
  if v_count <> 0 then
    raise exception using message = format(
      'v_satisfied_before was satisfied before ever reaching the threshold, but %s '
      'escalation email(s) were enqueued anyway.', v_count);
  end if;

  raise notice using message =
    'Step 2 ok: v_user and v_after (4 quiet days) each escalated exactly once, with exactly '
    'one self-dating email-channel outbox row naming the real elapsed count (4 days), no '
    'amount and no missed commitment; v_notyet (3 quiet days) and v_satisfied_before '
    '(already satisfied) escalated neither their episode nor an email.';

  -- -------------------------------------------------------------------------------
  -- 3. Same-hour re-run: the guarded update matches 0 rows (escalated_at is already set),
  --    so escalated_at is unchanged and no second email is enqueued -- the dedupe key would
  --    have caught it even if the guard somehow did not.
  -- -------------------------------------------------------------------------------
  select escalated_at into v_escalated_at from public.silence_episode where id = v_episode_user;

  perform public.enqueue_gate_reminders();

  select escalated_at into v_escalated_at2 from public.silence_episode where id = v_episode_user;
  if v_escalated_at2 is distinct from v_escalated_at then
    raise exception using message = format(
      'A same-hour re-run changed v_user''s own escalated_at from %s to %s -- the guarded '
      'update (where escalated_at is null) must match 0 rows once it is already set.',
      v_escalated_at, v_escalated_at2);
  end if;

  select count(*) into v_count
   from public.outbox where owner_id = v_user and dedupe_key like 'silence-escalate-%';
  if v_count <> 1 then
    raise exception using message = format(
      'A same-hour re-run left %s escalation email(s) for v_user, expected exactly 1 still.',
      v_count);
  end if;

  raise notice using message =
    'Step 3 ok: a same-hour re-run changed neither escalated_at nor the number of escalation '
    'emails -- the guarded update and the outbox''s own dedupe key both hold.';

  -- -------------------------------------------------------------------------------
  -- 4. Declaration lands after escalation: v_after answers, declaration_satisfies_silence()
  --    (5.2's own trigger, untouched by this story) sets satisfied_at immediately. The
  --    referee's own read must clear (Step 5 proves this through RLS), and a further pass
  --    must not send a second email for the same, now-satisfied episode.
  -- -------------------------------------------------------------------------------
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_after, v_commit_after, gen_random_uuid(), 'held', now());

  select satisfied_at into v_escalated_at from public.silence_episode where id = v_episode_after;
  if v_escalated_at is null then
    raise exception using message =
      'v_after''s own satisfied_at still reads null after a Declaration was filed -- '
      'declaration_satisfies_silence() (5.2''s own trigger) should be untouched by this story.';
  end if;

  perform public.enqueue_gate_reminders();

  select count(*) into v_count
   from public.outbox where owner_id = v_after and dedupe_key like 'silence-escalate-%';
  if v_count <> 1 then
    raise exception using message = format(
      'v_after''s episode was satisfied after escalating once; a later pass enqueued %s '
      'escalation email(s) total, expected exactly 1 still (no further email).', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: answering a Declaration after escalation satisfies the episode immediately '
    '(5.2''s own trigger, untouched), and no further escalation email follows.';

  -- -------------------------------------------------------------------------------
  -- 5. The referee's own read (RLS, FR-18/AD-7): exactly the escalated-and-unsatisfied
  --    episodes -- v_user's (still open) -- and nothing else: not v_notyet's (never
  --    escalated), not v_satisfied_before's (never escalated), and not v_after's own (was
  --    escalated, but satisfied since Step 4 -- the state must have cleared). Not scoped by
  --    owner_id, the same way every other referee policy in this codebase reads (4-5's own
  --    "at most one referee, so no owner scoping is needed").
  -- -------------------------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_referee, 'role', 'authenticated', 'app_role', 'referee')::text,
    true);

  select count(*) into v_count from public.silence_episode;
  if v_count <> 1 then
    raise exception using message = format(
      'The referee session reads %s silence_episode row(s), expected exactly 1 (v_user''s '
      'own, still escalated and unsatisfied).', v_count);
  end if;

  perform 1 from public.silence_episode where id = v_episode_user;
  if not found then
    raise exception using message =
      'The referee session cannot read v_user''s own escalated, still-open episode.';
  end if;

  perform 1 from public.silence_episode where id = v_episode_notyet;
  if found then
    raise exception using message =
      'The referee session read v_notyet''s episode -- it was never escalated '
      '(escalated_at is null), so "silence_episode: referee reads escalated" must not match it.';
  end if;

  perform 1 from public.silence_episode where id = v_episode_satisfied;
  if found then
    raise exception using message =
      'The referee session read v_satisfied_before''s episode -- it was never escalated '
      'either.';
  end if;

  perform 1 from public.silence_episode where id = v_episode_after;
  if found then
    raise exception using message =
      'The referee session read v_after''s episode after it was satisfied -- the policy''s '
      'own satisfied_at is null clause must stop matching the instant a Declaration lands, '
      'which is the whole mechanism the "state clears" Acceptance Criterion depends on.';
  end if;

  perform set_config('role', 'postgres', true);

  raise notice using message =
    'Step 5 ok: the referee session reads exactly v_user''s escalated-and-unsatisfied '
    'episode -- never one that was never escalated, and never one that has since been '
    'satisfied (state clears the instant a Declaration lands).';

  -- -------------------------------------------------------------------------------
  -- 6. outbox_claim's own channel filter (Always boundary: "the push and email workers can
  --    never claim each other's rows"). One push-channel row and one email-channel row, same
  --    owner -- outbox_claim(_) (default channel = push) claims the push row and never the
  --    email one; outbox_claim(_, 'email') claims the email row and never the push one.
  --
  --    Each channel is claimed exactly once here and the *returned* dedupe keys are checked
  --    for containment, rather than asserting an exact row count or claiming twice: this
  --    fixture's own earlier steps already left real, still-pending email-channel rows
  --    behind (v_user's and v_after's own escalation emails, neither ever claimed above), and
  --    outbox_claim mutates whatever it selects (attempts, claimed_at, not_before) -- a second
  --    call against the same channel would find the first call's own rows hidden behind their
  --    own fresh visibility timeout, not absent.
  -- -------------------------------------------------------------------------------
  perform public.outbox_enqueue(
    v_user,
    'channel-test-push-' || v_user::text,
    jsonb_build_object(
      'title', 'Test',
      'body', 'Push-channel isolation test, as of 00:00.',
      'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    )
  );

  perform public.outbox_enqueue(
    v_user,
    'channel-test-email-' || v_user::text,
    jsonb_build_object(
      'title', 'Test',
      'body', 'Email-channel isolation test, as of 00:00.',
      'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ),
    'email'
  );

  select coalesce(array_agg(dedupe_key), '{}') into v_claimed_dedupe
    from public.outbox_claim(50);

  if not ('channel-test-push-' || v_user::text = any(v_claimed_dedupe)) then
    raise exception using message =
      'outbox_claim(50) (default channel = push) did not claim the push-channel test row.';
  end if;

  if 'channel-test-email-' || v_user::text = any(v_claimed_dedupe) then
    raise exception using message =
      'outbox_claim(50) (default channel = push) claimed the email-channel test row -- the '
      'push worker must never be able to claim an email row.';
  end if;

  select coalesce(array_agg(dedupe_key), '{}') into v_claimed_dedupe
    from public.outbox_claim(50, 'email');

  if not ('channel-test-email-' || v_user::text = any(v_claimed_dedupe)) then
    raise exception using message =
      'outbox_claim(50, ''email'') did not claim the email-channel test row.';
  end if;

  if 'channel-test-push-' || v_user::text = any(v_claimed_dedupe) then
    raise exception using message =
      'outbox_claim(50, ''email'') claimed the push-channel test row -- the email worker '
      'must never be able to claim a push row.';
  end if;

  raise notice using message =
    'Step 6 ok: outbox_claim''s own p_channel filter isolates the two queues -- the default '
    '(push) claim never returns an email row, and an explicit email claim never returns a '
    'push row.';

  raise notice using message =
    'PASS. Every I/O Matrix row provable from SQL holds: exactly 4 consecutive quiet days '
    'escalates once with a self-dating, day-count-only email row; one short of the threshold '
    'or already satisfied never escalates; a same-hour re-run changes nothing; a Declaration '
    'after escalation satisfies the episode and blocks any further email; the referee''s own '
    'RLS read tracks the escalated-and-unsatisfied state exactly; and outbox_claim''s own '
    'p_channel filter keeps the push and email queues fully isolated.';
end $$;

rollback;
