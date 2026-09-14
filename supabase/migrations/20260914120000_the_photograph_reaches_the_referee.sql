-- Story 8.3 — the photograph reaches the referee.
--
-- Story 8.2 lets the referee refuse a flagged commitment-day, and `sign_off_day()` already refuses
-- to let him do it without a photograph. That photograph is one he cannot open: both referee
-- policies exclude a commitment-day row by `commitment_id is null`, narrowed there deliberately by
-- Story 6.8 (20260903120000:344-372). He can be asked to judge proof he is forbidden to see.
--
-- Four parts, and the third is the point of the first.
--
--   (i)   One `security definer` predicate -- "a photograph on this commitment-day reaches the
--         referee" -- plus the thin path-to-row resolution the storage policy needs.
--   (ii)  One EXECUTE grant, for the author's **copy** and for nothing else. Not the same
--         question as (i) and it must not be read as one; the section says which is which.
--   (iii) Both referee policies dropped and recreated on the predicate. `public.evidence` and
--         `storage.objects` move **together**: a photograph that is listable and unopenable, or
--         openable and unlistable, is the failure this story exists to avoid.
--   (iv)  `sign_off_day()` recreated with its body verbatim and its photograph guard reading the
--         same predicate -- so there is exactly one expression of the rule in the schema rather
--         than three that are free to drift. `sign_off_day()`'s own comment asked for this
--         (20260914090000:382-383); Epic 6 retrospective item 50 is what happens when nobody
--         does it, and all three of Story 8.2's review rounds found that same shape.
--
-- **What is deliberately NOT here.** `referee_day_lookup()` (20260908180000:147-189) still
-- excludes a commitment-day photograph, by join and by `e.commitment_id is null`, and this
-- migration does not touch it. Story 8.4 owns what the referee is *shown*; this story is reach
-- without visibility, the way Story 8.1 was a flag nothing read. The author's own policies,
-- `evidence_derive_owner()`, `evidence_object_must_exist()` and every referee **write** path are
-- likewise untouched -- `20260824130000:309`'s `role_from_table() = 'doer'` is why no referee
-- write path exists here and none is added.


-- ---------------------------------------------------------------------------------
-- (i) The one door.
-- ---------------------------------------------------------------------------------

/* The inline-the-lookup pattern that the seven policies of `20260907160000:130-192` use cannot
   carry this, and the guard it would otherwise have to edit must not be edited to fit. Those
   policies inline `(select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))`
   rather than call `paired_doer_id()`, and `:76-79` says why: granting the function *"would have
   meant editing a security guard to fit new code, which is the wrong direction."* That works only
   because the inlined read is of the caller's **own** `profile` row, which `profile: read own`
   already permits.

   It cannot work here. The flag's history lives in
   `commitment_requires_referee_approval_change`, which carries `revoke all` **and** an explicit
   deny-all policy (`20260911090000:111-117`), so a subquery inlined into a policy and evaluated as
   the referee returns nothing -- silently, which is the worst way for an authorization predicate
   to fail.

   Nor may the policy reach for `requires_referee_approval_as_of()` instead, and section (ii)
   below does not change that however it may look at a glance. A policy predicate that leans on a
   client EXECUTE grant is a policy whose correctness depends on an ACL -- and an ACL is the thing
   `drop function` destroys and a bare `create` in `public` hands straight back to PUBLIC. This
   function is `security definer`, so the policies that call it need no caller privilege on
   anything underneath; the grant in (ii) exists for the author's *copy* and no predicate rests on
   it. Two different questions that happen to name one function.

   The precedent that fits is `evidence_object_is_a_commitment_day()` (`20260903120000:315-320`)
   and `evidence_object_owner()` (`20260907160000:120-123`): a narrow `security definer` answer
   called *from* a policy and granted to `authenticated`, because it answers one fact about an
   argument the caller already named. */
create function public.photograph_reaches_the_referee(p_commitment_id uuid, p_for_day date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.requires_referee_approval_as_of(p_commitment_id, p_for_day) is true
     and (
       -- Story 6.8's commitment-day record, for a commitment carrying no due_time.
       exists (
         select 1 from public.evidence e
          where e.commitment_id = p_commitment_id and e.for_day = p_for_day
       )
       -- Story 6.3's claim-parented proof, for one that does.
       or exists (
         select 1 from public.evidence e
           join public.declaration d on d.id = e.declaration_id
          where d.commitment_id = p_commitment_id and d.for_day = p_for_day
       )
     );
$$;

comment on function public.photograph_reaches_the_referee(uuid, date) is
  'Story 8.3, and the single expression of "which photograph may the referee see". True when
  p_commitment_id asked for its referee''s signature through the whole of p_day AND a photograph
  of either parentage belongs to that commitment-day. Both halves of one question: the union of
  parentages (20260903120000:51-53) is what the day *was proved with* -- a commitment carrying a
  due_time proves itself with Story 6.3''s claim-parented photograph, one without with Story
  6.8''s commitment-day photograph -- and the flag is whether he may look at it. Read by exactly
  three callers: the `evidence` policy, the `storage.objects` policy through
  commitment_day_object_reaches_the_referee(), and sign_off_day()''s photograph guard. So the three can
  never come to disagree about one money-adjacent rule, which is Epic 6 retrospective item 50 and
  the shape all three of Story 8.2''s review rounds found.

  The flag is read only through requires_referee_approval_as_of(), never live, and compared with
  `is true` because that reader answers NULL for a commitment with no history at all and
  `not NULL` fails open. A flag switched off after the day still reaches back to it; a flag
  switched on after it does not reach forward into a day already lived.

  **Says nothing about *which* referee.** It answers about a commitment-day, not about a session:
  the pairing conjunct stays where it already is, in every one of the seven policies of
  20260907160000. Granted to `authenticated` on evidence_object_owner()''s terms -- it exposes no
  column of anything, and the commitment uuid is the capability. Only the account that owns the
  commitment and the referee paired to it can hold one (`commitment: referee reads his own
  doer''s` is what bounds the second), and a uuid is not guessable.

  **swept_at is not filtered, and that is a decision.** Three behaviours already exist for it:
  referee_day_lookup() filters swept rows server-side (20260908180000:176-179), the appeal detail
  and readKeptPhotos() filter client-side and *count* them as cleared, and sign_off_day()''s guard
  did not filter at all. This does not filter either, so nothing changes for the guard it
  replaces: the row is metadata and the bytes are what is gone, a caller signing a URL for a swept
  object already learns that, and a fourth behaviour here would be one more thing to disagree
  about.';

revoke execute on function public.photograph_reaches_the_referee(uuid, date) from public, anon;
grant execute on function public.photograph_reaches_the_referee(uuid, date) to authenticated;


/* The storage policy has only a path; the rule needs a day.

   `evidence_storage_path_leads_with_its_parent` (20260903120000:99-103) guarantees the first
   folder is the parent's id, so a commitment-day object's path yields a commitment -- but never
   its `for_day`, which is the argument requires_referee_approval_as_of() needs. A commitment is
   not a day. So the day is resolved through the `evidence` row that names the object, inside a
   definer function so RLS does not make the lookup disappear the way an inlined subquery would.

   The consequence is deliberate and is the safe direction: **an object with no `evidence` row is
   not reachable by the referee.** It proves nothing, Story 8.4's list is driven by rows, and an
   orphan failing closed costs nothing. Note this is the opposite direction from the *appeal* arm
   of the policy below, which is asked of the path precisely so that an orphaned upload stays
   readable (`4-6-the-referee-rules.sql` step 8) -- that arm is unchanged, and only the
   commitment-day arm resolves through a row. */
create function public.commitment_day_object_reaches_the_referee(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.evidence e
     where e.storage_path = p_name
       and e.commitment_id is not null
       and public.photograph_reaches_the_referee(e.commitment_id, e.for_day)
  );
$$;

comment on function public.commitment_day_object_reaches_the_referee(text) is
  'Story 8.3: whether a commitment-day object in the `appeal-evidence` bucket is one the referee
  may open -- the path resolved to its `evidence` row (storage_path = objects.name) so that
  photograph_reaches_the_referee() can be asked the commitment **and the day** it needs, which a
  path alone can never supply. Thin on purpose: it decides nothing of its own and adds no rule of
  its own, it only carries an argument across. False for an object with no row behind it, which is
  the direction that fails closed -- such an object proves nothing and Story 8.4''s list is driven
  by rows. security definer for evidence_object_is_a_commitment_day()''s reason, one table along:
  a policy subquery is evaluated as the caller, so an inlined lookup would answer `false` for
  every object and the widening would silently never fire.

  **Not a complete answer about an object, and the name says commitment_day for that reason.** It
  is false for every appeal- and declaration-parented object, which are reachable by the referee
  and always have been -- the policy''s other arm is what answers for those. Called on its own it
  would refuse objects he may certainly open. Use it only as the disjunct it was written to be.';

revoke execute on function public.commitment_day_object_reaches_the_referee(text) from public, anon;
grant execute on function public.commitment_day_object_reaches_the_referee(text) to authenticated;


-- ---------------------------------------------------------------------------------
-- (ii) One grant, for the author's copy. **No policy predicate may rest on it.**
--
-- Two questions wear the same function name here, and conflating them is how the next reader
-- undoes decision 2. This section is the one that says which is which.
--
-- **The question this does NOT answer.** Whether a *policy* may call
-- requires_referee_approval_as_of(). It may not, and the two helpers above exist so that it never
-- has to: a policy predicate resting on a client EXECUTE grant is a policy whose correctness
-- depends on an ACL, and an ACL is exactly what `drop function` destroys and a bare `create` in
-- `public` hands back to PUBLIC. `2-1-roles-and-rls.sql` is the guard that says so, and it has not
-- been edited to fit new code -- the widened policies reach the flag through
-- `photograph_reaches_the_referee()`, which is `security definer` and needs no caller privilege at
-- all. Nothing below changes that, and grepping this migration for a policy that calls the reader
-- directly must keep returning nothing.
--
-- **The question this does answer.** What the *author's copy* reads. Today's all-day photo control
-- tells him who can open the photograph he is about to take, and after this story that sentence is
-- decided by the flag **as of the day the photograph belongs to** -- the same reading the policy
-- makes. Left on the live `commitment.requires_referee_approval` column, the two disagree for the
-- rest of any day he moves the flag, and in the direction that matters: switched off at 10:00, the
-- policy still lets the referee open today's photograph while the screen says "Only you can open
-- it." That is Epic 6 retrospective A2 -- a privacy promised that the rules do not keep --
-- re-created inside the story that exists to be A2's consent answer.
--
-- **What it costs, stated rather than glossed.** The function takes an arbitrary
-- `p_commitment_id` and performs no ownership check of its own. One cannot be added: settlement
-- calls it from cron, where `auth.uid()` is null, so any `auth.uid()`-based guard inside it would
-- refuse the caller it was written for. What an authenticated session can therefore learn is one
-- boolean about a commitment uuid it must already hold -- and a uuid is obtainable only from
-- `commitment: read own` or `commitment: referee reads his own doer's`, which is to say by the
-- account that owns it or the referee paired to that account. The same shape as
-- `evidence_object_owner()`, which returns an owner id for any path on the same reasoning.
--
-- One inference it enables that the paragraph above does not cover, named rather than left to be
-- found: the answer is NULL for a commitment id that names no row at all and non-NULL for one
-- that does, so the function is also an existence oracle over commitment uuids. It is a weak one
-- -- a uuid is not guessable, and a caller holding one already knows it exists -- but it is the
-- one thing here that is true of ids the caller was *not* given, and a cost paragraph that lists
-- everything else should not be silent about it.
--
-- **hwt75 answered this Ask First on 2026-09-14**, told of that cost and of the alternative -- a
-- second narrow definer helper answering only the flag half, which would have needed no grant --
-- and chose the grant. `20260911090000:240-245` reserved the question for Story 8.6 and named the
-- two doors; this answers it one story early and closes both, so 8.6 inherits a decision rather
-- than making it again beside this one.
-- ---------------------------------------------------------------------------------

-- `anon` is deliberately not included and must never be: a signed-out caller holds no commitment
-- uuid legitimately, so the "must already know it" argument above does not cover him. Revoked
-- first and granted second, so the widening is one named role and never PUBLIC.
revoke execute on function public.requires_referee_approval_as_of(uuid, date) from public, anon;

grant execute on function public.requires_referee_approval_as_of(uuid, date) to authenticated;


-- ---------------------------------------------------------------------------------
-- (iii) Both referee policies, widened on the same predicate and in the same commit.
--
-- There is no in-place predicate change: widening a policy is `drop policy` + `create policy`,
-- and 20260907160000:140,182 shows the drop-then-create idiom for exactly these two. They are
-- here together because the story's own boundary says so -- a row he can list and not open, or an
-- object he can open and not list, is the failure this exists to avoid.
--
-- What neither of them loses: Story 6.8's narrowing still stands everywhere the flag is off. An
-- unflagged commitment-day photograph is exactly as private as 20260903120000 made it, and the
-- `owner_id` / `evidence_object_owner()` conjunct each policy already carried is untouched, so no
-- referee reaches an account he is not paired to.
-- ---------------------------------------------------------------------------------

drop policy "evidence: referee reads his own doer's" on public.evidence;

create policy "evidence: referee reads his own doer's"
  on public.evidence for select to authenticated
  using (
    public.role_from_token() = 'referee'
    and owner_id = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))
    and (
      -- An appeal's row and a claim's row, exactly as before: reachable since Story 4.6 and not
      -- what this story is about.
      commitment_id is null
      -- Story 6.8's kept record, and only when the commitment asked for his signature as of the
      -- day the photograph belongs to. `for_day` is `not null` whenever `commitment_id` is
      -- (`evidence_for_day_belongs_to_a_commitment`, 20260903120000:92), so the predicate is
      -- never asked about a day that does not exist.
      --
      -- **Half of the predicate is tautological here, and that is the price of decision 1.** Its
      -- union-of-parentages half asks whether a photograph exists for this commitment-day, and
      -- on this arm the row being filtered *is* one -- so only the flag half decides anything,
      -- at the cost of one extra index scan per row the referee can already see. A narrower
      -- flag-only helper would save that scan and break the acceptance criterion this story was
      -- written around: change "which photograph may the referee see" and all three askers must
      -- change, which is only true while all three ask the same function. The row set is bounded
      -- by one doer's evidence, and a re-derived rule is what Epic 6 retrospective item 50 cost.
      or public.photograph_reaches_the_referee(commitment_id, for_day)
    )
  );

drop policy "appeal-evidence objects: referee reads his own doer's" on storage.objects;

create policy "appeal-evidence objects: referee reads his own doer's"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'appeal-evidence'
    and public.role_from_token() = 'referee'
    and public.evidence_object_owner(objects.name) = (select pr.referee_of from public.profile pr where pr.id = (select auth.uid()))
    and (
      -- Unchanged, and still asked of the *path* rather than of a metadata row: an object can
      -- exist with no `evidence` row behind it -- the client uploads the object first and files
      -- the row second -- and `4-6-the-referee-rules.sql` step 8 asserts the referee can read
      -- exactly such an object.
      not public.evidence_object_is_a_commitment_day(objects.name)
      -- The whole of the widening, on the object side: the twin of the `evidence` arm above,
      -- resting on the same predicate, so the two cannot come to disagree about one photograph.
      or public.commitment_day_object_reaches_the_referee(objects.name)
    )
  );


-- ---------------------------------------------------------------------------------
-- (iv) The third asker, moved onto the door rather than left beside it.
--
-- `create or replace`, body **verbatim** from 20260914090000:202-433 with exactly one change: the
-- photograph guard now reads photograph_reaches_the_referee() instead of spelling the union of
-- parentages out a second time. Nothing else moves -- not a check, not an order, not a sentence.
--
-- The decision logic is identical, and the ordering is why. The guard sits below the
-- `requires_referee_approval_as_of(...) is not true` refusal, so the flag half of the predicate
-- is already known true by the time it is reached, and `not photograph_reaches_the_referee(...)`
-- is the same boolean the two `not exists` clauses were. It is asserted as such in
-- `8-2-the-referee-s-decision-and-what-a-refusal-costs.sql`, which runs unmodified.
--
-- Left as it stood, Story 8.4 would have had a fourth thing to re-derive. It now has one door to
-- walk through.
-- ---------------------------------------------------------------------------------

create or replace function public.sign_off_day(
  p_commitment_id uuid,
  p_for_day date,
  p_approved boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paired uuid;
  v_commitment record;
  v_carries_penalty boolean;
  v_reason text;
begin
  -- First statement, before any row is read -- the I/O Matrix's own "Not the referee" row.
  -- `is distinct from`, not `<>`: a plain `<>` against a NULL role evaluates NULL, and
  -- `if NULL then raise` never raises (20260825090000:105-109).
  if public.role_from_table() is distinct from 'referee' then
    raise exception 'Only the referee may sign off a day.';
  end if;

  -- Same NULL hazard, same fix, and checked before anything is read for the same reason the role
  -- is: `if not p_approved then` treats a NULL argument as false and would fall straight through
  -- into the refusal branch for a call that named no decision at all.
  if p_approved is null then
    raise exception 'p_approved must not be null. Say whether you approve or refuse.';
  end if;

  if p_commitment_id is null or p_for_day is null then
    raise exception 'A decision names one commitment and one day. Both are required.';
  end if;

  -- He must say why, and not without end -- `referee_decision_says_why` is the real guarantee,
  -- this is what turns it into a sentence he can act on. Both directions: an approval carrying a
  -- reason is refused with words rather than a raw 23514.
  if not p_approved then
    if p_reason is null or btrim(p_reason) = '' then
      raise exception 'A refusal has to say why. Give a reason.';
    end if;

    if char_length(btrim(p_reason)) > 2000 then
      raise exception
        'That reason is % characters. Say it in 2000 or fewer -- he reads it on the day it names.',
        char_length(btrim(p_reason));
    end if;
  elsif btrim(coalesce(p_reason, '')) <> '' then
    raise exception
      'An approval carries no reason -- it changes nothing, so there is nothing to explain. '
      'His silence would have approved the day anyway. If you meant to refuse, say so.';
  end if;

  v_reason := case when p_approved then null else btrim(p_reason) end;

  -- Establish the caller before reading anything of the author's. The pairing check belongs above
  -- the commitment lookup, not below it: a referee who could tell 'No such commitment.' from
  -- 'That commitment belongs to an account you are not paired to.' would have a commitment-id
  -- oracle across every account. `object_to_day()` orders itself this way and says why at
  -- 20260906080451:181-184. So the lookup is *scoped* to the paired account and the two cases
  -- share one sentence.
  v_paired := public.paired_doer_id();

  if v_paired is null then
    raise exception 'That commitment belongs to an account you are not paired to.';
  end if;

  select c.* into v_commitment
    from public.commitment c
   where c.id = p_commitment_id and c.owner_id = v_paired;

  if not found then
    raise exception 'That commitment belongs to an account you are not paired to.';
  end if;

  -- The flag, read **only** through requires_referee_approval_as_of() and never live -- the one
  -- door, in both of this story's readers (Epic 6 retrospective item 50). `is not true`, because
  -- the door answers NULL for a commitment with no history and `not NULL` fails open.
  if public.requires_referee_approval_as_of(p_commitment_id, p_for_day) is not true then
    raise exception 'That commitment did not ask for your signature on that day.';
  end if;

  -- The window. Half-open at both ends, matching every other deadline in this schema: a signature
  -- at exactly midnight is late, and one at exactly the day's first instant is in time.
  if now() >= public.day_ends_at(p_for_day) then
    raise exception 'That day has closed. A signature lands before midnight or not at all.';
  end if;

  if now() < public.day_begins_at(p_for_day) then
    raise exception 'That day has not started yet.';
  end if;

  -- The midnight race, narrowed. `now()` is transaction-start time, so a decision begun at
  -- 23:59:59.9 commits after midnight and can land while `settle_day()` is running -- and
  -- `settle_day()` reads `commitments_owing()` in five separate statements under READ COMMITTED
  -- (20260829090000:449, 464, 473, 509, 520), with the counts and the penalty insert before the
  -- frozen-outcome write. A refusal committing between those two produces a settlement reading
  -- `clean` with no penalty beside a frozen `missed`: a broken chain with nothing for a Grace Day
  -- to attach to, which `grace_day_validate()` refuses on both of its conditions at once.
  --
  -- This is check-then-act and does not eliminate that window; it takes it from the whole of
  -- settle_day()'s run down to the instant between this read and the insert below, and it turns
  -- the common case -- a referee deciding a day the cron already settled -- from a silent no-op
  -- into a sentence. **The real closure is the per-account advisory lock that every other writer
  -- of money-relevant state already takes and `settle_day()` alone does not**; giving it one
  -- changes the most load-bearing function in the schema for a reason that predates this epic, so
  -- it is its own story and is recorded in `deferred-work.md` with this finding as its evidence.
  if exists (
    select 1 from public.settlement s
     where s.subject = v_paired and s.period = p_for_day and s.kind = 'day'
  ) then
    raise exception
      'That day has already been settled, so a decision now would arrive too late to be read.';
  end if;

  -- Already decided, and this is checked **above** the refusal-only guards below, not beside the
  -- insert. A decision is final, and a repeat has to read as the guarded transition it is -- in
  -- the same words the race-loser gets -- whatever has happened to the commitment since. Ordered
  -- below it, a referee who refused at 21:00 and double-tapped after the author turned the money
  -- off at 22:00 was told "That commitment carried no penalty on that day": the wrong sentence,
  -- and one that tells him something about the author's edits that is none of his business.
  --
  -- The unique constraint is still the actual guarantee -- a check-then-act read cannot make one
  -- on its own -- and the raise beside the insert is what catches the race this read cannot.
  if exists (
    select 1 from public.referee_decision r
     where r.subject = v_paired and r.for_day = p_for_day
       and r.commitment_id = p_commitment_id
  ) then
    raise exception 'That day has already been decided, and a decision is final.';
  end if;

  -- Read once, here, and frozen onto the row below. Never re-read at settlement.
  v_carries_penalty := public.carries_penalty_as_of(p_commitment_id, p_for_day);

  -- ---------------------------------------------------------------------------------
  -- The landing guards, and only two of `object_to_day()`'s four survive the move before
  -- midnight. It lands as a day that a Grace Day can still reach, or it does not land.
  --
  -- Guard (a) -- a penalty in any state but `owed` (20260906080451:266-286) -- cannot apply:
  -- `penalty` is keyed by `settlement_id`, and a day that has not closed has no settlement and
  -- therefore no penalty. Guard (c) -- the `unanswered > 0` would-land-`expired` refusal
  -- (:307-333) -- cannot apply either: it counts the frozen rows of the settlement being
  -- superseded, and at refusal time there are none. What survives is exactly the pair that is a
  -- fact about the *commitment* rather than about a settlement.
  --
  -- All of these are refusal-only. An approval changes no outcome, so it can break nothing, and
  -- refusing one would be the mechanism nagging about a decision that costs nothing.
  -- ---------------------------------------------------------------------------------

  if not p_approved and v_carries_penalty is not true then
    raise exception
      'That commitment carried no penalty on that day, so refusing it would cost him nothing '
      'and break his chain with no Grace Day able to reach it.';
  end if;

  if not p_approved and v_commitment.cadence = 'weekly_quota' then
    raise exception
      'That is a Weekly Quota commitment. Its money is decided at week close and never by one '
      'day, so refusing it would break his chain with no Grace Day able to reach it.';
  end if;

  -- The third, which `object_to_day()` never needed: an hours quota is judged by measured minutes
  -- and `commitments_owing()` has excluded it outright since
  -- 20260820140000_weekly_quota_is_not_judged_daily.sql. Without this the RPC would report success
  -- for a decision the settlement arm can never read -- half-closing Story 8.1's own deferred
  -- entry, which left the flag settable on `do` + `daily_hours_quota` and inert.
  if not p_approved and v_commitment.cadence = 'daily_hours_quota' then
    raise exception
      'That commitment is measured in minutes over the day, never held or missed on one day, so '
      'there is no day here to refuse. Its hours decide it.';
  end if;

  -- A refusal needs something to have been refused. CAP-6 keeps photograph-less days off the
  -- referee's list, but a condition living only in Story 8.4's query is not enforced -- AD-1 says
  -- the server is the sole judge. **Both parentages count** (20260903120000:51-53): a commitment
  -- carrying a due_time proves itself with the claim-parented photograph of Story 6.3, one
  -- without with the commitment-day photograph of Story 6.8, and the union is what is asked here
  -- rather than a branch on due_time -- so a photograph the author really attached can never be
  -- read as no photograph.
  --
  -- Story 8.3 moved that union into photograph_reaches_the_referee() and put both referee
  -- policies on it, so the question this guard asks and the question the policies answer are now
  -- one expression rather than three. This function's own comment asked for exactly that --
  -- *"Story 8.4's list must ask this same question; the two must not be able to disagree"* -- and
  -- leaving it here as a second copy is how they would have. **Identical in what it decides:**
  -- the flag half of the predicate was established `is true` above, so what is left of it here is
  -- the union, unchanged.
  if not p_approved
     and not public.photograph_reaches_the_referee(p_commitment_id, p_for_day) then
    raise exception
      'There is no photograph on that day yet, so there is nothing to refuse.';
  end if;

  -- Archived, and this is the other half of the freeze above. Iteration 2 of this story's review
  -- froze the facts onto the row and gave `commitments_owing()` an archived-filter exception, but
  -- that exception has no time ordering: a commitment archived at 08:00 could be refused at 21:00
  -- and pulled back into a day the author had already retired it from. The exception stays as it
  -- is; the ordering is enforced here, by refusing to write the decision at all. Two narrow rules,
  -- each true on its own, rather than one timestamp comparison whose correctness depends on
  -- reading both.
  if v_commitment.archived_at is not null then
    raise exception 'That commitment is archived, so its days are no longer being judged.';
  end if;

  -- AD-15's guarded transition, and the only thing standing between two concurrent decisions --
  -- the read above serializes nothing, and two calls that both pass it arrive here. The second
  -- blocks on the unique index until the first commits, then finds its own `on conflict do
  -- nothing` inserted nothing. `object_to_day()`'s own idiom at 20260906080451:341-351.
  --
  -- `coalesce(..., false)` on the frozen money flag: carries_penalty_as_of() answers NULL only
  -- for a commitment with no log history at all, which the 20260827130000 backfill makes
  -- unreachable, and the column is `not null`. A refusal never reaches this line with anything
  -- but true -- the guard above refused it -- so the coalesce only ever decides what an
  -- *approval* records, and an approval's frozen facts are never read by anything.
  insert into public.referee_decision
    (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
  values (v_paired, (select auth.uid()), p_for_day, p_commitment_id, p_approved, v_reason,
          coalesce(v_carries_penalty, false), v_commitment.cadence)
  -- No `returning`: `FOUND` is set by the INSERT itself, and there is nothing here that wants
  -- the id. object_to_day() keeps its own because it builds an outbox dedupe key from it; this
  -- function deliberately enqueues nothing, so a handle on the row would be a variable written
  -- and never read. Story 8.5 adds the telling, and will add the `returning` with it.
  on conflict (subject, for_day, commitment_id) do nothing;

  if not found then
    raise exception 'That day has already been decided, and a decision is final.';
  end if;
end;
$$;
