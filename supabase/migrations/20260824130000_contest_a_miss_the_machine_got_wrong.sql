-- Story 4.4 — Contest a miss the machine got wrong (FR-14, FR-15).
--
-- Two data gaps made a naive build impossible, both closed before this file. (1) `penalty`
-- is one row per Failed Day (FR-13, 20260819230000), never per-commitment — "the associated
-- Penalty" means the whole day's Penalty, even when other, non-appealed misses contributed
-- to it. (2) `declaration.filed_by` (20260824120000) is what tells a machine-filed miss from
-- the author's own honest `slipped`, without which Appeal would be exploitable.
--
-- The shape: a client insert into `appeal`, RLS-gated to the owning account, whose
-- `before insert security definer` trigger (`appeal_hold_penalty`, mirroring
-- `focus_session_derive_day`'s exact shape) validates every eligibility condition, derives
-- `settlement_id`/`penalty_id`/`deadline`, and atomically moves that day's Penalty to
-- `held` in the same transaction the appeal row is written in. No RPC — this codebase has
-- no function that is both `security definer` and `EXECUTE`-granted to `authenticated`;
-- every privileged client-triggered write goes through this exact idiom
-- (`focus_session_derive_day`, `declaration_derive_day`), and Appeal follows it rather than
-- introducing a new one.
--
-- Weekly Quota is out of scope: `settle_week` writes no `settlement_commitment` row, so
-- there is nothing to trace a week's bundled Penalty back to one commitment (a pre-existing,
-- already-recorded gap, not restructured here). `appeal_hold_penalty`'s own join
-- (`s.kind = 'day'`) makes a Weekly Quota appeal attempt fail the "no machine miss on
-- record" check rather than silently succeed against the wrong thing.
--
-- The timeout-favors-the-author path (`held` past its deadline voids to `dropped`) and the
-- referee's own ruling surface are Story 4.6 — this migration only builds the Penalty state
-- the ruling will one day read, plus the plain guarded transition (`void_expired_appeals`,
-- 20260824140000) that makes the timeout side of it work today. No referee surface, login,
-- or ruling exists yet.

-- ---------------------------------------------------------------------------------
-- `penalty_state` gains the two values this story makes reachable. Isolated in its own
-- statement, referenced only from inside plpgsql function bodies below (deferred to when
-- those bodies actually run, in later transactions) — mirroring
-- 20260820150000_the_week_closes_and_settles.sql's own isolation of `alter type ... add
-- value`, which exists because Postgres refuses a new enum value used in the same
-- transaction that added it, outside a deferred function body.
-- ---------------------------------------------------------------------------------

alter type public.penalty_state add value if not exists 'held';
alter type public.penalty_state add value if not exists 'dropped';


-- ---------------------------------------------------------------------------------
-- The deadline. A sibling of `declaration_deadline` (20260819241000), not a reuse — that
-- one is anchored to a *day* plus the author's own morning hour; this one is anchored to
-- the instant the appeal itself was filed, and needs no hour at all.
--
-- FR-15's own committed assumption for a Daily commitment (Weekly Quota's deadline, Week
-- Close, has no bearing here — Weekly Quota carries no appeal at all): a Held Penalty
-- resolves by the deadline or by the referee's ruling, whichever comes first, and the
-- deadline is "end of the day following the appeal" — end of (appeal-day + 1), which is
-- the instant (appeal-day + 2) begins.
-- ---------------------------------------------------------------------------------

create function public.appeal_deadline(p_filed_at timestamptz)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (((p_filed_at at time zone 'Asia/Ho_Chi_Minh')::date + 2)::timestamp)
         at time zone 'Asia/Ho_Chi_Minh';
$$;

comment on function public.appeal_deadline(timestamptz) is
  'FR-15 [ASSUMPTION, unconfirmed]: end of the day following the day the appeal was filed '
  '(Asia/Ho_Chi_Minh, AD-6) -- anchored to the appeal''s own created instant, not to the '
  'for_day being appealed, so an appeal filed against an old miss still gets a full window '
  'measured from when he actually appealed.';

revoke execute on function public.appeal_deadline(timestamptz) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The appeal itself.
-- ---------------------------------------------------------------------------------

create table public.appeal (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profile (id) on delete cascade,
  commitment_id uuid not null references public.commitment (id) on delete cascade,

  -- AD-4: minted at the moment he taps Contest, reused by every retry, so a submission
  -- queued and flushed twice is one appeal.
  idempotency_key uuid not null unique,

  -- Client-supplied, unlike `declaration.for_day`/`focus_session.for_day`. An appeal does
  -- not describe an event that just happened -- it names an already-settled day the author
  -- is choosing to contest, read off a Ledger row that already exists.
  for_day date not null,

  -- The next three columns are derived by `appeal_hold_penalty` below, before the row is
  -- ever written (AD-1 -- no client computes eligibility or a verdict). `not null` holds
  -- because a `before insert` trigger fills them ahead of the constraint check, the same
  -- arrangement `focus_session.for_day` already relies on.
  settlement_id uuid not null references public.settlement (id) on delete cascade,
  penalty_id uuid not null references public.penalty (id) on delete cascade,
  deadline timestamptz not null,

  created_at timestamptz not null default now(),

  -- One appeal per commitment per day, as a database constraint rather than merely a UI
  -- guard -- the row this whole story's exploit-closure (declaration.filed_by) protects.
  constraint appeal_one_per_commitment_day unique (commitment_id, for_day)
);

comment on table public.appeal is
  'The author''s claim that a machine-filed miss was wrong. Filing one atomically moves that '
  'day''s Penalty to held (appeal_hold_penalty trigger, below). Append-only: no update or '
  'delete policy -- a ruling (Story 4.6) resolves the Penalty it points at, never this row.';

create index appeal_owner_idx on public.appeal (owner_id);
create index appeal_penalty_idx on public.appeal (penalty_id);

/* The eligibility check and the hold, in one atomic `before insert` trigger.
   Mirrors `focus_session_derive_day`'s exact shape: ownership lookup via
   `select ... where id = new.x`, compared to `new.owner_id`, raise on any mismatch,
   `security definer` so the checks are the trigger's own rather than a side effect of
   whatever the caller happens to be able to read, revoked from client roles (a trigger
   fires regardless of the EXECUTE grant -- the revoke only keeps it off
   /rest/v1/rpc/appeal_hold_penalty).

   Every condition raises rather than silently refusing to insert: an owned,
   Penalty-carrying commitment; a `day`-kind settlement whose *current* (un-superseded) row
   says `missed`; that day's own declaration filed by the machine, not the author; and the
   linked Penalty still `owed`. Any failure aborts the whole insert -- there is never a
   half-written appeal and never a Penalty moved to `held` for a claim that turned out not
   to qualify. */
create function public.appeal_hold_penalty()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_carries boolean;
  v_filed_by public.declaration_filed_by;
  v_settlement_id uuid;
  v_outcome public.commitment_outcome;
  v_penalty record;
begin
  select owner_id, carries_penalty into v_owner, v_carries
    from public.commitment where id = new.commitment_id;

  if not found or v_owner <> new.owner_id then
    raise exception 'Appeal commitment does not belong to the appealing account.';
  end if;

  if not v_carries then
    raise exception 'Only a Penalty-carrying commitment can be appealed.';
  end if;

  select sc.settlement_id, sc.outcome into v_settlement_id, v_outcome
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
   where sc.commitment_id = new.commitment_id and s.period = new.for_day
     and s.kind = 'day' and s.subject = new.owner_id and s.supersedes is null;

  if not found or v_outcome <> 'missed' then
    raise exception 'No machine miss on record for this commitment/day.';
  end if;

  select filed_by into v_filed_by from public.declaration
   where commitment_id = new.commitment_id and for_day = new.for_day;

  if v_filed_by is distinct from 'auto_check' then
    raise exception 'Only a machine-filed miss can be appealed.';
  end if;

  select id, state into v_penalty from public.penalty where settlement_id = v_settlement_id;

  if not found or v_penalty.state <> 'owed' then
    raise exception 'This day''s Penalty is not appealable.';
  end if;

  new.settlement_id := v_settlement_id;
  new.penalty_id := v_penalty.id;
  new.deadline := public.appeal_deadline(now());

  -- Guarded even here, on the row this trigger just proved is `owed`: belt-and-suspenders
  -- against a second appeal attempt racing this one for the same penalty through a
  -- different (commitment_id, for_day) pair on a Failed Day with more than one Penalty-
  -- carrying miss. `appeal_one_per_commitment_day` stops a literal duplicate; this guard is
  -- what stops two *different* eligible misses on the same day from both trying to hold the
  -- one Penalty FR-13 gives that day.
  update public.penalty set state = 'held' where id = v_penalty.id and state = 'owed';

  if not found then
    raise exception 'This day''s Penalty was claimed by another appeal first.';
  end if;

  return new;
end;
$$;

comment on function public.appeal_hold_penalty() is
  'before insert security definer trigger on public.appeal. Validates ownership, that the '
  'day''s current settlement_commitment outcome is missed, that the day''s own declaration '
  'was filed by the machine (not the author), and that the linked Penalty is still owed -- '
  'then derives settlement_id/penalty_id/deadline and holds the Penalty, atomically. Any '
  'failure raises; there is no silent no-op insert.';

create trigger appeal_hold_penalty
  before insert on public.appeal
  for each row execute function public.appeal_hold_penalty();

-- Reachable at /rest/v1/rpc otherwise, exactly the exposure 20260819121500 closed for
-- handle_new_user. A trigger fires regardless of the EXECUTE grant.
revoke execute on function public.appeal_hold_penalty() from public, anon, authenticated;

alter table public.appeal enable row level security;

create policy "appeal: read own"
  on public.appeal
  for select
  to authenticated
  using ((select auth.uid()) = owner_id);

create policy "appeal: file own"
  on public.appeal
  for insert
  to authenticated
  with check ((select auth.uid()) = owner_id and public.role_from_table() = 'doer');

-- No update and no delete policy. Resolving a Held Penalty is Story 4.6's ruling and this
-- story's own timeout job (20260824140000) -- both act on `penalty`, never rewrite the
-- appeal row that caused it.


-- ---------------------------------------------------------------------------------
-- Evidence. Optional, added by a second, separate insert after the appeal row already
-- exists -- never required to submit, never blocking the Penalty-hold transaction above.
-- ---------------------------------------------------------------------------------

create table public.appeal_evidence (
  id uuid primary key default gen_random_uuid(),
  appeal_id uuid not null references public.appeal (id) on delete cascade,

  -- Derived by the trigger below from the appeal it belongs to -- never client-sent. This
  -- is the exact fact the `appeal-evidence` storage bucket's own policy (below) has to be
  -- able to trust: evidence access derives from the appeal's own owner_id (NFR4), and that
  -- only holds if a client cannot simply claim a different one.
  owner_id uuid not null references public.profile (id) on delete cascade,

  -- The object's path in the `appeal-evidence` bucket, leading with the appeal's own id --
  -- what the storage policy below reads via storage.foldername(name) to derive access. The
  -- check enforces that lead at the metadata row itself: without it, a client could point
  -- this column at a path outside its own appeal (a different appeal's folder, or no real
  -- object at all) -- the storage.objects policy would still refuse the client any actual
  -- access to a mismatched object, but this row would misreport what the appeal owns.
  storage_path text not null unique
    check (storage_path like (appeal_id::text || '/%')),

  created_at timestamptz not null default now()
);

comment on table public.appeal_evidence is
  'Metadata for one object in the private `appeal-evidence` Storage bucket. owner_id is '
  'trigger-derived from the appeal it belongs to, never client-sent -- the fact NFR4''s '
  'storage.objects policy (below) depends on.';

create index appeal_evidence_appeal_idx on public.appeal_evidence (appeal_id);

create function public.appeal_evidence_derive_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.appeal where id = new.appeal_id;

  if not found then
    raise exception 'Evidence does not reference an appeal that exists.';
  end if;

  new.owner_id := v_owner;
  return new;
end;
$$;

comment on function public.appeal_evidence_derive_owner() is
  'before insert security definer trigger on public.appeal_evidence. Overwrites '
  'owner_id with the referenced appeal''s own owner_id, so a client can never attach '
  'evidence it does not own by sending a different value.';

create trigger appeal_evidence_derive_owner
  before insert on public.appeal_evidence
  for each row execute function public.appeal_evidence_derive_owner();

revoke execute on function public.appeal_evidence_derive_owner() from public, anon, authenticated;

alter table public.appeal_evidence enable row level security;

create policy "appeal_evidence: read own"
  on public.appeal_evidence
  for select
  to authenticated
  using ((select auth.uid()) = owner_id);

create policy "appeal_evidence: file own"
  on public.appeal_evidence
  for insert
  to authenticated
  with check ((select auth.uid()) = owner_id and public.role_from_table() = 'doer');

-- No update and no delete policy, for the same reason every other observation table in
-- this schema has none.


-- ---------------------------------------------------------------------------------
-- The bucket, and the policy that derives access from the appeal's own owner_id (NFR4).
--
-- `storage.objects` ships with RLS already enabled by Supabase; this only adds the two
-- policies this bucket needs. The bucket itself is declared in `supabase/config.toml` for
-- local dev -- the CLI creates it from that block on `supabase start`/`db reset`; there is
-- no first-party migration primitive for bucket creation, and this schema-level policy is
-- what actually decides who can reach an object once one exists, in every environment.
-- ---------------------------------------------------------------------------------

create policy "appeal-evidence objects: owner reads own"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'appeal-evidence'
    and exists (
      select 1 from public.appeal a
       where a.id::text = (storage.foldername(name))[1]
         and a.owner_id = (select auth.uid())
    )
  );

create policy "appeal-evidence objects: owner uploads own"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'appeal-evidence'
    and exists (
      select 1 from public.appeal a
       where a.id::text = (storage.foldername(name))[1]
         and a.owner_id = (select auth.uid())
    )
  );
