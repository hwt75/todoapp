---
title: 'Story 2.4a — The outbox, its worker, and its own schedule'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '2dfa71a'
review_loop_iteration: 0
story_key: '2-4a-the-outbox-and-its-worker'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/story-1-2-findings.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75.** This story exists because the author chose to build the delivery
> mechanism before the screen that depends on it. `SOLUTION-DESIGN.md` sequences it the same way, so
> this corrected an ordering I proposed wrongly rather than changing the plan.

## Intent

**Problem:** Story 1.2 proved that a push reaches the author's locked iPhone. It proved it with a CLI
run by hand, which is not a product. Every notification Epic 2 onwards depends on — the morning gate,
the day summary, the silence intervention — needs delivery that happens without anyone running a
command, and needs it to survive a settlement pass that rolls back.

**Approach:** AD-3, built as written. Settlement never calls out; it inserts into `outbox` in the
same transaction as the verdict. A worker drains the outbox at-least-once, holds the VAPID private
key, and is the only thing that signs a push. The worker is woken by its **own** `pg_cron` schedule
through `pg_net`, not by settlement — because a queue whose only consumer is triggered by its
producer looks exactly like a working system right up until the producer stops.

## What Story 1.2 obliges this one to do

The push proof left two findings that are constraints here, not trivia:

- **`201` means accepted by Apple, not delivered.** The worker must not treat a 2xx as proof the
  author saw anything. It marks the row *sent*, never *seen*.
- **A push can arrive materially late.** One arrived after the phone rejoined Wi-Fi, minutes after it
  was sent. So **every payload carries its own timestamp** and no notification ever says "now", or
  describes a state that may have changed by the time it is read.

## Boundaries & Constraints

**Always:**
- The VAPID private key lives **only** in the worker's own environment. Not in this repository, not
  in a migration, not in a Vercel variable, not in the database outside Vault.
- Every outbox row carries a dedupe key and every effect must be safe to run twice. At-least-once is
  the guarantee; exactly-once is not on offer and pretending otherwise is how duplicates become
  silent.
- A row that fails is left in a state that says *why*, with its attempt count. A queue that drops its
  failures is a queue with no evidence.
- The worker's schedule is independent of settlement's, and stays that way.

**Ask First:**
- Any settlement or application code that sends a push directly. That is the divergence
  `scripts/send-push.mjs` currently is, and it is meant to end with this story.
- Widening the outbox to carry anything other than an effect to perform.

**Never:**
- No client may read or write `outbox`. Not with a policy, not with a view. It is written by
  settlement and drained by the worker, and nothing else touches it.
- No service-role key in the repository. When the worker needs one, it comes from the function's own
  secrets.
- No settlement logic in the worker. It performs effects; it never decides anything.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Settlement enqueues and commits | Verdict + outbox row, one transaction | Worker sends on its next tick | — |
| Settlement rolls back | Transaction aborts | No verdict and no outbox row. Nothing is sent | The whole point of the pattern |
| Worker runs, queue empty | No pending rows | A no-op that costs nothing and logs nothing alarming | — |
| Worker runs twice on one row | Concurrent ticks | The row is claimed once; the second tick sees nothing to do | Claim must be atomic, not read-then-write |
| Push service returns 2xx | Apple accepted | Row marked **sent**, never *delivered* or *seen* | Story 1.2 proved these differ |
| Push service returns 404/410 | Subscription gone | That subscription is marked dead and stops being used | Not a retry. A dead endpoint retried forever is a queue that never drains |
| Push service returns 5xx or times out | Transient | Attempt counted, row retried on a later tick, with a ceiling | Past the ceiling it is a failure with a reason, not an infinite loop |
| No subscription for the account | Never subscribed, or all dead | Row marked undeliverable with that reason | Silently succeeding here would hide a broken channel |
| Payload read late | Arrives minutes after sending | Its own timestamp is in the body | Never "now", never a state that may have moved |
| Client tries to read the outbox | Signed-in account | Nothing. The table is not reachable from PostgREST at all | — |

</frozen-after-approval>

## Code Map

- `scripts/send-push.mjs` -- the CLI that proved the channel. It is the sanctioned AD-3 divergence
  recorded in `deferred-work.md`, and this story is what retires it. Its payload shape and its
  verbatim-status discipline are worth copying into the worker.
- `story-1-2-findings.md` -- rows 1, 2a, 2b and 3, and the constraints above.
- `supabase/migrations/20260819120000_account_and_roles.sql` -- the conventions: table and RLS
  together, `search_path` pinned, `with check` on the table-reading role helper.
- `.env` -- holds the VAPID pair today for the CLI. The public key stays; the private key's home
  becomes the worker's secrets.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_outbox.sql` -- enable `pg_cron` and `pg_net`; `push_subscription`
  (owner, endpoint, keys, `dead_at`) with RLS so an account manages only its own; `outbox` with its
  dedupe key, payload, status, attempt count and last error, and **no policies at all**; the atomic
  claim function; the enqueue function settlement will call.
- [ ] `supabase/functions/outbox-worker/index.ts` -- claims a batch, sends each via Web Push with the
  VAPID key from its own environment, marks sent, dead, or failed-with-reason. Never decides
  anything.
- [ ] `supabase/migrations/<ts>_outbox_schedule.sql` -- the `pg_cron` job that wakes the worker
  through `pg_net`, on its own schedule, reading its authorization from Vault.
- [ ] `components/push-probe.tsx` -- save the subscription to `push_subscription` instead of printing
  it for a human to copy into a file.
- [ ] `lib/outbox.ts` + test -- the payload shape, including the rule that every body carries its own
  timestamp, tested.
- [ ] `README.md` -- the two secrets that live in Supabase and nowhere else, and how to watch the
  queue drain.

**Acceptance Criteria:**
- Given a row enqueued in a transaction that then rolls back, then no row exists and nothing is sent.
- Given an enqueued row and a live subscription, then the worker sends it on its own schedule with no
  settlement pass having run, and the notification reaches the device.
- Given the same dedupe key twice, then one effect is performed.
- Given two workers running concurrently, then a row is claimed exactly once.
- Given a `404` or `410`, then that subscription is marked dead and is not retried.
- Given a signed-in client, then `outbox` is unreachable — no read, no write, not present in the API.
- Given the VAPID private key, then it appears nowhere in the repository, the client bundle, or any
  Vercel variable.

## Design Notes

**Proven end to end on 2026-08-19, on the author's own device.** A row was enqueued and then left
alone. `pg_cron` woke the worker on its own schedule; the worker returned
`{"ok":true,"claimed":1,"sent":1,"dead":0,"failed":0,"retrying":0}`; the row moved to `sent` with one
attempt, a stamped `sent_at` and no error; and the author confirmed the notification arrived on his
phone with the body it was given. The two ticks either side of it claimed nothing, which is the
empty-queue no-op the matrix asks for.

**Nobody ran a command.** That is the whole difference from Story 1.2, which proved Apple would
deliver but proved it with a CLI typed by hand. This proves the machine sends by itself.

The order the failures came in is worth keeping: the worker refused to run with no VAPID key and
returned `500`; the cron job failed nine times in nine minutes naming the missing Vault secrets; and
only once both were configured did a tick succeed. Every stage of not-being-ready announced itself,
which is what AD-3 asks for when it warns that a queue with no consumer looks exactly like a working
system.

**Why the worker is an Edge Function and settlement is not.** The author already chose plpgsql for
settlement because a pass must either complete or roll back entirely, with no HTTP hop where a job
can die after writing money. The same reasoning excludes Postgres from signing VAPID payloads and
parsing push-service responses. The outbox is the seam between those two facts.

**The claim must be atomic.** `select ... for update skip locked` and mark in one statement, not a
read followed by a write. Two ticks overlapping is a normal condition on a schedule, not an
exception, and a read-then-write claim sends the same notification twice on the day the first tick
runs slow.

**Retiring `send-push.mjs` is deliberate but not immediate.** It stays until the worker has been seen
to deliver, because it is the only working channel today and the last thing this story should do is
remove the fallback before the replacement is proven.

## Verification

**Commands:**
- `npm test` -- expected: payload-shape tests alongside the existing 154
- Advisor after applying -- expected: no new lints, and `outbox` flagged by nothing because it has no
  policies *and* no grants
- `select * from cron.job` -- expected: the worker's schedule, independent of any settlement job

**Manual checks:**
- Enqueue a row by hand, wait for a tick, and see the notification arrive on the phone with the queue
  drained and the row marked sent
- Enqueue inside a transaction, roll it back, and confirm nothing arrives
