-- The morning declaration: the author's own word about whether yesterday held.
--
-- A declaration is an *observation*, not a verdict. It records what he said and when he
-- said it. Settlement (2.5) is what turns observations into days, penalties and chains —
-- derived state has exactly one writer and this is not it (AD-8).

create type public.declaration_answer as enum ('held', 'slipped');

-- ---------------------------------------------------------------------------------
-- When he is asked.
--
-- The column lives on `profile`, which the client may not write — `role` is on that table
-- and an account that can edit its own role can rule on its own appeals. Rather than
-- write a clever policy that tries to allow one column and forbid another, the grant is
-- made per column. Postgres then refuses an update touching anything else, and the rule
-- is enforced by the privilege system rather than by an expression someone has to read
-- carefully.
-- ---------------------------------------------------------------------------------

alter table public.profile
  add column morning_hour smallint not null default 7;

alter table public.profile
  add constraint profile_morning_hour_range
  check (morning_hour between 0 and 23);

comment on column public.profile.morning_hour is
  'Local hour (Asia/Ho_Chi_Minh) after which yesterday''s declaration is asked for.';

create policy "profile: set own morning hour"
  on public.profile
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- The policy says *which row*; this says *which column*. Both are needed: without the
-- grant the policy would let a client rewrite its own role.
grant update (morning_hour) on table public.profile to authenticated;


-- ---------------------------------------------------------------------------------
-- The declaration itself.
-- ---------------------------------------------------------------------------------

create table public.declaration (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profile (id) on delete cascade,
  commitment_id uuid not null references public.commitment (id) on delete cascade,

  -- AD-4: generated at the moment of the tap and reused by every retry, so an answer
  -- queued offline and flushed twice is one answer.
  idempotency_key uuid not null unique,

  answer public.declaration_answer not null,

  -- The instant he tapped, which is not the instant this arrived. An answer given in
  -- airplane mode is dated when it was given.
  answered_at timestamptz not null,

  -- Derived by the trigger below. AD-6: no client ever sends a date.
  for_day date not null,

  created_at timestamptz not null default now(),

  -- One answer per commitment per day. Not a technicality: being asked twice about the
  -- same day is how a question stops being taken seriously.
  constraint declaration_one_per_commitment_day unique (commitment_id, for_day)
);

comment on table public.declaration is
  'What the author said about a commitment on a given day. An observation, never a verdict.';

create index declaration_owner_day_idx on public.declaration (owner_id, for_day);

/* The day an answer refers to.

   A declaration filed in the morning answers for the day before, and the boundary is
   Asia/Ho_Chi_Minh (AD-6) rather than the phone's idea of a date or the server's UTC.
   The rule is deliberately independent of `morning_hour`: answering at 06:00 and at 08:00
   both refer to yesterday, so moving the hour never silently re-points an answer at a
   different day.

   A trigger rather than a generated column because `at time zone` with a named zone is
   STABLE, not IMMUTABLE — timezone rules can change — and Postgres will not store a
   generated column computed from it. */
create function public.declaration_derive_day()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.for_day := ((new.answered_at at time zone 'Asia/Ho_Chi_Minh')::date - 1);
  return new;
end;
$$;

create trigger declaration_derive_day
  before insert on public.declaration
  for each row execute function public.declaration_derive_day();

revoke execute on function public.declaration_derive_day() from public, anon, authenticated;

alter table public.declaration enable row level security;

create policy "declaration: read own"
  on public.declaration
  for select
  to authenticated
  using ((select auth.uid()) = owner_id);

create policy "declaration: file own"
  on public.declaration
  for insert
  to authenticated
  with check ((select auth.uid()) = owner_id and public.role_from_table() = 'doer');

-- No update policy and no delete policy, on purpose. A declaration is a statement of what
-- he said at a moment. Amending it after the fact is an Appeal (FR-14) — a separate,
-- recorded act with a ruling — not an edit that quietly rewrites what was said.
