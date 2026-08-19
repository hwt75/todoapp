-- Closes a hole the previous migration opened, and that I claimed was closed.
--
-- `grant update (morning_hour)` ADDS a column privilege. It does not remove the
-- table-wide UPDATE that Supabase's default privileges had already granted to
-- `authenticated`, so the column grant was decoration and every account could set its own
-- `role`.
--
-- Found by trying it rather than by reading it: a signed-in account promoted itself to
-- `referee` on the first attempt. That is the exact escalation AD-12 exists to prevent —
-- a referee rules on appeals, so an account that can promote itself can rule on its own.
-- The Supabase security advisor did not flag it and reported the schema clean.
--
-- The revoke has to come first. A column grant only constrains when there is no broader
-- grant sitting behind it. `lib/roles.test.ts` now fails the build on a column grant that
-- has no matching revoke.

revoke update on table public.profile from anon, authenticated;
grant update (morning_hour) on table public.profile to authenticated;

-- Undo the damage from the verification run.
update public.profile set role = 'doer' where role = 'referee';
