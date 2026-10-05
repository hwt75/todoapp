-- A Do-it commitment on an hours quota cannot ask for the referee's signature.
--
-- Deferred from Story 8.1, done on hwt75's decision of 2026-10-05. `commitment_sign_off_needs_a_do`
-- (20260911090000:61) constrains the kind only, so `do` + `daily_hours_quota` + the flag was
-- saveable and inert: `commitments_owing()` excludes that cadence outright, no day of it can ever be
-- signed off, and the setup warning told the author his friend could refuse it. Story 8.2 closed the
-- RPC half -- sign_off_day() refuses a refusal on that cadence with its own sentence -- and this
-- closes the row half.
--
-- sign_off_day()'s guard stays: a commitment flagged as of the day can still be moved to an hours
-- quota later that day by an update that switches the flag off at the same time, and sign_off_day()
-- reads the cadence live. 8-2-the-referee-s-decision-and-what-a-refusal-costs.sql builds that path.
--
-- **Checked against the live project before writing this** (2026-10-05): no commitment carries the
-- flag on an hours quota, so the check is added validated.

alter table public.commitment
  add constraint commitment_sign_off_not_on_hours_quota
    check (not requires_referee_approval or cadence <> 'daily_hours_quota');

comment on constraint commitment_sign_off_not_on_hours_quota on public.commitment is
  'An hours quota is judged by banked minutes and commitments_owing() excludes it, so no day of one
  can ever be signed off. Story 8.1''s deferred half: commitment_sign_off_needs_a_do names the kind
  only. sign_off_day() keeps its own refusal for a commitment flagged as of the day and moved to an
  hours quota afterwards.';
