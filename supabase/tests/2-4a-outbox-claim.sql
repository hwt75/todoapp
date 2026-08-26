-- Story 2.4a — the queue hands each effect out once, and takes it back if nobody sends it.
--
-- AD-3's guarantee is at-least-once: every effect carries a dedupe key and must be safe to
-- execute twice. Exactly-once is not on offer, and pretending otherwise is how duplicates
-- become silent. What the queue does have to guarantee is that a claimed row is invisible to
-- the next tick for long enough to be sent, and visible again if the worker dies holding it.
--
-- The worker was proven end to end once, by hand, in Story 2.4a: `pg_cron` woke it, it
-- reported `claimed 1 / sent 1`, and the push reached the author's phone. What was never
-- checked is the behaviour under a second tick — the case that only happens at 07:30 on a
-- morning when something is slow, and that duplicates a notification when it is wrong.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-4a-outbox-claim.sql
--
-- One transaction, rolled back at the end. It settles nothing and is safe against any
-- database.
--
-- **One property this file cannot drive: `for update skip locked`.** It needs two sessions
-- holding row locks at the same time, and this is one transaction by design. Step 5 reads the
-- shipped function body instead and says so plainly rather than implying more than it proved.

begin;

do $$
declare
  v_user   uuid := gen_random_uuid();
  v_first  uuid;
  v_again  uuid;
  v_count  integer;
  v_ids    uuid[];
  v_body   text;
  v_att    integer;
  v_when   timestamptz;

  -- Every body has to satisfy the outbox's own rule, which is the point of it being there.
  v_time_clause text := 'as of 07:30';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          'retro-2-4a-claim-' || v_user::text || '@example.test',
          'not-a-real-password-this-account-never-signs-in',
          now(), now(), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

  -- -------------------------------------------------------------------------------
  -- 1. An effect enqueued twice is enqueued once.
  --
  -- Settlement is retried, overlapped and triggered by hand. The dedupe key is what makes
  -- each of those a no-op instead of a second notification about the same day.
  -- -------------------------------------------------------------------------------
  v_first := public.outbox_enqueue(v_user, 'summary-' || v_user::text || '-2026-08-18',
    jsonb_build_object('title', 'Today',
                       'body', 'Four of five on Tuesday. Start with No fap tomorrow.',
                       'sent_at', '2026-08-18T14:00:00Z'));

  v_again := public.outbox_enqueue(v_user, 'summary-' || v_user::text || '-2026-08-18',
    jsonb_build_object('title', 'Today',
                       'body', 'Four of five on Tuesday. Start with No fap tomorrow.',
                       'sent_at', '2026-08-18T14:00:01Z'));

  if v_first is null then
    raise exception using message = 'The first enqueue returned null.';
  end if;

  if v_again is not null then
    raise exception using message =
      'A repeated dedupe key was enqueued again. `outbox_enqueue` returns null on conflict '
      'precisely so a retried settlement pass does not send a second notification.';
  end if;

  select count(*) into v_count from public.outbox where owner_id = v_user;
  if v_count <> 1 then
    raise exception using message = format(
      'The queue holds %s rows for one dedupe key, expected 1.', v_count);
  end if;

  raise notice using message = 'Step 1 ok: the same effect enqueued twice is one row.';

  -- -------------------------------------------------------------------------------
  -- 2. Two more effects, one of which is not due yet.
  -- -------------------------------------------------------------------------------
  perform public.outbox_enqueue(v_user, 'gate-' || v_user::text || '-slot-0',
    jsonb_build_object('title', 'Yesterday',
                       'body', '1 commitment is unanswered for 2026-08-18, ' || v_time_clause || '.',
                       'sent_at', '2026-08-19T00:30:00Z'));

  perform public.outbox_enqueue(v_user, 'gate-' || v_user::text || '-slot-1',
    jsonb_build_object('title', 'Yesterday',
                       'body', '1 commitment is unanswered for 2026-08-18, as of 08:30.',
                       'sent_at', '2026-08-19T01:30:00Z'));

  -- The last one is deferred, the way a released row is: due in the future.
  update public.outbox set not_before = now() + interval '5 minutes'
   where owner_id = v_user and dedupe_key = 'gate-' || v_user::text || '-slot-1';

  -- -------------------------------------------------------------------------------
  -- 3. A claim takes what is due, in the order it arrived, and no more than the batch.
  -- -------------------------------------------------------------------------------
  select array_agg(id order by created_at) into v_ids
    from public.outbox_claim(1);

  if array_length(v_ids, 1) <> 1 then
    raise exception using message = format(
      'A batch of 1 claimed %s rows.', coalesce(array_length(v_ids, 1), 0));
  end if;

  if v_ids[1] <> v_first then
    raise exception using message =
      'The claim did not take the oldest row first. A queue that hands out its newest '
      'effect first delivers this morning''s reminder after tonight''s summary.';
  end if;

  select attempts, not_before into v_att, v_when
    from public.outbox where id = v_first;

  if v_att <> 1 then
    raise exception using message = format(
      'A claimed row records %s attempts, expected 1. The count is the only evidence a '
      'send was ever tried.', v_att);
  end if;

  if v_when <= now() then
    raise exception using message =
      'A claimed row is immediately due again, so the next tick can claim it while the '
      'first is still sending — and the author gets the same notification twice.';
  end if;

  raise notice using message =
    'Step 3 ok: the oldest due row was claimed, attempts is 1, and it is invisible until later.';

  -- -------------------------------------------------------------------------------
  -- 4. The second tick sees only what is genuinely due.
  --
  -- One row is claimed and hidden, one is deferred into the future. Exactly one is left.
  -- -------------------------------------------------------------------------------
  select array_agg(id) into v_ids from public.outbox_claim(10);

  if coalesce(array_length(v_ids, 1), 0) <> 1 then
    raise exception using message = format(
      'The second claim took %s rows, expected exactly 1 — the claimed row is hidden and '
      'the deferred one is not due.', coalesce(array_length(v_ids, 1), 0));
  end if;

  select payload ->> 'body' into v_body from public.outbox where id = v_ids[1];
  if v_body not like '%as of 07:30%' then
    raise exception using message = format(
      'The second claim took the wrong row: "%s".', v_body);
  end if;

  -- And a third finds nothing at all.
  select count(*) into v_count from public.outbox_claim(10);
  if v_count <> 0 then
    raise exception using message = format(
      'A third claim took %s rows when everything due was already out.', v_count);
  end if;

  raise notice using message =
    'Step 4 ok: the deferred row stayed put and a third tick found nothing.';

  -- -------------------------------------------------------------------------------
  -- 5. The property this file cannot drive, read rather than run.
  --
  -- Two workers ticking at once must not hand the same row to both. That needs two
  -- sessions holding locks simultaneously; this is one transaction, so the assertion below
  -- is a text read and is worth exactly what a text read is worth. It is here so that
  -- deleting the clause is noticed, not so that anyone believes it was exercised.
  -- -------------------------------------------------------------------------------
  if pg_get_functiondef('public.outbox_claim(integer, public.outbox_channel)'::regprocedure)
       not like '%for update skip locked%' then
    raise exception using message =
      'outbox_claim no longer takes `for update skip locked`. Two overlapping ticks will '
      'block on each other or hand the same effect to both workers. NOT VERIFIED HERE — '
      'this is a read of the function body, and the real check needs two sessions.';
  end if;

  raise notice using message =
    'Step 5 read (not run): outbox_claim still says `for update skip locked`.';
  raise notice using message =
    'PASS. One effect per dedupe key, oldest first, claimed once, and invisible while it is out.';
end $$;

rollback;
