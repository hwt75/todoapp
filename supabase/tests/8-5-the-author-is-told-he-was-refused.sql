-- Story 8.5 — the author is told he was refused.
--
-- A refusal enqueues exactly one push to the author, in its own transaction; an approval and a
-- silence enqueue none. The referee's reason rides verbatim in `quote`, the commitment name in the
-- title, and the body -- the only field `outbox_body_is_sendable` reads -- is built from the app's
-- words and the date alone, so **no one's wording can abort a refusal**. A reason too large for a
-- push is left out whole, never cut.
--
-- What is proved, in order:
--
--   1.  The body passes push_body_is_sendable on every weekday, quoted or not.
--   2-4. A refusal: one push, to the author, on the push channel, keyed by the decision's id,
--       the name in the title, the day in the body, the reason byte-for-byte in `quote`. An
--       approval enqueues nothing, and a second refusal of a decided day raises in its own words
--       and enqueues nothing more. Hostile wording -- "right now" in the commitment name,
--       "currently" in the reason -- and the refusal still lands. A 200-character name is clipped
--       in the title and nowhere else.
--   5.  The byte budget at its edge: exactly 3500 carries the quote, 3501 does not, and both
--       refusals land. A multibyte reason is measured in bytes, not characters.
--   6.  sign_off_day() still reads the one door 8.3 built, now reads refusal_payload(), and is
--       the only function in the schema that writes a `refusal-` key -- so a silence, which has
--       no transaction of its own, cannot produce one.
--
-- `8-2-the-referee-s-decision-and-what-a-refusal-costs.sql` running with only its outbox count
-- changed (0 -> one per refusal) is what proves sign_off_day() decides nothing differently.

begin;

-- CI's database has the storage schema and not the bucket row -- README.md, "A fixture that
-- writes `evidence` also writes its photograph".
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;

-- =================================================================================
-- Step 1: the body can never fail the check, whatever the day.
-- =================================================================================
do $$
declare
  d date;
begin
  for d in select generate_series(date '2026-09-28', date '2026-10-04', interval '1 day')::date
  loop
    if not public.push_body_is_sendable(public.refusal_body(d, true))
       or not public.push_body_is_sendable(public.refusal_body(d, false)) then
      raise exception using message = format(
        'refusal_body() for %s fails push_body_is_sendable. Every refusal on that weekday would '
        'abort in its own transaction: "%s"', d, public.refusal_body(d, true));
    end if;
  end loop;

  raise notice using message =
    'Step 1 ok: the refusal body passes push_body_is_sendable on all seven weekdays, quoted or not.';
end $$;


do $$
declare
  v_doer   uuid := gen_random_uuid();
  v_ref    uuid := gen_random_uuid();
  v_today  date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

  v_plain   uuid;  -- refused with an ordinary reason
  v_ok      uuid;  -- approved
  v_hostile uuid;  -- named "right now", refused "currently"
  v_edge    uuid;  -- reason sized to put the payload at exactly 3500 bytes
  v_over    uuid;  -- one byte more
  v_big     uuid;  -- a 1500-character Vietnamese reason: well under by characters, over by bytes
  v_long    uuid;  -- a 200-character name, refused with an ordinary reason

  v_id       uuid;
  v_before   integer;
  v_count    integer;
  v_row      record;
  v_decision uuid;
  v_payload  jsonb;
  v_base     integer;
  v_reason   text;
  v_edge_r   text;
  v_over_r   text;
  v_big_r    text := repeat('ệ', 1500);
  v_raised   text;
begin
  foreach v_id in array array[v_doer, v_ref] loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'refused-' || gen_random_uuid()::text || '@example.test',
            'not-a-real-password-this-account-never-signs-in', now(), now(), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);
  end loop;

  update public.profile set role = 'referee', referee_of = v_doer where id = v_ref;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Thuốc', 'do', 'daily', true, true, true)
  returning id into v_plain;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Gym', 'do', 'daily', true, true, true)
  returning id into v_ok;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Stop scrolling right now', 'do', 'daily', true, true, true)
  returning id into v_hostile;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Edge', 'do', 'daily', true, true, true)
  returning id into v_edge;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Over', 'do', 'daily', true, true, true)
  returning id into v_over;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), 'Đọc sách', 'do', 'daily', true, true, true)
  returning id into v_big;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty,
                                 requires_photo, requires_referee_approval)
  values (v_doer, gen_random_uuid(), repeat('Long name ', 20), 'do', 'daily', true, true, true)
  returning id into v_long;

  -- A photograph on each: sign_off_day() refuses a day with nothing to refuse.
  foreach v_id in array array[v_plain, v_ok, v_hostile, v_edge, v_over, v_big, v_long] loop
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_id::text || '/' || v_today::text || '.jpg', v_doer);

    insert into public.evidence (commitment_id, for_day, storage_path, captured_on)
    values (v_id, v_today, v_id::text || '/' || v_today::text || '.jpg', v_today);
  end loop;

  -- The two edge reasons, sized against the real payload. `sent_at` is fixed-width, so the base
  -- is measured once with a one-byte reason and the edge is solved for. Multibyte on purpose:
  -- three-byte characters plus ASCII to land on the exact byte, so a character count and a byte
  -- count disagree and only the byte count can pass.
  v_base := octet_length(convert_to(
              public.refusal_payload('Edge', v_today, 'a')::text, 'UTF8')) - 1;
  v_edge_r := repeat('ệ', (3500 - v_base) / 3) || repeat('a', (3500 - v_base) % 3);
  v_base := octet_length(convert_to(
              public.refusal_payload('Over', v_today, 'a')::text, 'UTF8')) - 1;
  v_over_r := repeat('ệ', (3501 - v_base) / 3) || repeat('a', (3501 - v_base) % 3);

  -- Both sides of the edge, measured with the quote forced in -- the function's own decision is
  -- what is under test, so the fixture does not ask it.
  if octet_length(convert_to((public.refusal_payload('Edge', v_today, 'a')
         || jsonb_build_object('quote', v_edge_r))::text, 'UTF8')) <> 3500
     or octet_length(convert_to((public.refusal_payload('Over', v_today, 'a')
         || jsonb_build_object('quote', v_over_r))::text, 'UTF8')) <> 3501 then
    raise exception 'Fixture: the edge and over payloads are not 3500 and 3501 bytes.';
  end if;

  select count(*) into v_before from public.outbox;

  -- =================================================================================
  -- Steps 2-5, as the referee.
  -- =================================================================================
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_ref, 'role', 'authenticated',
                                       'app_role', 'referee')::text, true);
  perform set_config('role', 'authenticated', true);

  perform public.sign_off_day(v_plain, v_today, false, 'That is yesterday''s pill.');
  perform public.sign_off_day(v_ok, v_today, true, null);
  perform public.sign_off_day(v_hostile, v_today, false,
                              'He is currently on his phone. Right now, at the moment, just now.');
  perform public.sign_off_day(v_edge, v_today, false, v_edge_r);
  perform public.sign_off_day(v_over, v_today, false, v_over_r);
  perform public.sign_off_day(v_big, v_today, false, v_big_r);
  perform public.sign_off_day(v_long, v_today, false, 'Not that one.');

  -- A second refusal of a decided day: raised, and nothing more enqueued.
  v_raised := null;
  begin
    perform public.sign_off_day(v_plain, v_today, false, 'Again.');
  exception when others then
    v_raised := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  if v_raised is distinct from 'That day has already been decided, and a decision is final.' then
    raise exception 'A second refusal of a decided day raised %, wanted the already-decided refusal.',
      coalesce(v_raised, 'nothing');
  end if;

  -- Six refusals, one approval, one repeat: exactly six pushes.
  select count(*) - v_before into v_count from public.outbox;
  if v_count <> 6 then
    raise exception using message = format(
      'Seven decisions and one repeat enqueued %s outbox row(s), wanted 6: one per refusal, none '
      'for the approval, none for the repeat.', v_count);
  end if;

  -- Every one of them, keyed by its own decision and aimed at the author.
  for v_row in
    select d.id, d.commitment_id, d.approved, d.reason, c.name,
           o.owner_id, o.channel, o.payload
      from public.referee_decision d
      join public.commitment c on c.id = d.commitment_id
      left join public.outbox o on o.dedupe_key = 'refusal-' || d.id::text
     where d.subject = v_doer
  loop
    if v_row.approved then
      if v_row.payload is not null then
        raise exception 'The approval of % enqueued a push. An approval changes nothing.',
          v_row.name;
      end if;
      continue;
    end if;

    if v_row.payload is null then
      raise exception 'The refusal of % enqueued nothing under refusal-<decision id>.', v_row.name;
    end if;

    if v_row.owner_id is distinct from v_doer or v_row.channel is distinct from 'push' then
      raise exception 'The refusal of % went to % on %, wanted the author on push.',
        v_row.name, v_row.owner_id, v_row.channel;
    end if;

    -- Compared exactly, never with LIKE: a name containing % or _ would match more than itself.
    v_reason := case when char_length(btrim(v_row.name)) > 80
                     then left(btrim(v_row.name), 79) || '…'
                     else btrim(v_row.name) end || ' — your referee refused it';
    if v_row.payload->>'title' is distinct from v_reason then
      raise exception 'The title "%" is not the commitment name "%" followed by the refusal.',
        v_row.payload->>'title', v_row.name;
    end if;

    if not public.push_body_is_sendable(v_row.payload->>'body')
       or v_row.payload->>'body' not like '%' || to_char(v_today, 'YYYY-MM-DD') || '%'
       or v_row.payload->>'body' not like '%' || to_char(v_today, 'FMDay') || '%' then
      raise exception 'The body for % does not name the day or would not pass the check: "%"',
        v_row.name, v_row.payload->>'body';
    end if;

    -- Byte-for-byte, where it travels at all.
    if v_row.payload ? 'quote' and v_row.payload->>'quote' is distinct from v_row.reason then
      raise exception 'The quote for % is not the stored reason verbatim.', v_row.name;
    end if;
  end loop;

  raise notice using message =
    'Steps 2-4 ok: six refusals, six pushes -- each to the author on push, keyed by its own '
    'decision, the name in the title (clipped at 80 characters), the day in a sendable body, the '
    'reason verbatim -- and none for the approval or the repeat. "right now" in a name and '
    '"currently" in a reason aborted nothing.';

  -- =================================================================================
  -- Step 5: the byte budget.
  -- =================================================================================
  for v_row in
    select c.id, c.name, o.payload
      from public.referee_decision d
      join public.commitment c on c.id = d.commitment_id
      join public.outbox o on o.dedupe_key = 'refusal-' || d.id::text
     where d.subject = v_doer and c.id in (v_plain, v_hostile, v_edge, v_over, v_big)
  loop
    if (v_row.id in (v_plain, v_hostile, v_edge)) <> (v_row.payload ? 'quote') then
      raise exception using message = format(
        'The push for %s %s a quote. Exactly 3500 bytes carries it; 3501 and a 4500-byte reason '
        'do not.', v_row.name,
        case when v_row.payload ? 'quote' then 'carries' else 'is missing' end);
    end if;

    if not (v_row.payload ? 'quote')
       and v_row.payload->>'body' not like '%in your Ledger after midnight%' then
      raise exception 'The quote-less push for % does not say where the reason is.', v_row.name;
    end if;
  end loop;

  raise notice using message =
    'Step 5 ok: a payload of exactly 3500 bytes carries the reason, one of 3501 and a 4500-byte '
    'Vietnamese reason leave it out whole and point at the Ledger, and all five refusals landed.';
end $$;


-- =================================================================================
-- Step 6: one door, and the telling beside it.
-- =================================================================================
do $$
declare
  v_def text := pg_get_functiondef('public.sign_off_day(uuid, date, boolean, text)'::regprocedure);
begin
  if v_def not like '%photograph_reaches_the_referee%'
     or v_def like '%join public.declaration d on d.id = e.declaration_id%' then
    raise exception 'sign_off_day() no longer reads photograph_reaches_the_referee() alone.';
  end if;

  if v_def not like '%refusal_payload%' or v_def not like '%''refusal-'' ||%' then
    raise exception
      'sign_off_day() no longer builds its push through refusal_payload() under a refusal- key.';
  end if;

  -- The only writer of a refusal key. settle_day() and every other enqueuer build their own
  -- prefixes; a silence has no transaction to enqueue from, so this is what "none for a silence"
  -- rests on.
  if (select array_agg(p.proname::text order by p.proname)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prosrc like '%''refusal-''%')
     is distinct from array['sign_off_day'] then
    raise exception 'Something other than sign_off_day() now writes a refusal- outbox key.';
  end if;

  raise notice using message =
    'Step 6 ok: sign_off_day() still reads the one door, tells the author through '
    'refusal_payload(), and is the only writer of a refusal- key.';
  raise notice using message =
    'PASS. A refusal tells the author once, in words nobody''s wording can break.';
end $$;

rollback;
