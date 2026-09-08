-- Epic 6 retrospective, item 43 / defect A2 (HIGH) -- the second half.
--
-- The first half was copy: `EVIDENCE_COPY.hint` used to tell the author "It is private -- only you
-- can open it" while `evidence: referee reads his own doer's` (20260907160000:141) already granted
-- the referee every one of those rows. The sentence was what moved, because the policy is what
-- makes him able to rule at all.
--
-- This is the other half. Having decided he may see a claim's proof, the product should actually
-- show it to him -- and on the one screen he opens on his own initiative, `Look up a day`
-- (Story 6.7), it shows him the commitment, the outcome and the objection window and no photograph
-- at all. He is asked whether a day held with the thing it was proved with invisible.
--
-- WHY THIS IS A FUNCTION CHANGE AND NOT A NEW POLICY
--
-- His *reach* is already sufficient: he may read the `evidence` row (`commitment_id is null`, his
-- own doer) and he may sign the object behind it (`appeal-evidence objects: referee reads his own
-- doer's`, :183). What he cannot do is the join -- there is no `declaration: referee ...` policy at
-- all, so an evidence row reaches him carrying a `declaration_id` he can never resolve to a day or
-- a commitment. The rows are unusable rather than unavailable.
--
-- Granting him select on `declaration` would fix that by handing him the author's claim rows
-- wholesale -- every answer, every `answered_at` -- to solve a problem that is only about
-- photographs. So the join moves inside `referee_day_lookup()` instead, which is already
-- `security definer`, already the sole door this screen goes through, and already scoped to
-- `paired_doer_id()`. After this migration the referee can read exactly the tables and objects he
-- could read before it; only what the one door hands back is wider.
--
-- WHAT IT DOES NOT REACH
--
-- Commitment-day photos (Story 6.8 -- the records the author keeps against a commitment rather
-- than to prove a claim) stay out. They answer for no verdict, and 6.8 narrowed both referee
-- policies specifically to exclude them. The join is on `declaration_id`, which already excludes
-- them structurally; `e.commitment_id is null` is asserted anyway, so that the day the parent
-- constraint is relaxed this function does not quietly widen with it.
--
-- Appeal-parented evidence is also absent, and deliberately: it belongs to the appeal he is ruling
-- on and is already rendered by `components/referee-appeal-detail.tsx`. This screen answers "what
-- was this day proved with", and a contest filed later is not that.

-- The return type changes, so this cannot be `create or replace`.
drop function public.referee_day_lookup(uuid);

create function public.referee_day_lookup(p_settlement_id uuid)
returns table (
  commitment_id uuid,
  commitment_name text,
  outcome public.commitment_outcome,
  objection_deadline timestamptz,
  already_objected boolean,
  evidence_paths text[]
)
language sql
security definer
stable
set search_path = ''
as $$
  select sc.commitment_id,
         c.name,
         sc.outcome,
         public.objection_deadline(s.settled_at),
         exists (
           select 1 from public.objection o
            where o.subject = s.subject and o.for_day = s.period
         ),
         -- Empty array rather than null for a day with no proof: the client renders nothing
         -- either way, and a null would make every caller test for two shapes of "none".
         coalesce(
           (select array_agg(e.storage_path order by e.created_at, e.id)
              from public.declaration d
              join public.evidence e on e.declaration_id = d.id
             where d.commitment_id = sc.commitment_id
               -- The claim for *this* day, not every claim this commitment ever carried.
               and d.for_day = s.period
               -- Redundant against the outer scoping, and kept: this subquery reads two tables
               -- the caller has no policy on, inside a security definer function, so its own
               -- owner filter is written out rather than inferred from context.
               and d.owner_id = s.subject
               and e.commitment_id is null),
           '{}'::text[]
         )
    from public.settlement_commitment sc
    join public.settlement s on s.id = sc.settlement_id
    join public.commitment c on c.id = sc.commitment_id
   where sc.settlement_id = p_settlement_id
     and s.kind = 'day'
     and public.role_from_table() = 'referee'
     and s.subject = public.paired_doer_id();
$$;

comment on function public.referee_day_lookup(uuid) is
  'Story 6.7, widened by epic 6 retrospective item 43. What one settled day he already named '
  'recorded: each commitment, its name, its frozen outcome, when the 48-hour objection window '
  'closes, whether the day has already been objected to, and the storage paths of the photos the '
  'day''s claims were proved with. Takes exactly one settlement id -- there is no range form and '
  'no way to ask it what days exist, because a browsable list of the author''s days is a queue in '
  'everything but name -- and answers only for the account he is paired to, the same boundary '
  'object_to_day() writes within. The evidence paths are declaration-parented only: commitment-day '
  'photos (6.8) are the author''s own records, answer for no verdict, and are excluded here as '
  'they are by both referee evidence policies. security definer rather than an RLS policy on '
  'settlement_commitment: that table is chain_current''s own base table, and granting the referee '
  'select on it would silently reopen a doer-facing surface (the 20260825100000 incident). It is '
  'also why the evidence join lives here rather than behind a new declaration policy -- the join '
  'is all he was missing, and a policy would have handed him every claim row to supply it.';
