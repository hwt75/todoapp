-- Story 4.1 — an Auto-check is attached, not read. FR-8 was resolved NEGATIVE for the one
-- concrete service considered (TryHackMe, Story 1.3): its completion history is not
-- readable from outside. So `account_elsewhere` ships with its own resolver stubbed to
-- always read `unavailable` — this migration builds the generic attach/resolve/file
-- mechanism, not a real integration. FR-8b's fall-through (unavailable/missed file
-- nothing) still has to hold generically, even with no live data source to exercise it.
--
-- Three pieces, same shape as the rest of the schema:
--   1. Config lives on `commitment` (never a global setting), mirroring `weekly_target`'s
--      symmetry-constraint pattern (20260819150000).
--   2. A pluggable per-kind resolver (`resolve_account_elsewhere`), separate from the
--      dispatcher/filer — the one seam a future story needs to plug in a real check.
--   3. A `security definer` resolution pass on its own cron slot, matching `settle_day`'s
--      house style (20260820140000): schema-qualified, `set search_path = ''`, revoked
--      from `public`/`anon`/`authenticated` — server/cron-only.
--
-- What this migration deliberately does not touch: `declaration_answer`'s enum,
-- `commitments_owing()`, `settle_day()`. A `held` result files a `declaration` row ahead
-- of settlement and stops there; settlement itself is untouched, per this story's own
-- "Ask First" boundary.

create type public.auto_check_kind as enum ('account_elsewhere');

create type public.auto_check_result as enum ('held', 'missed', 'unavailable');

comment on type public.auto_check_result is
  'What one Auto-check resolved to (FR-8b, AD-10). `unavailable` means tried and failed, '
  'never "not yet tried" — only `missed` ever invokes FR-2a precedence, and that '
  'precedence is Story 4.3''s scope, not this one''s.';


-- ---------------------------------------------------------------------------------
-- Config, on the commitment it belongs to (never a global setting — Epic 4 context).
-- ---------------------------------------------------------------------------------

alter table public.commitment
  add column auto_check_kind public.auto_check_kind,
  add column auto_check_account_ref text,
  add column auto_check_last_checked_at timestamptz;

comment on column public.commitment.auto_check_kind is
  'Which Auto-check is attached, if any. One slot per commitment (v1) — a second kind '
  'is Story 4.2''s scope, once a second real kind exists.';

comment on column public.commitment.auto_check_account_ref is
  'What the author typed to identify the account elsewhere. Saved as-is: no OAuth, no '
  'fetch or validation against it at link or resolve time.';

comment on column public.commitment.auto_check_last_checked_at is
  'When the resolution pass last looked at this commitment. Null until the first pass '
  'after linking, and cleared on unlink along with the other two columns.';

-- The symmetry `weekly_target`/`week_start_day` already established: a kind without an
-- account ref (or the reverse) is a half-filled form, not a valid attach.
alter table public.commitment
  add constraint commitment_auto_check_symmetry check (
    (auto_check_kind is not null) = (auto_check_account_ref is not null)
  );

-- Mirrors `commitment_name_not_blank`. Refused client-side too (`draftProblems`), but the
-- database is the actual authority.
alter table public.commitment
  add constraint commitment_auto_check_ref_not_blank check (
    auto_check_account_ref is null or length(btrim(auto_check_account_ref)) > 0
  );

-- `auto_check_last_checked_at` can be null while linked (no pass has run yet), but it can
-- never hold a value while unlinked — that would be a stale read surviving an unlink.
alter table public.commitment
  add constraint commitment_auto_check_last_checked_requires_kind check (
    auto_check_last_checked_at is null or auto_check_kind is not null
  );

-- Mirrors `autoChecksPossible()` (lib/commitment.ts): nothing can observe an abstention —
-- there is no sensor for a thing not done — so an Auto-check can never attach to one.
alter table public.commitment
  add constraint commitment_auto_check_not_on_abstain check (
    auto_check_kind is null or kind <> 'abstain'
  );


-- ---------------------------------------------------------------------------------
-- The per-kind resolver. `account_elsewhere` has no live data source in v1 (FR-8's own
-- negative finding), so it always reads `unavailable` — the seam a future story fills by
-- adding a real one, not by changing this function's shape or its caller.
-- ---------------------------------------------------------------------------------

create function public.resolve_account_elsewhere(p_commitment_id uuid)
returns public.auto_check_result
language sql
stable
set search_path = ''
as $$
  select 'unavailable'::public.auto_check_result
$$;

comment on function public.resolve_account_elsewhere(uuid) is
  'Always unavailable in v1 — no external account is reachable from outside (Story 1.3). '
  'The one seam a future story plugs a real check into; nothing else about the dispatcher '
  'or filer changes when it does.';

revoke execute on function public.resolve_account_elsewhere(uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The filer. Files exactly one `declaration` row, and only on `held` — `missed` and
-- `unavailable` both file nothing in this story (FR-8b's fall-through; distinguishing
-- them for a penalty-carrying commitment is Story 4.2/4.3's scope).
--
-- `answered_at = now()` and nothing else about the date: `declaration_derive_day`
-- (20260819200000:87-100) derives `for_day` as yesterday from that instant, the same as
-- every other declaration. `on conflict` targets that trigger-derived column directly —
-- the `before insert` trigger runs before the conflict check, so this is exactly
-- "insert unless that day already has a declaration," matching `declaration_one_per_-
-- commitment_day`'s own uniqueness rather than racing it.
--
-- Silent on success: no `outbox_enqueue` call anywhere in this function. Machine
-- confirmation produces no notification (UX-DR29) — the author is simply never prompted
-- for that commitment.
-- ---------------------------------------------------------------------------------

create function public.file_auto_check_result(
  p_commitment_id uuid,
  p_owner_id uuid,
  p_result public.auto_check_result
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- `is distinct from`, not `<>`: a plain `<>` against a null result is null itself, which
  -- `if` treats as false and falls through to the insert below. Not reachable today (the
  -- only resolver in play never returns null), but the dispatcher's own `case` has no
  -- `else` — the exact seam this file's own header comment names as a future story's to
  -- fill — so an unmatched kind must read as "don't file," not silently as `held`.
  if p_result is distinct from 'held' then
    return;
  end if;

  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (p_owner_id, p_commitment_id, gen_random_uuid(), 'held', now())
  on conflict (commitment_id, for_day) do nothing;
end;
$$;

comment on function public.file_auto_check_result(uuid, uuid, public.auto_check_result) is
  'Files one declaration(answer=held) when result is held and that day is still '
  'undeclared; missed/unavailable file nothing. Never calls outbox_enqueue (UX-DR29).';

revoke execute on function public.file_auto_check_result(uuid, uuid, public.auto_check_result)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The dispatcher. Loops every linked commitment whose target day (yesterday, the same
-- day a morning declaration would answer for) has no declaration yet, resolves it through
-- its own kind's resolver, files the result, and bumps `auto_check_last_checked_at`
-- regardless of outcome — a pass that looked and found nothing is still a pass that
-- looked.
--
-- An already-declared commitment is excluded from the loop entirely: its resolver is
-- never even called, so it is never queried or overwritten, matching the "Already
-- declared" row of the spec's own I/O matrix.
-- ---------------------------------------------------------------------------------

create function public.resolve_auto_checks()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_day date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  linked record;
  result public.auto_check_result;
  processed integer := 0;
begin
  for linked in
    select c.id, c.owner_id, c.auto_check_kind
      from public.commitment c
     where c.auto_check_kind is not null
       and c.archived_at is null
       and not exists (
         select 1 from public.declaration d
          where d.commitment_id = c.id and d.for_day = target_day
       )
  loop
    result := case linked.auto_check_kind
      when 'account_elsewhere' then public.resolve_account_elsewhere(linked.id)
    end;

    perform public.file_auto_check_result(linked.id, linked.owner_id, result);

    -- `and auto_check_kind is not null`: this loop's own snapshot can go stale mid-pass —
    -- a concurrent unlink between the select above and this update would otherwise set a
    -- non-null timestamp against a now-null kind, violate
    -- `commitment_auto_check_last_checked_requires_kind`, and abort the whole pass
    -- (including every row already filed earlier in this same loop). Guarding the update
    -- makes a mid-flight unlink a no-op for that one row instead.
    update public.commitment
       set auto_check_last_checked_at = now()
     where id = linked.id
       and auto_check_kind is not null;

    processed := processed + 1;
  end loop;

  return processed;
end;
$$;

comment on function public.resolve_auto_checks() is
  'One resolution pass: every linked, undeclared commitment is resolved through its own '
  'kind''s resolver, filed, and has auto_check_last_checked_at bumped. Server/cron-only.';

revoke execute on function public.resolve_auto_checks() from public, anon, authenticated;

-- Hourly, at the top of the hour — the one slot still free (:05 gate reminders, :15
-- settle-days, :25 focus prompts, :45 settle-weeks) and deliberately ahead of :15, so a
-- `held` result files its declaration before that same hour's settle-days pass reads it.
select cron.schedule(
  'resolve-auto-checks',
  '0 * * * *',
  $$select public.resolve_auto_checks()$$
);
