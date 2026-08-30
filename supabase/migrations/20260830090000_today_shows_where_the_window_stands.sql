-- Story 6.5 — Today shows where the window stands.
--
-- Stories 6.1 through 6.4 built the whole state machine in `lifecycle.md` and the Today screen
-- renders none of it: every timed commitment reads `Not yet` all day, beside a *Claim* control
-- offered four hours early, offered again after the window has shut, and offered a second time
-- after a reload of a day already claimed. The one state that costs money at midnight — a window
-- that shut with nothing proven — looks exactly like one still waiting for its hour.
--
-- Almost all of that distinction is a clock, and a clock is the one thing a server read cannot
-- keep telling the truth about: a row fetched at 20:29 is wrong at 20:31, and CAP-7 requires the
-- surface to become distinct "without opening anything or refreshing". So the split is:
--
--   * the client owns the clock — `lib/timed-window.ts` decides ahead / open / shut from the
--     commitment's own `due_time` and `late_window_minutes`, which Today already reads;
--   * this view owns the two facts a client cannot know and must not tally for itself —
--     whether today's claim exists, and whether a photo has landed on it (AD-8).
--
-- It reports facts, never a verdict. Nothing here decides whether a day held: that is
-- `commitments_owing()` and `settle_day()` (20260829090000), and this story does not touch them.
-- FR-10 still forbids announcing mid-day that a day is lost, which is why the shut state this
-- feeds says "nothing claimed" and not "missed" — the day is not over, and a photo attached to a
-- claim already made can still land right up to midnight.

create view public.timed_claim_today
with (security_invoker = true)
as
with today as (
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date as d
)
select c.owner_id,
       c.id as commitment_id,
       -- What a photo attaches to. Without it a reload strands a claim made earlier today: the
       -- id lives only in the component state the claim returned, so the author who claimed at
       -- 20:31 and closed the app had no way back to the upload control at 20:40, and the day
       -- failed at midnight for a photo he was never offered a second chance to attach.
       d.id as declaration_id,
       -- The existence of an evidence row *is* acceptance — the capture-date rule and the
       -- frozen-day refusal both live in `evidence_derive_owner()` (20260828150000), so a row
       -- that exists is a row that passed them.
       --
       -- The same existence test `commitments_owing()` (20260829090000:308) applies when it
       -- decides whether a timed claim reports `held` or `slipped`. Two copies, deliberately:
       -- extracting it would mean recreating the function every settlement path reads, in a
       -- story whose whole point is that it moves no money. If a later story needs to touch
       -- that function anyway, this is the second caller that should move with it.
       (d.id is not null and exists (
          select 1 from public.evidence e where e.declaration_id = d.id
        )) as proven
  from public.commitment c
  cross join today t
  left join public.declaration d
         on d.commitment_id = c.id
        and d.for_day = t.d
 where c.due_time is not null
   and c.archived_at is null;

comment on view public.timed_claim_today is
  'Story 6.5: for every open timed commitment of the caller, whether today has been claimed '
  '(declaration_id, also what a photo attaches to) and whether a photo has landed on that claim '
  '(proven). Facts only — never a verdict, which stays with commitments_owing() and settle_day(). '
  'Reads the LIVE due_time rather than due_time_as_of(): this view is about the window that can '
  'still be acted on today, and declaration_derive_day() judges a tap against the same live '
  'value, so a commitment timed this morning is claimable and visible today. Settlement reads the '
  'frozen value for the opposite reason (Story 6.4). security_invoker, so RLS on commitment, '
  'declaration and evidence is what scopes it — never a client-side tally of raw rows (AD-8).';
