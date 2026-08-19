-- Closes two holes the Supabase security advisor found immediately after the first
-- migration. Kept as a separate migration rather than folded back into that file:
-- migrations are append-only once applied, and the correction is more instructive in
-- the history than a tidy first file would have been.
--
-- Every later migration should run `get_advisors` after applying. It caught both of
-- these in seconds, and neither was visible by reading the SQL.

-- 1. `role_from_table` never needed SECURITY DEFINER.
--
-- It reads only the caller's own role, and the `profile: read own` policy already grants
-- exactly that. Running it as DEFINER bought nothing and put a privilege boundary in the
-- path of a function that every write policy will call. As INVOKER the semantics are
-- identical — the caller's own row for a signed-in session, and null for `anon`, whose
-- `auth.uid()` is null and whose read the policy therefore denies.
--
-- The grant to `authenticated` stays: a policy that calls a function requires the
-- querying role to hold EXECUTE, and revoking it would turn "zero rows" into
-- "permission denied for function" on every table guarded this way.
create or replace function public.role_from_table()
returns public.app_role
language sql
stable
security invoker
set search_path = ''
as $$
  select role from public.profile where id = (select auth.uid())
$$;

comment on function public.role_from_table() is
  'WRITE AND MONEY PATHS. Always current. Use in every `with check`. SECURITY INVOKER: '
  'it reads only the caller''s own row, through the same policy any other read uses.';

-- 2. `handle_new_user` was reachable at /rest/v1/rpc/handle_new_user.
--
-- It is a trigger function and must stay SECURITY DEFINER — it inserts the profile row
-- that no client policy permits, which is the point: an account that could create its own
-- profile could choose its own role. But nothing should be able to call it directly.
-- A trigger invokes its function regardless of EXECUTE grants, so revoking costs nothing.
revoke execute on function public.handle_new_user() from public, anon, authenticated;
