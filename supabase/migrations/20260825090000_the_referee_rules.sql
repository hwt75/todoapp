-- Story 4.6 — The referee rules (FR-20).
--
-- A Held Penalty (4.4) has had no way to resolve except timing out in the author's favour --
-- the referee could read an Appeal (4.5) but had no write access at all. This is his first
-- write: one `security definer` function, gated by `role_from_table()` (never
-- `role_from_token()` -- `lib/roles.ts`'s own rule for anything guarding money), directly
-- callable by an `authenticated` referee session rather than fronted by an Edge Function --
-- unlike pairing (Story 4.5), this needs no service-role key, and the function itself is the
-- privilege boundary, the same shape `settle_day`/`void_expired_appeals` already use for
-- schedule-only functions, just granted to `authenticated` instead of revoked from it.
--
-- Both rulings perform the exact guarded, first-writer-wins transition `void_expired_appeals()`
-- already uses (`update penalty set state = <target> where id = :id and state = 'held'`) --
-- AD-15's shared machinery, so a raced timeout or a second ruling call finds zero rows and is
-- refused with a clear message, never silently ignored (mirrors `appeal_hold_penalty()`'s own
-- `if not found then raise`).
--
-- Rejection ("He didn't") is the transition alone: `held -> owed`, nothing else.
--
-- Approval ("He did it") is `held -> voided`, then an append-only corrective settlement --
-- mirroring `supersede_expiries()`'s pattern (recompute `admitted`/`silent`, insert a
-- `settlement` row with `supersedes`, insert a `penalty` only if still owed) -- recomputing
-- the day's verdict with the appealed commitment_id excluded from `admitted`, using
-- `settle_day()`'s own current formula verbatim (20260824100000: the `cadence <>
-- 'weekly_quota'` exclusion included) rather than a hardcoded `verdict = 'clean'`. Unlike
-- `supersede_expiries()`'s own first cut, this also freezes `settlement_commitment` for the
-- correction -- the fix `20260820102000_supersession_freezes_the_day.sql` already made for
-- exactly this shape of bug (a correction with no frozen outcomes vanishes the whole day from
-- every commitment's chain, not only the appealed one, because `chain_current` reads only
-- `settlement_current`). The appealed commitment freezes as `held` here regardless of what its
-- own machine-filed declaration says -- that is the entire content of "He did it": the
-- machine's `missed` did not happen, and the chain has to say so, not merely stop charging for
-- it.
--
-- Either ruling enqueues one outbox notification to the author, in the same transaction as the
-- state change (AD-3), keyed `ruling-<appeal_id>` -- an appeal can only ever be ruled once (the
-- guard above), so this key is never written twice, and a race loser never reaches the enqueue
-- call at all (its own guarded update already raised).

alter type public.penalty_state add value if not exists 'voided';

comment on type public.penalty_state is
  'owed (2.6); held, dropped (4.4, an Appeal in flight or timed out in the author''s favour); '
  'voided (4.6, an Appeal the referee approved -- distinct from dropped, which nobody ruled '
  'on). collected (4.7) and waived (5.1, Grace Day -- a different fact entirely) are still '
  'ahead.';


-- ---------------------------------------------------------------------------------
-- The ruling's own notification body. Self-dates with the appealed day's weekday
-- (`push_body_is_sendable` requires either a clock time or a named weekday), mirroring
-- `week_summary_body`'s "week of <Weekday>, <date>" shape -- amount named once, past tense,
-- UX-DR24's own plain language ("He did it" / "He didn't") carried straight into the
-- author-facing sentence rather than a bureaucratic "approved"/"rejected".
-- ---------------------------------------------------------------------------------

create function public.appeal_ruling_body(p_approved boolean, p_for_day date, p_amount bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_approved then
      'The referee ruled: he did it. ' || translate(to_char(p_amount, 'FM999G999G999'), ',', '.')
        || '₫ for ' || to_char(p_for_day, 'FMDay') || ', ' || to_char(p_for_day, 'YYYY-MM-DD')
        || ' is cleared.'
    else
      'The referee ruled: he didn''t. '
        || translate(to_char(p_amount, 'FM999G999G999'), ',', '.') || '₫ for '
        || to_char(p_for_day, 'FMDay') || ', ' || to_char(p_for_day, 'YYYY-MM-DD') || ' is owed.'
  end;
$$;

comment on function public.appeal_ruling_body(boolean, date, bigint) is
  'The ruling notification''s body. Self-dates with the appealed day''s own weekday '
  '(push_body_is_sendable has no clock time to reach for here). UX-DR24''s plain language '
  '("He did it" / "He didn''t") carried into the author-facing sentence.';

revoke execute on function public.appeal_ruling_body(boolean, date, bigint)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The ruling itself.
-- ---------------------------------------------------------------------------------

create function public.rule_appeal(p_appeal_id uuid, p_approved boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appeal record;
  v_amount bigint;
  v_admitted integer;
  v_silent integer;
  v_verdict public.day_verdict;
  v_correction uuid;
begin
  -- First statement, before any row of the appeal itself is read -- the I/O Matrix's own
  -- "Non-referee calls rule_appeal()" row: refused before any read. role_from_table() is
  -- invoker-rights over public.profile (lib/roles.ts), always current, never the token.
  -- `is distinct from`, not `<>` -- mirroring appeal_hold_penalty()'s own idiom
  -- (`v_filed_by is distinct from 'auto_check'`): a plain `<>` against a NULL role (no
  -- profile row for this session, however that came to be) evaluates NULL, and `if NULL
  -- then raise` never raises in plpgsql -- the refusal would silently not happen for the
  -- one caller a role check exists to catch. `is distinct from` never returns NULL.
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may rule on an appeal.';
  end if;

  -- Same NULL hazard, same fix: `if not p_approved then` below treats a NULL argument as
  -- false and would fall through into the *approval* branch -- voiding a Held Penalty and
  -- correcting the day -- for a malformed call that named no ruling at all. Checked before
  -- the appeal itself is ever read, same as the role check above.
  if p_approved is null then
    raise exception 'p_approved must not be null.';
  end if;

  select * into v_appeal from public.appeal where id = p_appeal_id;

  if not found then
    raise exception 'No such appeal.';
  end if;

  if not p_approved then
    -- "He didn't": the guarded transition alone, identical shape to
    -- void_expired_appeals()'s own held -> dropped. No settlement change (I/O Matrix: "Reject").
    update public.penalty
       set state = 'owed'
     where id = v_appeal.penalty_id and state = 'held'
    returning amount_dong into v_amount;

    if not found then
      raise exception
        'This appeal has already been resolved -- by an earlier ruling or by timing out.';
    end if;

    perform public.outbox_enqueue(
      v_appeal.owner_id,
      'ruling-' || p_appeal_id::text,
      jsonb_build_object(
        'title', 'The referee ruled',
        'body', public.appeal_ruling_body(false, v_appeal.for_day, v_amount),
        'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      )
    );

    return;
  end if;

  -- "He did it": the same guarded transition, voiding rather than reverting -- the race
  -- guard is this update alone; everything below only ever runs for the single call that
  -- actually won it.
  update public.penalty
     set state = 'voided'
   where id = v_appeal.penalty_id and state = 'held'
  returning amount_dong into v_amount;

  if not found then
    raise exception
      'This appeal has already been resolved -- by an earlier ruling or by timing out.';
  end if;

  -- The day's verdict, recomputed with the appealed commitment excluded from admitted --
  -- settle_day()'s own current formula (20260824100000), mirrored exactly, including the
  -- weekly_quota exclusion (a Weekly Quota commitment's own money is never decided by a
  -- daily settlement, appealed or not). silent is always 0 in practice here -- a Held
  -- Penalty only ever sits on a settlement that read `failed` (appeal_hold_penalty()'s own
  -- eligibility check), and a `failed` verdict only happens once every commitment for the
  -- day has already answered -- but it is computed the same way settle_day() does regardless,
  -- rather than assumed away.
  select count(*) filter (
           where o.carries_penalty and o.answer = 'slipped' and o.cadence <> 'weekly_quota'
             and o.commitment_id <> v_appeal.commitment_id
         ),
         count(*) filter (
           where o.carries_penalty and o.answer is null and o.cadence <> 'weekly_quota'
             and o.commitment_id <> v_appeal.commitment_id
         )
    into v_admitted, v_silent
    from public.commitments_owing(v_appeal.owner_id, v_appeal.for_day) o;

  v_verdict := case when v_admitted + v_silent > 0 then 'failed' else 'clean' end;

  insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
  values (
    v_appeal.owner_id, v_appeal.for_day, 'day', v_verdict, v_admitted + v_silent,
    v_appeal.settlement_id
  )
  returning id into v_correction;

  -- What each commitment did, frozen against the correction -- supersede_expiries()'s own
  -- fix (20260820102000) for the identical shape of bug, mirrored here: chain_current reads
  -- only settlement_current, so a correction with no frozen outcomes would vanish the whole
  -- day from every commitment's chain, not only the appealed one. The appealed commitment
  -- reads `held` unconditionally -- the machine's own `missed` is exactly what this ruling
  -- overturned, so freezing it as `missed` again here would restore the money and keep the
  -- broken chain, which is not what "He did it" means.
  insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
  select v_correction, v_appeal.owner_id, o.commitment_id,
         case
           when o.commitment_id = v_appeal.commitment_id then 'held'
           when o.answer = 'held' then 'held'
           when o.answer = 'slipped' then 'missed'
           else 'unanswered'
         end::public.commitment_outcome
    from public.commitments_owing(v_appeal.owner_id, v_appeal.for_day) o;

  -- A new, smaller-context penalty only if the day still owes one once the appealed
  -- commitment no longer counts -- FR-13's bundling rule applied to the correction exactly
  -- as settle_day()/supersede_expiries() apply it to their own inserts. Only the appealed
  -- Penalty voids; a second, non-appealed miss the same day still costs what it always did.
  if (v_admitted + v_silent) > 0 then
    insert into public.penalty (subject, settlement_id, amount_dong)
    values (v_appeal.owner_id, v_correction, public.penalty_amount_dong());
  end if;

  perform public.outbox_enqueue(
    v_appeal.owner_id,
    'ruling-' || p_appeal_id::text,
    jsonb_build_object(
      'title', 'The referee ruled',
      'body', public.appeal_ruling_body(true, v_appeal.for_day, v_amount),
      'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    )
  );
end;
$$;

comment on function public.rule_appeal(uuid, boolean) is
  'FR-20. The referee''s ruling on a Held Penalty: role_from_table() = ''referee'' checked '
  'first, before any row is read. Reject (held -> owed) changes only the Penalty. Approve '
  '(held -> voided) also inserts a corrective settlement -- admitted/silent recomputed with '
  'the appealed commitment excluded (settle_day()''s own formula), a new penalty only if '
  'another genuine miss remains, and settlement_commitment frozen for the correction so the '
  'chain reads restored, not merely skipped. Either path is the single guarded transition '
  'void_expired_appeals() already uses (AD-15): a raced timeout or a second ruling call finds '
  'zero rows and raises, never silently no-ops. Enqueues one outbox notification to the '
  'author in the same transaction (AD-3), keyed by appeal id so a race loser -- which never '
  'gets past its own guard -- never double-enqueues.';

-- Directly callable by an authenticated referee session (unlike settle_day/settle_week,
-- schedule-only, or appeal_hold_penalty, trigger-only) -- the function itself is the
-- privilege boundary, exactly like appeal_hold_penalty's own security-definer role check,
-- just reached over /rest/v1/rpc instead of a trigger.
revoke execute on function public.rule_appeal(uuid, boolean) from public, anon;
grant execute on function public.rule_appeal(uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------------
-- Evidence, for the referee. Story 4.5 already lets him read appeal_evidence's own metadata
-- row (the RLS-table policy); nothing yet let him load the actual object the metadata
-- describes. NFR4's own rule -- visible to the submitting owner and the ruling referee,
-- nobody else -- was only ever half built (Story 4.4 flagged the gap in its own review).
-- A third storage.objects policy, alongside the two owner-only ones from 20260824130000,
-- rather than replacing either: the owner still uploads and reads his own evidence exactly
-- as before.
-- ---------------------------------------------------------------------------------

create policy "appeal-evidence objects: referee reads all"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'appeal-evidence'
    and public.role_from_token() = 'referee'
  );
