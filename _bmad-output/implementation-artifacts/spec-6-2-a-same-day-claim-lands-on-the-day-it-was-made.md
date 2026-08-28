---
title: 'Story 6.2 — A same-day claim lands on the day it was made'
type: 'feature'
created: '2026-08-28'
status: 'approved'
review_loop_iteration: 0
baseline_commit: '0114c34'
story_key: '6-2-a-same-day-claim-lands-on-the-day-it-was-made'
context:
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/brownfield.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-1-a-commitment-can-carry-a-time-and-a-late-window.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-28 by hwt75** — all four decisions below: the trigger reads the commitment as
> the caller, the cross-account hole is closed here, a late tap is refused at insert, and the
> morning-gate exclusion moves into this story. Frozen from here.

## Intent

**Problem:** Story 6.1 gave a commitment a time of day and a window. Nothing reads either. The only
way to say anything about a commitment is still the morning question, which files against *yesterday*
by definition — so a commitment due at 20:00 today cannot be answered today, and answering it
tomorrow morning is exactly the arrangement the time was supposed to replace.

**Approach:** Teach the day-derivation trigger that a timed commitment is answered on its own day
rather than the day before, give the author somewhere to say so, and stop the morning question from
asking a second time about something already claimed. The claim travels the existing offline path
unchanged: the instant of the tap is what is stored, and what day that instant belongs to is the
server's decision, never the phone's.

This story ends at the claim. No photo, no verdict, no reminder — a claimed day is not yet a held
day, and nothing here changes what settlement concludes.

## Boundaries & Constraints

**Always:**
- The instant stored is the instant he tapped, never the instant it arrived (AD-6). A claim made at
  20:14 in a tunnel and flushed at 09:00 the next morning is a claim for 20:14.
- The day is derived by the server from that instant. No client sends a date, and no client decides
  which day its own claim belongs to (AD-6).
- Flushing twice produces one row. The idempotency key is generated at the tap and reused by every
  retry (AD-4).
- An untimed commitment behaves exactly as it does today: answered the next morning, filed against
  yesterday, three days to answer. Nothing in this story may change what one of those does.

**Ask First:**
- Any second copy of the dedupe-and-flush loop. It currently lives inside
  `components/morning-gate.tsx`; a Today surface that needs the same behaviour must share it, not
  copy it. `lib/offline-queue.ts` says in its own header that two implementations of "flushing twice
  produces one row" would drift, and the drift would be invisible until it cost money.
- Any change to `public.commitments_owing()`. That function is what settlement, penalties, expiry and
  the day summary all read — it decides what is *true*, and it belongs to Story 6.4. This story
  changes only what the client *asks* (see decision 4).

**Never:**
- Do not judge anything. Whether a claim was inside its window is settlement's conclusion, not this
  story's, and derived state has exactly one writer (AD-8).
- Do not make `declaration_derive_day()` `security definer`. It must read the commitment as the
  caller, or it becomes a way to derive a day from a row the caller does not own.
- Do not add a column the client fills in to say "this one is same-day". A flag the client controls
  is a date the client derives, wearing a different hat.
- Do not touch `EXPIRY_DAYS` or `declaration_deadline()`. A timed commitment's deadline is Story 6.4.

## The four decisions worth your attention

**1. The trigger has to read the commitment, and that is the least-bad option.**
`declaration_derive_day()` is currently pure: `for_day := (answered_at at HCM)::date - 1`, no table
access. To branch it must know whether the referenced commitment carries a `due_time`, which means a
`select` against `public.commitment` on the insert path.

The two alternatives are worse. Letting the client send `for_day` breaks AD-6 outright. Adding a
client-set boolean is the same thing with a longer name — the client would be deciding which day its
own claim lands on, and a client that can pick its day can pick a day whose window is still open.

So: the trigger reads the commitment, stays `set search_path = ''`, and stays **invoker-rights**. Not
`security definer` — under RLS the caller can only see commitments it owns, and that is exactly the
check we want on this path rather than one written by hand.

**2. Nothing currently stops a declaration naming someone else's commitment.**
Found while reading for decision 1, and it is not caused by this story. `declaration`'s insert policy
checks `auth.uid() = owner_id and role_from_table() = 'doer'` and never checks that
`commitment_id` belongs to that owner. Once the trigger reads the commitment as the caller, a
declaration against a commitment the caller cannot see gets `not found` and the trigger can refuse —
which closes the hole as a side effect of decision 1 rather than by a separate policy.

**Settled: closed here, and said out loud**, since this story is already editing that exact
trigger. The alternative is filing it in `deferred-work.md` and leaving a cross-account write path
open for the sake of scope purity.

**3. A claim filed after the window has shut: refused, or accepted and judged late?**
This is the decision that changes what a late tap costs, and neither answer is comfortable.

*Accept it, let 6.4 judge:* purest against AD-8 — settlement is the only judge, `answered_at` already
carries the moment, and nothing is thrown away. But follow it through. A commitment due at 20:00
with a 30-minute window, claimed at 00:05: the trigger derives **tomorrow**, so today gets no claim
and fails — and tomorrow's slot is now occupied by a claim made before tomorrow's window even opened,
which 6.4 will also read as a miss. `declaration_one_per_commitment_day` means he cannot file again
at 20:05 tomorrow. **Five minutes late costs two days.**

*Refuse it at insert:* the trigger raises when the tap falls outside the commitment's window on the
day it derives. One day is lost instead of two, and the refusal is immediate and legible instead of
arriving at day close. The cost is that a genuine act goes unrecorded — but the record that matters
is the photo, and the photo has its own path in 6.3.

**Settled: refuse.** A rule that quietly charges for a day the author never got to attempt is
worse than one that says no at the moment of the tap.

**4. The morning gate must stop asking, and that is scope this story did not claim.**
`stories.yaml` puts the gate exclusion in 6.4. It cannot wait there. The morning gate draws its
questions from `commitmentsOwing()` in `lib/declaration.ts`, which filters on cadence and knows
nothing about a due time. Ship 6.2 without changing it and the author who claimed his 20:00
commitment today is asked about it again tomorrow morning — and his answer collides with
`declaration_one_per_commitment_day` on a row he cannot see.

The split that holds: **`lib/declaration.ts` decides what to *ask* and moves now; `public.commitments_owing()` decides what is *true* and stays in 6.4.** That division is already written
into the comment above `commitments_owing()` in `20260819220000_settlement.sql`, so this follows the
seam the code already has rather than cutting a new one.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Untimed commitment, morning answer | Tap at 07:30 on D+1 | `for_day` = D. Unchanged in every respect | — |
| Timed commitment, claim inside window | Due 20:00 +30, tap 20:14 on D | `for_day` = D | — |
| Timed, tap at the first instant of the window | Tap exactly 20:00:00 | Accepted, `for_day` = D | — |
| Timed, tap at the last instant | Tap 20:29:59 | Accepted | — |
| Timed, tap after the window | Tap 20:31 | **Refused** (decision 3) | Trigger raises; the form says the window has shut |
| Timed, tap before the window opens | Tap 06:00 for a 20:00 commitment | **Refused** | Same rule, other side |
| Claim made offline, flushed next day | Tap 20:14 on D, flush 09:00 on D+1 | `for_day` = D — the tap is what dates it | Queue holds it; `answeredAt` is the tap |
| Same claim flushed twice | Same idempotency key | One row; second is a no-op | `23505` classified as a duplicate, not a conflict |
| Two devices claim the same commitment and day | Different keys | One row; the second is a conflict, not a duplicate | Existing `classifyConflict()` path, unchanged |
| Morning gate, day after a timed claim | Gate opens on D+1 | The timed commitment is **not** asked about | Excluded by `commitmentsOwing()` (decision 4) |
| Declaration naming another account's commitment | Any | **Refused** | Trigger cannot see the row and raises (decision 2) |
| Timed commitment with a window that has not opened yet today | Today surface | No claim control offered yet | Presentation only; the trigger refuses regardless |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819200000_declaration.sql` — `declaration_derive_day()`, the
  `declaration_one_per_commitment_day` unique constraint, and the insert policy that never checks
  commitment ownership. All three are read carefully before anything is written.
- `supabase/migrations/20260819220000_settlement.sql` — `commitments_owing()` and, above it, the
  comment stating the client keeps its own copy because it decides what to *ask*, not what is
  *true*. That sentence is the seam decision 4 follows.
- `lib/declaration.ts` — `commitmentsOwing()`, `isDeclared()`, `dayInQuestion()`, `calendarMoment()`.
  The asking side, and the only file in this story that decides what a question is.
- `lib/declaration-submit.ts` — `classifyWriteError()`, `classifyConflict()`, and the day-turnover
  guard. A same-day claim reuses all of it; none of it changes shape.
- `lib/offline-queue.ts` — `QueuedDeclaration` already carries `answeredAt` and an idempotency key,
  which is everything a timed claim needs. **The module does not change.**
- `components/morning-gate.tsx` — the flush loop that must be shared rather than copied, and the
  reference for how a write result is classified and reported.
- `components/today.tsx` — already loads every unarchived commitment; the claim control goes here.
- `supabase/tests/2-4-*.sql`, `supabase/tests/README.md` — the form the new database check takes.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_a_claim_lands_on_the_day_it_was_made.sql` — rewrite
  `declaration_derive_day()` to read the referenced commitment, derive the current local day for a
  timed one and the previous day for every other, refuse a commitment the caller cannot see, and
  refuse a tap outside the window. Comments carry the reason the function is not `security definer`
  and the reason a late tap is refused rather than judged.
- [x] `lib/declaration.ts` — `commitmentsOwing()` stops asking about timed commitments; a predicate
  for it that says why, next to `isDeclared()`.
- [x] `lib/declaration.test.ts` — the morning gate no longer asks about a timed commitment, and
  still asks about every other kind, including on both sides of the archive boundary.
- [x] A shared claim-submission path — extracted from `components/morning-gate.tsx` so the gate and
  Today run one implementation of enqueue, flush, classify and remove. Its own test file.
- [x] `components/today.tsx` — a claim control on a timed commitment, and what it says when the
  server refuses a late tap. States beyond "can claim / cannot claim" belong to Story 6.5.
- [x] `components/today.test.tsx` — the control appears for a timed commitment and not for an
  untimed one; a refusal is reported rather than reported as saved.
- [x] `supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql` — both derivations, both window
  boundaries, the cross-account refusal, and that an offline claim is dated by its tap.

**Acceptance Criteria:**
- Given a timed commitment due at 20:00 with a 30-minute window, when a claim is filed at 20:14 on
  day D, then `for_day` is D.
- Given an untimed commitment, when the morning answer is filed at 07:30 on day D+1, then `for_day`
  is D, exactly as before this story.
- Given the same timed commitment, when a claim is filed at 20:31, then the server refuses it and the
  author is told the window has shut — not told it was saved.
- Given a claim tapped at 20:14 with no connection, when it flushes at 09:00 the next morning, then
  `for_day` is D and the recorded instant is 20:14.
- Given that claim flushing twice, then one row exists and the second attempt is reported as a
  duplicate rather than as a conflict.
- Given a timed commitment claimed on day D, when the morning gate opens on D+1, then it is not among
  the questions asked.
- Given a declaration naming a commitment belonging to another account, then the server refuses it.

## Verification gate — settled before this story starts

The trigger rewritten here decides which day **every** declaration in the product belongs to,
including every untimed one. It cannot fail visibly: a wrong branch writes `for_day` off by one, the
row looks entirely normal, and the day it belongs to is wrong everywhere downstream — settlement,
chains, penalties, the ledger. Story 6.1 could defensibly ship with its checks unrun, because a
constraint that fails to refuse leaves a visibly wrong row. This one could not.

So it was settled first, and it needed no decision. Docker 29.5.3 is installed and running on this
machine and `npx supabase` works — the Epic 2 retrospective's note that neither existed here was
stale. The local stack now runs database-only, and every file under `supabase/tests/` passes against
it, including Story 6.1's.

```
npx supabase start -x gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
npx supabase db reset
docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql
```

**This story's database check must pass before it is closed.** That is now an ordinary requirement
rather than an aspiration, and the same is true of every story after it.

## Close — 2026-08-28

**Everything ran, and everything passed.** `npm test` — 1136 tests across 47 files.
`supabase/tests/6-2-a-claim-lands-on-the-day-it-was-made.sql` passed all six steps on a real
database, and all 32 files under `supabase/tests/` were then run against the same database with
the new trigger in place: **32 pass, 0 fail**. The rewrite of the function that decides which day
every declaration in the product belongs to breaks nothing that came before it. `tsc --noEmit`,
`eslint` and `prettier --check` are clean.

The database check drove both edges of the window from the server side — 20:00:00 and 20:29:59
accepted, 20:30:00, 20:31 and 06:00 refused — plus the untimed derivation, an offline claim dated
by its tap, the cross-account refusal, and the machine-filed row keeping its own branch.

**Three things the work found that the spec did not anticipate:**

1. **Today may not read `declaration`, and a test already said so.** The claim control was first
   built to hide itself for a commitment already claimed today, which meant reading that table.
   `components/today.test.tsx` asserts `expect(seen).not.toContain('declaration')` — one source
   for a position, never a client-side tally of raw rows (AD-8). The read was removed rather than
   the guard relaxed. The consequence is stated below.
2. **A machine-filed declaration on a timed commitment had no defined meaning.** The combination
   is reachable — a timed commitment may carry an Auto-check — and `file_auto_check_result()`
   files at an arbitrary resolve instant, which a same-day derivation would date wrongly. The
   machine branch was left exactly as it was and the choice is asserted in step 6 of the database
   check, so changing it in Story 6.4 is a deliberate act with a failing test rather than a silent
   drift. Recorded as an open question on `SPEC.md`.
3. **`QueuedClaim` needed a `timed` flag that never reaches the server.** The duplicate-versus-
   conflict read has to look on the day the server chose, and that day is now one of two. The flag
   lives on an interface in `lib/declaration-write.ts` rather than in `lib/offline-queue.ts`, which
   stays generic and unchanged, and it is absent on items queued before this story — all of which
   were untimed, so the falsy default is also the correct one.

**Known gap, deliberately left for Story 6.5.** Because this screen cannot read `declaration`, the
claim control is offered again after a reload for a commitment already claimed today, and the
second tap is refused by `declaration_one_per_commitment_day` with a sentence saying the day is
already answered. Legible, but not what the screen should say. Story 6.5 is where a window's real
state — ahead, open, shut, claimed — gets a source it can read.

**Still true:** the migration is applied locally only. `npm run migrations:check` fails with
`LegacyProjectNotLinkedError` and the author's own project has not received either of this epic's
migrations.
