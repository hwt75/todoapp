-- Story 6.3 — evidence detaches from the appeal it was born attached to.
--
-- `appeal_evidence.appeal_id` was `not null`, so a photo could not exist without an appeal and
-- an appeal could not exist without a machine-filed miss to contest. Every photo in this
-- product was therefore downstream of a loss. Story 6.2 gave the author a way to claim a timed
-- commitment at the moment he does it, and that claim proves nothing on its own -- it is a tap,
-- which is the same word he could type the next morning.
--
-- One store, not two. The bucket, the ownership derivation, the capture-date rule and the
-- privacy that depends on all three are what make this trustworthy, and writing a second copy
-- of them for claims is how the two would drift into disagreeing about who may see a photo.
--
-- **The table is renamed and the bucket is not.** A table holding photos that prove ordinary
-- days, named for the dispute mechanism that happened to need it first, is a name that lies.
-- `alter table rename` carries policies, indexes and foreign keys with it, so the rename is
-- mechanical. The bucket keeps `appeal-evidence` because that is where the objects already are
-- and renaming one means moving every object in it -- recorded here and in config.toml rather
-- than papered over.

alter table public.appeal_evidence rename to evidence;
alter function public.appeal_evidence_derive_owner() rename to evidence_derive_owner;
alter trigger appeal_evidence_derive_owner on public.evidence rename to evidence_derive_owner;
alter index appeal_evidence_appeal_idx rename to evidence_appeal_idx;

alter policy "appeal_evidence: read own" on public.evidence rename to "evidence: read own";
alter policy "appeal_evidence: file own" on public.evidence rename to "evidence: file own";
alter policy "appeal_evidence: referee reads all" on public.evidence
  rename to "evidence: referee reads all";


-- ---------------------------------------------------------------------------------
-- A second kind of parent.
-- ---------------------------------------------------------------------------------

alter table public.evidence alter column appeal_id drop not null;

alter table public.evidence
  add column declaration_id uuid references public.declaration (id) on delete cascade;

comment on column public.evidence.declaration_id is
  'Story 6.3: the claim this photo proves, when it proves one. Exactly one of appeal_id and '
  'declaration_id is set -- an appeal contests a day that already closed, a declaration is the '
  'author saying he did the thing, and a photo belongs to one or the other, never both.';

create index evidence_declaration_idx on public.evidence (declaration_id);

-- Exactly one parent. The same biconditional shape `commitment_weekly_quota_targets` uses: a
-- row with neither is metadata for an object nothing can reach, and a row with both would make
-- the storage-path check and the owner derivation disagree about which id leads the folder.
alter table public.evidence
  add constraint evidence_exactly_one_parent
    check ((appeal_id is null) <> (declaration_id is null));

-- The path must still lead with the parent's own id -- that is what `storage.foldername(name)`
-- reads to derive access. Dropped and recreated rather than edited: the old one names
-- `appeal_id` alone and would refuse every claim's photo. `appeal_evidence_check` is the name
-- Postgres generated for it: it was written inline on the column with no name of its own, and
-- an unnamed inline check on a table with only one becomes `<table>_check`.
alter table public.evidence drop constraint appeal_evidence_check;

alter table public.evidence
  add constraint evidence_storage_path_leads_with_its_parent
    check (storage_path like (coalesce(appeal_id, declaration_id)::text || '/%'));


-- ---------------------------------------------------------------------------------
-- Owner and day, derived from whichever parent this row has.
-- ---------------------------------------------------------------------------------

create or replace function public.evidence_derive_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner   uuid;
  v_for_day date;
  v_today   date;
begin
  if new.appeal_id is not null then
    select owner_id, for_day into v_owner, v_for_day
      from public.appeal where id = new.appeal_id;

    if not found then
      raise exception 'Evidence does not reference an appeal that exists.';
    end if;
  else
    select owner_id, for_day into v_owner, v_for_day
      from public.declaration where id = new.declaration_id;

    if not found then
      raise exception 'Evidence does not reference a claim that exists.';
    end if;

    -- Midnight is the deadline, and there is nothing after it (SPEC.md). Enforced here, at
    -- the moment of the upload, rather than left for settlement to discover -- the same call
    -- Story 6.2 made about a late tap, for the same reason: refusing at the moment of the act
    -- is legible, and silently accepting something that will not count is not.
    --
    -- Deliberately NOT applied to an appeal above. An appeal contests a day that has already
    -- closed and lives on its own deadline; binding its evidence to the midnight of the day it
    -- proves would break a path that works today.
    v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

    if v_today > v_for_day then
      raise exception
        'A claim can only be proved on the day it was made. That day (%) has ended.', v_for_day;
    end if;
  end if;

  -- FR-14, unchanged since 20260827100000: an old photo proves nothing. `captured_on` is read
  -- from the file's own `lastModified` rather than from EXIF (see lib/evidence.ts), which is a
  -- real and accepted limitation -- enough to refuse an evidently unrelated file, not a
  -- cryptographic proof of when a photo was taken.
  if new.captured_on is null or new.captured_on <> v_for_day then
    raise exception 'Evidence must be dated the day it proves.';
  end if;

  -- Never client-sent. This is the exact fact the bucket's storage.objects policies depend on
  -- (NFR4): access derives from the parent's own owner_id, which only holds if a client cannot
  -- claim a different one.
  new.owner_id := v_owner;
  return new;
end;
$$;

comment on function public.evidence_derive_owner() is
  'before insert security definer trigger on public.evidence. Overwrites owner_id with the '
  'parent row''s own owner_id -- an appeal''s or a declaration''s -- so a client can never '
  'attach evidence it does not own. Refuses any insert whose captured_on is missing or does '
  'not match that parent''s own for_day, and refuses a claim''s evidence once the day it '
  'proves has ended. An appeal''s evidence is exempt from that deadline: it contests a day '
  'that already closed and lives on the appeal''s own.';

revoke execute on function public.evidence_derive_owner() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The bucket's own policies learn the second parent.
--
-- Recreated rather than extended in place: a policy's `using`/`with check` cannot be altered
-- piecemeal, and the pair has to stay symmetrical or an object becomes uploadable and then
-- unreadable by the same account.
--
-- The referee's read policy (20260825090000) is deliberately untouched. He can still see every
-- object in the bucket that belongs to an appeal, and nothing new: a referee who can see proof
-- of ordinary days but cannot act on it is surveillance nobody asked for. Story 6.7 gives him
-- the objection and the access together, or neither.
-- ---------------------------------------------------------------------------------

drop policy "appeal-evidence objects: owner reads own" on storage.objects;
drop policy "appeal-evidence objects: owner uploads own" on storage.objects;

create policy "appeal-evidence objects: owner reads own"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'appeal-evidence'
    and (
      exists (
        select 1 from public.appeal a
         where a.id::text = (storage.foldername(name))[1]
           and a.owner_id = (select auth.uid())
      )
      or exists (
        select 1 from public.declaration d
         where d.id::text = (storage.foldername(name))[1]
           and d.owner_id = (select auth.uid())
      )
    )
  );

create policy "appeal-evidence objects: owner uploads own"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'appeal-evidence'
    and (
      exists (
        select 1 from public.appeal a
         where a.id::text = (storage.foldername(name))[1]
           and a.owner_id = (select auth.uid())
      )
      or exists (
        select 1 from public.declaration d
         where d.id::text = (storage.foldername(name))[1]
           and d.owner_id = (select auth.uid())
      )
    )
  );
