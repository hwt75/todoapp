-- A referee belongs to one doer. (Stage 1 of 2: scope every read. Opens nothing.)
--
-- Seven policies grant the referee reads with no owner comparison at all -- `appeal`, `evidence`,
-- `settlement`, `penalty`, `commitment`, `silence_episode` and the evidence bucket. That was
-- deliberate and written down: `paired_doer_id()`'s own comment says `role_from_table() =
-- 'referee'` "is not scoping -- profile_single_referee makes the referee global, and 20260824160000
-- accepted that unscoped reach explicitly because it was read-only." The safety rests on exactly
-- one referee existing, authorised by the one real account.
--
-- The product is about to allow a referee per account, which breaks that chain at both ends: the
-- moment a second referee exists, referee B reads account A's appeals, evidence photos,
-- settlements, penalties, commitments and silence episodes.
--
-- **This migration opens nothing.** `profile_single_referee` still stands, `is_live_doer` still
-- gates every invitation, and each policy only gains a conjunct. It can therefore only ever remove
-- access: if the pairing is wrong the failure is a referee who sees too little, which is visible,
-- harmless and reversible. Stage 2 opens the gate, and is sound only because this landed first.


-- ---------------------------------------------------------------------------------
-- The pairing, recorded rather than re-derived.
-- ---------------------------------------------------------------------------------

/* `paired_doer_id()` derives the pairing from the invitation history on every call, with a fallback
   to "the live doer". That fallback is already fragile: it is a scalar subquery over
   `profile where is_live_doer`, and the live project currently carries **two** such accounts, so it
   would raise rather than answer if the first branch were ever null. A policy cannot afford either
   the round trip or the ambiguity, so the pairing becomes a column. */
alter table public.profile
  add column referee_of uuid references public.profile (id) on delete cascade;

comment on column public.profile.referee_of is
  'On a referee profile, the doer account he was invited by and may read. Null on every doer, and
  null on a referee whose pairing could not be resolved -- which is deliberately fail-closed: every
  referee policy compares against paired_doer_id(), so an unresolved pairing sees nothing rather
  than everything.';

-- At most one referee per doer. `profile_single_referee` (at most one referee *ever*) still stands
-- alongside it and is Stage 2's to drop; this is the constraint that replaces it.
create unique index profile_one_referee_per_doer
  on public.profile (referee_of)
  where referee_of is not null;

/* Backfill from accepted invitations only.

   A referee paired through `pair-referee` before invitations existed leaves no invitation row, and
   this deliberately does not guess for him: the old fallback would have named "the live doer",
   which is no longer a single account. He is left null, sees nothing, and the maintainer sets the
   column by hand -- a refusal anyone can notice beats a guess nobody can. */
update public.profile p
   set referee_of = ri.created_by
  from public.referee_invite ri
 where ri.accepted_by = p.id
   and ri.accepted_at is not null
   and p.role = 'referee';

create or replace function public.paired_doer_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.referee_of from public.profile p where p.id = (select auth.uid());
$$;

comment on function public.paired_doer_id() is
  'The doer account the calling referee is paired to, from profile.referee_of. Null for a doer, and
  null for a referee whose pairing was never recorded -- both of which make every referee policy
  match nothing, which is the intended direction of failure. Read from a column since Stage 1 of
  "a referee belongs to one doer": it was derived from referee_invite with a fallback to the single
  live doer, and there is no longer a single live doer.';

revoke execute on function public.paired_doer_id() from public, anon, authenticated;

-- Deliberately still revoked. `2-1-roles-and-rls.sql:504` lists this function as one no client may
-- reach, and the policies below therefore inline the lookup rather than call it: granting it would
-- have meant editing a security guard to fit new code, which is the wrong direction. The inlined
-- subquery reads only the caller's own profile row, which `profile: read own` already allows.


-- ---------------------------------------------------------------------------------
-- The one surface with no owner column.
-- ---------------------------------------------------------------------------------

/* `storage.objects` carries no owner of its own that RLS can trust -- the `owner` column is set by
   whoever uploaded and is not the product's notion of ownership. Access has always been derived
   from the path, whose first segment is the parent row's id (`evidence_storage_path_leads_with_its
   _parent`, 20260824130000:254), so ownership is derived the same way.

   Defensive about the cast: an object can be named anything, and a path whose first segment is not
   a uuid must answer "nobody" rather than raise inside a policy. */
create function public.evidence_object_owner(p_name text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with parent as (
    select case
             when (storage.foldername(p_name))[1] ~ '^[0-9a-fA-F-]{36}$'
             then ((storage.foldername(p_name))[1])::uuid
           end as id
  )
  select coalesce(
    (select a.owner_id from public.appeal a, parent where a.id = parent.id),
    (select d.owner_id from public.declaration d, parent where d.id = parent.id),
    (select c.owner_id from public.commitment c, parent where c.id = parent.id)
  );
$$;

comment on function public.evidence_object_owner(text) is
  'The doer who owns the row an evidence object hangs off, resolved from the object name''s first
  path segment -- the same segment the bucket policies have always read. Null when the segment is
  not a uuid or names no row, so a policy comparing against it refuses rather than raises.';

revoke execute on function public.evidence_object_owner(text) from public, anon;

-- Granted because the bucket policy calls it, exactly as `evidence_object_is_a_commitment_day()`
-- beside it already is (20260903120000): the answer is a single uuid about a path the caller had to
-- name, and the policy that uses it is what decides whether the object itself is readable.
grant execute on function public.evidence_object_owner(text) to authenticated;


-- ---------------------------------------------------------------------------------
-- The seven policies. Each gains exactly one conjunct.
-- ---------------------------------------------------------------------------------

drop policy "appeal: referee reads all" on public.appeal;
create policy "appeal: referee reads his own doer's"
  on public.appeal for select to authenticated
  using (public.role_from_token() = 'referee' and owner_id = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid())));

drop policy "commitment: referee reads all" on public.commitment;
create policy "commitment: referee reads his own doer's"
  on public.commitment for select to authenticated
  using (public.role_from_token() = 'referee' and owner_id = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid())));

drop policy "evidence: referee reads all" on public.evidence;
create policy "evidence: referee reads his own doer's"
  on public.evidence for select to authenticated
  using (
    public.role_from_token() = 'referee'
    -- 6.8's narrowing, unchanged: a commitment-day row is the author's own record and answers for
    -- no verdict.
    and commitment_id is null
    and owner_id = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))
  );

drop policy "settlement: referee reads day and week" on public.settlement;
create policy "settlement: referee reads his own doer's day and week"
  on public.settlement for select to authenticated
  using (
    public.role_from_token() = 'referee'
    and kind in ('day', 'week')
    and subject = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))
  );

drop policy "penalty: referee reads day and week" on public.penalty;
create policy "penalty: referee reads his own doer's day and week"
  on public.penalty for select to authenticated
  using (
    public.role_from_token() = 'referee'
    and subject = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))
    and exists (
      select 1 from public.settlement s
       where s.id = penalty.settlement_id and s.kind in ('day', 'week')
    )
  );

drop policy "silence_episode: referee reads escalated" on public.silence_episode;
create policy "silence_episode: referee reads his own doer's escalated"
  on public.silence_episode for select to authenticated
  using (
    public.role_from_token() = 'referee'
    and escalated_at is not null
    and satisfied_at is null
    and owner_id = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))
  );

drop policy "appeal-evidence objects: referee reads all" on storage.objects;
create policy "appeal-evidence objects: referee reads his own doer's"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'appeal-evidence'
    and public.role_from_token() = 'referee'
    -- Asked of the path rather than of a metadata row, unchanged: an object can exist with no
    -- `evidence` row behind it, and 4-6 step 8 asserts the referee can read exactly such an object.
    and not public.evidence_object_is_a_commitment_day(objects.name)
    and public.evidence_object_owner(objects.name) = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))
  );
