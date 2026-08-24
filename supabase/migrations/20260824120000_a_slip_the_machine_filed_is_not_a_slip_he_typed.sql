-- Story 4.4 — the gap three stories have now hit, closed at last: nothing on `declaration`
-- says whether the author typed his own answer or a machine filed it on his behalf.
--
-- Cheap by design, and the third story to need this exact fix. Story 4.1 deferred it (the
-- `held` branch of `file_auto_check_result` writes a `declaration` row indistinguishable
-- from the author's own tap — a recorded gap at the time, since nothing then needed to know
-- which one wrote it). Story 4.3 worked around it in copy rather than schema
-- (`morning-gate.tsx`'s own `classifyConflict` explicitly refuses to word a `23505` conflict
-- as "an Auto-check", because the row that won carries no fact saying so). This story cannot
-- work around it at all: without a way to tell a machine's `missed` from the author's own
-- honest `slipped`, Appeal would be exploitable — self-declare a slip, appeal it, and let the
-- timeout void a Penalty that was never actually the machine's call.
--
-- `filed_by` must be genuinely unforgeable, not merely defaulted. The `declaration` table's
-- own INSERT grant to `authenticated` (the live project's own default provisioning, per
-- `2-1-roles-and-rls.sql`'s header comment -- not something any migration in this repo
-- creates) is a *table*-level grant, not scoped to a column allowlist the way
-- `profile.morning_hour`'s own grant already is. A `default` only fills a column the
-- client's insert *omits* -- it does nothing to stop the client from sending
-- `filed_by: 'auto_check'` explicitly in the same statement, which is exactly the exploit
-- this whole story exists to close (self-declare a slip, appeal it, let the timeout drop a
-- Penalty that was never actually the machine's call). So `filed_by` is force-set by the
-- existing `declaration_derive_day()` trigger below, the same way `appeal.settlement_id`/
-- `penalty_id`/`deadline` and `appeal_evidence.owner_id` are force-set later in this story
-- -- never left to a default a client insert can simply override.

create type public.declaration_filed_by as enum ('doer', 'auto_check');

alter table public.declaration
  add column filed_by public.declaration_filed_by not null default 'doer';

comment on column public.declaration.filed_by is
  'Who actually filed this row: the author''s own tap, or file_auto_check_result() acting on '
  'his behalf. Force-set by declaration_derive_day() below, not merely defaulted -- a client '
  'insert that explicitly sends filed_by=''auto_check'' is overwritten back to ''doer'' '
  'before the row is ever checked against a policy. Story 4.4''s Appeal eligibility trigger '
  'reads this to refuse an appeal against the author''s own honest slip.';

-- `declaration_derive_day()` (20260819200000) already runs on every insert into
-- `declaration`, client-originated or not -- the one seam that sees every write regardless
-- of who made it. Extended, not replaced with a new trigger: two `before insert` triggers
-- on the same table would run in name order with no reason to, and this one already exists
-- for exactly this table's own derived-value shape.
--
-- `current_user in ('anon', 'authenticated')` is true only for a genuine client-originated
-- statement -- `file_auto_check_result()` is `security definer`, so its own INSERT (which
-- explicitly sets `filed_by = 'auto_check'`, below) runs as that function's owner, never as
-- either role. This leaves that explicit value untouched while forcing every other caller's
-- attempt back to `'doer'`, regardless of what it sent.
create or replace function public.declaration_derive_day()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.for_day := ((new.answered_at at time zone 'Asia/Ho_Chi_Minh')::date - 1);

  if current_user in ('anon', 'authenticated') then
    new.filed_by := 'doer';
  end if;

  return new;
end;
$$;

revoke execute on function public.declaration_derive_day() from public, anon, authenticated;

-- `file_auto_check_result`, unchanged except for the one column this story adds to its
-- `missed` branch. The `held` branch is untouched on purpose: `filed_by` exists so Appeal
-- (this story) can tell a machine `missed` from the author's own `slipped`, and a `held`
-- day never carries a Penalty to appeal in the first place.
create or replace function public.file_auto_check_result(
  p_commitment_id uuid,
  p_owner_id uuid,
  p_result public.auto_check_result
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_carries_penalty boolean;
begin
  if p_result = 'held' then
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (p_owner_id, p_commitment_id, gen_random_uuid(), 'held', now())
    on conflict (commitment_id, for_day) do nothing;
    return;
  end if;

  if p_result = 'missed' then
    select c.carries_penalty into v_carries_penalty
      from public.commitment c
     where c.id = p_commitment_id;

    if coalesce(v_carries_penalty, false) then
      insert into public.declaration
        (owner_id, commitment_id, idempotency_key, answer, answered_at, filed_by)
      values
        (p_owner_id, p_commitment_id, gen_random_uuid(), 'slipped', now(), 'auto_check')
      on conflict (commitment_id, for_day) do nothing;
    end if;
    return;
  end if;

  -- `unavailable`, or an unmatched/null result — file nothing, same as always.
end;
$$;

comment on function public.file_auto_check_result(uuid, uuid, public.auto_check_result) is
  'Files declaration(answer=held) on held, and declaration(answer=slipped, filed_by=''auto_check'') '
  'on missed when the commitment carries a Penalty (FR-2a) -- both only when that day is still '
  'undeclared. missed with no Penalty, unavailable, and a null/unmatched result all file '
  'nothing. carries_penalty is read here, not passed in, mirroring auto_check_pending''s own '
  'self-contained design. Never calls outbox_enqueue (UX-DR29).';

revoke execute on function public.file_auto_check_result(uuid, uuid, public.auto_check_result)
  from public, anon, authenticated;
