# Epic 5 Context: The way back

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

The product notices when the author has gone quiet and intervenes on the second day rather than
letting Silence pass as a neutral non-event, gives him a limited, countable Grace Day allowance to
void a Failed Day's penalty without lying about what happened, tells the Referee by email when
Silence persists past the intervention so a friend can reach out without being handed a task, and
produces a monthly report that shows whether the whole arrangement — including the Referee's own
participation — is still alive. This is the product's recovery layer: every other epic assumes the
author keeps showing up, and this one is what happens when he stops.

## Stories

- Story 5.1: A countable way to be forgiven (FR-17, Grace Days void a Failed Day's penalty)
- Story 5.2: The app notices I have gone quiet (FR-16, day-two Silence intervention)
- Story 5.3: The friend is told I have disappeared (FR-18, Referee email escalation)
- Story 5.4: The long view, including whether this still works (FR-24, monthly report)

## Requirements & Constraints

- **Silence** is consecutive days with no Declaration answered and no app interaction — the primary
  signal this epic exists to catch, distinct from a single Failed Day.
- **Day-two intervention (FR-16):** after two consecutive days of Silence, routine notifications —
  including the outstanding Declaration prompt — are replaced by one intervention naming the pattern,
  Grace Days remaining, and exactly one concrete action for today. It suppresses the day's ordinary
  reminders rather than adding to them, and is the sole notification that delivers once and does not
  persist or re-deliver — nagging someone already withdrawn is how you lose him. It may take the
  morning slot because it fires before the first Declaration's 48-hour expiry: it is a final warning,
  not a resignation — answering any outstanding Declaration still saves the day and ends the episode.
- **Grace Days (FR-17):** a limited monthly allowance `[ASSUMPTION: two per month, non-carrying —
  never confirmed by the author]` that voids one day's Penalty and preserves that day's Chains.
  Always visible with a running count wherever it can be spent: the Day summary, an owed Ledger row,
  and the silence intervention. Must never be reachable *only* through the intervention — spending
  one's own allowance must not require going quiet for two days first. Cannot be applied to a day
  already marked Collected. Never accrues or is spent automatically.
- **Referee escalation (FR-18):** when Silence persists beyond the intervention
  `[ASSUMPTION: at four days — unconfirmed]`, the system emails the Referee and surfaces the state on
  his home. States only the number of days — no amount, no missed commitment named — asks him for no
  action and adds nothing to his queue. Fires once per Silence episode, not daily. Any Declaration
  answered ends the episode and cancels further escalation.
- **Monthly report (FR-24):** covers every success measure, including the counter-metrics (total
  penalties incurred; days between opening the app and acknowledging the first Failed Day; appeals
  rejected as a share filed). Reports Chains, Penalties Incurred and Penalties Collected as two
  separate stated figures — never merged, since their divergence is the only visible evidence the
  Referee has stopped participating — plus median days to return after a Failed Day and the count of
  Silence episodes longer than two days.
- The daily summary notification (Epic 2) is this product's only heartbeat: real observability is out
  of scope for v1, so if settlement stops running for any reason, the visible symptom is that the
  daily summary stops arriving. Nothing in this epic assumes a separate monitoring layer exists.

## Technical Decisions

- **One writer for derived state (AD-8):** chain, ledger balance, and every projection are written
  only by settlement. A Grace Day spend, like an appeal ruling or collection confirmation, is recorded
  as an *event* and never repairs a chain or balance directly — it is folded in by the next settlement
  pass. This closes a specific defect found in review: two independent writers of the same chain
  (settlement and a grace-day "repair") disagreeing.
- **Append-only verdicts (AD-9):** a Grace Day produces a new row referencing the original
  penalty/verdict rather than mutating it, so the Ledger's displayed state is always a fold of that
  chain, never an overwritten field.
- **Timezone (AD-6):** all day, week, and Silence-streak boundaries are computed server-side in
  `Asia/Ho_Chi_Minh`; clients send instants only, never a derived date.
- **Outbox for outbound effects (AD-3):** the intervention push and the Referee escalation email are
  written to the transactional outbox in the same transaction as the detection/verdict, never sent
  directly; a worker on its own `pg_cron` schedule (via `pg_net`) drains it independently of whatever
  triggered the write, and each entry is dedupe-keyed so a re-run is harmless.
- **Notification lifecycle in the database (AD-11):** the intervention's one-shot, non-persistent
  delivery is a row with a due time and a satisfied-at; the client never schedules or re-schedules it.
- **RLS only (AD-7):** what the Referee's home surface may read (his own Silence-escalation state)
  versus what stays doer-only is enforced in row-level security, never application code.
- **Naming conventions:** table `grace_day`; event `grace.spent`; money stored as integer đồng, never
  floating point; all user-facing copy originates in EXPERIENCE.md before it appears in a component.

## UX & Interaction Patterns

- **Grace day control:** offered wherever a Failed Day is visible and still open — the Day summary, an
  owed Ledger row, and the silence intervention — always stating the remaining count, never applied
  automatically.
- **Ledger row states gain `Waived`** — one of only two tinted outcomes in that list alongside
  `Collected`; the row itself otherwise stays neutral, only its pill carries color (UX-DR13).
- **Commitment row state set gains** "waived by grace day."
- **Today surface gains a state:** the silence intervention replacing routine content entirely, with
  no debt figure and no red.
- **Intervention copy (verbatim, both variants per UX-DR21):** no Declarations pending — *"Two quiet
  days. This is the part where it usually ends. It doesn't have to. Do one thing today — TryHackMe,
  twenty minutes."* Declarations pending — *"...Wednesday and Thursday close tonight — answer them,
  and do one thing today."* States the deadline once, as fact rather than threat, and never says what
  closing costs.
- **Referee escalation copy (verbatim):** *"[Author] hasn't opened this in four days. Nothing needs
  deciding — but he'd probably rather hear from you than from the app."* — the only message that asks
  the Referee to act as a person rather than process a queue.
- **Settings surface** shows Grace Days remaining — a row explicitly deferred out of Story 3.0 into
  this epic.
- **Monthly report** presents Penalties Incurred and Penalties Collected as two separate stated
  figures, never merged into one (UX-DR19).
- Global rules inherited from Epic 1 still bind here: no screen goes fully red, color is never the
  sole carrier of state, and no literal hex/spacing value or invented copy string appears in a
  component.

## Cross-Story Dependencies

- Story 5.1 (Grace Days) is a prerequisite for 5.2 — the intervention must state Grace Days
  remaining — and extends entry points (Day summary, Ledger) that already exist from Epic 2 rather
  than introducing a new surface.
- Story 5.2 (Silence intervention) depends on the Declaration/expiry mechanics from Epic 2 (Stories
  2.4, 2.7): it must fire before the first Declaration's 48-hour expiry and remain answerable from
  inside the app during the intervention.
- Story 5.3 (Referee escalation) depends on Story 5.2's Silence-episode detection — it escalates the
  same episode at a later threshold and shares its end condition (any Declaration answered ends the
  episode and cancels escalation) — and on the Referee account/home surface built in Epic 4 (Story
  4.5), whose state set already reserves a "has gone quiet" slot for this story.
- Story 5.4 (Monthly report) is a read-only aggregation over data every prior epic already produces —
  Chains (Epic 2), Penalties incurred/collected (Epic 2, Epic 4), Silence episodes (Stories 5.2/5.3) —
  which is why it is sequenced last in this epic.
