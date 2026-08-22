# Epic 3 Context: Work with no finish line, and weeks that hold

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Let the author commit to *time* rather than completion, and close the two cadences Epic 2 left open.
Open-ended work — company work, three hours a day — has no finish line and cannot be ticked honestly,
so it is committed to as accumulated minutes banked through Focus Sessions; the failure being
addressed is *starting*, not finishing. Alongside it, the weekly quota gets arithmetic instead of a
silent deadline — it grows louder as sessions remaining approach days remaining — and the week gets
its own settlement point. A Settings surface opens the epic, because the morning hour it exposes is
what the reminders in every later story schedule against, and the product currently has no way to
move it or see what's switched off.

## Stories

- Story 3.0: Change the hour I am asked, and see what is switched off
- Story 3.1: Start the work by starting a clock
- Story 3.2: Know where the hours stand without opening anything
- Story 3.3: A weekly quota that counts down
- Story 3.4: The week closes and settles

## Requirements & Constraints

- **A session is deliberately unpoliced.** Pressing start counts; nothing detects leaving or asks
  whether he's still working. Accepted knowingly — a timer that punishes checking a message is one he
  stops starting — and it is exactly why timer-backed work carries no Penalty.
- Only one session runs at a time. Sessions survive backgrounding and lock, bank elapsed minutes on
  stop, accumulate across multiple sessions in a day, and must bank correctly if the app is killed
  mid-session.
- **A weekly quota cannot fail mid-week.** 0 of 3 on a Tuesday is not a miss; no reminder may frame a
  mid-week shortfall as a failure. It is judged only at Week Close, where a shortfall produces one
  Failed-Day-equivalent penalty for the week — not one per missed day.
- **Two distinct quota pipelines — do not conflate them.** A Weekly Quota commitment (e.g. gym, 3×/week)
  is judged by *counting qualifying days*, each filed through the ordinary Declaration or Auto-check
  exactly like a Daily commitment, against the target count and week start day stored on the commitment
  (FR-1). A Daily Hours Quota commitment (company work) is judged by *summing banked minutes* from
  Focus Sessions (3.1/3.2) against a target duration. FR-4's "sessions remaining" for a Weekly Quota
  commitment means qualifying-day occurrences, not the Focus Session entity — the shared word is a
  naming collision, not a shared pipeline. 3.3 has no dependency on Focus Session data.
- Reminder frequency and urgency for a Weekly Quota commitment increase as sessions remaining approach
  (per the PRD consequence, specifically when equal to) days remaining — escalation is computed by
  settlement and stored as notification-schedule rows (AD-11), never decided client-side.
- **Quota legibility without opening the app (FR-12, NFR1).** Banked-vs-target progress for a Daily
  Hours Quota commitment must be readable from the notification itself. The running-session screen, if
  opened, shows the day's *total* and a progress bar, not just the current session.
- **Unstarted-work prompt (FR-5).** No minutes banked by a configured hour triggers a one-action
  notification. Literal template, self-dated so a stale lock-screen copy can be told from a fresh one:
  `<name>, <banked> of <target>, as of <time>.` — e.g. `Company work, 0:00 of 3:00, as of 10:20.` before
  the first session, `Company work, 0:50 of 3:00, as of 12:40.` once something is banked. Nothing sends
  once the target is met that day.
- Week Close arrives as a notification first, verdict in one line, screen as the detail behind it.
- The morning hour is writable by the author and validated in the database, not the form alone; the
  gate and its reminders follow it. Settings shows notification-permission and install state with what
  breaks if each is off, in plain language — install state matters most, since no install means no push
  means no product.
- Rows Settings can't yet fill (referee pairing, grace days) are absent, not shown empty/disabled, with
  a record of which later story brings each one.
- Offline observations queue locally and reconcile without duplicating; replaying the queue produces
  one session, not two.

## Technical Decisions

- **The server is the sole judge.** The client submits `focus.started`/`focus.stopped` observations and
  never computes quota position, a verdict, or a penalty.
- **An event belongs to the day of its start instant** (AD-14): a 23:50–00:20 session accrues wholly to
  the start day — under a flat penalty, the difference between a Failed Day and a clean one.
- **`Asia/Ho_Chi_Minh` owns every boundary** (AD-6): day, week and 48-hour. Clients send instants; the
  server derives days. Storage is `timestamptz`.
- **Week settlement is one plpgsql function invoked by `pg_cron` in one transaction** (AD-2), named
  `settle_week()`, idempotent on `(subject, period, settlement_kind)` (AD-5). Refuses to run outside
  schedule without an override, rejected for the live doer account (AD-16). Schema/function changes are
  numbered migrations.
- **Every derived value has exactly one writer: settlement** (AD-8) — quota progress, chains, penalties,
  ledger state.
- **Nothing outbound leaves settlement** (AD-3): verdicts and notifications write to the outbox in the
  same transaction; a `pg_net`-woken worker drains it, and every effect is dedupe-keyed and safe twice.
- **Notification lifecycle lives in the database** (AD-11): due time, re-delivery schedule, satisfied-at.
  Escalating quota reminders and the unstarted-work prompt are rows, not client-side timers.
- **Every submitted event carries a client-generated idempotency key created at action time** (AD-4).
- **Penalty resolution is a single guarded transition, first writer wins** (AD-15). Week Close both
  judges quotas and resolves outstanding Held Penalties — one of the two racers this rule exists for.
- RLS expresses authorization on every table (AD-7); the morning-hour write goes through the author's
  own profile grant.
- Money is integer đồng, never float. Copy originates in the experience spec; every visual value
  resolves to a named token.
- Device/browser-dependent behaviour (permission state, install state) is extracted into a pure
  function and tested there, never left inside a component only a real device can exercise.

## UX & Interaction Patterns

- Focus Session labels are plain-language: start reads **Start the clock**; the day total reads
  **Banked today**; stop reads **Stop and bank it** — the screen's one filled action button. Starting a
  second session while one runs says so out loud: *"A clock is already running on another commitment.
  Stop that one first."*
- The running-session screen states plainly it keeps running while locked and watches nothing.
- **Urgent is not failure.** Urgent means *sort this out*; failed means *you lost this* — distinguishable
  at a glance. A quota pill in the urgent family carries position and days remaining as text
  (`1/3 · 3 days`) so colour is never the sole carrier. Pills are never interactive, never a button fill;
  rows stay untinted.
- `figure` type is reserved to exactly two elements product-wide; the running timer is the second (the
  debt total is the first).
- The morning slot belongs to the Declaration; quota reminders and focus prompts never occupy it. Every
  notification offers at most one action and is fully legible on the lock screen.
- Under Reduce Motion, the quota bar snaps rather than fills and the timer updates without animation —
  the only motion in the product; disabling it must not freeze mid-fill.
- The Epic 2 accessibility floor (Dynamic Type, 44×44pt targets, AA contrast for any new token pair) is
  inherited, not re-litigated.

## Cross-Story Dependencies

- **3.0 comes first**: 3.2 and 3.3 schedule reminders against the hour it makes configurable.
- **3.1 → 3.2**: banked minutes must exist before progress against a target can be shown or a
  not-started prompt justified.
- **3.3 → 3.4**: the weekly quota position must exist before Week Close can judge it. 3.3 does not
  depend on 3.1/3.2 — it counts qualifying days, not banked minutes.
- **Depends on Epic 2** for the settlement engine, event log, outbox/worker, notification lifecycle
  rows, the row and status-pill components, and commitment configuration — a Weekly Quota commitment's
  target count and week start day, and a Daily Hours Quota commitment's target minutes, are stored
  there.
- **Depends on Epic 1** for the proven push channel and token layer.
- **Reaches into Epic 4**: Week Close resolves outstanding Held Penalties, but Held Penalties only exist
  once Appeals do. The resolution path is built here; it has nothing to resolve until then.
- Settings rows for referee pairing and grace days are deliberately deferred to Epic 4 and Epic 5.
