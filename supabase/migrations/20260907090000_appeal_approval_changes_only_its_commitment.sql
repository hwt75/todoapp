-- Epic 6 retrospective item 37: an approved Appeal corrects the settlement the Appeal
-- captured, not a new reading of the owner's live commitments. This matters when that source
-- is already an objection correction: recomputing from commitments_owing() silently erased the
-- referee's frozen `missed` outcome on another commitment.

create or replace function public.rule_appeal(p_appeal_id uuid, p_approved boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appeal record;
  v_amount bigint;
  v_source_missed_count integer;
  v_missed_count integer;
  v_appealed_outcome public.commitment_outcome;
  v_appealed_carries boolean;
  v_appealed_cadence public.commitment_cadence;
  v_verdict public.day_verdict;
  v_correction uuid;
begin
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may rule on an appeal.';
  end if;

  if p_approved is null then
    raise exception 'p_approved must not be null.';
  end if;

  select * into v_appeal from public.appeal where id = p_appeal_id;

  if not found then
    raise exception 'No such appeal.';
  end if;

  if not p_approved then
    update public.penalty
       set state = 'owed'
     where id = v_appeal.penalty_id and state = 'held'
    returning amount_dong into v_amount;

    if not found then
      raise exception
        'This appeal has already been resolved -- by an earlier ruling or by timing out.';
    end if;

    update public.appeal set ruled_at = now() where id = p_appeal_id;

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

  -- AD-15: only the ruling that wins this held -> voided transition may write the
  -- correction, timestamp, or outbox row below.
  update public.penalty
     set state = 'voided'
   where id = v_appeal.penalty_id and state = 'held'
  returning amount_dong into v_amount;

  if not found then
    raise exception
      'This appeal has already been resolved -- by an earlier ruling or by timing out.';
  end if;

  update public.appeal set ruled_at = now() where id = p_appeal_id;

  -- The source settlement is the aggregate the Appeal actually held. Its frozen outcome says
  -- whether this commitment was missed; carries_penalty remains historical by day; cadence is
  -- read only for the existing rule that Weekly Quota misses never contribute to a day Penalty.
  select s.missed_count,
         sc.outcome,
         public.carries_penalty_as_of(sc.commitment_id, s.period),
         c.cadence
    into v_source_missed_count, v_appealed_outcome, v_appealed_carries, v_appealed_cadence
    from public.settlement s
    join public.settlement_commitment sc
      on sc.settlement_id = s.id and sc.commitment_id = v_appeal.commitment_id
    join public.commitment c on c.id = sc.commitment_id
   where s.id = v_appeal.settlement_id;

  v_missed_count := v_source_missed_count
    - case
        when v_appealed_outcome = 'missed'
         and v_appealed_carries
         and v_appealed_cadence <> 'weekly_quota'
        then 1
        else 0
      end;

  v_verdict := case when v_missed_count > 0 then 'failed' else 'clean' end;

  insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
  values (
    v_appeal.owner_id, v_appeal.for_day, 'day', v_verdict, v_missed_count,
    v_appeal.settlement_id
  )
  returning id into v_correction;

  -- Freeze the complete source day verbatim, changing only the commitment this Appeal names.
  -- Never rebuild a correction from commitments_owing(): live state cannot reproduce an earlier
  -- objection, archive, or other correction.
  insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
  select v_correction, sc.subject, sc.commitment_id,
         case
           when sc.commitment_id = v_appeal.commitment_id
             then 'held'::public.commitment_outcome
           else sc.outcome
         end
    from public.settlement_commitment sc
   where sc.settlement_id = v_appeal.settlement_id;

  if v_missed_count > 0 then
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
  'FR-20 / Epic 6 retrospective item 37. The referee role and non-null ruling are checked '
  'before the Appeal is read. Reject keeps the existing held -> owed Penalty transition and '
  'writes no correction. Approve wins the guarded held -> voided transition, then supersedes '
  'the settlement captured by the Appeal: it copies that settlement''s complete frozen outcome '
  'set, changes only the appealed commitment to held, and derives missed_count from the source '
  'aggregate minus that row only when its historical carries_penalty flag and live non-weekly '
  'cadence made it a day-Penalty contributor. Both branches stamp ruled_at and enqueue exactly '
  'one ruling notification only after winning the transition; race losers raise and write none.';

revoke execute on function public.rule_appeal(uuid, boolean) from public, anon;
grant execute on function public.rule_appeal(uuid, boolean) to authenticated;
