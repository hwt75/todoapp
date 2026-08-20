-- A correction has to carry the day, not just the verdict.
--
-- `supabase/tests/2-7-supersession.sql` was written to adjudicate a finding the Epic 2
-- retrospective could only read (A1). It ran for the first time today, against this schema,
-- and it confirmed it at step 4:
--
--   A1 CONFIRMED. The correction carries 0 frozen commitment outcomes, expected 1.
--
-- `supersede_expiries()` was authored before `settlement_commitment` existed, and the two
-- later migrations that added outcome writes (`20260819260000_chain.sql:254`,
-- `20260819262000:95`) added them to `settle_day` alone. So a correction wrote a verdict and
-- a penalty and nothing else. `chain_current` joins the outcomes through `settlement_current`,
-- which means the original's outcomes left with the superseded row and the correction brought
-- none: the day vanished from the chain entirely, filed as a day the commitment was not owed
-- — "skipped, not broken", the one reading it must never get.
--
-- The scenario is Story 2.7's own declared acceptance criterion. He answered while offline,
-- inside the deadline; the submission was still queued when 48 hours elapsed. The expiry was
-- taken back, his money was returned — and he was quietly a day short of chain, on the day he
-- had done everything right.
--
-- The fix is the one `settle_day` already makes: freeze what each commitment did, in the same
-- transaction as the verdict, from the answers that turned out to have been given in time.

create or replace function public.supersede_expiries()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_row record;
  morning integer;
  deadline timestamptz;
  total integer;
  timely integer;
  admitted integer;
  correction uuid;
  corrected integer := 0;
begin
  for expired_row in
    select s.* from public.settlement_current s where s.verdict = 'expired'
  loop
    select p.morning_hour into morning from public.profile p where p.id = expired_row.subject;
    deadline := public.declaration_deadline(expired_row.period, morning);

    select count(*),
           count(*) filter (where d.id is not null and d.answered_at < deadline),
           count(*) filter (
             where d.answered_at < deadline and d.answer = 'slipped' and o.carries_penalty
           )
      into total, timely, admitted
      from public.commitments_owing(expired_row.subject, expired_row.period) o
      left join public.declaration d
             on d.commitment_id = o.commitment_id and d.for_day = expired_row.period;

    -- Still short an answer, or an answer that was genuinely late. The expiry stands and
    -- the remedy is a Grace Day, not a rewrite.
    continue when timely < total;

    insert into public.settlement (subject, period, kind, verdict, missed_count, supersedes)
    values (
      expired_row.subject,
      expired_row.period,
      expired_row.kind,
      (case when admitted > 0 then 'failed' else 'clean' end)::public.day_verdict,
      admitted,
      expired_row.id
    )
    returning id into correction;

    -- What each commitment did, frozen against the correction — the half that was missing.
    -- Every answer here is timely by the `continue` above, so the `else` arm is unreachable
    -- rather than lenient; it is written the same way `settle_day` writes it so the two
    -- cannot drift into disagreeing about what an outcome means.
    insert into public.settlement_commitment (settlement_id, subject, commitment_id, outcome)
    select correction, expired_row.subject, o.commitment_id,
           case o.answer
             when 'held' then 'held'
             when 'slipped' then 'missed'
             else 'unanswered'
           end::public.commitment_outcome
      from public.commitments_owing(expired_row.subject, expired_row.period) o;

    -- The correction carries its own penalty if he did admit a slip. The original's penalty
    -- stays in the table as history and stops counting, because `penalty_current` follows
    -- the chain.
    if admitted > 0 then
      insert into public.penalty (subject, settlement_id, amount_dong)
      values (expired_row.subject, correction, public.penalty_amount_dong());
    end if;

    corrected := corrected + 1;
  end loop;

  return corrected;
end;
$$;

revoke execute on function public.supersede_expiries() from public, anon, authenticated;

-- **Still no summary, and that is a decision rather than an oversight.** A corrected day is
-- reached days after the evening it belongs to, so "Four of five on Tuesday. Start with X
-- tomorrow." would arrive as advice about a tomorrow that has already been and gone. The
-- money and the chain are restored silently; the day appears on the Ledger and on the Chains
-- calendar as what it really was. Recorded in deferred-work.md rather than left to be
-- rediscovered, which is the mechanism A3 said this project keeps failing to use.
