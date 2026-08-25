-- Story 4.5 — The referee has his own way in (FR-19).
--
-- The referee's account is created by `supabase/functions/pair-referee`, the one place in
-- this codebase a service-role client may live (`lib/supabase/server.ts`'s own header
-- comment). This migration builds everything that function and the referee's own session
-- depend on afterwards: the guarantee that only one referee profile can ever exist, and the
-- read-only RLS that lets a `role = 'referee'` session see Appeals and Penalties and
-- nothing else (AD-7 — the `/referee` route redirecting a non-referee session, added in
-- `app/page.tsx`, is UX polish, never the enforcement boundary).
--
-- Every new policy here reads `role_from_token()` (`lib/roles.ts`'s own read/write split):
-- this story adds no write path for a referee, so `role_from_table()` is never needed.

-- ---------------------------------------------------------------------------------
-- One referee at most (Non-Goal: "no second Referee... beyond the single doer–Referee
-- pair"). `pair-referee` checks this with a plain read before creating anything — cheap,
-- but a check-then-act race between two concurrent pairing attempts would still let both
-- pass it. This index is the actual guarantee: every row with `role = 'referee'` shares the
-- same indexed value, so a second one violates uniqueness regardless of timing. `pair-referee`
-- treats the resulting 23505 as the same refusal its own early check produces.
-- ---------------------------------------------------------------------------------

create unique index profile_single_referee
  on public.profile (role)
  where role = 'referee';

comment on index public.profile_single_referee is
  'At most one referee profile, ever (Story 4.5 Non-Goal). A partial unique index rather '
  'than an application check, because a check-then-act race in pair-referee cannot make '
  'this guarantee on its own -- every role=''referee'' row indexes to the same value, so a '
  'second one is refused by Postgres regardless of timing.';


-- ---------------------------------------------------------------------------------
-- Appeal and appeal_evidence: read-only, all of them, with no owner_id scoping.
--
-- This is narrower than it looks, not wider than intended: `pair-referee` refuses to create
-- a referee unless the caller's own `profile.is_live_doer` is true (the same AD-16 flag
-- every settlement function already uses to tell the real account from an incidental one --
-- never client-writable, `20260819201000` grants `authenticated` only `morning_hour`). So
-- the one referee that can ever exist was paired by the real doer, not by any of the
-- unrestricted self-registered `role = 'doer'` accounts `sign-in.tsx`'s own open signup can
-- produce (`profile_single_referee` above is genuinely a system-wide "at most one," not "at
-- most one per doer" -- there being at most one referee is what that index guarantees, not
-- that there is at most one doer, which nothing in this schema enforces).
--
-- What this does NOT close: these policies still grant the paired referee a read of every
-- doer account's appeals/evidence/settlements/penalties/commitments, not only the live
-- doer's -- a stranger who self-registers *after* pairing still adds incidental rows the
-- referee can see. Accepted for now (recorded in deferred-work.md): the exposure runs from
-- a stranger's own incidental data toward the referee, never from the live doer's real data
-- toward an unauthorized party, and scoping every policy here to `is_live_doer` is a larger
-- change than this finding's own severity asked for in this round.
-- ---------------------------------------------------------------------------------

create policy "appeal: referee reads all"
  on public.appeal
  for select
  to authenticated
  using (public.role_from_token() = 'referee');

create policy "appeal_evidence: referee reads all"
  on public.appeal_evidence
  for select
  to authenticated
  using (public.role_from_token() = 'referee');

-- No insert, update or delete policy for a referee on either table, on this story's own
-- Always boundary: read-only for the referee, throughout. Ruling (4.6) and collecting (4.7)
-- act on `penalty`, never on `appeal` or `appeal_evidence`.


-- ---------------------------------------------------------------------------------
-- Settlement and penalty: read-only, scoped to `kind in ('day', 'week')` -- FR-19 grants
-- Penalties and Appeals only. `settlement_kind` carries only those two values today, so the
-- clause is trivially true for every row that exists; it is written anyway so a future
-- settlement kind this story never anticipated is refused by construction rather than by
-- someone remembering to update this policy when it is added.
--
-- `penalty` carries no `kind` of its own (only `settlement` does) -- the scoping here joins
-- to `settlement` rather than skip it, for the same future-proofing reason, even though
-- every penalty today is already provably day- or week-kind by construction (it exists only
-- because `settle_day`/`settle_week` inserted it).
--
-- Both `penalty_current` and `settlement_current` (20260819241000) are `security_invoker`
-- views over these two tables -- a referee reading through either view is still governed by
-- the policies below, with no separate grant needed.
-- ---------------------------------------------------------------------------------

create policy "settlement: referee reads day and week"
  on public.settlement
  for select
  to authenticated
  using (public.role_from_token() = 'referee' and kind in ('day', 'week'));

create policy "penalty: referee reads day and week"
  on public.penalty
  for select
  to authenticated
  using (
    public.role_from_token() = 'referee'
    and exists (
      select 1 from public.settlement s
       where s.id = penalty.settlement_id
         and s.kind in ('day', 'week')
    )
  );

-- No insert, update or delete policy for a referee on either table. Ruling (4.6, "He did
-- it" / "He didn't") and collecting (4.7, Mark Collected) are separate, later stories --
-- this one grants no write path for a referee at all, on any table.


-- ---------------------------------------------------------------------------------
-- Commitment: read-only, every row, every column. The referee needs a commitment's `name`
-- for later stories (4.6/4.7 collection copy, "todoapp says you owe ... for [commitment]"),
-- but Postgres has no column-level RLS -- a policy filters rows, never columns -- so a
-- referee who can read `name` at all can also read `auto_check_account_ref` (Story 4.1,
-- what the author typed to identify an account elsewhere) through the same row. There is
-- nothing more sensitive on `commitment` today: no location field exists on this table (one
-- may exist on a future table this story explicitly does not grant), and this comment is
-- the record of that trade-off for whoever adds one.
-- ---------------------------------------------------------------------------------

create policy "commitment: referee reads all"
  on public.commitment
  for select
  to authenticated
  using (public.role_from_token() = 'referee');

-- No insert, update or delete policy for a referee. Commitment configuration belongs to the
-- doer alone (existing "commitment: create own" / "commitment: edit own" policies).


-- ---------------------------------------------------------------------------------
-- Explicit absence, recorded rather than merely true by omission (AD-7's own spirit: an
-- access rule is a decision, and silence reads as an oversight). No policy anywhere in this
-- migration grants `role_from_token() = 'referee'` any access to:
--
--   `declaration`        -- the author's own word about a day. Never the referee's to read.
--   `chain_current`      -- a view over `settlement_commitment`, whose own "read own" policy
--                           (`auth.uid() = subject`) already excludes a referee session with
--                           no code change here -- there is simply no referee row for it to
--                           match, on any account.
--   `focus_session`      -- timed work, and the location it would eventually carry.
--   `push_subscription`  -- a device's push endpoint; not this story's concern either way,
--                           and irrelevant to a referee whose own channel is email (NFR3).
--
-- Every one of these already ships with RLS enabled and its own policy scoped to
-- `auth.uid() = owner_id`/`subject` (or, for `chain_current`, inherits that same scoping
-- through `security_invoker`). A referee session satisfies none of those conditions for any
-- row, so it already reads zero rows from all four -- this migration adds nothing to them,
-- on purpose, and `supabase/tests/4-5-the-referee-has-his-own-way-in.sql` proves it stays
-- that way rather than trusting the absence to hold silently.
-- ---------------------------------------------------------------------------------
