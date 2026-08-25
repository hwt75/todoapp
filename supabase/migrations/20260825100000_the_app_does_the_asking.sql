-- Story 4.7 — The app does the asking, the referee does the collecting (FR-21).
--
-- An owed Penalty has had no collection path at all — the referee could rule an Appeal (4.6)
-- but had no way to ask for the money or record that it was paid. This is that path: one
-- `security definer` function, `mark_penalty_collected(p_penalty_id uuid)`, mirroring
-- `rule_appeal()`'s own shape exactly (`role_from_table()` gate first, before any row is
-- read; the single guarded `owed -> collected` transition AD-15 already uses for
-- `rule_appeal()`/`void_expired_appeals()`) — except simpler, because marking a debt
-- collected changes nothing about the day itself: no settlement write, no chain correction,
-- no outbox notification. The verdict already stands; this only records that the money
-- changed hands.
--
-- The referee's own home surface (`components/referee-home.tsx`) also needs to name which
-- commitment(s) a given day's Penalty belongs to, for the collection message. `penalty` is
-- 1:1 with `settlement` (Story 4.6's own established fact), but a day's settlement can cover
-- more than one missed commitment — so the second half of this migration is
-- `referee_missed_commitments(p_settlement_ids uuid[])`, a `security definer` function that
-- reads `settlement_commitment` filtered `outcome = 'missed'` and `settlement.kind = 'day'`,
-- gated by `role_from_table() = 'referee'`.
--
-- Deliberately NOT a new RLS `select` policy directly on `settlement_commitment` (iteration
-- 0 of this migration shipped exactly that, and it was wrong — see the Spec Change Log).
-- `settlement_commitment` is also `chain_current`'s own base table
-- (`20260819260000_chain.sql:73-`, `security_invoker`), so any RLS grant on the table is
-- silently also a grant on that view — reopening the doer-facing surface Story 4.5's own
-- frozen Intent explicitly and repeatedly keeps off-limits to the referee
-- (`20260824160000_the_referee_has_his_own_way_in.sql`'s own "Explicit absence" section names
-- `chain_current` by name). A function scoped to exactly the columns and rows this story
-- needs answers "which commitment(s) missed" without widening access to anything built
-- directly on the same base table. `role_from_table() = 'referee'` is used here as a plain
-- row filter, not an early `raise` — AD-7's own convention for a read (a non-referee caller
-- simply gets zero rows back), unlike `mark_penalty_collected()`'s write below, which
-- correctly refuses outright.

alter type public.penalty_state add value if not exists 'collected';

comment on type public.penalty_state is
  'owed (2.6); held, dropped (4.4, an Appeal in flight or timed out in the author''s favour); '
  'voided (4.6, an Appeal the referee approved -- distinct from dropped, which nobody ruled '
  'on); collected (4.7, the referee''s own mark_penalty_collected() -- the only way a debt is '
  'ever discharged). waived (5.1, Grace Day -- a different fact entirely) is still ahead.';


-- ---------------------------------------------------------------------------------
-- The collection itself.
-- ---------------------------------------------------------------------------------

create function public.mark_penalty_collected(p_penalty_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exists boolean;
begin
  -- First statement, before any row of the penalty itself is read — mirrors rule_appeal()'s
  -- own first statement exactly, `is distinct from`, never `<>`: a plain `<>` against a NULL
  -- role (no profile row for this session, however that came to be) evaluates NULL, and `if
  -- NULL then raise` never raises in plpgsql — the refusal would silently not happen for the
  -- one caller a role check exists to catch. role_from_table() (never role_from_token() —
  -- lib/roles.ts's own rule for anything guarding money) is invoker-rights over
  -- public.profile, always current.
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may mark a Penalty collected.';
  end if;

  -- A distinct "No such penalty." for a bogus id, before the guarded transition is even
  -- attempted — mirrors rule_appeal()'s own precedent (Story 4.6: "No such appeal." versus
  -- its own guarded-transition refusal). Without this, a nonexistent id and a genuinely
  -- already-collected one would read the identical "already been resolved" message, which
  -- names the wrong problem for the first case.
  select exists (select 1 from public.penalty where id = p_penalty_id) into v_exists;

  if not v_exists then
    raise exception 'No such penalty.';
  end if;

  -- The one and only transition this story ever writes: owed -> collected. Identical guarded
  -- shape to rule_appeal()'s own held -> owed/voided and void_expired_appeals()'s own
  -- held -> dropped (AD-15) — a double-click, or a call against a Penalty that is already
  -- collected, still held, or otherwise not owed, finds zero rows and is refused, never
  -- silently ignored. No settlement write, no settlement_commitment write, no outbox call —
  -- the day's verdict already stands; this only records that the money changed hands.
  update public.penalty
     set state = 'collected'
   where id = p_penalty_id and state = 'owed';

  if not found then
    raise exception
      'This penalty has already been resolved -- collected already, or no longer owed.';
  end if;
end;
$$;

comment on function public.mark_penalty_collected(uuid) is
  'FR-21. The only way a debt is ever discharged: role_from_table() = ''referee'' checked '
  'first, before any row is read, then a distinct "No such penalty." for a bogus id (mirrors '
  'rule_appeal()''s own precedent), then the single guarded transition owed -> collected '
  '(AD-15, identical shape to rule_appeal()/void_expired_appeals()). No settlement, chain or '
  'outbox write -- the day''s verdict already stands; this only records that the money '
  'changed hands. Zero rows affected on the guarded update (already collected, or held '
  'pending appeal) raises the "already been resolved" message rather than silently '
  'no-opping, distinct from "No such penalty." for an id that never existed at all.';

-- Directly callable by an authenticated referee session, exactly like rule_appeal() (Story
-- 4.6) — the function itself is the privilege boundary, reached over /rest/v1/rpc.
revoke execute on function public.mark_penalty_collected(uuid) from public, anon;
grant execute on function public.mark_penalty_collected(uuid) to authenticated;


-- ---------------------------------------------------------------------------------
-- Which commitment(s) missed, for the referee. `settlement_commitment`'s own existing
-- owner-only "read own" policy (`20260819260000_chain.sql`) is untouched — the owner still
-- reads his own chain exactly as before, and this function grants no new table-level access,
-- referee or otherwise (it is `security definer`: it reads under its own privilege, filtered
-- to exactly the rows its own `where` clause names, never widening what any RLS policy
-- exposes).
--
-- `settlement_commitment` carries no `kind` of its own (only `settlement` does) — the join
-- to `settlement` names it, the same reasoning `20260824160000`'s own
-- `penalty: referee reads day and week` policy gives. `kind = 'day'`, not `in ('day',
-- 'week')`: a week's own settlement never gets a `settlement_commitment` row in the first
-- place (`settle_week`/`settle_due_weeks` never insert one — Week Close freezes no
-- per-commitment outcome, `lib/ledger.ts`'s own "Never"), so scoping to anything wider would
-- answer nothing more in practice while inviting a future settlement kind through by
-- accident.
--
-- The `exists (select 1 from public.penalty p ...)` clause matters, not decoration: without
-- it this function would just as happily name commitments for a `held`, `dropped`, `voided`
-- or already-`collected` Penalty's settlement as for an `owed` one, if ever called with that
-- settlement id — a referee-facing read boundary should do exactly what its own name and
-- comment claim, not merely what its only caller today happens to ask for.
-- ---------------------------------------------------------------------------------

create function public.referee_missed_commitments(p_settlement_ids uuid[])
returns table (settlement_id uuid, commitment_name text)
language sql
security definer
stable
set search_path = ''
as $$
  select sc.settlement_id, c.name
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
    join public.commitment c on c.id = sc.commitment_id
   where sc.outcome = 'missed'
     and s.kind = 'day'
     and sc.settlement_id = any(p_settlement_ids)
     and public.role_from_table() = 'referee'
     and exists (
       select 1 from public.penalty p
        where p.settlement_id = sc.settlement_id and p.state = 'owed'
     );
$$;

comment on function public.referee_missed_commitments(uuid[]) is
  'FR-21. Names the commitment(s) a day-kind, owed Penalty''s own settlement recorded '
  '`missed`, for the referee''s own collection list. `role_from_table() = ''referee''` is a '
  'plain row filter here, not an early raise (AD-7''s "filters rather than refuses" read '
  'convention) -- a non-referee caller gets zero rows back, never an error. The `exists` '
  'clause against public.penalty is load-bearing, not decoration: it is what actually limits '
  'this to an *owed* Penalty''s own settlement, matching what the name/comment claim rather '
  'than merely `outcome = ''missed''` and `kind = ''day''` alone, which would also answer for '
  'a held/dropped/voided/collected Penalty''s settlement if ever asked. Deliberately a '
  'security definer function rather than an RLS policy on settlement_commitment itself: that '
  'table is also chain_current''s own base table (security_invoker), so any RLS grant on it '
  'would silently also grant chain_current, reopening the doer-facing surface Story 4.5''s '
  'own frozen Intent keeps off-limits to the referee.';

-- Directly callable by an authenticated referee session, exactly like mark_penalty_collected
-- above -- the function itself is the privilege boundary, reached over /rest/v1/rpc. A
-- non-referee caller is not refused (it is a read, not a write) -- its own `where` clause
-- simply matches nothing for it, per the comment above.
revoke execute on function public.referee_missed_commitments(uuid[]) from public, anon;
grant execute on function public.referee_missed_commitments(uuid[]) to authenticated;
