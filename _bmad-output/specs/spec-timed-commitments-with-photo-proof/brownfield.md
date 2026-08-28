# Brownfield notes

What already exists that this spec lands on, and what each piece forces. Every path is repo-relative. Where a migration is named, that migration is the authority; the TypeScript beside it is a readable copy.

## Reused unchanged

| Thing | Where | Why it matters |
|---|---|---|
| `appeal-evidence` bucket | `supabase/config.toml:132` | Private, 10 MiB, `image/png · image/jpeg · image/heic`. Already the right shape for proof photos. |
| `appeal_evidence` table + object policies | `20260824130000_contest_a_miss_the_machine_got_wrong.sql` | Read access derived from the parent row's `owner_id`, never from a client-supplied value. |
| `appeal_evidence_derive_owner()` | `20260827100000_evidence_must_be_dated_the_day_it_proves.sql` | Overwrites `owner_id` from the parent, and refuses any insert whose `captured_on` is null or ≠ the day being proven. **This trigger is correct and is not changed.** |
| `captured_on` sourcing | `lib/appeal.ts` (`fileCapturedOn`) | Read from `file.lastModified`, not EXIF. No EXIF dependency exists in this repo. |
| Referee evidence viewer | `components/referee-appeal-detail.tsx` | The referee can already see photos. The surface exists; only what it hangs off changes. |
| Offline queue | `lib/offline-queue.ts` | Generic over item type, keyed by idempotency key generated at the tap, stores the instant of the tap. The **claim** uses it as-is. |
| Outbox worker schedule | `20260819183000_outbox_schedule.sql` | Already runs every minute. Delivery latency is not the problem. |
| Grace Day | `lib/grace.ts`, `20260825110000_a_countable_way_to_be_forgiven.sql` | Two per calendar month via `grace_days_per_month()`. Becomes the only remedy for a missed photo — and the reason the new window must not be called "grace". |
| Day freeze | `20260820102000_supersession_freezes_the_day.sql` | A frozen day is closed to new evidence. |

## Must change

**`commitment` — new columns and a constraint**
`20260819150000_commitment.sql` currently carries `kind`, `cadence`, `carries_penalty`, and the three cadence targets. Add the time of day and the late window, plus a check that the window cannot cross midnight. The existing cadence-target constraints are the pattern to copy: which fields must be present is decided by a constraint, never by the form. Mirror the new rules into `lib/commitment.ts` (`CommitmentDraft`, `draftProblems`, `requiredTargets`) the same way — mirror, not enforcement point.

**`declaration_derive_day()` — must branch**
`20260819200000_declaration.sql` computes `new.for_day := ((new.answered_at at time zone 'Asia/Ho_Chi_Minh')::date - 1)` unconditionally. That subtraction is what makes a morning answer refer to yesterday. A same-day claim on a timed commitment must resolve to the *current* local day, so the trigger has to look at the referenced commitment. Left alone, every timed claim files against the wrong day and the unique constraint on `(commitment_id, for_day)` will collide with the previous day's answer.

**`settle_day()` — per-commitment deadline**
`20260819241000_expiry_and_supersession.sql` gates day close on `declaration_deadline(p_day, morning_hour)` = `day + 3` at the account's morning hour, holding the day open while `answered < total and not past_deadline`. A timed commitment's deadline is midnight of its own day. Without this, a forgotten photo leaves the whole day open for three days instead of failing at midnight — which contradicts the spec's central rule.

**`gate_reminder()` — exclude timed commitments**
`20260819210000_gate_reminder.sql` already filters `c.cadence <> 'daily_hours_quota'` for exactly this kind of reason. Timed commitments join that exclusion: their question is not asked the next morning.

**Reminder scheduling — a real gap, not a column**
`gate_reminder` is enqueued by cron **hourly at :05**. A commitment due at 20:30 would first be reminded at 21:05 — after a 30-minute window has already shut. Serving CAP-6 needs either a per-minute enqueuer for timed commitments or a separate schedule alongside the existing one. `20260819221000_settlement_schedule.sql` runs hourly at :15 and the outbox worker every minute; the new job must pick a minute that collides with neither.

**Evidence detached from `appeal`**
`appeal_evidence.appeal_id` is currently the only way a photo can exist. Proof on an ordinary day has no appeal. Whatever shape the detachment takes, three properties must survive: owner is derived server-side from the parent row and never trusted from the client; `captured_on` must equal the day being proven; the bucket stays private with access derived from that ownership.

**Referee objection — new, and the mirror of an existing thing**
`appeal` is the doer contesting the machine: it has a deadline, a ruling function (`rule_appeal()`, `20260825090000_the_referee_rules.sql`), and expiry (`20260824140000_void_expired_appeals.sql`). The objection is the same skeleton pointed the other way — the referee contesting the doer. Build it from that shape rather than inventing a second dispute mechanism. Its deadline, its output, and its interaction with a frozen day are open questions in SPEC.md and must be answered before implementation.

## Accepted consequence

Splitting the claim from the photo protects the claim from a dead network. It does not protect the photo. A commitment done late in the day somewhere without signal, where signal does not return before midnight, still costs the day. This follows directly from "midnight is death" and was chosen knowingly. CAP-8 exists because of it: the cost is stated when the time is set, not discovered at month end.

## Invariants that do not move

- **AD-1** — the server is the sole judge. Client-side checks exist to save a round trip, never to decide.
- **AD-4** — idempotency keys are generated at the moment of the tap and reused by every retry, so a double-tap or a replayed offline write lands once.
- **AD-6** — every boundary resolves in `Asia/Ho_Chi_Minh`. No client ever derives a date for storage. `due_time` is a local time of day, not an instant.
- **AD-8** — settlement is the single writer of derived state. Nothing here writes a verdict.
