# Epic 3 Context: Work with no finish line, and weeks that hold

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Let the author commit to *time* rather than completion, and close the two cadences Epic 2 left open.
Open-ended work — company work, three hours a day — has no finish line and cannot be ticked honestly,
so it is committed to as accumulated minutes banked through Focus Sessions. The failure being
addressed is *starting*, not finishing: he opens the laptop and ends up elsewhere. Alongside it, the
weekly quota gets arithmetic instead of a deadline — it grows louder as sessions remaining approach
days remaining — and the week acquires its own settlement point. A Settings surface opens the epic,
because the morning hour it exposes is the hour the reminders in the stories after it are scheduled
against, and because the product currently has no way to move it or to see what is switched off.

## Stories

- Story 3.0: Change the hour I am asked, and see what is switched off
- Story 3.1: Start the work by starting a clock
- Story 3.2: Know where the hours stand without opening anything
- Story 3.3: A weekly quota that counts down
- Story 3.4: The week closes and settles

## Requirements & Constraints

- **A session is deliberately unpoliced.** Pressing start counts. Nothing detects leaving, pauses on a
  switch away, or asks whether he is still working. This is a known loophole, accepted knowingly — a
  timer that punishes checking a message is a timer he stops starting — and it is exactly why
  timer-backed work carries no Penalty.
- Only one session runs at a time. Sessions continue while the app is backgrounded and while the phone
  is locked, bank their elapsed minutes on stop, accumulate across multiple sessions in a day, and must
  bank correctly if the app is killed mid-session.
- **A weekly quota cannot fail mid-week.** 0 of 3 on a Tuesday is not a miss, and no reminder may frame
  a mid-week shortfall as a failure. It is judged only at Week Close, where a shortfall produces a
  Failed Day under the same flat 500,000 VND rule as any other.
- Reminder frequency and urgency increase as sessions remaining approaches days remaining, for Weekly
  Quota commitments.
- **Quota legibility without opening the app (FR-12, NFR1).** Banked-versus-target progress for a
  Daily Hours Quota commitment must be readable from the notification surface itself — a capability
  reachable only by opening the app unprompted does not exist. The running-session screen, when it is
  opened, shows the day's *total* and a progress bar, not only the current session's elapsed time.
- **The unstarted-work prompt (FR-5).** When a Daily Hours Quota commitment has banked no minutes by a
  configured hour, a notification prompts the author to start a session. Like every notification, it
  offers exactly one action — no secondary controls, no dismiss-and-snooze.
- Week Close arrives as a notification first, stating the week's verdict in one line, with the screen
  as the detail behind it.
- The morning hour is writable by the author and validated in the database, not by the form alone; the
  morning gate and its reminders both follow it. Settings shows notification-permission and
  home-screen-install state with what breaks if each is off, in plain language rather than as bare
  toggles — install state being the one that matters most, since without it there is no push and
  without push there is no product.
- Rows Settings cannot yet fill (referee pairing, grace days) are absent rather than shown empty or
  disabled, with a record of which story brings each one.
- Offline observations queue locally and reconcile without duplicating; replaying the queue produces
  one session, not two.

## Technical Decisions

- **The server is the sole judge.** The client submits `focus.started` / `focus.stopped` observations
  and never computes quota position, a verdict, or a penalty.
- **An event belongs to the day containing its start instant** (AD-14). A session from 23:50 to 00:20
  accrues wholly to the start day and is never split across the boundary — under a flat penalty this is
  the difference between a Failed Day and a clean one.
- **One timezone owns every boundary** (AD-6): all day, week and 48-hour boundaries computed in
  `Asia/Ho_Chi_Minh`. Clients send instants; the server derives days. Storage is `timestamptz`.
- **Week settlement is one plpgsql function invoked directly by `pg_cron` in one transaction**
  (AD-2), named `settle_week()` by convention, keyed for idempotency on
  `(subject, period, settlement_kind)` so a retried or overlapping pass is a no-op (AD-5). It refuses
  to run outside its schedule without an explicit override, which is rejected for the live doer
  account (AD-16). All schema and function changes arrive as numbered migrations.
- **Every derived value has exactly one writer, and it is settlement** (AD-8): quota progress, chains,
  penalties, ledger state. Nothing else repairs them.
- **Nothing outbound leaves settlement** (AD-3). Verdicts and their notifications are written to the
  outbox in the same transaction; a worker drained on its own `pg_cron` schedule via `pg_net` sends
  them, and every effect carries a dedupe key and is safe to execute twice.
- **Notification lifecycle state lives in the database** (AD-11) — due time, re-delivery schedule,
  satisfied-at. The client never schedules its own reminders; escalating quota reminders and the
  unstarted-work prompt are rows, not timers on a phone.
- **Every submitted event carries a client-generated idempotency key created at action time** (AD-4),
  reused by retries and enforced unique.
- **Penalty resolution is a single guarded transition** (AD-15) — first writer wins. Week Close both
  judges quotas and resolves outstanding Held Penalties, so it is one of the two racers this rule
  exists for.
- Authorization is expressed in RLS on every table (AD-7); the morning-hour write goes through the
  author's own profile grant.
- Money is stored as integer đồng, never floating point. User-facing strings originate in the
  experience spec; every visual value resolves to a named token, with no literal hex or spacing.
- Behaviour depending on device or browser context — permission state, install state, platform
  capability — is extracted into a pure function and tested there, never left inside a component only a
  real device can exercise.

## UX & Interaction Patterns

- The Focus Session's two labels follow the plain-language rule: the control that opens a session
  reads **Start the clock**, not Start — the thing being started is a clock and nothing else. The
  day's accumulated minutes read **Banked today**, not Total or Progress — *banked* is the word the
  stop control already uses, and it says the minutes are deposited rather than merely observed.
- The stop control reads **Stop and bank it**, not Stop — stopping deposits the time. It is the
  screen's single filled action button, per the one-action-button rule.
- Because only one session runs at a time, starting a second must say so out loud rather than silently
  doing nothing: *"A clock is already running on another commitment. Stop that one first."* — this is
  the one surface whose entire job is making the tap feel like something happened.
- The running-session screen states plainly that the timer keeps running while the phone is locked and
  watches nothing — this is what removes the suspicion that would stop him pressing start.
- **Urgent is not failure.** The urgent family means *sort this out*; the failed family means *you lost
  this*. They must be distinguishable at a glance, and a quota pill in the urgent family carries the
  position and days remaining as text (`1/3 · 3 days`) so colour is never the sole carrier.
- Status pills are never interactive and never take a button fill; commitment rows stay untinted.
- The large `figure` type role is reserved to exactly two elements in the whole product; the running
  timer is the second one (the debt total is the first, already spent).
- The morning slot belongs to the Declaration. Quota reminders and focus prompts may never occupy it.
- Every notification offers at most one action and is fully legible on the lock screen.
- **Under Reduce Motion, the quota bar snaps rather than fills** and the timer updates without
  animation — this is the only motion in the product, and disabling it must not make the bar
  disappear or freeze mid-fill; it jumps directly to the current value.
- The accessibility floor delivered in Epic 2 (Dynamic Type without clipping, 44×44pt targets, AA
  contrast for any token pair added later) is inherited, not re-litigated.

## Cross-Story Dependencies

- **3.0 comes first**: 3.2 and 3.3 schedule reminders against the hour it makes configurable.
- **3.1 → 3.2**: banked minutes must exist before progress against a target can be shown or a
  not-started prompt can be justified.
- **3.3 → 3.4**: the weekly quota position must exist before Week Close can judge it.
- **Depends on Epic 2** for the settlement engine, event log, outbox and worker, notification
  lifecycle rows, the row and status-pill components, and commitment configuration — a Weekly Quota
  commitment's target count and week start day, and a Daily Hours Quota commitment's target minutes,
  are stored there.
- **Depends on Epic 1** for the proven push channel and the token layer; Web Push was verified working
  on the author's own device, so no story here needs to re-establish it.
- **Reaches into Epic 4**: Week Close resolves outstanding Held Penalties, but Held Penalties only come
  into existence with Appeals. Build the resolution path here; it has nothing to resolve until then.
- Settings rows for referee pairing and grace days remaining are deliberately deferred to Epic 4 and
  Epic 5 respectively.
