-- Story 8.5 — The author is told he was refused.
--
-- Since Story 8.2 a refusal fails the author's day, and Story 8.4 gave the referee the button to
-- make one -- but sign_off_day() enqueued nothing, so the author learned his day was refused only
-- by finding it failed. CAP-7: one message naming the commitment, the day and the reason verbatim.
--
-- **The one hard constraint is `outbox_body_is_sendable`** (20260820101000:46-48), a CHECK on
-- `payload ->> 'body'` that refuses "right now", "currently", "just now" and "at the moment"
-- anywhere in it. objection_body() kept the referee's reason out of its push for exactly that
-- reason (20260903140000:262-300): free text in the body can abort the transaction that carries
-- it. A refusal that fails because of someone's wording is the failure this story exists to avoid.
--
-- **hwt75 decided on 2026-09-29** that the reason travels anyway, in a separate `quote` field the
-- service worker shows under the app's own sentence (`lib/push-payload.ts`), and that a reason too
-- large for a push is left out whole rather than cut. So:
--
--   * the body is built from the app's words and the date alone -- nothing anyone typed;
--   * the commitment name rides in the title, which no check reads and a lock screen shows first;
--   * the reason rides in `quote`, byte-for-byte as referee_decision.reason stores it.
--
-- **What is deliberately NOT here.** No change to push_body_is_sendable, the outbox check,
-- outbox_enqueue(), object_to_day() or objection_body(). No change to what sign_off_day() decides:
-- it is re-created verbatim from 20260914120000:306-536 with exactly two additions, the
-- `returning` and the enqueue. Every assertion in `8-2-...sql` but one passes unmodified, which is
-- what proves the first half; the one that moved is its outbox count, 0 -> one per refusal, which
-- is this story. `8-3-...sql` step 7 still reads its text.


-- ---------------------------------------------------------------------------------
-- (i) What the app says.
-- ---------------------------------------------------------------------------------

/* Self-dates with the refused day's own weekday, as objection_body() and appeal_ruling_body() do:
   push_body_is_sendable needs a clock time or a named day, and a refusal is about a day.

   Takes no name and no reason, on purpose. Every argument is a date or a boolean, so no input can
   make this sentence fail the check -- which is the property sign_off_day() depends on to be sure
   its enqueue never aborts a refusal. `8-5-...sql` asserts it against hostile names and reasons.

   `p_quoted` says whether the referee's words travel with this push. When they do, the body ends
   by introducing them; when they were too large to fit, it says where to read them -- "after
   midnight", because a Ledger row exists only once settle_day() has closed the day, which is
   shortly after midnight and never before it.

   "Refused it", not "refused that day": a refusal names one commitment, and the title says which;
   the other commitments on the same day are untouched. */
create function public.refusal_body(p_for_day date, p_quoted boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'Your referee refused it for '
      || to_char(p_for_day, 'FMDay') || ', ' || to_char(p_for_day, 'YYYY-MM-DD')
      || '. That day will close as a failed day at midnight. '
      || case
           when p_quoted then 'His reason, in his words:'
           else 'His reason was too long for a notification. It is on that day in your Ledger '
                || 'after midnight.'
         end;
$$;

comment on function public.refusal_body(date, boolean) is
  'Story 8.5. The refusal push''s body: the refused day by weekday and date, that it closes failed,
  and either an introduction to the referee''s words (carried separately, in `quote`) or where to
  read them when they were too large to send. Built from a date and a boolean only, so nothing
  anyone typed can make it fail push_body_is_sendable and abort the refusal that enqueues it.';

revoke execute on function public.refusal_body(date, boolean) from public, anon, authenticated;


/* The whole payload, and the one place the size decision is made.

   **3500 bytes of the payload's UTF-8 JSON text.** Web push caps the encrypted record at 4096
   bytes -- about 3993 of plaintext once aes128gcm's header, delimiter and tag are paid -- and the
   outbox worker sends `JSON.stringify(row.payload)` whole (supabase/functions/outbox-worker/
   index.ts:83-85). Bytes, never characters: a Vietnamese reason costs up to three bytes a
   character, so a 2000-character reason can be 6000 bytes. `jsonb::text` puts a space after every
   `:` and `,`, so it measures a little more than the worker sends -- the safe direction -- and the
   rest of the headroom is for the title and `sent_at`.

   **Too large means left out whole.** hwt75's decision: a reason is never cut, because a cut
   sentence is a paraphrase the referee did not write. The body then says where to read it.

   The title carries the commitment name. A name the author typed may contain "right now" as
   easily as a reason may, and the title is the one field no check reads. `A commitment` stands in
   for a blank one, the fallback every referee surface already uses.

   **The name is clipped to 80 characters in the title, and only there.** `commitment.name` has no
   length bound, so without this a long enough name would push even the quote-less payload past
   what a push service accepts, and the author would never be told. The title is the app's own
   line, so clipping it is not the cut hwt75 ruled out -- that rule is about the referee's words,
   which are never touched. 80 characters is at most 320 bytes, so the quote-less payload is
   bounded well inside the budget whatever the author named his commitment. */
create function public.refusal_payload(p_commitment_name text, p_for_day date, p_reason text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_base jsonb;
  v_quoted jsonb;
begin
  v_base := jsonb_build_object(
    'title', case
               when char_length(btrim(p_commitment_name)) > 80
                 then left(btrim(p_commitment_name), 79) || '…'
               else coalesce(nullif(btrim(p_commitment_name), ''), 'A commitment')
             end || ' — your referee refused it',
    'sent_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  v_quoted := v_base || jsonb_build_object(
    'body', public.refusal_body(p_for_day, true),
    'quote', p_reason
  );

  if p_reason is not null
     and octet_length(convert_to(v_quoted::text, 'UTF8')) <= 3500 then
    return v_quoted;
  end if;

  return v_base || jsonb_build_object('body', public.refusal_body(p_for_day, false));
end;
$$;

comment on function public.refusal_payload(text, date, text) is
  'Story 8.5. The refusal push: {title, body, quote?, sent_at}. The commitment name in the title,
  the app''s own dated sentence in the body, and the referee''s reason verbatim in `quote` -- left
  out whole, never cut, when the payload''s UTF-8 JSON text would exceed 3500 bytes, in which case
  the body says where to read it. Neither title nor quote is read by outbox_body_is_sendable.';

revoke execute on function public.refusal_payload(text, date, text)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- (ii) sign_off_day(), telling the author.
--
-- `create or replace`, body verbatim from 20260914120000:306-536 with exactly two additions: the
-- insert's `returning id`, and one enqueue for a refusal. The ACL Story 8.2 set and 8.3 kept
-- survives a replace; `2-1-roles-and-rls.sql` step 9 and `8-2-...sql` assert it in both
-- directions.
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
  v_decision uuid;
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
  -- Story 8.5: the id is the outbox dedupe key below, the same reason object_to_day() keeps its
  -- own. A race loser's `on conflict do nothing` returns no row, so `FOUND` is false and it raises
  -- before it can reach the enqueue -- exactly one push per refusal, by the unique constraint.
  on conflict (subject, for_day, commitment_id) do nothing
  returning id into v_decision;

  if not found then
    raise exception 'That day has already been decided, and a decision is final.';
  end if;

  -- Story 8.5, CAP-7. The author is told, in the refusal's own transaction (AD-3) and on the push
  -- channel -- if this enqueue fails, the refusal does not land. An approval changes nothing and
  -- says nothing; a silence has no transaction to say it in.
  --
  -- refusal_payload() is what keeps someone's wording from aborting this: the commitment name
  -- rides in the title and the reason in `quote`, neither of which outbox_body_is_sendable reads,
  -- and the body it does read is built from the app's words and the date alone.
  if not p_approved then
    perform public.outbox_enqueue(
      v_paired,
      'refusal-' || v_decision::text,
      public.refusal_payload(v_commitment.name, p_for_day, v_reason)
    );
  end if;
end;
$$;

-- `create or replace` keeps the comment it finds, and 20260914090000:435-446 ended "Enqueues
-- nothing -- telling the author is Story 8.5". Left alone, the catalog would say the opposite of
-- what the function now does.
comment on function public.sign_off_day(uuid, date, boolean, text) is
  'Story 8.2; Story 8.3; Story 8.5. The referee''s decision on one flagged commitment-day of the
  doer he is paired to, before that day closes. Checks role_from_table() = ''referee'' as its first
  statement, then the reason, then the pairing -- above any read of the author''s, so there is no
  commitment-id oracle. Reads the flag only through requires_referee_approval_as_of(), never live,
  and the photograph through photograph_reaches_the_referee(). Refuses outside the local day, on a
  day already settled, on a commitment that is archived or already decided, and -- for a refusal
  only -- on one carrying no penalty that day, on either quota cadence, and on a commitment-day
  with no photograph. Freezes carries_penalty and cadence onto the row. Takes no advisory lock: the
  unique constraint plus `on conflict do nothing` serialises two decisions on one commitment-day.
  A refusal enqueues exactly one push to the author, keyed refusal-<decision id>, built by
  refusal_payload(); an approval enqueues nothing.';
