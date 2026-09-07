-- At most one live doer.
--
-- `is_live_doer` marks the real account among the unlimited ones `sign-in.tsx`'s open signup can
-- produce. AD-16 leans on it: `settle_day()` raises rather than skipping when `p_override` meets a
-- live doer, so one live account disables the override path for the whole call. Until today it also
-- decided who could hand out the referee slot -- and the referee read every account's appeals,
-- evidence, settlements and penalties.
--
-- Nothing ever enforced that there was only one. The live project carried **two** on 2026-09-07,
-- one of them an empty account flagged by hand during testing, and neither the schema nor any test
-- would have said so. `paired_doer_id()` even resolved through a scalar subquery over that flag,
-- which raises rather than answers when it matches more than one row -- reachable only because a
-- coalesce short-circuited past it.
--
-- The referee no longer reads it at all (20260907160000, 20260907170000), so what is left is AD-16.
-- One account, enforced the same way `profile_one_referee_per_doer` is: by the index, not by a
-- convention nobody can see.

create unique index profile_one_live_doer
  on public.profile ((true))
  where is_live_doer;

comment on index public.profile_one_live_doer is
  'At most one account may carry is_live_doer. A partial unique index on a constant, so every
  flagged row indexes to the same value and the second is refused by Postgres regardless of timing
  -- the shape profile_one_referee_per_doer uses for the same reason. The flag is not
  client-writable (only morning_hour is granted to authenticated, 20260819201000), so this guards
  the dashboard and the SQL console, which is exactly where the second one came from.';
