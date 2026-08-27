-- Epic 5 retrospective (2026-08-26), action item 5, proposed here as its own migration --
-- `settlement_current` (20260819241000) has been `select s.*` since the day it was created.
-- `penalty_current` hit exactly the mechanical consequence of that shape on 2026-08-25/26
-- (finding SM-4 / the Story 5.4 fix, `20260826110000...sql`): `create or replace view` never
-- lets a `*`-expanded view change an existing output column's position, and `alter table ...
-- add column` always appends the new column at the end of the base table -- so the very next
-- `settlement` column ever added would try to rename an existing view column and fail with
-- Postgres 42P16, exactly like `penalty_current` just did. This closes the identical gap
-- proactively, before it recurs -- `chain_current` and `penalty_current` both depend on
-- `settlement_current`, so the blast radius here is wider than `penalty_current`'s own was.
--
-- Every existing column is spelled out explicitly, in its original order (id, subject,
-- period, kind, verdict, missed_count, settled_at, supersedes) -- genuinely a no-op today,
-- the same as `penalty_current`'s own fix was: no column renamed, none reordered, none
-- dropped. The next `alter table public.settlement add column ...` can then append its new
-- column to this view's own select list, last, without ever touching the columns before it.

create or replace view public.settlement_current
with (security_invoker = true)
as
select s.id, s.subject, s.period, s.kind, s.verdict, s.missed_count, s.settled_at, s.supersedes
  from public.settlement s
 where not exists (select 1 from public.settlement c where c.supersedes = s.id);

comment on view public.settlement_current is
  'The current state of every settled period: the end of each supersession chain (AD-9).
  Columns spelled out explicitly (Epic 5 retrospective, 2026-08-27, action item 5) so the
  next settlement column added can append here without Postgres 42P16 -- the exact
  view-column-freeze error penalty_current hit for the identical reason, one day earlier.';
