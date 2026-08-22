-- The first migration, and therefore the one that sets the conventions every later
-- migration copies. Three of them are load-bearing:
--
-- 1. A table and its row-level security arrive in the same migration. Never a
--    follow-up. A table that exists for one deploy without policies has been readable
--    by anyone holding the publishable key for the length of that deploy.
--
-- 2. Every function pins `search_path` to empty and fully qualifies its references.
--    A SECURITY DEFINER function that resolves names through a caller-controlled
--    search_path is a privilege escalation, and two of the functions below are
--    SECURITY DEFINER by necessity.
--
-- 3. Role is resolved through exactly two named functions, and which one a policy may
--    call depends on what the policy guards. See the block above them.

create type public.app_role as enum ('doer', 'referee');

create table public.profile (
  id uuid primary key references auth.users (id) on delete cascade,
  role public.app_role not null default 'doer',
  created_at timestamptz not null default now()
);

comment on table public.profile is
  'One row per account. `role` is the server-side source of truth for authorization (AD-12); '
  'it is never writable from a client session.';

alter table public.profile enable row level security;

-- Read your own row, and nothing else. Not an error for anyone else's — RLS filters
-- rather than refuses, because a 403 would confirm the row exists.
create policy "profile: read own"
  on public.profile
  for select
  to authenticated
  using ((select auth.uid()) = id);

-- There is deliberately no insert, update or delete policy for `authenticated`.
-- The row is created by the trigger below, and `role` is the one column a client must
-- never be able to change — an account that can promote itself to referee can rule on
-- its own appeals, which is the whole mechanism this product sells.


-- ---------------------------------------------------------------------------------
-- Role resolution. Two functions, and the choice between them is not a matter of taste.
--
-- `role_from_token` reads the claim the auth hook stamped into the JWT. It costs
-- nothing, and it is STALE until the access token refreshes. Use it to decide what a
-- session may *read*.
--
-- `role_from_table` reads the profile row. It is always current, so revoking a referee
-- bites immediately. Use it for every write, and for anything that moves money.
--
-- The names say which is which on purpose, and `lib/roles.test.ts` fails the build if a
-- `with check` clause anywhere in this directory calls `role_from_token`. Two sources of
-- truth for one question is a real cost; the guard is what makes it affordable.
-- ---------------------------------------------------------------------------------

create function public.role_from_token()
returns public.app_role
language sql
stable
set search_path = ''
as $$
  select nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'app_role',
    ''
  )::public.app_role
$$;

comment on function public.role_from_token() is
  'READ PATHS ONLY. Fast, and stale until the access token refreshes. Returns null when '
  'the claim is absent, so a policy using it denies rather than grants.';

create function public.role_from_table()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.profile where id = (select auth.uid())
$$;

comment on function public.role_from_table() is
  'WRITE AND MONEY PATHS. Always current. Use in every `with check`.';

revoke execute on function public.role_from_token() from public;
revoke execute on function public.role_from_table() from public;
grant execute on function public.role_from_token() to authenticated;
grant execute on function public.role_from_table() to authenticated;


-- ---------------------------------------------------------------------------------
-- A profile exists for every account, created server-side.
--
-- SECURITY DEFINER because the client has no insert policy and must not have one:
-- letting a session create its own profile row means letting it choose its own role.
-- ---------------------------------------------------------------------------------

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profile (id, role) values (new.id, 'doer');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ---------------------------------------------------------------------------------
-- The auth hook that puts `app_role` into the access token.
--
-- This function is created here, but the hook is not active until it is selected in
-- the dashboard under Authentication -> Hooks (Customize Access Token). Until then
-- `role_from_token()` returns null and every policy built on it denies — which is the
-- correct direction to fail, but it means read paths look broken rather than open.
-- ---------------------------------------------------------------------------------

create function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  claims jsonb;
  found_role public.app_role;
begin
  select p.role into found_role
    from public.profile p
   where p.id = (event ->> 'user_id')::uuid;

  claims := event -> 'claims';

  if found_role is not null then
    claims := jsonb_set(claims, '{app_role}', to_jsonb(found_role::text));
  else
    -- Explicitly null rather than absent, so a downstream reader cannot mistake
    -- "no profile yet" for "claim was dropped".
    claims := jsonb_set(claims, '{app_role}', 'null'::jsonb);
  end if;

  return jsonb_set(event, '{claims}', claims);
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;

-- The hook runs as supabase_auth_admin, which is subject to RLS on public.profile like
-- anyone else. Without this policy the hook reads nothing and every token is stamped
-- with a null role.
grant select on table public.profile to supabase_auth_admin;

create policy "profile: auth admin reads for the token hook"
  on public.profile
  for select
  to supabase_auth_admin
  using (true);
