---
title: 'Story 3.1 — Start the work by starting a clock'
type: 'feature'
created: '2026-08-20'
status: 'done'
baseline_commit: 'a799d7f98a7ae59fdf0bb313459948ef55c9503b'
review_loop_iteration: 0
story_key: '3-1-start-the-work-by-starting-a-clock'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-20 by tmtuan123** — all six decisions, and the full spec kept rather than split.
> It runs to roughly 4,300 tokens against the workflow's 1,600 proposal; the scope standard only
> splits a spec carrying two independently shippable deliverables, and this is one goal reaching
> across the database, `lib/` and one surface. Frozen from here.
>
> Stamped in its own commit, before any implementation, as Story 3.0 was (retro P2b).

## Intent

**Problem:** The one kind of work the author actually avoids — company work, three hours a day —
cannot be committed to at all. `cadence = 'daily_hours_quota'` and `daily_minutes_target` have
existed since `20260819150000_commitment.sql:33`, and both `commitments_owing()` and the reminder
path deliberately exclude that cadence with the comment that *the timer answers it*
(`20260819220000_settlement.sql:81-83`, `20260819210000_gate_reminder.sql:63`). There is no timer.
So an hours-quota commitment can be created, is asked nothing, is measured by nothing, and shows a
target it has no way to reach — `lib/declaration.ts:74-81` says so in its own doc comment.

**Approach:** A session is a **recorded start instant, not a running process**. Tapping start writes
`{key, commitmentId, startedAt}` to local storage and nothing else; the screen renders `now −
startedAt`. Tapping *Stop and bank it* inserts one row carrying both instants, and the database
derives the day and the minutes. Nothing has to survive backgrounding because nothing is running —
which is also why nothing can pause it, flag it, or ask whether he is still working.

## Decisions

### D1. The session is a fact, not a timer

The acceptance criteria ask for a session that continues while backgrounded and while the phone is
locked, and that nothing invalidates or pauses. The codebase has no wake lock, no background sync
and no page↔service-worker channel (`app/sw.ts` has no `message` listener), and building one to keep
a `setInterval` alive would be building the exact machinery the story forbids using.

**Proposed:** store the start instant; compute elapsed on render. A killed app, a locked phone and a
five-hour background are all the same event — nothing was running, so nothing stopped. The screen
ticks once a second because text has to change, not because time is being counted somewhere.

**Consequence, stated rather than hidden:** the running session lives only in this device's local
storage until it is stopped. If that storage is cleared mid-session the session is gone. The
alternative — insert a row at start and update it at stop — was rejected because it puts an
`update` policy on an insert-only schema, and because a start tapped offline could not be updated
by a stop tapped offline: the queue would carry a correction to a row that does not exist yet.

### D2. One row at stop, and the day comes from the start instant (AD-14)

`declaration` is the shape to copy: a client-generated `idempotency_key uuid not null unique`
(`20260819200000_declaration.sql:53`), the instant sent by the client, and the date derived by a
`before insert` trigger — a generated column is impossible because `at time zone` with a named zone
is STABLE, which `declaration_derive_day()` explains at `20260819200000_declaration.sql:84-86`.

**Proposed:** `focus_session` carries `started_at`, `stopped_at`, and `for_day` set by
`focus_session_derive_day()` to `(started_at at time zone 'Asia/Ho_Chi_Minh')::date` — with **no**
`- 1`, which is the one place this differs from the declaration trigger it is modelled on. A session
from 23:50 to 00:20 is thirty minutes on the day it started, and is never split.

The same trigger refuses a commitment whose cadence is not `daily_hours_quota` and one the inserting
account does not own — it is already looking the row up, and RLS alone would let a valid session
point at somebody else's commitment.

### D3. Minutes are floored once, at the day, not per session

`duration_seconds` is a stored generated column over `stopped_at - started_at` (immutable, unlike
the day). `focus_day_minutes` sums seconds per `(commitment_id, for_day)` and floors once.

Flooring each session instead would silently discard up to 59 seconds per session, so three
twenty-minute sittings could bank 59 minutes of an hour. The total is what the quota is judged
against; it is the thing that must be right.

### D4. The offline queue is widened, not copied

`lib/offline-queue.ts` already holds the two rules this needs — key minted at the tap, and a second
flush producing one row. Only its *type* is declaration-specific.

**Proposed:** make the item type generic over `{ idempotencyKey: string }` and give every function a
**defaulted** key parameter (`QUEUE_KEY` stays the default). Every existing call site and
`lib/offline-queue.test.ts` compile and pass untouched, the way the D3 extraction in Story 3.0 did.
Sessions queue under `todoapp.focus-session-queue.v1`.

### D5. An hours-quota row's tap opens the timer, because it has no chain to open

`components/commitment-row.tsx:84-92` routes every tap to Chains detail. An hours-quota commitment
is excluded from `commitments_owing()`, so it never reaches `settlement_commitment`, so
`chain_current` has nothing for it — its Chains detail is empty by construction.

**Proposed:** Today routes a `daily_hours_quota` row to the Focus Session surface and every other
row to Chains detail, as it does now. No second control, no menu. The fork lives in
`components/today.tsx`, which already selects `cadence`, so `commitment-row.tsx` is not touched at
all. `app/page.tsx` gains a `focusOf` state beside `chainOf`, the same nullable `{id, name}` shape,
and the same `Back to today`.

The day's banked total is shown on the Focus Session surface and nowhere else. Putting it on the
Today row is Story 3.2's criterion, not this one.

### D6. Two missing strings are added to `EXPERIENCE.md` before they are written in a component

UX-DR26 requires user-facing copy to originate there. `EXPERIENCE.md` specifies *Stop and bank it*
(:132-134), the unwatched sentence (:130) and the `0:50 of 3:00` reading (:224-225) — but no start
label and no label for the banked total.

**Proposed:** add **`Start the clock`** and **`Banked today`** to `EXPERIENCE.md` in this story's
commit, then use them. Inventing copy in JSX and backfilling the design doc is how the two documents
stop being one contract.

## Boundaries & Constraints

**Always:**

- The client sends instants and a key. The day, the duration and the daily total are the database's
  (AD-1, AD-6). No client-side minute arithmetic reaches a write — the one place the client adds
  minutes of its own is the displayed total while a stopped session is still queued, and that
  number is never sent anywhere.
- The key is minted when **start** is tapped and reused by every retry (AD-4).
- Copy lives in `lib/`, not in JSX — the rule `lib/settings.ts:12-14` states.
- Every visual value resolves to a token (UX-DR5). The running elapsed claims the second and last
  `figure` role, which `components/debt-block.tsx:5-16` has been holding open for it.
- Stop is the screen's only filled action button and reads *Stop and bank it* (UX-DR6, UX-DR24).

**Ask First:**

- Any cap, warning or auto-stop on a long-running session — see Design Notes.
- Giving `focus_session` an update or delete policy.
- Lifting the `daily_hours_quota` exclusion in `commitments_owing()` or `enqueue_gate_reminders()`.
  Measuring the quota is Story 3.2; judging it is Story 3.4. This story banks minutes and stops.
- A notification of any kind. The morning slot belongs to the Declaration (UX-DR27).

**Never:**

- Anything that detects, pauses, invalidates or flags a session for inattention — no
  `visibilitychange` handler, no wake lock, no heartbeat.
- Splitting a session across midnight.
- A second copy of the queue's dedupe or flush logic.
- CSS animation or a transition. There is none in the product, there is no motion token to resolve
  against, and none is needed (NFR13 holds by construction).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
| --- | --- | --- | --- |
| Start tapped | Hours-quota commitment, nothing running | Key + `startedAt` written locally; screen shows the elapsed figure and the unwatched sentence | N/A |
| App killed, phone locked, or three hours backgrounded | A start instant is recorded | Reopening shows the same session still running, elapsed from the original instant | N/A |
| *Stop and bank it* | Session running 50 minutes | One row; `for_day` from `started_at`; day total rises by 50; local record cleared | N/A |
| Two sessions in one day | 20 min, then 40 min | Day total reads 60 — summed and floored once, not per session | N/A |
| 23:50 → 00:20 | Crosses midnight | 30 minutes, wholly on the start day (AD-14) | N/A |
| Stopped with no network | Offline | Queued under its own key; the day total shown adds the queued minutes to what the view returns, so the screen does not lose time it has been told about | Replayed on the next flush; `23505` counts as delivered |
| Queue flushed twice | Same key twice | One row | Unique violation classified `duplicate`, item leaves the queue |
| Insert against a non-hours-quota commitment | `cadence = 'daily'` | Refused by the trigger | Message names the cadence; nothing is written |
| Insert against a commitment the account does not own | Foreign `commitment_id` | Refused by the trigger | Same |
| `stopped_at <= started_at` | Clock moved backwards | Refused by the check constraint | The refusal is shown; nothing claims to have banked |
| Signed out | No session | The surface is unreachable | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql` (new) — the table,
  its `before insert` trigger, `focus_day_minutes`, RLS and the trailing revoke. Sorts after the
  current last migration `20260820103000_close_penalty_amount_exposure.sql`.
- `supabase/migrations/20260819200000_declaration.sql:53,84-98,104-120` — the shape to copy: unique
  key, derive-day trigger and why it is a trigger, select-own + insert-own policies, no update.
- `supabase/migrations/20260819150000_commitment.sql:11,33,53,66-68` — `commitment_cadence`,
  `daily_minutes_target`, its biconditional check, and the comment that named this story.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:31` — `security_invoker` view
  style for `focus_day_minutes`.
- `supabase/tests/3-1-focus-session.sql` (new) — `begin`/`rollback`, live-doer guard, in-fixture
  grants, numbered steps, `PASS.` notice. Model on `supabase/tests/3-0-morning-hour.sql`.
- `lib/focus-session.ts` (new) — the running-session record, `elapsed`, the `0:50` and
  `0:50 of 3:00` renderings, and the screen's strings. Pure and storage-injected, like
  `lib/offline-queue.ts:17-19`.
- `lib/offline-queue.ts:32,34,50,56,74` — widen the item type and default the key parameter (D4).
- `components/focus-session.tsx` (new) — the surface. `'use client'`, a `View` union, `Back to
  today` first, `role="group"` rows and one `aria-label` per row. Model on `components/settings.tsx`.
- `components/today.tsx:15,40` — already selects `cadence` and `daily_minutes_target`; the tap fork
  lives here (D5). `components/commitment-row.tsx:84-92` is the untouched consumer.
- `app/page.tsx:19-21,61-89` — `focusOf` state and its branch.
- `app/globals.css:321-328` + `app/tokens.css:80-81` — `--type-figure` and how `debt-block-figure`
  spends the first of its two roles.
- `_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md:130,132-134,224-225`
  — the specified copy, and where the two new strings go (D6).

## Tasks & Acceptance

**Execution:**

- [x] `EXPERIENCE.md` — add `Start the clock` and `Banked today` to the Focus Session copy, so the
      component quotes the design doc rather than the other way round (D6).
- [x] `supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql` — table,
      `stopped_at > started_at` check, `duration_seconds` generated column,
      `focus_session_derive_day()` with its cadence and ownership refusals, `focus_day_minutes`
      view, RLS and policies in the same file, trailing revoke.
- [x] `supabase/tests/3-1-focus-session.sql` — the matrix's database rows: day from the start
      instant across midnight, two sessions summing and flooring once, both trigger refusals, the
      check violation, and one account failing to read another's sessions.
- [x] `lib/focus-session.ts` + test — start/read/clear against an injected `Storage`, elapsed across
      a midnight boundary, `0:00`/`0:50`/`10:05` renderings, and `0:50 of 3:00`.
- [x] `lib/offline-queue.ts` + existing test — generic item, defaulted key; `lib/offline-queue.test.ts`
      and `components/morning-gate.tsx` compile and pass **unchanged**.
- [x] `components/focus-session.tsx` + test — idle and running states, the figure, the unwatched
      sentence, the day total read from `focus_day_minutes`, stop banking online and stop queueing
      offline, and a refused insert that does not claim to have banked.
- [x] `components/today.tsx` — fork the row tap on cadence to a new `onOpenFocus`; existing Today
      tests still pass and `commitment-row.tsx` is not touched.
- [x] `app/page.tsx` — `focusOf` branch, `Back to today` returns to Today.

**Acceptance Criteria:**

- Given a *Put hours in* commitment, when I tap it on Today, then the Focus Session surface opens
  and offers `Start the clock`; and when I tap start, then the elapsed figure runs and the screen
  states that it keeps running while the phone is locked and watches nothing.
- Given a running session, when the app is closed and reopened, then the same session is still
  running and its elapsed is measured from the original start instant, with nothing pausing,
  flagging or invalidating it.
- Given a running session, when I tap `Stop and bank it` — the screen's only filled button — then
  the minutes reach that commitment's total for the day the session **started**.
- Given a session stopped without a network, when the queue is later flushed any number of times,
  then exactly one session exists.

## Design Notes

**No cap on a session's length, and that is a decision.** A timer left running overnight banks nine
hours nobody worked. Refusing or clamping it would be the first thing in this product to judge how
the author spends time, and the epic's own premise is that a timer which polices is a timer he stops
starting. A silent clamp is refused outright — `spec-3-0` D1 settled that a value the database
quietly changes is worse than a refusal. So the row is written as tapped. If it bites, the answer is
a visible prompt at stop, not a rule in the schema; recorded here so a future reader knows it was
weighed rather than missed.

**The client's clock is the only clock.** Both instants come from the device, exactly as
`declaration.answered_at` already does. A device whose clock jumps mid-session banks a wrong
duration, and nothing here can detect it.

**What Story 3.2 gets, and why it is not here.** This story renders the day total as text so
accumulation is visible and testable. The progress bar, the notification that prompts an unstarted
quota, and Reduce Motion's snap are 3.2's own acceptance criteria; `focus_day_minutes` is the seam
they read. `commitments_owing()` keeps excluding the cadence until 3.4 judges it.

## Verification

**Commands:**

- `npm test` — expected: the new `lib/focus-session` and `components/focus-session` tests pass
  alongside the existing 512, and `lib/offline-queue.test.ts` passes unmodified.
- `npx tsc --noEmit && npm run lint && npm run format:check` — expected: clean.
- `npx supabase db reset` then
  `docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/3-1-focus-session.sql`
  — expected: `PASS.`
- `docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/2-2-commitment-rules.sql`
  — expected: still `PASS.` Its assertion that an hours quota is never declared
  (`supabase/tests/2-2-commitment-rules.sql:239-252`) must survive this story untouched.

**Manual checks (only the author can do these):**

- Start a session on the installed app, lock the phone, leave it twenty minutes, reopen: the same
  session is still running and reads about twenty minutes, with nothing having asked anything.
- Start a session before midnight and stop it after: the minutes appear on the day it started.

## Verification record

**Built and checked on 2026-08-20**, on the branch this spec was approved on.

`npm test` — 569 passing across 30 files, up from 512. `npx tsc --noEmit`, `npm run lint` and
`npm run format:check` all clean. All eleven files under `supabase/tests/` were re-run against a
local stack and every one reports `PASS.`, including `2-2-commitment-rules.sql` and its assertion
that an hours quota is never declared. `lib/offline-queue.test.ts`'s existing tests and
`components/morning-gate.tsx` are unmodified, which is what D4's defaulted key parameter was for.

**A three-layer review ran against the diff and found fourteen real patch-level issues — no
`intent_gap`, no `bad_spec`.** The two worth naming: a failed read of the day's total was hiding the
Stop control entirely, which broke the frozen matrix row *"Stopped with no network"* outright; and a
tap on Start while another commitment's session was running was a silent no-op, changing nothing and
saying nothing. All fourteen are fixed — a `refused`/`unreadable` split in `View` so a failed read
never hides Stop, `startSession` returning a typed `StartOutcome` so a foreign session is refused out
loud, the day re-derived from the ticking clock so an open screen crosses midnight correctly while a
session runs, every permanent queue rejection surfaced rather than only the one just stopped, the
queue drained on mount and on `online` rather than only on stop, the running figure given
`role="timer"` and an accessible label, every remaining raw error string moved into `FOCUS_COPY`, a
missing `daily_minutes_target` treated as a failure rather than a quieter zero, the figure-role
budget test made to fail in both directions, `setInterval` faked so the ticking figure is actually
exercised rather than snapshotted, the banked read's `.eq` filters asserted rather than assumed, a
test proving the focus queue and the declaration queue never share a key, and a new SQL step proving
the schema — not merely this client — enforces AD-1 and AD-6 against a caller that sends its own day
or its own duration. The new tests were mutation-checked: reverting any one of the day-dependency,
the tick, the `for_day` filter, or the queue-key argument fails the suite, which is what makes a
green run mean something.

**One residual gap, left rather than papered over.** An idle Focus Session screen — nothing running —
left open across local midnight goes on reporting the previous day's total until touched. Fixing it
the way the running case was fixed would mean ticking a timer while idle, which the review's own
finding about an unnecessary interval forbids. Recorded in `deferred-work.md` rather than fixed
silently in one direction and left broken in the other.

## Suggested Review Order

**The database rule (D2, D3): a session is a fact judged by the schema, not by whoever writes it**

- The whole story's central claim: the day comes from `started_at` with no `- 1`, refusing what the
  client sends rather than trusting it (AD-6).
  [`20260820110000_a_session_lands_on_the_day_it_started.sql:90`](../../supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql#L90)

- The table it writes: the unique key (AD-4), the ordering check, and the two columns a client must
  never be trusted to set.
  [`20260820110000_a_session_lands_on_the_day_it_started.sql:19`](../../supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql#L19)

- The seam Story 3.2 and 3.4 will read: seconds exposed alongside minutes so a queued top-up can add
  before flooring once (D3).
  [`20260820110000_a_session_lands_on_the_day_it_started.sql:143`](../../supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql#L143)

- Proof the schema enforces it, not merely this client: a caller sending its own day or its own
  duration is overwritten or refused (review patch 13).
  [`3-1-focus-session.sql:378`](../../supabase/tests/3-1-focus-session.sql#L378)

**The session is a fact, not a process (D1): nothing runs, so nothing can be paused or lost**

- The record start writes, and nothing else — the shape a killed app and a locked phone both
  survive by construction.
  [`focus-session.ts:28`](../../lib/focus-session.ts#L28)

- The refusal a foreign session gets, so a second commitment's Start control never goes silently
  inert (review patch 2).
  [`focus-session.ts:158`](../../lib/focus-session.ts#L158)

- Seconds only on the figure that has to visibly run; every other duration stays `H:MM` (spec
  departure 1).
  [`focus-session.ts:211`](../../lib/focus-session.ts#L211)

- The copy this screen is allowed to say, sourced from `EXPERIENCE.md` before it was written here
  (D6), including the two strings review found missing.
  [`focus-session.ts:64`](../../lib/focus-session.ts#L64)

**The screen (review patches 1, 4–8): every control renders on what it can still do, not on what
failed**

- Where the day is derived from the ticking clock rather than captured once, so an open screen
  crosses midnight correctly.
  [`focus-session.tsx:130`](../../components/focus-session.tsx#L130)

- The one function three different moments call — stop, mount, and the network coming back —
  because a queue that only drains by coincidence is not a queue.
  [`focus-session.tsx:55`](../../components/focus-session.tsx#L55)

- The three-way read outcome (`ready` / `unreadable` / `refused`) that keeps Stop reachable when
  only the total failed to load.
  [`focus-session.tsx:194`](../../components/focus-session.tsx#L194)

**Wiring it into the app: one more row, one more branch, nothing else touched**

- The tap that forks by cadence, so an hours-quota row opens the clock instead of an empty Chains
  detail (D5).
  [`today.tsx:115`](../../components/today.tsx#L115)

- `focusOf` beside `chainOf`, the same shape, the same `Back to today`.
  [`page.tsx:90`](../../app/page.tsx#L90)

**Made generic without being duplicated (D4): the offline queue now serves two callers**

- The type parameter and the defaulted key that let every existing call site compile and pass
  unchanged.
  [`offline-queue.ts:1`](../../lib/offline-queue.ts#L1)

**Tests that can fail (review patches 9–12, mutation-checked)**

- The figure-role budget asserted in both directions, against a pattern a fallback claim cannot
  slip past.
  [`design-tokens.test.ts:200`](../../lib/design-tokens.test.ts#L200)

- Timers faked alongside the clock, so the ticking figure is exercised rather than snapshotted.
  [`focus-session.test.tsx:177`](../../components/focus-session.test.tsx#L177)

**Two departures from the spec's letter, both deliberate.**

- **The running figure reads `H:MM:SS`; every other duration reads `H:MM`.** The spec lists only
  `H:MM` renderings, but in `H:MM` the figure would read `0:00` for a full minute after the tap — on
  the one screen whose entire job is making *starting* feel like it happened. `formatDuration` still
  produces every rendering the spec names; `formatElapsed` adds seconds for the figure alone.
- **`focus_day_minutes` exposes `seconds` beside `minutes`.** The client needs the seconds so that a
  stopped-but-queued session is added before flooring rather than after, which is D3's rule applied
  to the one total the client composes itself.

**One defect found in passing, and fixed.** The figure-role budget guard in `lib/design-tokens.test.ts`
matched `/--type-figure\x08/` — a stray literal backspace byte where a `\b` was meant — so it had
never counted anything and the budget it exists to police was unenforced. It now matches
`var(--type-figure)` exactly, reads 2 (the debt block and this timer) against a cap of 2, and the
budget is closed. The naive fix would have counted `--type-figure-tracking` as a claimant and refused
the timer the role had been held open for.

**One matrix row is satisfied by construction rather than by a test, and is named here rather than
left to be discovered.** *Signed out → the surface is unreachable*: `FocusSession` renders only
inside `app/page.tsx:63`'s `ownerId &&` gate, takes a required `ownerId: string`, and is reachable
only through a Today callback that does not render signed out. Covering it would mean mounting
`Home` behind six mocks to assert an invariant TypeScript already refuses to break — and the same
gate protects the Ledger, Settings and Chains detail with no test either. Worth revisiting as one
test for the gate itself, not as four.

**Left for the author, because no file here can answer it.** Starting a session on the installed
app, locking the phone for twenty minutes and confirming it is still running from the original
instant; and starting before midnight and stopping after, to see the minutes land on the day the
session began. Both are why this story stays at `review` rather than moving itself to `done`.
