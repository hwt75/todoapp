---
title: 'Story 8.6 — Today says the day is waiting on his friend'
type: 'feature'
created: '2026-09-29'
status: 'done'
review_loop_iteration: 0
baseline_commit: '05b0bfac777ba7416b9289cbf5798a1fce5b0537'
story_key: '8-6-today-says-the-day-is-waiting-on-his-friend'
context:
  - '{project-root}/_bmad-output/specs/spec-commitments-the-referee-signs-off/SPEC.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-8-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-8-4-what-is-waiting-for-him-today.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Once a flagged commitment has its photograph, the author cannot tell that his referee
has not answered yet. CAP-8: a flagged row with a photograph and no decision says so, and stops
saying so once a decision lands or midnight passes. An unflagged row is unchanged.

**Approach:** "Waiting on the referee" is defined **once**, server-side, and both sides read it:
the referee's list (Story 8.4) and a new read for the author. Today shows one line on each waiting
row. The copy is information about his friend, not a task: it says the day holds without a decision.

## Boundaries & Constraints

**Always:** One definition of waiting — flagged as of today through
`photograph_reaches_the_referee()`, no `referee_decision` row, not archived, today in
`Asia/Ho_Chi_Minh` — used by `referee_waiting_today()` and by the author's read alike, so the
author is told "waiting" for exactly the rows his referee is shown. Nothing new is stored. The
author's read is scoped to `auth.uid()` and says nothing when he has no paired referee (a revoked
pairing auto-approves, so there is nobody to wait on). The line is copy only: no control, no
count, no deadline pressure, never the word "waiting" alone. An unflagged row renders exactly as
today.

**Ask First:** Any change to what `referee_waiting_today()` returns, to `sign_off_day()`, to
settlement, or to either referee policy. Any notification to anyone.

**Never:** No nudge or "remind him" control. No showing what the referee decided (8.5's push and
the Ledger own a refusal; an approval says nothing). No new column or table.

## I/O & Edge-Case Matrix

| Scenario | State | Expected |
|---|---|---|
| Waiting, untimed | Flagged as of today, kept photo, no decision | Row shows the line |
| Waiting, timed | Flagged, claim proved with a photo, no decision | Row shows the line |
| No photo yet | Flagged, nothing attached | No line |
| Decided | Approved or refused | No line, once Today re-reads |
| Unflagged | Photo kept, flag off as of today | No line; row byte-identical to before |
| Flag switched on this morning | Unflagged at today's start | No line — forward only |
| Flag switched off this morning | Flagged at today's start | Line — his referee still has it |
| No referee paired | Flag was on, pairing revoked | No line |
| Midnight | Screen open across the rollover | Line gone with yesterday's rows |
| Just attached | Author uploads the photo | Line appears without a manual reload |
| Came back to the app | Referee decided while the tab was hidden | Line gone after the tab is shown again |
| Read failed | The waiting read errors | No line; the rest of Today unaffected |

</frozen-after-approval>

## The copy — the one decision worth your attention

The story says the copy is the whole story, and SPEC CAP-8 binds it: *information about his friend,
not a task for him; the words must carry that the day is already safe without a decision.*
EXPERIENCE.md's model is the referee timeout note — *"Ignore this and it's dropped in his favor"* —
written so nobody feels like a bottleneck. And 8.1's setup copy already told him *"reminding him is
not your job"*; this should sound like the same app.

**Proposed:** *"Your referee hasn't looked at this yet. If he never does, it holds at midnight on
your photo — nothing here needs you."*

Why these words: *hasn't looked* is the fact CAP-8 asks for, about the friend, not the author;
*if he never does, it holds* is the silence rule, stated as the outcome rather than as a risk;
*nothing here needs you* closes the door on chasing without naming a chore. It does not say
*waiting*, which is the word that invites a chase, and it does not mention refusal, which would
turn information into worry.

## Code Map

- `supabase/migrations/20260929090000_what_is_waiting_for_him_today.sql:124-186` —
  `referee_waiting_today()`; its row gate and decided/archived exclusions become the shared
  definition. Re-create it on the shared helper with its return columns unchanged;
  `8-4-...sql` passing unmodified proves it returns the same rows.
- `supabase/migrations/20260914120000_the_photograph_reaches_the_referee.sql:62-118` — the predicate
  the definition rests on; granted to `authenticated`, read-only here.
- `supabase/migrations/20260911090000_...signature.sql:325-347` — `has_paired_referee()`, the
  author-side "is there anyone to wait on".
- `components/today.tsx:207-212,423-452` — `reachRead` stamped with `localDay` and discarded by
  mismatch: the pattern for the new read. `:216` `filedReload` — the upload-bumped reload to hook.
  `:870-910` — the photo control where the line sits. Timed rows' proof is `windows[id].proven`.
- `lib/evidence.ts:478-530` — `readRefereeReach()`: failure yields "unknown", never `false`.
- `lib/commitment.ts:285-290` — `REFEREE_SIGN_OFF_COPY.warning`, the voice to match.

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/20260929110000_today_says_the_day_is_waiting_on_his_friend.sql` —
      `commitment_days_waiting_on_referee(p_owner uuid, p_day date) returns setof uuid`
      (definer, revoked from clients); `referee_waiting_today()` re-created on it;
      `waiting_on_my_referee() returns setof uuid` for `auth.uid()`, today, empty without a
      paired referee; revoke `public, anon`, grant `authenticated`.
- [x] `lib/referee-waiting.ts` (or `lib/evidence.ts`) — the read, stamped with its day, failure →
      no line; `WAITING_ON_REFEREE_COPY`.
- [x] `components/today.tsx` — read on load, after an upload, and on `visibilitychange` to
      visible; render the line on waiting rows only.
- [x] Tests: `supabase/tests/8-6-...sql` (every DB row, both parentages, both flag-moved-today
      directions, no pairing, the author and the referee reading the same set, ACL both ways);
      `components/today.test.tsx` + lib tests (every UI row, copy asserted by regex in both
      directions — never "waiting", always the holds-anyway clause, no digits, no imperative to
      contact him); `2-1-roles-and-rls.sql`, README, sprint status.

**Acceptance Criteria:**

- Given any fixture, when the author's read and the referee's list run for the same doer and day,
  then they name the same commitments.
- Given every pre-existing SQL file, when run after this migration, then each passes unmodified
  except `2-1-roles-and-rls.sql`.

## Verification

**Commands:**

- `npx supabase db reset`, then every file in `supabase/tests/` — all pass.
- `npm test`, `npx tsc --noEmit`, `npm run lint`, `npm run format:check`, `npm run build` — clean.

**Run 2026-09-29, implementation.**

- `npx supabase db reset`, then all 51 files under `supabase/tests/` — **all pass.**
- `npm test` — 1549 passed, 54 files. `tsc`, `lint`, `format:check`, `build` — clean.

**Mutants watched.** The pairing check dropped from `waiting_on_my_referee()` — `8-6` step 3. Today
keeping an answer read for another day — *"drops yesterday's answer the moment the day turns
over"*. Today not re-reading when shown again — *"goes once the app is shown again after his
referee decided"*.

**One acceptance criterion was off by one file.** It said every pre-existing SQL file passes
unmodified except `2-1-roles-and-rls.sql`. `8-4-what-is-waiting-for-him-today.sql` step 3 asserted
that `referee_waiting_today()`'s *text* names `photograph_reaches_the_referee` — and moving the gate
into the shared definition is this story's whole design, so the call now lives one step down. That
assertion now checks both steps: the list names `commitment_days_waiting_on_referee`, and the
definition names the predicate. Its intent is kept; step 1 of the same file — the exact rows the
list returns — passes unmodified, which is what proves the list returns what it did.

**Placement.** The line sits under the kept photo on an untimed row and under "claimed and proven"
on a timed one: the only timed state in which a photograph exists.

## Review — 2026-09-29

Three layers. Verification-gap found nothing; blind and edge-case found the rest. **No
`intent_gap` and no `bad_spec`.** Patched:

- **The two sides could disagree after all.** The author's read checked `referee_of` alone; the
  referee's list also requires the role. A pairing row whose role had moved would tell the author
  his referee had not looked while his referee was shown nothing — the one disagreement this
  story's single definition exists to rule out. The author's side now asks the role too; `8-6`
  step 3(a) covers it and was watched to fail without it.
- **The day stamp was the device's.** `waiting_on_my_referee()` now returns the day it answered
  for, and Today stamps with that, so a read sent at 23:59:59 and answered after midnight cannot
  put yesterday's rows on today's screen.
- **A timed proof attached this session** left the row reading "claimed" until a full reload, so
  the "just attached" row failed for timed commitments. The line now follows the server's answer
  in that branch too.
- **One dropped request no longer takes the line away** — a failed re-read keeps the same day's
  answer. `pageshow` from the back/forward cache re-reads as `visibilitychange` does. The line is
  `role="status"`, so it is announced when it appears after an upload.
- **Tests:** a flagged, signed-off, photographed row the server did not name shows nothing — the
  case that proves the line comes only from the answer; the visibility override is a spy that is
  restored; the rollover test asserts the row is still there while the line is gone and awaits its
  release; an answer stamped with another day is never shown; a mixed answer keeps its well-formed
  rows. SQL gains yesterday's photo, another doer's day, the referee asking the author's read, and
  the moved role.
- `NO_WAITING` had been inserted between `Today`'s doc comment and the function it documents.

Rejected: the copy's wording and its "he" — approved as written, and the product's referee copy
says "he" throughout; logging a failed read — the other silent reads on this screen do not; a line
shown under a row whose photos failed to *display* — the server's answer is about what exists, not
what loaded.

After the patches: all 51 SQL files, 1553 unit tests, `tsc`, `lint`, `format:check`, `build` —
clean.

## Suggested Review Order

**One definition, two readers**

- "Waiting on the referee", said once.
  [`20260929110000:36`](../../supabase/migrations/20260929110000_today_says_the_day_is_waiting_on_his_friend.sql#L36)

- The referee's list, re-created on it with its columns unchanged.
  [`20260929110000:73`](../../supabase/migrations/20260929110000_today_says_the_day_is_waiting_on_his_friend.sql#L73)

- The author's read: himself, today, stamped with the server's day.
  [`20260929110000:144`](../../supabase/migrations/20260929110000_today_says_the_day_is_waiting_on_his_friend.sql#L144)

- The pairing asked the way the referee's side asks it — role included.
  [`20260929110000:161`](../../supabase/migrations/20260929110000_today_says_the_day_is_waiting_on_his_friend.sql#L161)

**What Today says, and when**

- The copy, and why it never says "waiting".
  [`referee-waiting.ts:69`](../../lib/referee-waiting.ts#L69)

- The read: server-stamped, `null` on failure.
  [`referee-waiting.ts:36`](../../lib/referee-waiting.ts#L36)

- Re-read when shown again, including from the back/forward cache.
  [`today.tsx:479`](../../components/today.tsx#L479)

- A failed re-read keeps what it had.
  [`today.tsx:503`](../../components/today.tsx#L503)

- A stale day is discarded, never shown.
  [`today.tsx:515`](../../components/today.tsx#L515)

**The proofs**

- The author and the referee name the same set.
  [`8-6-…sql:250`](../../supabase/tests/8-6-today-says-the-day-is-waiting-on-his-friend.sql#L250)

- Nobody to wait on, two ways.
  [`8-6-…sql:263`](../../supabase/tests/8-6-today-says-the-day-is-waiting-on-his-friend.sql#L263)

- Every UI row of the matrix.
  [`today.test.tsx:1784`](../../components/today.test.tsx#L1784)

- The one assertion 8-4 had to move one step down.
  [`8-4-…sql:439`](../../supabase/tests/8-4-what-is-waiting-for-him-today.sql#L439)
