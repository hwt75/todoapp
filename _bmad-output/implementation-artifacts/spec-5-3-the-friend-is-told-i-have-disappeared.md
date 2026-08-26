---
title: 'Story 5.3 — The friend is told I have disappeared'
type: 'feature'
created: '2026-08-26'
status: 'done'
review_loop_iteration: 0
baseline_commit: '8684618859caea13f1c1d546209ab0771e2db156'
story_key: '5-3-the-friend-is-told-i-have-disappeared'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-18 — a Silence episode (Story 5.2) that outlives its own intervention stays
invisible to the one person who could actually reach out: the Referee gets no signal, and the
author's disappearance keeps looking like a private failure instead of a moment for a friend.

**Approach:** Extend `enqueue_gate_reminders()` again (same hourly pass 5.2 already folded
detection into) to escalate an unsatisfied Silence episode once it reaches 4 consecutive quiet
days: stamp `silence_episode.escalated_at`, then enqueue an **email** through a new `channel` on
the existing outbox rather than a parallel queue. A new `email-worker` Edge Function (mirroring
`outbox-worker`'s shape) drains only that channel via Resend's HTTP API. The Referee's own email
comes from `auth.users` (resolved server-side, never trusted from payload); the recipient is
never the row's `owner_id` (still the doer, for audit/cascade, exactly as every other outbox row
already keys to the account the event is about). `components/referee-home.tsx` reads the same
escalated-and-unsatisfied episode via a new read-only RLS grant to render the state.

## Boundaries & Constraints

**Always:**
- `silence_episode` gains one nullable column, `escalated_at timestamptz` — an `alter table` in
  a new migration, never editing `20260826090000`'s file (AD-8/AD-9: same episode, one more
  lifecycle milestone, not a new verdict/table).
- `outbox` gains `channel public.outbox_channel not null default 'push'` (`enum ('push',
  'email')`). `outbox_enqueue`/`outbox_claim` gain an additional `p_channel` parameter defaulting
  to `'push'` (`create or replace`, backward-compatible — every existing caller keeps working
  unchanged). `outbox_claim(p_batch, p_channel)` filters `where channel = p_channel`, so the push
  and email workers can never claim each other's rows.
- Escalation fires once, at exactly 4 consecutive quiet days counted from the episode's own
  `started_day` (`asked_day - started_day >= 3`), guarded by `escalated_at is null` on both the
  read and the `update ... where` (mirrors `void_expired_appeals.sql`'s guarded-update, no-raise
  convention) — safe under a concurrent second run of the same hourly pass.
- Email payload reuses the outbox's existing `title`/`body`/`sent_at` contract (`title` becomes
  the subject). Body states the actual elapsed day count (not a hardcoded "four") — computed once
  at fire time from `asked_day - started_day + 1`.
- `email-worker` fails loudly (500, no silent drain) when `RESEND_API_KEY` or `RESEND_FROM_EMAIL`
  is unset — same discipline as `outbox-worker`'s VAPID check.
- A new `wake_email_worker()` + `cron.schedule('email-worker', ...)` invokes it hourly (offset
  from `gate-reminders`' own `:05`, e.g. `:55`), reusing the *same* Vault secrets
  (`outbox_worker_key`, `project_url`) `wake_outbox_worker()` already reads — no new Vault entry.
- `silence_episode` gets one new referee-facing RLS policy: `select` where
  `role_from_token()='referee' and escalated_at is not null and satisfied_at is null` — additive,
  in the new migration, alongside (not replacing) the existing doer "read own" policy.
- `components/referee-home.tsx` renders the escalated state alongside (not instead of) its
  existing appeals/penalties content — "adds nothing to his queues" per the AC means no new list
  item, not that it can't coexist with what's already there. No action control, no amount, no
  commitment name.
- README's "Custom SMTP is still coming" line (`README.md:168-169`) and the outbox secrets section
  (`README.md:196-227`) get a third-secret entry for `RESEND_API_KEY`/`RESEND_FROM_EMAIL`,
  mirroring the VAPID block exactly.

**Ask First:** None — email provider (Resend) and threshold (4 days) were both confirmed by the
human before this spec was written.

**Never:**
- No change to how 5.2's own detection or `satisfied_at` trigger work — escalation only reads an
  episode already opened by that code path.
- No second silence-detection re-derivation (e.g. re-checking `commitments_owing()` per day) for
  the escalation threshold — the episode staying open (untouched by the `satisfied_at` trigger)
  already proves continuous silence since `started_day`.
- No push-worker changes beyond the additive `p_channel` parameter — its existing behavior,
  tests, and call site stay byte-identical when the parameter is omitted.
- No Story 5.4 (monthly report) work.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Threshold reached | Open episode, `started_day` 4 quiet days ago, `escalated_at` null | `escalated_at` set once; one `email`-channel outbox row enqueued | N/A |
| Same-hour re-run | Detection re-runs before the next asked-day advances | Guarded update matches 0 rows; no second email enqueued | N/A |
| Declaration lands before threshold | Episode satisfied (5.2's trigger) before day 4 | Escalation never fires — read finds no open episode | N/A |
| Declaration lands after escalation | Episode satisfied after `escalated_at` is set | Referee-home state clears (RLS query returns nothing); no further email | N/A |
| No referee paired | Escalation fires, no `profile` row has `role='referee'` | `email-worker` marks the row `dead`, reason "no referee paired" | N/A |
| Resend API failure | Provider returns non-2xx | Row retried up to the same attempt ceiling as push, then `failed` | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260826090000_the_app_notices_ive_gone_quiet.sql:21-34,127-193` --
  `silence_episode` schema and the streak block in `enqueue_gate_reminders()` this story extends
  a second time; do not edit this file.
- `supabase/migrations/20260819180000_outbox.sql:73-186` -- `outbox` table, `outbox_enqueue`,
  `outbox_claim` -- add `channel` here via new migration's `create or replace`.
- `supabase/migrations/20260819183000_outbox_schedule.sql` -- `wake_outbox_worker()` + its cron;
  the exact shape to clone into `wake_email_worker()`.
- `supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql:56-155` -- referee RLS
  pattern per table, and the "explicit absence" block to extend now that `silence_episode` is no
  longer absent from what referee reads.
- `supabase/functions/outbox-worker/index.ts` -- clone into `supabase/functions/email-worker/`;
  keep the fail-loud env check, `MAX_ATTEMPTS`/retry shape, and `outbox_claim` RPC call
  (`p_channel: 'email'`); replace `web-push` with a `fetch` POST to `https://api.resend.com/emails`
  and replace the `push_subscription` lookup with a referee-profile + `auth.admin.getUserById`
  lookup (recipient is never `row.owner_id`'s own subscriptions).
- `components/referee-home.tsx:20-26,78-238` -- `View` union and load effect; add a
  `goneQuietSince: string | null` (the episode's `started_day`) field to the `ready` state and one
  more query block alongside the existing four.
- `lib/referee.ts:202-213` -- `REFEREE_HOME_COPY`; add the verbatim "gone quiet" string here first.
- `_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md:128,170` --
  copy already present verbatim; read, do not re-author.
- New: `supabase/migrations/<ts>_the_friend_is_told_i_have_disappeared.sql`,
  `supabase/functions/email-worker/index.ts`,
  `supabase/tests/5-3-the-friend-is-told-i-have-disappeared.sql`,
  `components/referee-home.test.tsx` (extend, don't replace).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_the_friend_is_told_i_have_disappeared.sql` -- `escalated_at`
  column, `outbox_channel` enum + `outbox.channel` column, `outbox_enqueue`/`outbox_claim`
  `p_channel` param, escalation block in `enqueue_gate_reminders()`, referee RLS policy on
  `silence_episode`, `wake_email_worker()` + its cron
- [x] `supabase/functions/email-worker/index.ts` -- new function per Code Map
- [x] `lib/referee.ts` -- add the verbatim gone-quiet copy to `REFEREE_HOME_COPY`
- [x] `components/referee-home.tsx` -- new query + `ready` state field + render block
- [x] `README.md` -- document `RESEND_API_KEY`/`RESEND_FROM_EMAIL` alongside the VAPID secrets
- [x] `supabase/tests/5-3-the-friend-is-told-i-have-disappeared.sql` -- proves every I/O Matrix row
  that is server-side behavior
- [x] `components/referee-home.test.tsx` -- the gone-quiet render block

**Acceptance Criteria:**
- Given Silence persists 4 consecutive quiet days, when the hourly pass runs, then the Referee is
  emailed once and the state appears on his home surface, naming the day count, no amount, no
  missed commitment
- Given the escalation, then it asks him for no action and adds no new queue item
- Given any Declaration is answered, then the episode ends (5.2's existing trigger) and the
  home-surface state clears; no further escalation email for that episode

## Design Notes

The email worker's recipient resolution deliberately does not mirror `outbox-worker`'s
`push_subscription` lookup by `owner_id`: that pattern finds *the same account's* devices, but
here the row's `owner_id` (the doer, kept for FK/cascade/audit consistency with every other
outbox row) and the actual recipient (the one `role='referee'` account) are different people.
Resolve the referee independently of the row's `owner_id`.

## Verification

**Commands:**
- `npx supabase db reset && docker exec supabase_db_todoapp psql -v ON_ERROR_STOP=1 <
  supabase/tests/5-3-the-friend-is-told-i-have-disappeared.sql` -- expect every I/O Matrix row to
  pass
- `npm test`, `npx tsc --noEmit`, `npm run lint`, `npm run format:check` -- all clean

**Manual checks (if no CLI):** set `RESEND_API_KEY`/`RESEND_FROM_EMAIL` as function secrets,
manually stamp a `silence_episode` row 4 days old, confirm an email arrives and
`referee-home.tsx` shows the state after next load.

## Suggested Review Order

**Escalation detection (the entry point)**

- The threshold check itself — 4 consecutive quiet days, guarded against the race where a
  Declaration lands mid-check.
  [`20260826100000_..._disappeared.sql:238-288`](../../supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql#L238)

- The guarded update — `escalated_at is null and satisfied_at is null` together, closing the
  gap a concurrent Declaration insert would otherwise leave open.
  [`20260826100000_..._disappeared.sql:264-269`](../../supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql#L264)

**The channel split — why push and email can never cross**

- `outbox_claim` gains `p_channel`, filtering the claim itself rather than trusting either
  worker to self-police which rows it touches.
  [`20260826100000_..._disappeared.sql:102-135`](../../supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql#L102)

- `outbox_enqueue` gains the matching `p_channel`, defaulting `push` so every pre-existing
  caller is untouched.
  [`20260826100000_..._disappeared.sql:64-92`](../../supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql#L64)

**Delivering the email**

- Recipient resolution as a discriminated union — "no referee paired" (terminal) is never
  confused with "resolution failed" (retryable).
  [`email-worker/index.ts:119-147`](../../supabase/functions/email-worker/index.ts#L119)

- The Resend call itself, and where the retry/dead/failed bookkeeping mirrors
  `outbox-worker`'s own shape.
  [`email-worker/index.ts:38-112`](../../supabase/functions/email-worker/index.ts#L38)

**The Referee's own read of the escalated state**

- One additive RLS policy, scoped to exactly `escalated_at is not null and satisfied_at is
  null` — the doer's own "read own" policy is untouched.
  [`20260826100000_..._disappeared.sql:368-376`](../../supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql#L368)

- `email-worker`'s own schedule — same Vault secrets `wake_outbox_worker()` already reads, a
  different hourly slot.
  [`20260826100000_..._disappeared.sql:390-433`](../../supabase/migrations/20260826100000_the_friend_is_told_i_have_disappeared.sql#L390)

**Client surface**

- The day-count helper, deliberately reusing `dayInQuestion()` so the number shown here can
  never drift from the number the email already sent.
  [`referee.ts:228-249`](../../lib/referee.ts#L240)

- The render block — alongside existing appeals/penalties content, no action control, no
  amount, no commitment name.
  [`referee-home.tsx:157-180,366-370`](../../components/referee-home.tsx#L157)

**Peripherals**

- The full I/O Matrix, proven against a real local Postgres, including the channel-isolation
  case the first review pass found untested.
  [`5-3-the-friend-is-told-i-have-disappeared.sql`](../../supabase/tests/5-3-the-friend-is-told-i-have-disappeared.sql)

- The day-count parity tests, and the render-block test.
  [`referee.test.ts`](../../lib/referee.test.ts) ·
  [`referee-home.test.tsx`](../../components/referee-home.test.tsx)

- The third secret, documented alongside VAPID.
  [`README.md`](../../README.md#L196)

