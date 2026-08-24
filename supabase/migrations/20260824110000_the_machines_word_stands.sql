-- Story 4.3 — when money rides on it, the machine's word stands (FR-2a precedence).
--
-- `file_auto_check_result` (20260823100000) already files a `declaration(answer='held')`
-- when its resolver reports `held`. It treated `missed` exactly like `unavailable` —
-- files nothing — which was correct for Story 4.1/4.2 (no live resolver could produce
-- `missed` yet) but leaves FR-2a's own precedence unbuilt: on a Penalty-carrying
-- commitment, a machine `missed` is supposed to be authoritative and structurally
-- uncorrectable by the author, not merely a fact that never got written down.
--
-- Fixed with one more branch, mirroring the `held` branch's exact idempotent shape
-- (server-generated `idempotency_key`, `answered_at = now()`, `on conflict
-- (commitment_id, for_day) do nothing`): a `missed` result on a `carries_penalty = true`
-- commitment files `declaration(answer='slipped')`. With no Penalty, still files nothing
-- — the author's own Declaration is what settles the day, unchanged (AC2, asserted by a
-- test rather than by new code, since Story 4.1's own fall-through already produces it).
--
-- `carries_penalty` is read inside this function itself, not passed as a new parameter —
-- mirroring `auto_check_pending`'s own self-contained design (Story 4.2): the caller
-- (`resolve_auto_checks`, unchanged by this migration) stays ignorant of what happens
-- once a result is handed off.
--
-- Why this is enough to make a `missed` result authoritative: `declaration` carries
-- `declaration_one_per_commitment_day` (20260819200000), unique on `(commitment_id,
-- for_day)`, and has no update or delete policy. Once this filer wins that race, a later
-- insert attempt for the same day — including the author's own, honest, contradicting tap
-- — is refused by the database itself, structurally, with nothing else to enforce. What
-- closes the gap that hid this (a `23505` on that unique constraint being treated as "my
-- own answer, arrived late" regardless of whose row actually won) is
-- `lib/declaration-submit.ts`'s `classifyConflict` and `components/morning-gate.tsx`'s use
-- of it — no schema change of their own.
--
-- Still untouched, per this story's own "Never" boundary: `declaration`'s columns and RLS
-- policies, `resolve_account_elsewhere`'s stub, `auto_check_pending`/`settle_day`/
-- `settle_week` (a filed `slipped` declaration reaches settlement through the exact same
-- existing path an author's own `slipped` tap already does — nothing downstream needs to
-- know which one wrote it), and `resolve_auto_checks`'s own dispatcher loop.

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

  -- FR-2a: on a Penalty-carrying commitment, a machine `missed` is authoritative — filed
  -- as a `slipped` declaration, the exact idempotent shape the `held` branch above uses.
  -- The per-day uniqueness that relies on is what then makes a later, contradicting human
  -- declare attempt structurally refused rather than merely discouraged. With no Penalty,
  -- files nothing: the author's own Declaration is what settles the day, with no other
  -- involvement (AC2).
  if p_result = 'missed' then
    select c.carries_penalty into v_carries_penalty
      from public.commitment c
     where c.id = p_commitment_id;

    if coalesce(v_carries_penalty, false) then
      insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
      values (p_owner_id, p_commitment_id, gen_random_uuid(), 'slipped', now())
      on conflict (commitment_id, for_day) do nothing;
    end if;
    return;
  end if;

  -- `unavailable`, or an unmatched/null result (the dispatcher's own `case` in
  -- `resolve_auto_checks` has no `else` — the same seam the pre-4.3 guard's own comment
  -- named) — file nothing, same as always.
end;
$$;

comment on function public.file_auto_check_result(uuid, uuid, public.auto_check_result) is
  'Files declaration(answer=held) on held, and declaration(answer=slipped) on missed when '
  'the commitment carries a Penalty (FR-2a) — both only when that day is still undeclared. '
  'missed with no Penalty, unavailable, and a null/unmatched result all file nothing. '
  'carries_penalty is read here, not passed in, mirroring auto_check_pending''s own '
  'self-contained design. Never calls outbox_enqueue (UX-DR29).';

revoke execute on function public.file_auto_check_result(uuid, uuid, public.auto_check_result)
  from public, anon, authenticated;
