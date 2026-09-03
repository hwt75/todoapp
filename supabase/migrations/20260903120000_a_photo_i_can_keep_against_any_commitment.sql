-- Story 6.8 — a photo the author keeps against any commitment, and against no verdict.
--
-- Every path to a photo in this product runs through Epic 6's timed machinery: a `due_time`, an
-- open window, a landed claim. Outside that window the control block draws nothing at all, so the
-- capability is indistinguishable from one never built -- and `commitment_time_needs_a_moment`
-- means an `abstain` or `daily_hours_quota` commitment cannot carry a time at all, so those two
-- kinds have no path to a photo under any circumstance.
--
-- This separates the store from the deadline. A commitment may be marked as one the author keeps
-- a photo against, and `evidence` gains a third parent kind: a commitment and a day.
--
-- **The photo decides nothing.** Settlement never reads `requires_photo`, and the three readers of
-- `evidence` -- `commitments_owing()`, `weekly_held_count()` and `timed_claim_today` -- are all
-- keyed on `declaration_id`, so a `commitment_id` row matches none of them. A day with the flag on
-- and no photo settles exactly as the same day would with the flag off. The morning Declaration
-- stays the sole judge (D1), and nothing here files one: auto-creating a `declaration` on upload
-- would file an answer the author never gave and hand the verdict a second writer (AD-8).
--
-- **One migration, because three things are load-bearing as a set.** The exactly-one-parent check,
-- the storage-path check and `evidence_derive_owner()` have to agree about which id leads the
-- object's folder, and that folder is what `storage.foldername(name)` reads to derive access
-- (NFR4, AD-7). Splitting them across migrations is how they would drift apart.
--
-- **Rejected: a `proof` slot table keyed (commitment_id, for_day).** One more table and one more
-- owner derivation to keep in agreement, buying nothing the column pair does not already give.


-- ---------------------------------------------------------------------------------
-- The flag, on the commitment.
-- ---------------------------------------------------------------------------------

alter table public.commitment
  add column requires_photo boolean not null default false;

comment on column public.commitment.requires_photo is
  'Story 6.8: whether the author keeps a photo against this commitment. Settlement never reads '
  'this column -- no verdict, penalty, chain or grace allowance depends on it, and a missing '
  'photo costs nothing. It puts an all-day upload control on the commitment''s row and does '
  'nothing else. Unlike due_time it applies to every kind and cadence, because a photo that '
  'decides nothing is meaningless for none of them. Deliberately has NO as-of change log '
  '(no requires_photo_as_of(), unlike carries_penalty_as_of() and due_time_as_of()): those '
  'exist so a switch flipped today cannot rewrite what yesterday meant, and there is no past '
  'verdict this could rewrite. late_window_minutes is the precedent. If a later story ever '
  'makes a missing photo cost anything, this column needs the log before that story ships.';


-- ---------------------------------------------------------------------------------
-- A third kind of parent: a commitment and a day.
-- ---------------------------------------------------------------------------------

alter table public.evidence
  add column commitment_id uuid references public.commitment (id) on delete cascade,
  add column for_day date;

comment on column public.evidence.commitment_id is
  'Story 6.8: the commitment this photo is a record for, when it is a record rather than a '
  'proof. Exactly one of appeal_id, declaration_id and commitment_id is set. A single uuid, so '
  'it leads the storage path exactly as the other two parents do.';

comment on column public.evidence.for_day is
  'The local day (Asia/Ho_Chi_Minh) a commitment-parented photo belongs to. Set when and only '
  'when commitment_id is set: a commitment is not a day, so this is the half of the parent an '
  'appeal and a declaration each carry on their own row. A stray for_day on one of those would '
  'give a future reader two places to look for one answer.';

create index evidence_commitment_idx on public.evidence (commitment_id, for_day);

-- Exactly one parent, now as a count.
--
-- A biconditional does not extend to three terms legibly -- `(a is null) <> (b is null)` says
-- "exactly one" for two and says nothing usable for three. The `::int` sum says the same thing
-- for any number of parents and reads as the sentence it enforces.
--
-- The rule itself is unchanged and matters for the same reasons: a row with no parent is
-- metadata for an object nothing can reach, and a row with two would make the storage-path check
-- and the owner derivation disagree about which id leads the folder.
alter table public.evidence drop constraint evidence_exactly_one_parent;

alter table public.evidence
  add constraint evidence_exactly_one_parent
    check (
      (appeal_id is not null)::int
      + (declaration_id is not null)::int
      + (commitment_id is not null)::int = 1
    );

-- `for_day` belongs to exactly one parent kind. The other two derive their day from the parent
-- row -- `appeal.for_day`, `declaration.for_day` -- and duplicating it here would be a second
-- copy of an answer that already exists, free to disagree with the first.
alter table public.evidence
  add constraint evidence_for_day_belongs_to_a_commitment
    check ((commitment_id is null) = (for_day is null));

-- The path must still lead with the parent's own id -- that is what `storage.foldername(name)`
-- reads to derive access. Dropped and recreated rather than edited: the old one coalesces two
-- parents and would refuse every commitment-day photo.
alter table public.evidence drop constraint evidence_storage_path_leads_with_its_parent;

alter table public.evidence
  add constraint evidence_storage_path_leads_with_its_parent
    check (
      storage_path like (coalesce(appeal_id, declaration_id, commitment_id)::text || '/%')
    );


-- ---------------------------------------------------------------------------------
-- Owner and day, derived from whichever of the three parents this row has.
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
  elsif new.declaration_id is not null then
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
  else
    -- Story 6.8. The parent is a commitment and a day, and the day is on this row rather than
    -- on the parent -- a commitment is not a day, so `for_day` is the half it cannot supply.
    select owner_id into v_owner
      from public.commitment where id = new.commitment_id;

    if not found then
      raise exception 'Evidence does not reference a commitment that exists.';
    end if;

    v_for_day := new.for_day;

    -- The declaration branch's own midnight rule, reused rather than rewritten: the control is
    -- offered for the whole of the commitment's local day and closes with it, and a day already
    -- ended takes no further evidence. Nothing settles differently either way -- this exists so
    -- the store cannot quietly accumulate a record of days the author never actually kept, which
    -- is the same reason Story 6.2 refuses a late tap instead of filing it.
    --
    -- `<>` rather than the declaration branch's `>`, and the difference is not a preference.
    -- There, `for_day` is derived server-side by `declaration_derive_day()` and can never be in
    -- the future, so `>` is already the whole rule. Here it is a client-sent column, and the
    -- capture-date rule below is no defence against a forward-dated one: `captured_on` comes
    -- from the client too, read off the file's own `lastModified` (lib/evidence.ts), which is
    -- trivially set to any date at all. A day is the day the photo is kept on, both ends.
    v_today := (now() at time zone 'Asia/Ho_Chi_Minh')::date;

    if v_today <> v_for_day then
      raise exception
        'A photo can only be kept on the day it belongs to, and today is not %.', v_for_day;
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
  -- claim a different one. It is also what refuses a foreign parent without any application
  -- check: the derived owner is the parent's, so `evidence: file own`'s `auth.uid() = owner_id`
  -- fails on the way out.
  new.owner_id := v_owner;
  return new;
end;
$$;

comment on function public.evidence_derive_owner() is
  'before insert security definer trigger on public.evidence. Overwrites owner_id with the '
  'parent row''s own owner_id -- an appeal''s, a declaration''s, or a commitment''s -- so a '
  'client can never attach evidence it does not own. Refuses any insert whose captured_on is '
  'missing or does not match the day it belongs to: the parent''s own for_day for an appeal or '
  'a claim, and the row''s own for_day for a commitment. Refuses a claim''s evidence once the '
  'day it proves has ended, and a commitment''s evidence on any day but the current one -- that '
  'for_day is client-sent, so it is bounded at both ends rather than one. An appeal''s evidence '
  'is exempt from the deadline entirely: it contests a day that already closed and lives on the '
  'appeal''s own.';

revoke execute on function public.evidence_derive_owner() from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The bucket's own policies learn the third parent.
--
-- Recreated rather than extended in place: a policy's `using`/`with check` cannot be altered
-- piecemeal, and the pair has to stay symmetrical or an object becomes uploadable and then
-- unreadable by the same account.
--
-- The referee's own two read policies are NOT left alone; they are narrowed below, and the
-- section after this one says why at length.
--
-- **`objects.name`, qualified, in every branch.** `public.commitment` has a `name` column of its
-- own, so a bare `storage.foldername(name)` inside the commitment subquery binds to the
-- *commitment's* name rather than the object's -- Postgres resolves the inner scope first and
-- says nothing. The policy then reads `storage.foldername('Sketchbook')`, which is an empty
-- array whose first element is null, so the branch is false for every object and the control
-- silently uploads nothing. Found by `6-8-...sql`'s own storage probe on the first run, which is
-- why that probe asserts the *positive* case alongside the refusals. The other two branches are
-- qualified with it too, though `appeal` and `declaration` carry no `name` column today: the
-- trap is one column away at all times, and a rule written the same way three times cannot be
-- half-remembered.
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
         where a.id::text = (storage.foldername(objects.name))[1]
           and a.owner_id = (select auth.uid())
      )
      or exists (
        select 1 from public.declaration d
         where d.id::text = (storage.foldername(objects.name))[1]
           and d.owner_id = (select auth.uid())
      )
      or exists (
        select 1 from public.commitment c
         where c.id::text = (storage.foldername(objects.name))[1]
           and c.owner_id = (select auth.uid())
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
         where a.id::text = (storage.foldername(objects.name))[1]
           and a.owner_id = (select auth.uid())
      )
      or exists (
        select 1 from public.declaration d
         where d.id::text = (storage.foldername(objects.name))[1]
           and d.owner_id = (select auth.uid())
      )
      or exists (
        select 1 from public.commitment c
         where c.id::text = (storage.foldername(objects.name))[1]
           and c.owner_id = (select auth.uid())
      )
    )
  );


-- ---------------------------------------------------------------------------------
-- The referee stops here.
--
-- `Today` tells the author, in the hint under this control, that the photo "is private -- only
-- you can open it". Two policies written before this parent kind existed made that sentence
-- false the moment the column landed. Neither is scoped to a parent kind -- quoted in full,
-- because a claim about another policy that is not its own text is how this hole was opened:
--
--   20260824160000:62  "evidence: referee reads all" (renamed by 20260828150000)
--     using (public.role_from_token() = 'referee')
--
--   20260825090000:263  "appeal-evidence objects: referee reads all"
--     using (bucket_id = 'appeal-evidence' and public.role_from_token() = 'referee')
--
-- The first is role alone; the second is role and a bucket. A commitment-day photo lands in
-- that bucket and in that table, so before this section a referee session read both the row and
-- the object for a private record kept against, say, an `abstain` commitment -- something no
-- verdict of his will ever touch.
--
-- **Narrowed by excluding the new kind, never by narrowing to appeals.** An appeal-only
-- predicate would also hide the declaration-parented timed proofs, and Story 6.7 exists to let
-- him object to exactly those. Appeal- and declaration-parented evidence stays exactly as
-- visible to him as it is today; only the commitment-day kind is taken away.
-- ---------------------------------------------------------------------------------

-- The object row carries no parent kind -- only a path whose first folder is the parent's id --
-- so the storage policy has to ask which kind that id names. It cannot ask directly: a policy's
-- subquery is evaluated as the caller, RLS and all, and a referee has no read policy on
-- `public.commitment` at all. The `exists` would be false for every object and the exclusion
-- would silently never fire, which is the same class of failure as the `objects.name` shadowing
-- above. `security definer` is what makes the answer true rather than merely visible.
create function public.evidence_object_is_a_commitment_day(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.commitment c
     where c.id::text = (storage.foldername(p_name))[1]
  );
$$;

comment on function public.evidence_object_is_a_commitment_day(text) is
  'Story 6.8: whether an object path in the `appeal-evidence` bucket leads with a commitment''s '
  'id -- that is, whether it is a commitment-day record rather than an appeal''s or a claim''s '
  'evidence. security definer because it is called from a storage.objects policy evaluated as a '
  'referee, who cannot read public.commitment and would otherwise get `false` for everything. '
  'Answers only whether a uuid names a commitment; it exposes no column of one.';

revoke execute on function public.evidence_object_is_a_commitment_day(text) from public, anon;
grant execute on function public.evidence_object_is_a_commitment_day(text) to authenticated;

drop policy "evidence: referee reads all" on public.evidence;

create policy "evidence: referee reads all"
  on public.evidence
  for select
  to authenticated
  using (
    public.role_from_token() = 'referee'
    -- The whole narrowing, on the table side: a commitment-day row is the author's own record
    -- and answers for no verdict. An appeal's row and a claim's row read exactly as before.
    and commitment_id is null
  );

drop policy "appeal-evidence objects: referee reads all" on storage.objects;

create policy "appeal-evidence objects: referee reads all"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'appeal-evidence'
    and public.role_from_token() = 'referee'
    -- Asked of the path rather than of a metadata row on purpose. An object can exist with no
    -- `evidence` row behind it -- the client uploads the object first and files the row second
    -- (components/today.tsx, components/appeal-form.tsx), so a failed second step leaves one --
    -- and `4-6-the-referee-rules.sql` step 8 asserts the referee can read exactly such an
    -- object. Keying this on `evidence` would have quietly changed that.
    and not public.evidence_object_is_a_commitment_day(objects.name)
  );
