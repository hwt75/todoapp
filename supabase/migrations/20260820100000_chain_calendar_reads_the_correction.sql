-- The Chains-detail calendar reads the correction, not the original.
--
-- Epic 2's retrospective found the one place in the product that reads a settlement-derived
-- base table directly: `components/chains-detail.tsx` selected from `settlement_commitment`
-- and joined `settlement_id(period)` back to `settlement`. Every other read in the codebase
-- goes through a `*_current` view, and both Story 2.7's and Story 2.9's specs claim that a
-- check confirms it — the check that exists asserts only that `chain_current`'s own SQL text
-- names `settlement_current`, so the component was outside its reach (A2).
--
-- The cost was not cosmetic. After a supersession the chain number follows the correction
-- (AD-9) while the calendar went on showing the superseded verdict's marks forever: two
-- surfaces of the same commitment disagreeing about the same day, with the wrong one being
-- the one that shows `unanswered` against a day he answered.
--
-- So the outcomes get the same treatment the verdicts and the penalties already have: a view
-- that follows the chain, and a component that has nothing to join.

create view public.settlement_commitment_current
with (security_invoker = true)
as
select sc.settlement_id,
       sc.subject,
       sc.commitment_id,
       sc.outcome,
       s.period,
       s.verdict
  from public.settlement_commitment sc
  join public.settlement_current s on s.id = sc.settlement_id;

comment on view public.settlement_commitment_current is
  'Frozen commitment outcomes for the settlements that still stand. The Chains-detail '
  'calendar reads this; `chain_current` derives the same join for its own arithmetic. A '
  'superseded day''s outcomes drop out of both together, so the number and the calendar '
  'cannot disagree about a day (AD-9).';

-- One consequence, stated rather than discovered later: while `supersede_expiries()` writes
-- a correction with no outcome rows of its own (A1, unfixed at the time of writing and
-- gated on `supabase/tests/2-7-supersession.sql` being run), a corrected day now shows
-- *nothing* on the calendar instead of showing the superseded verdict's marks. That is the
-- lesser of the two wrongs and it is the same wrong the chain already has, which is the
-- point: one defect in one place, visible in both surfaces at once, instead of two surfaces
-- quietly telling different stories about the same day.
