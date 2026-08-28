-- The referee signs himself up, from an invitation the doer minted.
--
-- `pair-referee` (Story 4.5) creates the account outright and hands the doer a generated
-- password to relay by text, call or in person. That works, and it stays. What it cannot do
-- is let the referee choose a secret the doer never saw: a password read off someone else's
-- screen is known to two people from the moment it exists, and the person it authenticates
-- is not the one who chose it.
--
-- This migration adds the one piece an invitation needs that the application cannot hold
-- safely on its own: a server-side record of who was invited, by whom, until when, and
-- whether the invitation has already been spent.
--
-- **The live-doer gate does not move.** `20260824160000`'s own header explains why the
-- referee's unscoped read of every appeal, every piece of evidence, every settlement and
-- every penalty is safe: the one referee that can ever exist was paired by the real doer,
-- never by one of the unrestricted self-registered accounts `sign-in.tsx`'s open signup can
-- produce. An invitation changes who picks the password. It does not change who is allowed
-- to decide that a referee exists at all -- `invite-referee` re-checks `is_live_doer`
-- exactly as `pair-referee` does, and this table is written by nothing else.
--
-- The token itself is never stored. Only its SHA-256, so a leaked copy of this table is not
-- a set of usable invitations -- the same reason a password column would hold a hash.

create table public.referee_invite (
  id uuid primary key default gen_random_uuid(),

  -- Fixed by the doer at mint time and never read from the acceptance request. This is the
  -- whole reason the address lives here rather than in the link: a token that carried its
  -- own email would let whoever holds it register any address they liked, and the doer's
  -- choice of *who* would be advisory.
  email text not null,

  -- SHA-256 of the token, hex. `unique` so a lookup by hash is an index probe rather than a
  -- scan, and so two invitations can never collide into one row.
  token_hash text not null unique,

  created_by uuid not null references public.profile (id) on delete cascade,
  created_at timestamptz not null default now(),

  -- An invitation that is never accepted has to stop being usable on its own. Enforced in
  -- `accept-referee-invite`, not by a constraint here: expiry is a comparison against the
  -- clock at read time, and a check constraint is evaluated at write time only.
  expires_at timestamptz not null,

  accepted_at timestamptz,
  accepted_by uuid references public.profile (id) on delete set null,

  -- Set when the doer mints a replacement. Superseding rather than deleting, so "this link
  -- stopped working" has a recorded answer instead of a missing row.
  revoked_at timestamptz,

  -- Stored rather than derived at read time, because the partial unique index below needs
  -- an immutable value to index. `now()` is not immutable, which is exactly why expiry is
  -- deliberately NOT part of this: an expired-but-unspent invitation still occupies the
  -- single outstanding slot until the doer mints a replacement, and that replacement
  -- revokes it in the same transaction.
  outstanding boolean not null
    generated always as (accepted_at is null and revoked_at is null) stored
);

comment on table public.referee_invite is
  'One invitation to become the referee. Minted only by the live doer (invite-referee), '
  'spent only once (accept-referee-invite). The token is stored as a SHA-256, never in the '
  'clear.';

comment on column public.referee_invite.email is
  'The address the referee account will be created with. Taken from this row at acceptance '
  'time, never from the acceptance request -- whoever holds the link cannot choose who they '
  'become.';

-- At most one invitation may be outstanding at a time. The same shape as
-- `profile_single_referee` (20260824160000) and for the same reason: a check-then-act in the
-- Edge Function cannot make this guarantee against a concurrent second mint, and two live
-- links to a single, unrepeatable referee slot is precisely the state worth making
-- unrepresentable. A replacement is minted by revoking the outstanding row first, in one
-- transaction, so the slot is free by the time the insert runs.
create unique index referee_invite_single_outstanding
  on public.referee_invite (outstanding)
  where outstanding;

comment on index public.referee_invite_single_outstanding is
  'At most one outstanding invitation, ever. A partial unique index rather than an '
  'application check, for the reason profile_single_referee gives: timing cannot defeat it.';

alter table public.referee_invite enable row level security;

-- The doer reads the invitations he minted, and nothing else. This is what lets Settings say
-- "an invitation for ref@example.com is outstanding until Friday" after a reload, rather
-- than forgetting the moment the component unmounts.
--
-- Deliberately not scoped to `role_from_token()`: a doer who minted a row is the only
-- account whose id can appear in `created_by` at all, so `auth.uid()` is already the whole
-- filter. Adding a role test would narrow nothing and would go stale with the token.
create policy "referee_invite: read own"
  on public.referee_invite
  for select
  to authenticated
  using ((select auth.uid()) = created_by);

-- There is deliberately no insert, update or delete policy. Every write is an Edge Function
-- holding the service role, which RLS does not apply to.
--
-- The revokes are not decoration, and `20260819201000` is why this migration says so out
-- loud: Supabase's default privileges hand `authenticated` table-wide DML on a new table,
-- and RLS with no permissive policy denies it -- but the two protections are independent,
-- and a later migration that adds a well-meaning policy would find the grant still sitting
-- there. A row this table cannot have written to it is one an account cannot mint itself an
-- invitation with.
revoke all on table public.referee_invite from anon, authenticated;

-- Granted explicitly rather than left to whatever the project's default privileges happen to
-- be. Every other table in this directory relies on those ambient defaults, and
-- `supabase/tests/`'s own headers record the cost: the local stack grants `authenticated`
-- nothing, the live project grants it everything, and each test file has to re-grant by hand
-- before it can prove RLS is the thing refusing a write. A table whose privileges are
-- written down is one where a refusal means what it appears to mean in both places.
--
-- SELECT only, and only for `authenticated`. `referee_invite: read own` narrows that to the
-- rows this account minted; the grant is what makes the policy reachable at all.
grant select on table public.referee_invite to authenticated;

-- The two Edge Functions. `service_role` bypasses RLS, so this grant -- not a policy -- is
-- the whole of their access, and it is why there is no insert/update policy above for anyone
-- else to inherit.
grant select, insert, update on table public.referee_invite to service_role;
