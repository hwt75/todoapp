-- Story 8.2 — the referee's decision, and what a refusal costs.
--
-- The mechanism's whole force is the refusal, and the property that makes it affordable is a
-- negative: **a day nobody decided must settle identically to the unflagged case**, chain and
-- penalty included. That is Step 6 here, asserted field by field against a twin on the same
-- account rather than assumed, and it is also what the rest of this directory proves by passing
-- unmodified — the regression that matters is the one nobody had to write, the precedent
-- `6-8-a-photo-i-can-keep-against-any-commitment.sql:16-22` set.
--
-- Precisely: 47 `.sql` files here, 46 of them pre-existing, and Story 8.2 modified exactly one of
-- those — `2-1-roles-and-rls.sql`, whose must-be-revoked array gained `effective_answer()`. The
-- other 45 run untouched against a settlement path that has been re-declared four times over.
-- `README.md` is documentation, is modified too, and is not one of the 47.
--
-- Everything else asserted here is either one row of the story's own I/O matrix, pinned against
-- the sentence that produces it, or one of the properties the design rests on:
--
--   1. **Silence approves.** Step 6, and Step 7's planted decision row on a commitment that never
--      asked for a signature — the settlement arm reads the flag through
--      requires_referee_approval_as_of() and ignores a row it does not cover.
--   2. **A refusal survives everything the author can still do to the commitment that day.**
--      Step 11: archive, the money switched off, the cadence moved to *either* quota, and the flag
--      itself switched off — each after the refusal and before midnight, and each one used to void
--      it outright.
--   3. **A refusal is not the author's answer.** Step 13: `answer` still reads null on a day he
--      said nothing on, so the silence intervention's own arithmetic still calls that day quiet
--      and `commitment_answer_rate_for_month()` still counts zero answers.
--   4. **One mechanism per job.** Step 14: object_to_day() refuses a commitment that asked for the
--      signature on the day itself, read as of the day it names rather than live — and still
--      accepts an unflagged one, so the guard closes one door and not the path.
--   5. **A decision is final and nobody may write one but the RPC.** Step 16.
--
--   docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql
--
-- One transaction, rolled back at the end. Nothing persists.
--
-- It needs a database with **no live doer account**: `settle_day` raises rather than skipping when
-- `p_override` meets one (AD-16), so a single live profile would disable every settlement below.
-- Local stack or preview branch, never the author's own project. Step 0 says so rather than
-- failing somewhere confusing later.
--
-- **The order is the product's own order, and it has to be.** Every decision lands before
-- midnight (Step 2), the author's edits land after it and still before midnight (Step 3), and
-- the day is settled once, afterwards (Step 5). `sign_off_day()` refuses a day that has already
-- settled, so a file that settled first and decided afterwards would be testing that refusal and
-- nothing else.
--
-- **One account per scenario, and one referee each.** `commitments_owing()` returns every
-- commitment an account owns, so two scenarios sharing an account would share every day and
-- neither could be read on its own — the reason `6-4` and `6-7` both give. `profile.referee_of`
-- is unique per doer, so rather than repoint one referee eleven times (6-7's device, which exists
-- because that story's fixture predates the per-account model) each doer gets his own. A real
-- deployment has one pairing per account; this has eleven of them side by side.
--
-- **No `ci-clock-window` marker.** `now()` is transaction-start time and this file is one
-- transaction, so every comparison the RPC and the settlement make is against the same instant
-- this file computed `v_today` from. A run that begins at 23:59:59 cannot cross midnight
-- mid-assertion, because there is only ever one `now()`.
--
-- **The fixture trap, and it is silent.** `settle_day()` skips a whole day if any owed commitment
-- still has `answer is null` before its own deadline (20260829090000:472-476), and an untimed
-- commitment's deadline is the next morning. Every commitment on an account whose day is asserted
-- below therefore carries either a declaration or a refusal — otherwise the step would assert
-- against a day that never settled and pass for the wrong reason. The clock is never moved.

begin;

-- The local stack's default privileges differ from the author's own project (recorded at length
-- in `2-1-roles-and-rls.sql`'s own header). `sign_off_day` and `object_to_day` carry their own
-- EXECUTE grants in their migrations and need nothing here; the ordinary table reads and the
-- client-side inserts this fixture drives through RLS still do.
grant select on table public.profile, public.commitment, public.settlement, public.penalty,
                    public.settlement_commitment, public.referee_decision, public.chain_current
  to authenticated;
grant select, insert on table public.grace_day to authenticated;

-- Deliberately wider than the migration: Step 16 drives the append-only claim from a client
-- session that holds `insert`, `update` and `delete` on the table, so what refuses it is RLS
-- having no policy for those commands rather than a privilege the client never had. Without this
-- the step would pass against a table with a wide-open insert policy.
grant insert, update, delete on table public.referee_decision to authenticated;

-- The bucket the fixture's photographs belong to. It is `config.toml` configuration created by
-- the CLI through the storage API, not by a migration, so a database started with `-x storage-api`
-- -- which is how CI starts it -- has the schema but not the row. Staged here so the file runs
-- against any database, and it rolls back with everything else.
insert into storage.buckets (id, name)
values ('appeal-evidence', 'appeal-evidence')
on conflict (id) do nothing;


-- =================================================================================
-- Step 0b: the one grant this migration makes, asserted rather than re-issued.
--
-- The whole file runs as `postgres`, which may execute anything, so every sign_off_day() call
-- below would pass with the grant lost and the feature dead in production. Granting it here would
-- paper over exactly that, which is why this only asks. The idiom is
-- 8-1-a-commitment-can-ask-for-the-referee-s-signature.sql:31-53's.
-- =================================================================================
do $$
begin
  if not has_function_privilege(
       'authenticated', 'public.sign_off_day(uuid, date, boolean, text)', 'execute') then
    raise exception using message =
      '`authenticated` cannot EXECUTE public.sign_off_day(uuid, date, boolean, text). It is the '
      'one door a referee session has to this story, and without it every decision fails at the '
      'API with a permission error while this file stays green -- re-granting it here would hide '
      'precisely that breakage.';
  end if;

  -- The other direction, because `drop function` destroys the ACL and a bare `create` in `public`
  -- hands EXECUTE straight back to PUBLIC, `anon` included.
  if has_function_privilege(
       'anon', 'public.sign_off_day(uuid, date, boolean, text)', 'execute') then
    raise exception using message =
      '`anon` can EXECUTE public.sign_off_day(). It decides money on somebody else''s account; a '
      'signed-out caller has no business reaching /rest/v1/rpc/sign_off_day at all.';
  end if;

  raise notice using message =
    'Precondition ok: sign_off_day() is executable by `authenticated` and not by `anon`, and '
    'nothing is granted to either by this file.';
end;
$$;


do $$
declare
  -- One doer per scenario, and one referee paired to each.
  v_a  uuid := gen_random_uuid(); -- nobody decides: the baseline the whole story rests on
  v_b  uuid := gen_random_uuid(); -- an approval, which must change nothing at all
  v_c  uuid := gen_random_uuid(); -- a refusal on a timed commitment, and the Grace Day after it
  v_d  uuid := gen_random_uuid(); -- a refusal on an untimed one the author never answered
  v_e  uuid := gen_random_uuid(); -- archived after the refusal
  v_f  uuid := gen_random_uuid(); -- the money switched off after the refusal
  v_g  uuid := gen_random_uuid(); -- cadence moved to weekly_quota after the refusal
  v_h  uuid := gen_random_uuid(); -- cadence moved to daily_hours_quota after the refusal
  v_i  uuid := gen_random_uuid(); -- the flag switched off after the refusal
  v_j  uuid := gen_random_uuid(); -- the 48-hour objection, refused on a flagged commitment
  v_k  uuid := gen_random_uuid(); -- the RPC's own refusal list, nothing settled
  v_l  uuid := gen_random_uuid(); -- an expired day corrected later: the refused one HAS a claim
  v_m  uuid := gen_random_uuid(); -- the same, and the refused one has no claim at all
  v_n  uuid := gen_random_uuid(); -- an Auto-check attached after the refusal: the sixth escape
  v_o  uuid := gen_random_uuid(); -- what the evening summary says to start with tomorrow

  v_ra uuid := gen_random_uuid();
  v_rb uuid := gen_random_uuid();
  v_rc uuid := gen_random_uuid();
  v_rd uuid := gen_random_uuid();
  v_re uuid := gen_random_uuid();
  v_rf uuid := gen_random_uuid();
  v_rg uuid := gen_random_uuid();
  v_rh uuid := gen_random_uuid();
  v_ri uuid := gen_random_uuid();
  v_rj uuid := gen_random_uuid();
  v_rk uuid := gen_random_uuid();
  v_rl uuid := gen_random_uuid();
  v_rm uuid := gen_random_uuid();
  v_rn uuid := gen_random_uuid();
  v_ro uuid := gen_random_uuid();
  -- A referee with a role and no pairing at all. Not the same thing as a doer, and refused for a
  -- reason of its own.
  v_rnone uuid := gen_random_uuid();

  v_a_flag  uuid; -- flagged, timed, photo-proven
  v_a_twin  uuid; -- its unflagged twin, identical in every other respect
  v_a_never uuid; -- unflagged, and carries a decision row planted behind the RPC's back
  v_b_flag  uuid;
  v_b_twin  uuid;
  v_c_flag  uuid; -- refused
  v_c_twin  uuid; -- must settle exactly as it would have
  v_d_flag  uuid; -- untimed, commitment-day photograph, never answered
  v_e_flag  uuid;
  v_f_flag  uuid;
  v_g_flag  uuid; -- TIMED and unclaimed on purpose: the weekly_quota `where` predicate
  v_h_flag  uuid;
  v_i_flag  uuid;
  v_j_flag  uuid; -- flagged as of yesterday, switched off today
  v_k_plain uuid; -- never flagged
  v_k_free  uuid; -- flagged, carries no penalty
  v_k_week  uuid; -- flagged, weekly_quota
  v_k_hours uuid; -- flagged, daily_hours_quota
  v_k_proof uuid; -- flagged, and no photograph on the day
  v_k_arch  uuid; -- flagged, photographed, then archived at 08:00
  v_k_twice uuid; -- flagged, photographed, decided once
  v_l_flag  uuid; -- refused, and the author DID answer it in time
  v_l_late  uuid; -- unanswered at midnight: what makes the day expire
  v_m_flag  uuid; -- refused, and never answered at all
  v_m_late  uuid;
  v_n_flag  uuid; -- refused, un-flagged, then given an Auto-check
  v_n_mate  uuid; -- the commitment whose day the escape would have held open
  v_o_old   uuid; -- held, and created FIRST: what the suggestion falls back to
  v_o_flag  uuid; -- refused, created second

  v_today     date := (now() at time zone 'Asia/Ho_Chi_Minh')::date;
  v_yesterday date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1;
  v_tomorrow  date := (now() at time zone 'Asia/Ho_Chi_Minh')::date + 1;
  -- The expired day Step 16b corrects. Four days back so that an untimed commitment's own
  -- deadline -- the morning hour on D + 3, which is yesterday morning -- has certainly passed at
  -- every hour this file could run at. Nothing here is compared against the wall clock beyond
  -- that, and `now()` is transaction-stable, so there is still no window to declare.
  v_dexp      date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 4;

  v_claim   uuid;
  v_s       uuid;
  v_row     record;

  -- Observed
  v_verdict  public.day_verdict;
  v_outcome  public.commitment_outcome;
  v_outcome2 public.commitment_outcome;
  v_state    public.penalty_state;
  v_count    integer;
  v_missed   integer;
  v_current  integer;
  v_longest  integer;
  v_current2 integer;
  v_longest2 integer;
  v_refused  boolean;
  v_flag     boolean;
  v_message  text;
  v_uuid     uuid;
  v_answer   public.declaration_answer;
  v_total    integer;
  v_answered integer;
  v_body     text;
  v_outbox   integer;
begin
  -- =================================================================================
  -- Step 0: the live-doer preflight. Every settlement below is an override.
  -- =================================================================================
  if exists (select 1 from public.profile where is_live_doer) then
    raise exception using message =
      'This database has a live doer account, so settle_day refuses every override (AD-16). '
      'Run against a local or branch database instead.';
  end if;

  -- =================================================================================
  -- Step 1: the fixture. Eleven accounts, eleven pairings, one unpaired referee.
  -- =================================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'story-8-2-' || id::text || '@example.test',
         'not-a-real-password-this-account-never-signs-in',
         now(), now(), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
    from unnest(array[v_a, v_b, v_c, v_d, v_e, v_f, v_g, v_h, v_i, v_j, v_k, v_l, v_m, v_n, v_o,
                      v_ra, v_rb, v_rc, v_rd, v_re, v_rf, v_rg, v_rh, v_ri, v_rj, v_rk,
                      v_rl, v_rm, v_rn, v_ro, v_rnone]) as t(id);

  -- `referee_of` lives on the *referee's* row and points at the doer (20260907160000:29). The
  -- pairing has to exist before any flagged commitment is written, because
  -- commitment_sign_off_needs_a_referee() fires at write time (20260911090000:263).
  update public.profile set role = 'referee', referee_of = v_a where id = v_ra;
  update public.profile set role = 'referee', referee_of = v_b where id = v_rb;
  update public.profile set role = 'referee', referee_of = v_c where id = v_rc;
  update public.profile set role = 'referee', referee_of = v_d where id = v_rd;
  update public.profile set role = 'referee', referee_of = v_e where id = v_re;
  update public.profile set role = 'referee', referee_of = v_f where id = v_rf;
  update public.profile set role = 'referee', referee_of = v_g where id = v_rg;
  update public.profile set role = 'referee', referee_of = v_h where id = v_rh;
  update public.profile set role = 'referee', referee_of = v_i where id = v_ri;
  update public.profile set role = 'referee', referee_of = v_j where id = v_rj;
  update public.profile set role = 'referee', referee_of = v_k where id = v_rk;
  update public.profile set role = 'referee', referee_of = v_l where id = v_rl;
  update public.profile set role = 'referee', referee_of = v_m where id = v_rm;
  update public.profile set role = 'referee', referee_of = v_n where id = v_rn;
  update public.profile set role = 'referee', referee_of = v_o where id = v_ro;
  -- Role, and no pairing. The whole of his case.
  update public.profile set role = 'referee' where id = v_rnone;

  -- Accounts A, B and C: a flagged commitment and an unflagged twin that differs from it in
  -- exactly one column. A's third commitment is the one a decision row is planted on.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill (signed off)', 'do', 'daily', true, true, true,
          time '10:00', 30)
  returning id into v_a_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill (twin)', 'do', 'daily', true, true, false,
          time '10:00', 30)
  returning id into v_a_twin;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_a, gen_random_uuid(), 'Pill (never asked)', 'do', 'daily', true, true, false,
          time '10:00', 30)
  returning id into v_a_never;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Pill (signed off)', 'do', 'daily', true, true, true,
          time '10:00', 30)
  returning id into v_b_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_b, gen_random_uuid(), 'Pill (twin)', 'do', 'daily', true, true, false,
          time '10:00', 30)
  returning id into v_b_twin;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_c, gen_random_uuid(), 'Pill (signed off)', 'do', 'daily', true, true, true,
          time '10:00', 30)
  returning id into v_c_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_c, gen_random_uuid(), 'Pill (twin)', 'do', 'daily', true, true, false,
          time '10:00', 30)
  returning id into v_c_twin;

  -- The untimed shapes. A commitment with no due_time proves itself with the commitment-day
  -- photograph of Story 6.8 rather than a claim's (SPEC.md's own assumption), and the referee
  -- necessarily decides before the author is ever asked -- the morning question for today is
  -- asked tomorrow. That is frozen decision 4, as a fixture.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_d, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_d_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_e, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_e_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_f, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_f_flag;

  -- Timed, and deliberately never claimed. `commitments_owing()`'s last `where` predicate drops a
  -- timed weekly_quota commitment on a day it was not claimed, so this is the shape that makes
  -- the cadence edit bite: freeze the cadence in the select list alone and this row disappears
  -- from the day entirely.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 due_time, late_window_minutes)
  values (v_g, gen_random_uuid(), 'Pill (signed off)', 'do', 'daily', true, true, true,
          time '10:00', 30)
  returning id into v_g_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_h, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_h_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_i, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_i_flag;

  -- Account I is the flag switched off after the refusal, and it has to prove the *historical*
  -- read rather than the backward extrapolation a commitment created today would fall into. So
  -- this one predates today and its flag entry predates today with it: after the switch-off
  -- below, requires_referee_approval_as_of(v_i_flag, today) takes the day-start branch and finds
  -- the entry that governed the whole of today, while the live column says false.
  update public.commitment set created_at = now() - interval '90 days' where id = v_i_flag;
  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_today) - interval '10 days'
   where commitment_id = v_i_flag;

  -- Account F is the money switched off after the refusal, and its log needs care for a
  -- different reason: `commitment_carries_penalty_change.changed_at` defaults
  -- to `now()`, which is transaction-stable, so the creation entry and the 22:00 entry would tie
  -- inside this one transaction and the reader would break that tie arbitrarily -- and the steps
  -- would pass whether or not the frozen value is what settlement reads. Two real requests never
  -- share one now(). The idiom is carries_penalty_freezes_by_day.sql:81-100's.
  update public.commitment_carries_penalty_change
     set changed_at = public.day_begins_at(v_today) - interval '1 day'
   where commitment_id = v_f_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_j, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_j_flag;

  -- Account K's seven, one per refusal the RPC makes. Nothing on this account ever settles: the
  -- deadline gate holds its day open on the commitments nobody ever answers, which is what keeps
  -- the refusals below reaching the check each one is about.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_k, gen_random_uuid(), 'Never asked', 'do', 'daily', true)
  returning id into v_k_plain;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_k, gen_random_uuid(), 'No money on it', 'do', 'daily', false, true, true)
  returning id into v_k_free;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 weekly_target, week_start_day)
  values (v_k, gen_random_uuid(), 'Weekly quota', 'do', 'weekly_quota', true, true, true, 3, 1)
  returning id into v_k_week;

  -- `do` + `daily_hours_quota` + the flag: saveable, and inert, which is exactly what Story 8.1's
  -- deferred entry left open. The RPC is what closes the half of it that matters.
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval,
                                 daily_minutes_target)
  values (v_k, gen_random_uuid(), 'Hours quota', 'do', 'daily_hours_quota', true, true, true, 60)
  returning id into v_k_hours;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_k, gen_random_uuid(), 'Nothing to look at', 'do', 'daily', true, true, true)
  returning id into v_k_proof;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_k, gen_random_uuid(), 'Retired this morning', 'do', 'daily', true, true, true)
  returning id into v_k_arch;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_k, gen_random_uuid(), 'Decided once', 'do', 'daily', true, true, true)
  returning id into v_k_twice;

  -- The same now()-tie care account F needs, and for the same reason: Step 15 turns this
  -- commitment's money off to prove that a repeat gets the repeat's sentence whatever the author
  -- has done since. Written here rather than beside account F's because v_k_twice does not exist
  -- until this line -- an `in (v_f_flag, v_k_twice)` up there silently matched nothing, and the
  -- ordering assertion passed for three runs without the edit it is about ever happening.
  update public.commitment_carries_penalty_change
     set changed_at = public.day_begins_at(v_today) - interval '1 day'
   where commitment_id = v_k_twice;

  -- --------------------------------------------------------------------------------
  -- Accounts L and M: the expired day that is corrected afterwards (Step 16b).
  --
  -- Two commitments each. The flagged one is refused; the other is what makes the day expire, by
  -- being unanswered at midnight and past its own deadline, and is then answered by a declaration
  -- that was made in time and merely delivered late -- Story 2.7's whole subject.
  --
  -- They differ in one thing only, and it is the thing that separates the two reads this step
  -- exists for: **account L's refused commitment carries a claim of its own and account M's
  -- carries none.** L catches the `admitted` filter and the outcome mapping; M is the only one
  -- that catches `timely`, because a refused commitment with no declaration is what makes
  -- `timely < total` true forever and strands the day in `expired`.
  -- --------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_l, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_l_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_l, gen_random_uuid(), 'Read (answered offline)', 'do', 'daily', true)
  returning id into v_l_late;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_m, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_m_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_m, gen_random_uuid(), 'Read (answered offline)', 'do', 'daily', true)
  returning id into v_m_late;

  update public.commitment set created_at = now() - interval '90 days'
   where id in (v_l_flag, v_l_late, v_m_flag, v_m_late);

  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_dexp) - interval '10 days'
   where commitment_id in (v_l_flag, v_m_flag);

  -- --------------------------------------------------------------------------------
  -- Account N: the sixth escape, and the only one that costs somebody else the day.
  --
  -- `commitment_sign_off_not_with_auto_check` (20260911090000:68-70) is a CHECK on the LIVE row,
  -- and `commitment: edit own` is unrestricted. So the author can un-flag the commitment at 22:00
  -- -- which does not un-refuse the day, because the lateral reads the `_as_of()` door -- and then
  -- attach an Auto-check the CHECK now permits. auto_check_pending() reads true (there is no
  -- declaration; an untimed commitment's author is not asked until the next morning) and
  -- settle_day()'s AD-13 gate would hold the WHOLE ACCOUNT'S day for up to 96 hours.
  --
  -- `v_n_mate` exists to make that collateral damage visible: it is a perfectly ordinary
  -- commitment the author answered, and the escape takes its day away too.
  -- --------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_n, gen_random_uuid(), 'Gym (signed off)', 'do', 'daily', true, true, true)
  returning id into v_n_flag;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_n, gen_random_uuid(), 'Vitamin', 'do', 'daily', true)
  returning id into v_n_mate;

  -- --------------------------------------------------------------------------------
  -- Account O: what the author is told that evening.
  --
  -- Two held claims and a refusal, with the HELD one created first. That ordering is the whole
  -- point: settle_day()'s suggestion query is `order by (answer = 'slipped') desc, created_at`,
  -- so read through the author's own answer both commitments tie at false and the oldest wins,
  -- while read through the referee's decision the refused one sorts first. Account C pins the
  -- survivor clause and needs the opposite ordering; one account cannot do both.
  -- --------------------------------------------------------------------------------
  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence, carries_penalty)
  values (v_o, gen_random_uuid(), 'Đọc sách', 'do', 'daily', true)
  returning id into v_o_old;

  insert into public.commitment (owner_id, idempotency_key, name, kind, cadence,
                                 carries_penalty, requires_photo, requires_referee_approval)
  values (v_o, gen_random_uuid(), 'Chạy bộ (signed off)', 'do', 'daily', true, true, true)
  returning id into v_o_flag;

  -- Account J's commitment is judged on yesterday, so it has to predate it. Its flag log is
  -- backdated with it -- without that, requires_referee_approval_as_of(v_j_flag, yesterday) would
  -- fall to the backward extrapolation and the day-start branch Step 14 is about would never be
  -- exercised.
  update public.commitment set created_at = now() - interval '90 days' where id = v_j_flag;
  update public.commitment_requires_referee_approval_change
     set changed_at = public.day_begins_at(v_yesterday) - interval '10 days'
   where commitment_id = v_j_flag;

  -- --------------------------------------------------------------------------------
  -- The claims and the photographs.
  --
  -- Inserted as `postgres`, which takes declaration_derive_day()'s non-doer branch and lands the
  -- claim on the local day before `answered_at` -- so 08:00 tomorrow files today. The device
  -- `6-7` already uses, with today in place of a past day. The evidence trigger is left ON:
  -- neither of its midnight rules refuses a photograph for a day that is still running, which is
  -- the whole point of a decision that lands before midnight.
  -- --------------------------------------------------------------------------------
  for v_row in
    select * from (values
      (v_a, v_a_flag), (v_a, v_a_twin), (v_a, v_a_never),
      (v_b, v_b_flag), (v_b, v_b_twin),
      (v_c, v_c_flag), (v_c, v_c_twin)
    ) as t(owner_id, commitment_id)
  loop
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_row.owner_id, v_row.commitment_id, gen_random_uuid(), 'held',
            ((v_today + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh')
    returning id into v_claim;

    -- The photograph, uploaded before the row that points at it: evidence_object_must_exist()
    -- (20260910090000) refuses a storage_path naming no object.
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_claim::text || '/pill.jpg', v_row.owner_id);

    insert into public.evidence (declaration_id, owner_id, storage_path, captured_on)
    values (v_claim, v_row.owner_id, v_claim::text || '/pill.jpg', v_today);
  end loop;

  -- The commitment-day photographs: the other parentage, and the one an untimed flagged
  -- commitment proves itself with (20260903120000:51-53). `sign_off_day()` counts both arms, and
  -- both are exercised here rather than one -- account C is refused on a claim's photograph and
  -- account D on a commitment-day one.
  for v_row in
    select * from (values
      (v_d, v_d_flag), (v_e, v_e_flag), (v_f, v_f_flag), (v_g, v_g_flag),
      (v_h, v_h_flag), (v_i, v_i_flag),
      (v_k, v_k_arch), (v_k, v_k_twice),
      (v_n, v_n_flag), (v_o, v_o_flag)
    ) as t(owner_id, commitment_id)
  loop
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence', v_row.commitment_id::text || '/' || v_today::text || '.jpg',
            v_row.owner_id);

    insert into public.evidence (commitment_id, for_day, owner_id, storage_path, captured_on)
    values (v_row.commitment_id, v_today, v_row.owner_id,
            v_row.commitment_id::text || '/' || v_today::text || '.jpg', v_today);
  end loop;

  -- Account K's archived commitment retires at 08:00, before any referee looks at it. Written
  -- after its photograph, because evidence_derive_owner() would refuse a photo on a commitment
  -- whose day has been left behind.
  update public.commitment set archived_at = public.day_begins_at(v_today) + interval '8 hours'
   where id = v_k_arch;

  -- Account J's own day: the morning question for yesterday, answered this morning.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_j, v_j_flag, gen_random_uuid(), 'held',
          ((v_yesterday + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  -- Account N's ordinary commitment and both of account O's answer today's question. Untimed, so
  -- they go through the same postgres path: 08:00 tomorrow files today.
  for v_row in
    select * from (values
      (v_n, v_n_mate), (v_o, v_o_old), (v_o, v_o_flag)
    ) as t(owner_id, commitment_id)
  loop
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_row.owner_id, v_row.commitment_id, gen_random_uuid(), 'held',
            ((v_today + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');
  end loop;

  -- Account L's refused commitment answered its own day in time, the morning after. Account M's
  -- deliberately answers nothing at all, ever -- that is the whole difference between them.
  insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
  values (v_l, v_l_flag, gen_random_uuid(), 'held',
          ((v_dexp + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');

  raise notice using message =
    'Fixture ok: eleven accounts, eleven pairings, one unpaired referee, and not one decision '
    'row yet.';

  -- =================================================================================
  -- Step 2: the decisions, all before midnight and all before anything settles.
  -- =================================================================================
  -- sign_off_day()'s comment ends "Enqueues nothing -- telling the author is Story 8.5", and that
  -- split is a frozen decision: folding the notification in is the merge that produced Epic 6's
  -- 1,579-line single-block test file. A stray outbox_enqueue() added later would ship green
  -- against a file that never mentions the table, so the whole queue is counted across the nine
  -- decisions below rather than a dedupe-key prefix guessed in advance.
  select count(*) into v_outbox from public.outbox;

  perform set_config('role', 'authenticated', true);

  -- The approval, which must change nothing at all.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rb, 'role', 'authenticated', 'app_role', 'referee')::text, true);
  perform public.sign_off_day(v_b_flag, v_today, true);

  -- The refusal on a timed commitment, against the claim-parented photograph.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rc, 'role', 'authenticated', 'app_role', 'referee')::text, true);
  perform public.sign_off_day(v_c_flag, v_today, false, 'The photograph is of yesterday''s pill.');

  -- The refusal on an untimed commitment, against the commitment-day photograph, on a day the
  -- author has not been asked about yet and will not be until tomorrow morning.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rd, 'role', 'authenticated', 'app_role', 'referee')::text, true);
  perform public.sign_off_day(v_d_flag, v_today, false, 'That is the car park, not the gym.');

  -- The five that the author then tries to undo.
  for v_row in
    select * from (values
      (v_re, v_e_flag), (v_rf, v_f_flag), (v_rg, v_g_flag), (v_rh, v_h_flag), (v_ri, v_i_flag),
      (v_rn, v_n_flag), (v_ro, v_o_flag)
    ) as t(referee, commitment_id)
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_row.referee, 'role', 'authenticated',
                        'app_role', 'referee')::text, true);
    perform public.sign_off_day(v_row.commitment_id, v_today, false,
                                'Refused at 21:00, before he touched anything.');
  end loop;

  -- And account K's one real decision, which Step 15 then tries to make a second time.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rk, 'role', 'authenticated', 'app_role', 'referee')::text, true);
  perform public.sign_off_day(v_k_twice, v_today, false, 'The photograph shows the wrong day.');

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  select count(*) into v_count from public.referee_decision;
  if v_count <> 11 then
    raise exception using message = format(
      'The fixture wrote %s decision rows, expected 11.', v_count);
  end if;

  select count(*) - v_outbox into v_count from public.outbox;
  if v_count <> 0 then
    raise exception using message = format(
      'Eleven decisions enqueued %s outbox row(s), expected 0. sign_off_day() tells the author '
      'nothing -- that is Story 8.5, split out on purpose -- and its own comment says so.',
      v_count);
  end if;

  raise notice using message =
    'Step 2 ok: eleven decisions, one approval and ten refusals, every one of them before its '
    'day closed, and not one outbox row between them.';

  -- =================================================================================
  -- Step 3: the four edits `commitment: edit own` permits between a refusal and midnight, and
  -- the flag itself switched off. Each one voided a refusal outright at some point in this
  -- story's review; each is made here in the order that used to lose.
  --
  -- Every `update public.commitment` is scoped by id. An unscoped one would rewrite the whole
  -- fixture and every assertion after it would be measuring something else.
  -- =================================================================================
  update public.commitment set archived_at = now() where id = v_e_flag;
  update public.commitment set carries_penalty = false where id = v_f_flag;
  update public.commitment
     set cadence = 'weekly_quota', weekly_target = 3, week_start_day = 1
   where id = v_g_flag;
  update public.commitment
     set cadence = 'daily_hours_quota', daily_minutes_target = 60
   where id = v_h_flag;
  update public.commitment set requires_referee_approval = false where id = v_i_flag;

  -- The sixth, and the only one that costs another commitment its day. Two statements, in the
  -- order the author would have to make them: commitment_sign_off_not_with_auto_check is a CHECK
  -- on the live row, so the flag comes off first and the Auto-check goes on afterwards. Nothing
  -- in the schema refuses either step.
  update public.commitment set requires_referee_approval = false where id = v_n_flag;
  update public.commitment
     set auto_check_kind = 'account_elsewhere', auto_check_account_ref = 'story-8-2-n'
   where id = v_n_flag;

  -- Said out loud, so the step below cannot pass because the escape was never armed.
  if not public.auto_check_pending(v_n_flag, v_today) then
    raise exception using message =
      'The fixture is wrong: auto_check_pending() reads false for account N''s commitment, so '
      'the AD-13 gate would not have fired even with the bug. Step 11''s sixth row would pass '
      'without proving anything.';
  end if;

  -- =================================================================================
  -- Step 4: a decision row naming a day the flag was off, planted behind the RPC's back.
  --
  -- The second half of the matrix's "Flag off as of that day" row. Step 15 asserts the RPC
  -- refuses to write one; this asserts that if one somehow existed the settlement arm would
  -- ignore it, because the lateral reads the flag through requires_referee_approval_as_of().
  -- =================================================================================
  insert into public.referee_decision
    (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
  values (v_a, v_ra, v_today, v_a_never, false, 'Planted behind the RPC''s back.', true, 'daily');

  -- =================================================================================
  -- Step 5: midnight. Yesterday for account J, today for everyone else.
  -- =================================================================================
  perform public.settle_day(v_yesterday, true);
  perform public.settle_day(v_today, true);

  -- =================================================================================
  -- Step 6: silence approves, asserted field by field against an unflagged twin.
  --
  -- The assertion this story exists to make, and the one it would be cheapest to assume. Account
  -- A's two commitments differ in exactly one column. Nobody decided either. If they settle
  -- differently in any respect, the mechanism has cost the author something his friend never did.
  -- =================================================================================
  select id, verdict, missed_count into v_s, v_verdict, v_missed
    from public.settlement
   where subject = v_a and period = v_today and kind = 'day' and supersedes is null;

  if v_s is null then
    raise exception using message =
      'Account A''s day did not settle at all. Every commitment on it carries a declaration and a '
      'photograph, so this is the fixture trap the header names rather than a finding about the '
      'feature.';
  end if;

  if v_verdict <> 'clean' or v_missed <> 0 then
    raise exception using message = format(
      'Account A''s day reads `%s` with missed_count %s, expected `clean` / 0 -- a flagged '
      'commitment with a photograph and no decision holds exactly as an unflagged one does.',
      v_verdict, v_missed);
  end if;

  select count(*) into v_count from public.penalty_current
   where subject = v_a and period = v_today and kind = 'day';
  if v_count <> 0 then
    raise exception using message = format(
      'Account A''s silent day carries %s penalty row(s), expected 0.', v_count);
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_a_flag;
  select outcome into v_outcome2 from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_a_twin;

  if v_outcome is distinct from 'held' or v_outcome2 is distinct from 'held'
     or v_outcome is distinct from v_outcome2 then
    raise exception using message = format(
      'Account A''s flagged commitment froze `%s` and its unflagged twin froze `%s`. They must '
      'be the same, and both `held`.', coalesce(v_outcome::text, '<null>'),
      coalesce(v_outcome2::text, '<null>'));
  end if;

  select current_days, longest_days into v_current, v_longest
    from public.chain_current where commitment_id = v_a_flag;
  select current_days, longest_days into v_current2, v_longest2
    from public.chain_current where commitment_id = v_a_twin;

  if v_current is distinct from v_current2 or v_longest is distinct from v_longest2
     or v_current is distinct from 1 then
    raise exception using message = format(
      'Account A''s chains read %s/%s (flagged) and %s/%s (twin), expected 1/1 and identical.',
      v_current, v_longest, v_current2, v_longest2);
  end if;

  -- And `answer` still says what the author said, on a day nobody decided.
  select o.refused, o.answer into v_refused, v_answer
    from public.commitments_owing(v_a, v_today) o where o.commitment_id = v_a_flag;
  if v_refused is distinct from false or v_answer is distinct from 'held' then
    raise exception using message = format(
      'commitments_owing() reads refused=%s answer=%s for a flagged commitment nobody decided, '
      'expected false/held.', v_refused, coalesce(v_answer::text, '<null>'));
  end if;

  raise notice using message =
    'Step 6 ok: with no decision at all, a flagged commitment and its unflagged twin settle to '
    'the same verdict, the same frozen outcome, the same (absent) penalty and the same chain.';

  -- =================================================================================
  -- Step 7: the planted decision row changed nothing.
  -- =================================================================================
  select o.refused into v_refused
    from public.commitments_owing(v_a, v_today) o where o.commitment_id = v_a_never;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_a_never;

  if v_refused is distinct from false or v_outcome is distinct from 'held' then
    raise exception using message = format(
      'A decision row on a commitment that never asked for a signature read refused=%s and froze '
      '`%s`. The settlement arm must ignore it entirely -- the flag is what says whose day this '
      'mechanism reaches.', v_refused, coalesce(v_outcome::text, '<null>'));
  end if;

  raise notice using message =
    'Step 7 ok: a decision row on an unflagged commitment changes nothing -- the arm reads the '
    'flag, not the row.';

  -- =================================================================================
  -- Step 8: an approval changes nothing, and is on the record.
  -- =================================================================================
  select id, verdict, missed_count into v_s, v_verdict, v_missed
    from public.settlement
   where subject = v_b and period = v_today and kind = 'day' and supersedes is null;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_b_flag;
  select outcome into v_outcome2 from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_b_twin;

  select count(*) into v_count from public.penalty_current
   where subject = v_b and period = v_today and kind = 'day';

  if v_verdict <> 'clean' or v_missed <> 0 or v_count <> 0
     or v_outcome is distinct from 'held' or v_outcome2 is distinct from 'held' then
    raise exception using message = format(
      'Account B''s approved day reads `%s` / missed %s / %s penalties, with outcomes `%s` and '
      '`%s`. An approval changes no outcome: silence already approved it.',
      v_verdict, v_missed, v_count, coalesce(v_outcome::text, '<null>'),
      coalesce(v_outcome2::text, '<null>'));
  end if;

  select current_days into v_current from public.chain_current where commitment_id = v_b_flag;
  if v_current is distinct from 1 then
    raise exception using message = format(
      'Account B''s approved commitment reads a chain of %s, expected 1.',
      coalesce(v_current, 0));
  end if;

  select o.refused into v_refused
    from public.commitments_owing(v_b, v_today) o where o.commitment_id = v_b_flag;
  if v_refused is distinct from false then
    raise exception using message = format(
      'commitments_owing() reads refused=%s for an APPROVED commitment-day. Only a refusal may '
      'match the lateral -- an approval that reached it would fail the day the referee blessed.',
      v_refused);
  end if;

  select approved, reason into v_flag, v_message
    from public.referee_decision
   where subject = v_b and for_day = v_today and commitment_id = v_b_flag;
  if v_flag is distinct from true or v_message is not null then
    raise exception using message = format(
      'The approval row reads approved=%s reason=%s, expected true and null.',
      v_flag, coalesce(v_message, '<null>'));
  end if;

  raise notice using message =
    'Step 8 ok: an approval is recorded, carries no reason, and changes not one byte of the '
    'settlement.';

  -- =================================================================================
  -- Step 9: a refusal on a timed commitment, and a Grace Day still reaches it.
  -- =================================================================================
  select id, verdict, missed_count into v_s, v_verdict, v_missed
    from public.settlement
   where subject = v_c and period = v_today and kind = 'day' and supersedes is null;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_c_flag;
  select outcome into v_outcome2 from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_c_twin;

  if v_verdict <> 'failed' or v_outcome is distinct from 'missed'
     or v_outcome2 is distinct from 'held' then
    raise exception using message = format(
      'The refused timed day reads `%s`, refused commitment `%s`, the other commitment `%s`. '
      'Expected `failed` / `missed` / `held` -- every other commitment on the day settles as it '
      'would have.', v_verdict, coalesce(v_outcome::text, '<null>'),
      coalesce(v_outcome2::text, '<null>'));
  end if;

  if v_missed <> 1 then
    raise exception using message = format(
      'The refused day reads missed_count %s, expected exactly 1. A refused commitment the author '
      'never answered must not be counted once as admitted and once as silent.', v_missed);
  end if;

  select count(*), min(state) into v_count, v_state from public.penalty_current
   where subject = v_c and period = v_today and kind = 'day';
  if v_count <> 1 or v_state <> 'owed' then
    raise exception using message = format(
      'The refused day carries %s live penalty row(s) reading `%s`, expected exactly 1 `owed`.',
      v_count, coalesce(v_state::text, '<null>'));
  end if;

  -- The chain, which is what the mechanism is actually for. The refused commitment's breaks; the
  -- one beside it does not.
  select current_days into v_current from public.chain_current where commitment_id = v_c_flag;
  select current_days into v_current2 from public.chain_current where commitment_id = v_c_twin;
  if coalesce(v_current, 0) <> 0 or v_current2 is distinct from 1 then
    raise exception using message = format(
      'After the refusal the chains read %s (refused) and %s (its account-mate), expected 0 and '
      '1. Breaking the refused commitment''s chain, and only that one, is the point.',
      coalesce(v_current, 0), coalesce(v_current2, 0));
  end if;

  -- And `answer` is untouched: the author said `held` and the record still says so.
  select o.refused, o.answer into v_refused, v_answer
    from public.commitments_owing(v_c, v_today) o where o.commitment_id = v_c_flag;
  if v_refused is distinct from true or v_answer is distinct from 'held' then
    raise exception using message = format(
      'commitments_owing() reads refused=%s answer=%s for the refused commitment. `answer` must '
      'still be the author''s own word -- three readers outside settlement count it.',
      v_refused, coalesce(v_answer::text, '<null>'));
  end if;

  -- What the author is actually told that evening, which is where these two reads are visible to
  -- him. settle_day() picks a survivor (`where answer = 'held'`) and a suggestion
  -- (`order by (answer = 'slipped') desc, created_at`); read through the author's own word rather
  -- than the referee's decision, the survivor clause names the very commitment that was refused.
  -- `2-8-summary-copy.sql:130-133` pins that day_summary_body() emits "<survivor> held though"
  -- whenever survivor is non-null, so this is a real push on a real evening, not an internal.
  select x.payload->>'body' into v_body from public.outbox x
   where x.dedupe_key = 'summary-' || v_c::text || '-' || v_today::text;

  if v_body is null then
    raise exception using message =
      'No summary was enqueued for the refused day. A failed day sends one -- only an expired day '
      'does not -- so the two assertions below would be vacuous.';
  end if;

  if v_body like '%Pill (signed off) held though%' then
    raise exception using message = format(
      'The evening summary names the refused commitment as the one that held: "%s". The author is '
      'charged 500,000₫ for it and told in the same sentence that it held.', v_body);
  end if;

  if v_body not like '%Pill (twin) held though%' then
    raise exception using message = format(
      'The evening summary does not name the commitment that actually held: "%s".', v_body);
  end if;

  -- A Grace Day reaches it exactly as it reaches a machine-filed miss. The author's own client
  -- insert through RLS, as components/ledger.tsx makes it.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_c, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  insert into public.grace_day (owner_id, for_day) values (v_c, v_today);

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  perform public.apply_grace_days();

  select count(*), min(state) into v_count, v_state from public.penalty_current
   where subject = v_c and period = v_today and kind = 'day';
  if v_count <> 1 or v_state <> 'waived' then
    raise exception using message = format(
      'After a Grace Day the refused day carries %s live penalty row(s) reading `%s`, expected '
      'exactly 1 `waived` -- CAP-5 says a Grace Day still reaches it.',
      v_count, coalesce(v_state::text, '<null>'));
  end if;

  -- The decision itself survives. Forgiving the money does not unsay the referee's words.
  select count(*) into v_count from public.referee_decision
   where subject = v_c and for_day = v_today and commitment_id = v_c_flag;
  if v_count <> 1 then
    raise exception using message = format(
      'Account C carries %s decision row(s) after the Grace Day, expected 1.', v_count);
  end if;

  -- And the chain comes back, which is pinned here rather than left to be discovered.
  --
  -- apply_grace_days() (20260825110000:436-438) freezes EVERY commitment on the day as `held`, as
  -- a literal, and is deliberately NOT routed through effective_answer(): it reads no answer at
  -- all, so there is nothing there to move. That is intended in both directions. A Grace Day
  -- forgives the day **whole** -- the only shape that does not vanish the day from every other
  -- commitment's chain (20260820102000's whole subject) -- and CAP-5 says a Grace Day still
  -- reaches a refused day. So spending one repairs the chain the refusal broke, which is what
  -- forgiveness means here rather than a leak in the mechanism.
  select id, verdict into v_s, v_verdict from public.settlement s
   where s.subject = v_c and s.period = v_today and s.kind = 'day'
     and not exists (select 1 from public.settlement c where c.supersedes = s.id);

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_c_flag;
  select current_days into v_current from public.chain_current where commitment_id = v_c_flag;

  if v_verdict <> 'clean' or v_outcome is distinct from 'held'
     or v_current is distinct from 1 then
    raise exception using message = format(
      'After the Grace Day the refused commitment reads verdict `%s`, outcome `%s`, chain %s. '
      'Expected `clean` / `held` / 1: a Grace Day forgives the day whole, and CAP-5 says it '
      'still reaches a refused one. If that ever has to change it is apply_grace_days() that '
      'changes, and this assertion is what will say so.',
      v_verdict, coalesce(v_outcome::text, '<null>'), coalesce(v_current, 0));
  end if;

  raise notice using message =
    'Step 9 ok: a refusal on a timed commitment freezes `missed` inside the day''s own '
    'settlement, costs one owed penalty, breaks only its own chain, leaves `answer` alone, and a '
    'Grace Day waives it exactly as it waives any other Failed Day.';

  -- =================================================================================
  -- Step 10: a refusal on an untimed commitment the author never answered.
  --
  -- Frozen decision 4: the referee's window closes at midnight and the author's own deadline for
  -- today is tomorrow morning, so he necessarily decides against a photograph rather than a
  -- claim. The day must land `failed` rather than `expired` -- `expired` is the one verdict a
  -- Grace Day cannot reach -- which is what makes the refusal count as *answered*, and the day
  -- must settle at all rather than being held open for an author who has not been asked yet.
  -- =================================================================================
  select id, verdict, missed_count into v_s, v_verdict, v_missed
    from public.settlement
   where subject = v_d and period = v_today and kind = 'day' and supersedes is null;

  if v_s is null then
    raise exception using message =
      'The untimed refused day did not settle at all. The deadline gate must not hold a day open '
      'for a commitment the referee has already decided -- an untimed one''s own deadline is the '
      'next morning, so without that the day would wait past the midnight the decision beat.';
  end if;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_d_flag;

  select count(*), min(state) into v_count, v_state from public.penalty_current
   where subject = v_d and period = v_today and kind = 'day';

  if v_verdict <> 'failed' or v_outcome is distinct from 'missed' or v_missed <> 1
     or v_count <> 1 or v_state <> 'owed' then
    raise exception using message = format(
      'The untimed refused day reads `%s` / `%s` / missed %s / %s penalty (`%s`). Expected '
      '`failed` / `missed` / 1 / 1 (`owed`) -- never `expired`, which no Grace Day can reach.',
      v_verdict, coalesce(v_outcome::text, '<null>'), v_missed, v_count,
      coalesce(v_state::text, '<null>'));
  end if;

  raise notice using message =
    'Step 10 ok: a refusal on an untimed commitment the author never answered lands `failed` '
    'with an owed penalty, reaching a shape a photograph test placed at the due_time check would '
    'never have touched.';

  -- =================================================================================
  -- Step 11: the refusal survived every edit the author made after it.
  -- =================================================================================
  for v_row in
    select * from (values
      (v_e, v_e_flag, 'archived it at 21:30'),
      (v_f, v_f_flag, 'turned the money off at 22:00'),
      (v_g, v_g_flag, 'moved it to a Weekly Quota at 22:00'),
      (v_h, v_h_flag, 'moved it to an hours quota at 22:00'),
      (v_i, v_i_flag, 'switched the sign-off flag off at 22:00'),
      (v_n, v_n_flag, 'un-flagged it and attached an Auto-check at 22:01')
    ) as t(doer, commitment_id, label)
  loop
    select id, verdict, missed_count into v_s, v_verdict, v_missed
      from public.settlement
     where subject = v_row.doer and period = v_today and kind = 'day' and supersedes is null;

    if v_s is null then
      raise exception using message = format(
        'The day dropped out of settlement entirely after the author %s. A refusal at 21:00 must '
        'survive it.', v_row.label);
    end if;

    select outcome into v_outcome from public.settlement_commitment
     where settlement_id = v_s and commitment_id = v_row.commitment_id;

    select count(*), min(state) into v_count, v_state from public.penalty_current
     where subject = v_row.doer and period = v_today and kind = 'day';

    if v_verdict <> 'failed' or v_outcome is distinct from 'missed' or v_missed <> 1
       or v_count <> 1 or v_state <> 'owed' then
      raise exception using message = format(
        'The author %s and the day now reads `%s` / `%s` / missed %s / %s penalty (`%s`), '
        'expected `failed` / `missed` / 1 / 1 (`owed`). A refusal costs what it cost when it was '
        'made -- an enforcement mechanism the person being enforced against can switch off is not '
        'one.', v_row.label, v_verdict, coalesce(v_outcome::text, '<null>'), v_missed, v_count,
        coalesce(v_state::text, '<null>'));
    end if;

    select current_days into v_current from public.chain_current
     where commitment_id = v_row.commitment_id;
    if coalesce(v_current, 0) <> 0 then
      raise exception using message = format(
        'The author %s and the chain still reads %s, expected 0.', v_row.label,
        coalesce(v_current, 0));
    end if;
  end loop;

  -- The sixth escape's real cost was never the refused commitment: it was the day. Account N's
  -- ordinary commitment -- answered, nothing to do with the referee -- has to have settled too.
  select id into v_s from public.settlement
   where subject = v_n and period = v_today and kind = 'day' and supersedes is null;
  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_n_mate;
  if v_outcome is distinct from 'held' then
    raise exception using message = format(
      'Account N''s ordinary commitment froze `%s`, expected `held`. The AD-13 gate holding a '
      'day open takes the whole account with it -- that is what "no day is ever held open waiting '
      'for a person" costs when the person can arm it himself.',
      coalesce(v_outcome::text, '<null>'));
  end if;

  raise notice using message =
    'Step 11 ok: archiving, turning the money off, moving the cadence to EITHER quota, switching '
    'the flag off, and attaching an Auto-check after un-flagging -- each after the refusal, each '
    'before midnight -- leaves the day `failed` with its owed penalty and its broken chain, and '
    'leaves the account-mate''s day settled rather than held open for 96 hours.';

  -- =================================================================================
  -- Step 12: the frozen facts are what the row records, and the referee is named.
  -- =================================================================================
  select referee_id, carries_penalty into v_uuid, v_flag
    from public.referee_decision
   where subject = v_f and for_day = v_today and commitment_id = v_f_flag;

  if v_uuid is distinct from v_rf then
    raise exception using message = format(
      'The decision names referee_id %s, expected the calling referee %s. A statement about '
      'somebody else''s money has to say who made it.', coalesce(v_uuid::text, '<null>'), v_rf);
  end if;

  if v_flag is distinct from true then
    raise exception using message = format(
      'The decision froze carries_penalty=%s, expected true -- the value in force when it was '
      'made, not the one the author left behind at 22:00.', v_flag);
  end if;

  select cadence::text into v_message from public.referee_decision
   where subject = v_h and for_day = v_today and commitment_id = v_h_flag;
  if v_message is distinct from 'daily' then
    raise exception using message = format(
      'The decision froze cadence=%s, expected `daily`.', coalesce(v_message, '<null>'));
  end if;

  -- And the world really did move under it, or Step 11 would be asserting nothing.
  -- `carries_penalty_as_of()` cuts at the day's END (20260827130000:109), so the author's 22:00
  -- toggle is inside its window and a live read now says false -- which is the whole reason the
  -- value has to be stored rather than re-asked.
  if public.carries_penalty_as_of(v_f_flag, v_today) is not false then
    raise exception using message = format(
      'carries_penalty_as_of(f, today) reads %s after the author turned the money off at 22:00. '
      'It must read false, or Step 11 passes without the frozen value being what settlement '
      'read.', public.carries_penalty_as_of(v_f_flag, v_today));
  end if;

  select cadence::text into v_message from public.commitment where id = v_g_flag;
  if v_message is distinct from 'weekly_quota' then
    raise exception using message = format(
      'Account G''s live cadence reads %s, expected weekly_quota -- the edit Step 11 is about did '
      'not happen.', coalesce(v_message, '<null>'));
  end if;

  select requires_referee_approval into v_flag from public.commitment where id = v_i_flag;
  if v_flag is not false
     or public.requires_referee_approval_as_of(v_i_flag, v_today) is not true then
    raise exception using message = format(
      'Account I reads live flag %s and as-of-today %s. The point of the acceptance criterion is '
      'that the two disagree and settlement follows the second.',
      v_flag, public.requires_referee_approval_as_of(v_i_flag, v_today));
  end if;

  -- Account O: the other half of the evening message. Its held commitment was created FIRST, so
  -- read through the author's word both commitments tie at `not slipped` and the oldest wins the
  -- suggestion; read through the decision, the refused one sorts first and is what he is told to
  -- start with tomorrow -- which is correct, and is the whole content of that ordering.
  select x.payload->>'body' into v_body from public.outbox x
   where x.dedupe_key = 'summary-' || v_o::text || '-' || v_today::text;

  if v_body is null then
    raise exception using message =
      'No summary was enqueued for account O, so the suggestion assertion below is vacuous.';
  end if;

  if v_body not like '%Start with Chạy bộ (signed off) tomorrow.%' then
    raise exception using message = format(
      'The evening summary tells him to start with something other than the refused commitment: '
      '"%s". The suggestion prefers what was missed, and a refusal is a miss.', v_body);
  end if;

  raise notice using message =
    'Step 12 ok: the decision names the referee who made it, records the world it was made in, '
    'and that world has since moved under it -- live reads now disagree with every frozen one.';

  -- =================================================================================
  -- Step 13: a refusal is not the author's answer.
  --
  -- `count(o.answer)` is how the Story 5.2 silence intervention decides he has gone quiet
  -- (20260826090000:156, 20260826130000:74) and how commitment_answer_rate_for_month() computes
  -- SM-6 (20260826110000:321). Account D was refused and never answered anything. The detector's
  -- own arithmetic is asserted rather than the detector itself, so nothing here depends on the
  -- hour the file runs at -- the detector will not look at a day before the account's morning
  -- hour, and this file never moves the clock.
  -- =================================================================================
  select count(*), count(o.answer) into v_total, v_answered
    from public.commitments_owing(v_d, v_today) o;

  if v_total <= 0 or v_answered <> 0 then
    raise exception using message = format(
      'The silence detector''s own read of a refused day gives total=%s answered=%s, expected a '
      'positive total and 0 answered. A third party''s write must not make the author look '
      'present on a day he said nothing on.', v_total, v_answered);
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_d, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  select r.asked, r.answered into v_total, v_answered
    from public.commitment_answer_rate_for_month(v_today) r
   where r.commitment_id = v_d_flag;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  if coalesce(v_total, 0) <= 0 or coalesce(v_answered, -1) <> 0 then
    raise exception using message = format(
      'commitment_answer_rate_for_month() reads asked=%s answered=%s for the refused commitment, '
      'expected a positive asked and 0 answered.', coalesce(v_total, 0), coalesce(v_answered, -1));
  end if;

  raise notice using message =
    'Step 13 ok: neither the silence detector''s arithmetic nor the monthly answer rate counts a '
    'refusal as something the author said.';

  -- =================================================================================
  -- Step 14: one mechanism per job. The 48-hour objection cannot reach a flagged commitment,
  -- and the flag it reads is the one that stood on the day being objected to.
  -- =================================================================================
  update public.commitment set requires_referee_approval = false where id = v_j_flag;

  if public.requires_referee_approval_as_of(v_j_flag, v_yesterday) is not true then
    raise exception using message =
      'The fixture is wrong: account J''s commitment must read flagged as of yesterday after the '
      'flag was switched off today, or the step below would prove nothing about the historical '
      'read.';
  end if;

  select id, verdict into v_s, v_verdict from public.settlement
   where subject = v_j and period = v_yesterday and kind = 'day' and supersedes is null;

  select outcome into v_outcome from public.settlement_commitment
   where settlement_id = v_s and commitment_id = v_j_flag;

  if v_verdict <> 'clean' or v_outcome is distinct from 'held' then
    raise exception using message = format(
      'Account J''s flagged day settled `%s` / `%s` with nobody deciding, expected `clean` / '
      '`held` -- silence approves.', v_verdict, coalesce(v_outcome::text, '<null>'));
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rj, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  v_refused := false;
  begin
    perform public.object_to_day(v_s, v_j_flag, 'I did not see him there.');
  exception when others then
    v_refused := true;
    v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  if not v_refused or v_message not ilike '%signature on the day itself%' then
    raise exception using message = format(
      'object_to_day() on a commitment that asked for the signature was not refused in its own '
      'words. refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  select count(*) into v_count from public.settlement where supersedes = v_s;
  if v_count <> 0 then
    raise exception using message = format(
      'The refused objection still wrote %s correction(s).', v_count);
  end if;

  -- The negative that keeps this honest: the same call on an UNFLAGGED commitment still works, so
  -- the guard refuses the flagged case and not the path itself. Account A's twin, settled clean.
  select id into v_s from public.settlement
   where subject = v_a and period = v_today and kind = 'day' and supersedes is null;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ra, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  perform public.object_to_day(v_s, v_a_twin, 'The photograph is of the box, not the pill.');

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  select count(*) into v_count from public.settlement where supersedes = v_s;
  if v_count <> 1 then
    raise exception using message = format(
      'An objection to an UNFLAGGED commitment wrote %s correction(s), expected 1. Story 8.2 '
      'closes one door; it does not touch the objection path for every other commitment.',
      v_count);
  end if;

  raise notice using message =
    'Step 14 ok: a flagged commitment is unreachable by object_to_day() -- read as of the day it '
    'names, not live -- and an unflagged one still is reachable.';

  -- =================================================================================
  -- Step 15: the RPC's own refusal list, one row of the matrix at a time.
  -- =================================================================================

  -- Not the referee: `anon` cannot reach the function at all, and a doer session is refused
  -- before any row is read -- proven against a real commitment AND a bogus id, so the message
  -- itself pins the ordering rather than the final state alone.
  if has_function_privilege('anon', 'public.sign_off_day(uuid, date, boolean, text)', 'execute')
  then
    raise exception using message =
      '`anon` can execute sign_off_day(), so an unauthenticated caller can reach '
      '/rest/v1/rpc/sign_off_day.';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_k, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, false, 'I say so.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%only the referee%' then
    raise exception using message = format(
      'A doer signing off his own day was not refused with a referee-specific message. '
      'refused=%s, message=%s', v_refused, coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.sign_off_day(gen_random_uuid(), v_today, false, 'I say so.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%only the referee%'
     or v_message ilike '%not paired%' then
    raise exception using message = format(
      'A doer naming a bogus commitment id read "%s" -- the role check must refuse before any row '
      'is read, so this must read the same referee-only message as a real one.',
      coalesce(v_message, '<null>'));
  end if;

  -- Wrong account: a real referee, paired to somebody else. Same sentence for a commitment that
  -- exists and one that does not, because telling them apart is a commitment-id oracle.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ra, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, false, 'Not mine to judge.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%account you are not paired to%' then
    raise exception using message = format(
      'A referee signing off another account''s commitment read "%s".',
      coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.sign_off_day(gen_random_uuid(), v_today, false, 'Not mine to judge.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%account you are not paired to%' then
    raise exception using message = format(
      'A referee naming a commitment id that does not exist read "%s". It must be the same '
      'sentence a commitment on another account gets, or he can enumerate ids across every '
      'account.', coalesce(v_message, '<null>'));
  end if;

  -- Unpaired: role `referee`, `referee_of` null. Not a doer, and refused before any row of the
  -- author's is read.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rnone, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, false, 'Nobody asked me.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%account you are not paired to%' then
    raise exception using message = format(
      'An unpaired referee read "%s".', coalesce(v_message, '<null>'));
  end if;

  -- Everything below is account K's own referee.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rk, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  -- A refusal with no reason, and one that never ends. Both before the CHECK could fire.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, false, '   ');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%has to say why%' then
    raise exception using message = format(
      'A refusal with a blank reason read "%s", expected the sentence rather than a raw CHECK '
      'violation.', coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, false, null);
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%has to say why%' then
    raise exception using message = format(
      'A refusal with no reason at all read "%s".', coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, false, repeat('x', 2001));
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%2000 or fewer%' then
    raise exception using message = format(
      'A 2001-character reason read "%s".', coalesce(v_message, '<null>'));
  end if;

  -- An approval that carries a reason, refused with a sentence rather than a bare CHECK.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, true, 'Well done.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%approval carries no reason%' then
    raise exception using message = format(
      'An approval carrying a reason read "%s".', coalesce(v_message, '<null>'));
  end if;

  -- A null decision. `if not p_approved` would treat it as false and fall into the refusal.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, null, 'Maybe.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%p_approved must not be null%' then
    raise exception using message = format(
      'A null p_approved read "%s".', coalesce(v_message, '<null>'));
  end if;

  -- The flag was never on for that day.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_plain, v_today, false, 'I looked anyway.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%did not ask for your signature%' then
    raise exception using message = format(
      'A commitment that never asked for a signature read "%s".', coalesce(v_message, '<null>'));
  end if;

  -- Too late, and not yet. Both halves of the window, half-open in the same direction as every
  -- other deadline in this schema.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_yesterday, false, 'Late.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%before midnight or not at all%' then
    raise exception using message = format(
      'A decision on yesterday read "%s".', coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_tomorrow, false, 'Early.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%has not started yet%' then
    raise exception using message = format(
      'A decision on tomorrow read "%s".', coalesce(v_message, '<null>'));
  end if;

  -- No money on it, a Weekly Quota, and an hours quota -- the landing guards, refusal-only.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_free, v_today, false, 'He did not do it.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%carried no penalty%'
     or v_message not ilike '%Grace Day%' then
    raise exception using message = format(
      'A refusal on a commitment carrying no penalty read "%s", and it must name the broken chain '
      'no Grace Day could reach.', coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_week, v_today, false, 'He did not do it.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%week close%' then
    raise exception using message = format(
      'A refusal on a Weekly Quota commitment read "%s", and it must name week close.',
      coalesce(v_message, '<null>'));
  end if;

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_hours, v_today, false, 'He did not do it.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%minutes%' then
    raise exception using message = format(
      'A refusal on an hours-quota commitment read "%s", and it must name the measured minutes '
      'that decide it -- commitments_owing() excludes that cadence outright, so a success here '
      'would report a decision nothing can ever read.', coalesce(v_message, '<null>'));
  end if;

  -- An approval on the same three is NOT refused: silence already approved the day, so an
  -- approval that changes nothing can break nothing either, and a refusal here would be the
  -- mechanism nagging about a decision that costs the author nothing.
  perform public.sign_off_day(v_k_free, v_today, true);

  -- No photograph. CAP-6 keeps these off the referee's list; AD-1 says the server is what
  -- actually enforces it.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_proof, v_today, false, 'Nothing there.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%no photograph on that day%' then
    raise exception using message = format(
      'A refusal on a commitment-day with no photograph read "%s".',
      coalesce(v_message, '<null>'));
  end if;

  -- Archived before the refusal was ever attempted. The other half of the archived exception in
  -- `commitments_owing()`: a commitment retired at 08:00 is not resurrected at 21:00.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_arch, v_today, false, 'He did not do it.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%archived%' then
    raise exception using message = format(
      'A refusal on a commitment archived this morning read "%s".',
      coalesce(v_message, '<null>'));
  end if;

  -- A decision is final, and the second one is refused rather than silently ignored.
  v_refused := false;
  begin
    perform public.sign_off_day(v_k_twice, v_today, true, null);
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%already been decided%' then
    raise exception using message = format(
      'A second decision on the same commitment-day read "%s".', coalesce(v_message, '<null>'));
  end if;

  -- And it keeps getting that sentence after the author has edited the commitment underneath it.
  -- The already-decided read sits ABOVE the refusal-only landing guards for this reason: ordered
  -- below them, a referee who refused at 21:00 and double-tapped after the author turned the
  -- money off at 22:00 is told "That commitment carried no penalty on that day" -- the wrong
  -- sentence, and one that tells him about an edit that is none of his business.
  --
  -- Account K never settles, so this reaches the ordering rather than the already-settled check.
  perform set_config('role', 'postgres', true);
  update public.commitment set carries_penalty = false where id = v_k_twice;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rk, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  v_refused := false;
  begin
    perform public.sign_off_day(v_k_twice, v_today, false, 'Asking again, later.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;
  if not v_refused or v_message not ilike '%already been decided%' then
    raise exception using message = format(
      'A repeat on a commitment the author had since edited read "%s", expected the '
      'already-decided sentence. A decision is final, and which sentence he gets must not depend '
      'on what the author has done to the commitment since.', coalesce(v_message, '<null>'));
  end if;

  -- A day already settled. The narrowed midnight race: account A settled in Step 5, and its
  -- flagged commitment is still flagged and still inside its own local day.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ra, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  v_refused := false;
  begin
    perform public.sign_off_day(v_a_flag, v_today, false, 'The cron beat me to it.');
  exception when others then
    v_refused := true; v_message := sqlerrm;
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  if not v_refused or v_message not ilike '%already been settled%' then
    raise exception using message = format(
      'A decision on a day that had already settled read "%s". It must be a sentence rather than '
      'a silent no-op -- and rather than a half-honoured settlement.',
      coalesce(v_message, '<null>'));
  end if;

  select count(*), min(approved::text) into v_count, v_message from public.referee_decision
   where subject = v_k and commitment_id = v_k_twice;
  if v_count <> 1 or v_message <> 'false' then
    raise exception using message = format(
      'Account K carries %s decision row(s) for that commitment reading approved=%s, expected '
      'exactly 1 and the first one -- a decision is final and the first writer wins.',
      v_count, coalesce(v_message, '<null>'));
  end if;

  raise notice using message =
    'Step 15 ok: every refusal in the matrix, each in its own words, with the role gate first and '
    'the pairing check above any read of the author''s.';

  -- =================================================================================
  -- Step 16: append-only, and nobody writes one of these but the RPC.
  -- =================================================================================
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_c, 'role', 'authenticated', 'app_role', 'doer')::text, true);

  -- The author reads his own, which is the entire reason the reason is stored.
  select count(*) into v_count from public.referee_decision where subject = v_c;
  if v_count <> 1 then
    raise exception using message = format(
      'The author reads %s of his own decision rows, expected 1.', v_count);
  end if;

  -- And writes none of them, with the grants for all three in his hand.
  -- Pinned to 42501, not to "something raised". Caught as a bare `when others`, a NOT NULL or
  -- foreign-key slip in this fixture row would satisfy the assertion for entirely the wrong
  -- reason and the append-only claim would be resting on a typo. The idiom is the three CHECK
  -- assertions below this one.
  v_refused := false;
  begin
    insert into public.referee_decision
      (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
    values (v_c, v_rc, v_yesterday, v_c_flag, true, null, true, 'daily');
  exception when others then
    v_refused := true;
    get stacked diagnostics v_message = returned_sqlstate;
  end;
  if not v_refused or v_message <> '42501' then
    raise exception using message = format(
      'A client session inserting a referee_decision row directly was refused with SQLSTATE %s, '
      'expected 42501 -- RLS having no insert policy. A client that can write one of these can '
      'decide a day, and anything else refusing it here means this step is not testing that.',
      coalesce(v_message, '<nothing raised>'));
  end if;

  update public.referee_decision set reason = 'I take it back.' where subject = v_c;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'A client session updated %s decision row(s). There is no update policy, and no '
      'withdrawal.', v_count);
  end if;

  delete from public.referee_decision where subject = v_c;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception using message = format(
      'A client session deleted %s decision row(s).', v_count);
  end if;

  -- The referee reads none of them, including his own. He is told what is waiting for him through
  -- a definer function in Story 8.4, never through a policy on this table -- granting the referee
  -- `select` on a settlement table is a prior incident in this repository (20260825100000:21-33).
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rc, 'role', 'authenticated', 'app_role', 'referee')::text, true);

  select count(*) into v_count from public.referee_decision;
  if v_count <> 0 then
    raise exception using message = format(
      'The referee reads %s decision row(s), expected 0.', v_count);
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);

  -- The CHECK itself, exercised as `postgres` where no RLS stands in front of it -- including the
  -- 2000-character boundary the RPC's own sentence names, which must be accepted.
  insert into public.referee_decision
    (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
  values (v_k, v_rk, v_yesterday, v_k_proof, false, repeat('x', 2000), true, 'daily');

  v_refused := false;
  begin
    insert into public.referee_decision
      (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
    values (v_k, v_rk, v_tomorrow, v_k_proof, false, repeat('x', 2001), true, 'daily');
  exception when check_violation then
    v_refused := true;
    get stacked diagnostics v_message = constraint_name;
  end;
  if not v_refused or v_message <> 'referee_decision_says_why' then
    raise exception using message = format(
      'A 2001-character reason was refused by `%s`, expected referee_decision_says_why.',
      coalesce(v_message, '<none>'));
  end if;

  v_refused := false;
  begin
    insert into public.referee_decision
      (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
    values (v_k, v_rk, v_tomorrow, v_k_proof, true, 'Well done.', true, 'daily');
  exception when check_violation then
    v_refused := true;
    get stacked diagnostics v_message = constraint_name;
  end;
  if not v_refused or v_message <> 'referee_decision_says_why' then
    raise exception using message = format(
      'An approval carrying a reason was refused by `%s`, expected referee_decision_says_why.',
      coalesce(v_message, '<none>'));
  end if;

  v_refused := false;
  begin
    insert into public.referee_decision
      (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
    values (v_k, v_rk, v_tomorrow, v_k_proof, false, '   ', true, 'daily');
  exception when check_violation then
    v_refused := true;
    get stacked diagnostics v_message = constraint_name;
  end;
  if not v_refused or v_message <> 'referee_decision_says_why' then
    raise exception using message = format(
      'A whitespace-only reason was refused by `%s`, expected referee_decision_says_why.',
      coalesce(v_message, '<none>'));
  end if;

  -- The bound in the other direction, which btrim() hides. Ten real characters padded to 60,000:
  -- `char_length(btrim(reason)) between 1 and 2000` reads 10 and passes it, so the constraint
  -- this file calls the real guarantee would store an arbitrarily large value. sign_off_day()
  -- btrims before it writes and would never produce this row -- but the RPC is not the only thing
  -- that can reach the table, `postgres` is, and the CHECK is what is supposed to say so.
  v_refused := false;
  begin
    insert into public.referee_decision
      (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
    values (v_k, v_rk, v_tomorrow, v_k_proof, false,
            repeat(' ', 30000) || 'He did not' || repeat(' ', 30000), true, 'daily');
  exception when check_violation then
    v_refused := true;
    get stacked diagnostics v_message = constraint_name;
  end;
  if not v_refused or v_message <> 'referee_decision_says_why' then
    raise exception using message = format(
      'A 60,010-character reason that trims to 10 was refused by `%s`, expected '
      'referee_decision_says_why. Bounding only the trimmed length bounds nothing.',
      coalesce(v_message, '<none>'));
  end if;

  raise notice using message =
    'Step 16 ok: the author reads his own and writes none, the referee reads none at all, and the '
    'CHECK accepts 2000 characters and refuses 2001, a blank reason and an explained approval.';

  -- =================================================================================
  -- Step 16b: the expiry correction reads the refusal too.
  --
  -- `supersede_expiries()` is the last reader of `commitments_owing()` that decides what a
  -- commitment DID, and it carries settle_day()'s own shapes. A day that settled `expired` and is
  -- corrected later must not restore a refused commitment to `held`, drop its penalty and repair
  -- the chain the refusal broke.
  --
  -- **The decision rows below are planted as `postgres`, not written through sign_off_day(), and
  -- that is forced rather than convenient.** A decision lands strictly inside its own local day;
  -- a day can only settle `expired` once every unanswered commitment is past its own deadline,
  -- which for an untimed one is the morning of D + 3. The two windows cannot overlap, so a
  -- refusal on a day that later expires is necessarily a row written days ago. The RPC's own
  -- window is what Step 15 tests; this step is about what settlement does with the row.
  -- =================================================================================
  insert into public.referee_decision
    (subject, referee_id, for_day, commitment_id, approved, reason, carries_penalty, cadence)
  values (v_l, v_rl, v_dexp, v_l_flag, false, 'That is the car park, not the gym.', true, 'daily'),
         (v_m, v_rm, v_dexp, v_m_flag, false, 'That is the car park, not the gym.', true, 'daily');

  perform public.settle_day(v_dexp, true);

  for v_row in
    select * from (values
      (v_l, v_l_flag, v_l_late, 'whose refused commitment he did answer'),
      (v_m, v_m_flag, v_m_late, 'whose refused commitment he never answered')
    ) as t(doer, flagged, late, label)
  loop
    select id, verdict into v_s, v_verdict from public.settlement
     where subject = v_row.doer and period = v_dexp and kind = 'day' and supersedes is null;

    select outcome into v_outcome from public.settlement_commitment
     where settlement_id = v_s and commitment_id = v_row.flagged;

    if v_verdict is distinct from 'expired' or v_outcome is distinct from 'missed' then
      raise exception using message = format(
        'The fixture for the account %s settled `%s` with the refused commitment reading `%s`, '
        'expected `expired` / `missed`. The day has to expire on the OTHER commitment''s silence '
        'for this step to be about the correction at all.',
        v_row.label, coalesce(v_verdict::text, '<null>'), coalesce(v_outcome::text, '<null>'));
    end if;

    -- The answer he really gave in time, delivered late. Story 2.7's whole subject, and the only
    -- thing that makes an expired day eligible for a correction.
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (v_row.doer, v_row.late, gen_random_uuid(), 'held',
            ((v_dexp + 1)::timestamp + interval '8 hours') at time zone 'Asia/Ho_Chi_Minh');
  end loop;

  perform public.supersede_expiries();

  for v_row in
    select * from (values
      (v_l, v_l_flag, v_l_late, 'whose refused commitment he did answer'),
      (v_m, v_m_flag, v_m_late, 'whose refused commitment he never answered')
    ) as t(doer, flagged, late, label)
  loop
    select id, verdict, missed_count into v_s, v_verdict, v_missed
      from public.settlement s
     where s.subject = v_row.doer and s.period = v_dexp and s.kind = 'day'
       and not exists (select 1 from public.settlement c where c.supersedes = s.id);

    if v_s is null or v_verdict is distinct from 'failed' then
      raise exception using message = format(
        'After the late answer, the account %s reads `%s` for that day, expected `failed`. An '
        'expired day the author has now answered must be corrected -- and a refusal must not be '
        'what strands it in `expired`, which is the one verdict grace_day_validate() refuses.',
        v_row.label, coalesce(v_verdict::text, '<null>'));
    end if;

    select outcome into v_outcome from public.settlement_commitment
     where settlement_id = v_s and commitment_id = v_row.flagged;
    select outcome into v_outcome2 from public.settlement_commitment
     where settlement_id = v_s and commitment_id = v_row.late;

    if v_outcome is distinct from 'missed' or v_outcome2 is distinct from 'held'
       or v_missed <> 1 then
      raise exception using message = format(
        'The correction for the account %s froze `%s` for the refused commitment and `%s` for the '
        'one he answered, missed_count %s. Expected `missed` / `held` / 1 -- a correction that '
        'restores a refused commitment to held un-says the referee and hands the money back.',
        v_row.label, coalesce(v_outcome::text, '<null>'),
        coalesce(v_outcome2::text, '<null>'), v_missed);
    end if;

    select count(*), min(state) into v_count, v_state from public.penalty_current
     where subject = v_row.doer and period = v_dexp and kind = 'day';
    if v_count <> 1 or v_state <> 'owed' then
      raise exception using message = format(
        'The correction for the account %s carries %s live penalty row(s) reading `%s`, expected '
        'exactly 1 `owed` -- the refusal still costs what it cost.',
        v_row.label, v_count, coalesce(v_state::text, '<null>'));
    end if;

    select current_days into v_current from public.chain_current
     where commitment_id = v_row.flagged;
    if coalesce(v_current, 0) <> 0 then
      raise exception using message = format(
        'The correction for the account %s left the refused commitment a chain of %s, expected 0 '
        '-- chain_current follows settlement_current, so a correction reading `held` would repair '
        'the chain the refusal broke.', v_row.label, v_current);
    end if;
  end loop;

  raise notice using message =
    'Step 16b ok: an expired day corrected after the fact still reads the refusal -- `missed`, '
    'its penalty owed, its chain broken -- whether or not the author answered the refused '
    'commitment himself, which is the difference between the two accounts and the difference '
    'between the two reads.';
end;
$$;


-- =================================================================================
-- Step 17: the catalog. RLS on, and not one policy that is not a SELECT.
--
-- A policy added later for the referee's convenience is exactly the shape of the prior incident
-- at 20260825100000:21-33, and this is what would catch it.
-- =================================================================================
do $$
declare
  v_count integer;
  v_names text;
begin
  if not exists (
    select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'referee_decision' and c.relrowsecurity
  ) then
    raise exception using message =
      'Row level security is not enabled on public.referee_decision. Every policy below it is '
      'decoration without it (AD-7).';
  end if;

  select count(*),
         coalesce(string_agg(polname || ' (' || polcmd::text || ')', ', '), '<none>')
    into v_count, v_names
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'referee_decision' and p.polcmd <> 'r';

  if v_count <> 0 then
    raise exception using message = format(
      'public.referee_decision carries %s non-SELECT policy/policies: %s. sign_off_day() is the '
      'only writer, and a decision is never edited or withdrawn.', v_count, v_names);
  end if;

  select count(*) into v_count
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'referee_decision';

  if v_count <> 1 then
    raise exception using message = format(
      'public.referee_decision carries %s policies, expected exactly 1 -- the author''s read of '
      'his own.', v_count);
  end if;

  raise notice using message =
    'Step 17 ok: RLS is on, and the one policy on the table is the author reading his own.';
end;
$$;

rollback;
