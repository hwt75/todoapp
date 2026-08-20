---
title: 'Story 2.5 — The day closes on its own'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '542624f'
review_loop_iteration: 0
story_key: '2-5-the-day-closes-on-its-own'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75.** This is the first story that writes a verdict — the thing money will later
> attach to, in a ledger AD-9 makes append-only. Two rules below exist to stop a development mistake
> becoming a real charge, and one of them changes how every future settlement function is written.
> Read *The rules that outlive this story* first.

## Intent

**Problem:** Nothing judges anything yet. Declarations pile up as observations and Today still says
`Not yet` for a commitment answered an hour ago, because no code has ever decided what an answer
means. A product that takes money for a failed day cannot have "failed" be a thing nobody computed.

**Approach:** One plpgsql function, invoked directly by `pg_cron`, running in one transaction. It
closes a day when every declaration for it has been filed, records a verdict of clean or failed, and
does nothing else. Money is Story 2.6; chains are 2.9. This story establishes what a settled period
*is* and the guards that keep it from being settled twice.

## The rules that outlive this story

**1. A settled period is never re-settled (AD-5).** Settlement is keyed on
`(subject, period, kind)` with a uniqueness constraint, and a re-run is a **no-op, not an update**.
Cron runs overlap, get retried, and get triggered by hand. Under a flat penalty each of those is a
chance to charge twice for one day, and the constraint is what makes that impossible rather than
unlikely.

Late events for a settled period are recorded and ignored for that period's verdict. They are not
lost; they simply do not reopen a closed day.

**2. Development can never write a real verdict (AD-16).** This is the rule that changes how every
later settlement function is written, and it exists because there is exactly one live project and an
append-only ledger that by design cannot be quietly cleaned up.

So `settle_day` refuses to run when called by a client role, unless an explicit override is passed —
and the override is **rejected outright for the live doer account**. Iterating on settlement against
the author's real data has to be impossible, not discouraged. A test account can be settled freely; his
cannot, except by the schedule.

**3. Nothing announces mid-day that the day is lost (FR-10).** The flat penalty has a known side
effect: once the day is known lost, the rest of it has no stakes. Withholding that until Day Close is
what keeps the remaining hours worth anything. So this story enqueues **no notification at all**, and
a settled verdict never becomes visible on a day still in progress.

## Boundaries & Constraints

**Always:**
- One transaction per pass, called directly by `pg_cron`. No settlement logic crosses an HTTP
  boundary (AD-2). If it cannot be done in that transaction it belongs in the outbox.
- Every boundary in `Asia/Ho_Chi_Minh` (AD-6).
- A day closes only when every declared commitment for it has an answer. An unanswered declaration
  leaves the day open — its expiry to a miss under FR-9 is Story 2.7's, not this one's.

**Ask First:**
- Writing a penalty, a chain, or any ledger row. Those are 2.6 and 2.9, and a verdict is enough to
  be wrong about on its own.
- Settling a week. FR-2 judges a weekly quota at Week Close, which is a different pass.

**Never:**
- No notification of any kind from this story. Not a summary, not a warning, not a mid-day hint.
- No update to an existing settlement row. First writer wins; every later one is a no-op that says
  it found the period settled.
- No settlement invoked from application code, ever. The client asks nothing to be judged.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| All declarations filed, none missed | Day complete | Settled `clean` | — |
| All filed, a penalty-carrying one slipped | Day complete | Settled `failed`, missed count recorded | One Failed Day regardless of how many were missed |
| A penalty-free commitment slipped | Day complete | Settled `clean` — it costs nothing by design | Counted, not charged |
| One declaration missing | Day incomplete | Not settled. The day stays open | The expiry is FR-9 and Story 2.7 |
| Pass runs twice on the same day | Already settled | No-op. The row is untouched and the second run says so | Guaranteed by the unique key, not by checking first |
| Two passes overlap | Concurrent | One row. The loser is a no-op | `on conflict do nothing`, never read-then-write |
| Called from the app | Client role, no override | Refused | Settlement is never client-invoked |
| Called by hand with override, test account | Override passed | Runs | This is how it is developed against |
| Called by hand with override, live account | Override passed | **Refused** | AD-16: development can never write a real verdict |
| Day already lost, app opened before close | Mid-day | Nothing says so, nothing is tinted | FR-10 |
| Commitment archived mid-day | Archived after the day | Still judged for that day | The day predates the archive |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819200000_declaration.sql` -- the observations this reads, and the
  `for_day` trigger whose boundary rule it must agree with exactly.
- `lib/declaration.ts` -- `isDeclared` decides which cadences are settled by his word. The settlement
  function repeats that rule in SQL, and the two must not drift.
- `supabase/migrations/20260819210000_gate_reminder.sql` -- the same "who owes an answer" query,
  written once already. Worth factoring into one function both call.
- `lib/commitment-state.ts` -- `stateToday` returns `not_yet` for everything and says in a comment
  that it is the single place that changes when settlement exists. This is that moment.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_settlement.sql` -- `settlement_kind` and `day_verdict` enums; the
  `settlement` table with its `(subject, period, kind)` uniqueness; `is_live_doer` on `profile`; the
  shared "who owes an answer for this day" function that both the reminder and settlement call, so
  the rule exists once; `settle_day(p_day, p_override)` with its AD-16 guards; RLS so an account
  reads its own settlements and writes none.
- [x] `supabase/migrations/<ts>_settlement_schedule.sql` -- the `pg_cron` job, on its own schedule,
  after the day it settles has ended in `Asia/Ho_Chi_Minh`.
- [x] `lib/commitment-state.ts` -- `stateToday` learns to read a settled verdict, and returns
  `not_yet` for any day not yet closed.
- [x] `components/today.tsx` -- shows the settled state where one exists, and nothing different where
  it does not.

**Acceptance Criteria:**
- Given every declaration for a day is filed and one penalty-carrying commitment slipped, when the
  pass runs, then the day is settled `failed` exactly once.
- Given the pass runs again over that day, then nothing changes and the second run reports it found
  the period settled.
- Given two passes racing, then one row exists.
- Given a call from a client role, then it is refused.
- Given a call with the override against the live doer account, then it is refused.
- Given a day with an unanswered declaration, then no settlement row exists for it.
- Given this story, then no row is ever written to `outbox`.

## Design Notes

**Verified against the live project on 2026-08-19, and the best evidence was accidental.** Two test
accounts were prepared with a completed day — one with a penalty-carrying commitment slipped, one
where only a penalty-free commitment slipped — and before any manual run, the `pg_cron` job settled
both at 09:15 on its own. The first account was `failed` with `missed_count` 1; the second `clean`
with 0, because a penalty-free miss costs nothing by design. Three manual passes afterwards each
returned 0, which is AD-5's no-op holding.

Both AD-16 guards were exercised and both refused: a call with no schedule marker and no override,
and an override against an account flagged `is_live_doer`. FR-10 was checked directly — `outbox` is
empty and settlement enqueued nothing at all.

**A type error that applied cleanly and failed later.** `settle_day`'s `CASE` expression resolves to
`text`, and Postgres will not implicitly cast that to an enum on insert. A plain literal in the same
position is fine, which is why `kind` worked and `verdict` did not — and why the migration applied
without complaint and only broke when a pass had a real day to settle. Fixed by an explicit cast in a
follow-up migration.

**The UI tasks in this spec turned out to be nothing, and that is the honest outcome.** The task list
asked `stateToday` to learn to read a settled verdict. It cannot usefully: settlement closes a day
*after* it has ended, and Today shows *today*, so a day on that screen has no verdict by construction.
Forcing a change would have produced code that never runs. `stateToday` keeps returning `not_yet` and
now carries a comment saying why, so a later reader does not think it was forgotten. The verdicts
become visible in the Ledger, which is Story 2.6 — a list of days that have ended.

**Why the "who owes an answer" query is factored out now.** It already exists twice — once in
`lib/declaration.ts` for the client and once inside `enqueue_gate_reminders`. A third copy inside
settlement would be three places that must agree about which cadences are declared and how archiving
interacts with a past day. Two is already one too many; the SQL side should become one function that
both callers use, and the client's copy stays because it decides what to *ask*, not what is *true*.

**`is_live_doer` is a column, not a config value.** AD-16 needs the database itself to know which
account may never be settled by hand. A setting in an environment file would be absent exactly when
someone is running SQL against production by hand, which is the case it exists for.

## Verification

**Commands:**
- `npm test` -- expected: the state-model change passes alongside the existing 236
- Advisor after applying -- expected: no new lints
- `select * from cron.job` -- expected: a settlement job separate from the outbox worker's

**Manual checks:**
- Settle a test account's completed day twice; confirm one row and a second run that reports a no-op
- Mark a test account live and confirm the override is refused
- Confirm `public.outbox` is empty after a settlement pass
