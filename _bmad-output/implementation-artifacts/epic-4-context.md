# Epic 4 Context: The machine answers for him, and the friend rules

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Auto-checks let external systems file the author's daily Declaration on his behalf, and when a
penalty-carrying Auto-check reports a miss, a human — the Referee — has a way to overturn it before
money changes hands. These two mechanisms belong to one epic because an Appeal has nothing to
contest until an Auto-check can report a miss: split apart, one epic would ship a feature the other
has no reason to exist yet. This epic also stands up the Referee's entire surface (his own account,
authentication, and the appeal-ruling and collection screens), since Appeals need a ruler and
Penalties need a collector.

**Known scope change:** FR-8 (external account Auto-check) was resolved NEGATIVE by Story 1.3 —
TryHackMe's completion history is not readable from outside (bot-challenged, Enterprise-gated API,
stale badge). The TryHackMe commitment therefore ships with no Auto-check and keeps its Penalty,
which under FR-2a means the author's own Declaration settles it. FR-8's consequences (unavailable
reporting, fall-through) and FR-8b still apply — implement them generically — but v1 has no live
external-account integration to test them against; Story 4.1/4.2 should treat this as an
untriggered-in-practice path rather than dead code.

## Stories

- Story 4.1: Attach a check that answers for me (FR-8, external account Auto-check config/link UI)
- Story 4.2: A check that cannot run never says I missed (FR-8b, unavailable vs missed)
- Story 4.3: When money rides on it, the machine's word stands (FR-2a precedence)
- Story 4.4: Contest a miss the machine got wrong (FR-14, FR-15, Appeal submission and hold)
- Story 4.5: The referee has his own way in (FR-19, referee account/auth/scope)
- Story 4.6: The referee rules (FR-20, approve/reject an Appeal)
- Story 4.7: The app does the asking, the referee does the collecting (FR-21, collection flow)

## Requirements & Constraints

- **Precedence (FR-2a):** on a Penalty-carrying commitment with an Auto-check attached, the
  Auto-check's `missed` result is authoritative and cannot be corrected directly by the author — only
  an Appeal overturns it. On a commitment with no Penalty, the author's Declaration always overrides
  any Auto-check result; no Appeal exists for those. Turning a Penalty off on a commitment with a
  pending Appeal resolves that Appeal in the author's favor immediately.
- **Auto-check resolution (FR-8b, AD-10):** every Auto-check resolves to exactly one of `held`,
  `missed`, or `unavailable`. Only `missed` ever invokes FR-2a precedence. Absence of a result, a
  revoked/downgraded permission, or an unreachable service is `unavailable`, never `missed` —
  `unavailable` means *tried and failed*, never *not yet tried*. An `unavailable` result falls through
  to the author's Declaration with no Appeal involved. Availability is evaluated per Auto-check, not
  per commitment: a commitment with two checks keeps the one still working. The author is told, in
  plain language, which commitments are affected and what would restore the check.
- **Settlement gating (AD-13):** a day cannot settle while any attached Auto-check on it has not yet
  reached a terminal result; settlement refuses to run and reschedules rather than treating an
  in-flight check as unavailable.
- **Appeal window (FR-14):** an Appeal is same-day only — evidence dated after the claimed day is
  rejected. Submitting an Appeal moves the Penalty to `Held` before it is ever shown to the Referee as
  owed; a Held Penalty is invisible on the Referee's collection list until ruled on.
- **Ruling deadline (FR-15):** a Held Penalty resolves by the Referee's ruling or by its Cadence's
  settlement point, whichever comes first, always in the author's favor on timeout — it never
  converts to owed on its own. Deadline is Week Close for a Weekly Quota commitment; end of the
  following day for a Daily commitment `[ASSUMPTION, unconfirmed]`. This is the single most
  trust-critical rule in the product: if the author is ever charged because the Referee was simply
  busy, trust in the whole mechanism breaks permanently.
- **Referee scope (FR-19):** the Referee's account is distinct from the author's and sees only Appeals
  and Penalties — never Declarations, Chains, Focus Session activity, or location data. The author can
  never rule on his own Appeal from any surface. The Referee's surface must work fully with zero
  notification permissions (his channel is email, per NFR3) and be keyboard-navigable with no focus
  traps (NFR15).
- **Ruling (FR-20):** approval voids the Held Penalty and credits the commitment; rejection converts
  it to owed. Either ruling notifies the author with the outcome.
- **Collection (FR-21):** the Referee sees each owed Penalty with a pre-written, ready-to-copy
  collection message and a Mark Collected control — no composition required from him. Marking
  Collected is the *only* way a debt is discharged; uncollected debts age visibly and are never
  written off automatically.
- **Evidence privacy (NFR4):** Appeal evidence is visible to the Referee and the submitting author
  only, nobody else.

## Technical Decisions

- **Server is sole judge (AD-1, AD-8):** clients submit observations and Appeals only; every derived
  value (penalty state, chain, ledger balance) has exactly one writer — settlement. No client computes
  a verdict.
- **Outbox for notifications (AD-3):** ruling outcomes and other outbound messages are written to the
  transactional outbox in the same transaction as the state change, never sent directly; a separate
  `pg_net`-woken worker drains it.
- **Idempotency (AD-4):** Appeal submissions and other observations carry a client-generated
  idempotency key created at action time.
- **Guarded terminal transition (AD-15):** a Held Penalty's move to any terminal state (voided,
  converted to owed, expired-in-favor) is a single guarded transition — first writer wins, later
  writers are no-ops. This directly resolves the race between an Appeal ruling and Week Close both
  trying to resolve the same Held Penalty.
- **RLS only (AD-7):** all authorization — including "Referee sees only Appeals/Penalties," "author
  cannot rule on own Appeal," "evidence visible only to submitter + ruling referee" — lives in
  row-level security, never in application code.
- **Evidence storage:** Appeal evidence goes to a private Supabase Storage bucket whose access policy
  derives from the same rule as the `appeal` row it belongs to — the submitting doer and the ruling
  referee, nobody else. An object outlives its appeal only as long as the appeal is retained.
- **Money:** integer đồng, never floating point, per the spine's global convention.
- **Auto-check config is per-commitment**, never a global setting (applies to the external-account
  link and any future Auto-check).
- **`(referee)` route group** is the Referee surface (FR-19/20/21), governed by AD-7 (RLS) and AD-12
  (role resolved server-side, drives both routing and RLS) — the same Next.js codebase serves both
  roles.

## UX & Interaction Patterns

- **Account-elsewhere link component:** a sub-state of its Auto-check row in Task setup. Unlinked
  shows the service name and a link control; linked shows the account identifier and when it was last
  read. `[ASSUMPTION: v1 takes a public profile URL, no OAuth. If a service requires OAuth this row
  becomes a flow rather than a field.]`
- **Machine confirmation is silent (UX-DR29):** a passing Auto-check produces no notification and no
  interaction — the author is simply never prompted for that commitment.
- **Precedence disclosure:** enabling both the money toggle and an Auto-check on a commitment must
  state, before saving, that the machine's result will stand and an Appeal is the only way to overturn
  it — disclosed at setup time, not discovered the day it first costs money.
- **Appeal evidence:** camera or library only, restricted to items dated the claimed day; appears only
  in the Appeal flow, never as a check method (an old photo proves nothing).
- **Appeal machine's-account copy (UX-DR25):** states exactly what was observed and exactly what was
  required — e.g. *"Location saw you for 4 minutes. It needed 30."* Never a generic "verification
  failed."
- **Appeal hold-state copy (verbatim from EXPERIENCE.md):** *"500,000 is on hold, not charged. It
  stays on hold until [Referee] decides, or until [deadline] closes — and if he doesn't get to it,
  it's dropped."* The single most trust-critical sentence in the product.
- **Held-pending-appeal state color:** uses the **urgent** family, never the failed family and never
  the "held" *color* family (name collision: "held" the color token means *good/complete*; a Held
  Penalty is styled urgent — "sort this out," not "you lost this," and never styled as money already
  gone).
- **Referee empty state (default):** e.g. *"Nothing for you this week. [author] is at 4 of 5 today.
  You'll get an email if that changes."* — the progress crumb is the only retention lever over him.
- **Referee ruling controls:** labeled *He did it* / *He didn't* (UX-DR24 plain language, not
  "approve/reject").
- **Referee timeout note (written for the Referee's benefit):** *"Ignore this and it's dropped in his
  favor on [deadline]."* — tells him he is not a bottleneck.
- **Collection message (verbatim):** *"todoapp says you owe 500,000 for [day]. I'm just the one
  collecting it. When are you free?"* — attributes the demand to the app, not the Referee; copy
  control places it on the clipboard unchanged.
- **Ledger row states added by this epic:** `Dropped` (Story 4.4, timeout-voided appeal) and
  `Collected` (Story 4.7). An owed row carries its pill but the row itself stays neutral (UX-DR13); a
  Held Penalty stays invisible on the collection list until ruled on.
- **Referee state set:** Empty (default) · appeals pending · collections outstanding · both · has gone
  quiet (FR-18, Epic 5 — not built here, but the state exists in the set).
- **`button-action` constraint (UX-DR6):** on the Referee's surface, at most one card demands action
  above the fold.

## Cross-Story Dependencies

- Story 4.3 (FR-2a precedence) depends on Story 4.1/4.2 existing (an Auto-check must be attachable and
  able to report `missed` vs `unavailable` before precedence has anything to arbitrate).
- Story 4.4 (Appeal) depends on 4.3 — an Appeal only exists once a penalty-carrying Auto-check miss is
  possible.
- Story 4.6 (ruling) and Story 4.7 (collection) both depend on 4.5 (Referee account/auth existing
  first).
- **Corrected 2026-08-27 (Epic 4 retrospective):** the AD-15 guarded transition is intra-epic
  machinery shared among this epic's own Appeal-timeout path (`void_expired_appeals()`), ruling
  (`rule_appeal()`), and the toggle-off-ends-appeal fix (`commitment_carries_penalty_off_ends_appeal()`)
  — all can resolve the same Held Penalty, and only one may win. It is **not** shared with Epic 3's
  Week Close (Story 3.4): `settle_week()`/`settle_due_weeks()` never write `penalty.state`, and
  `appeal_hold_penalty()` restricts eligibility to `s.kind = 'day'`, so a Weekly-Quota Held Penalty
  cannot exist. The retrospective's own diff-scope review confirmed this by direct code
  inspection after a lens flagged the original claim above as unverified.
- Ledger outcomes `Owed` and `Expired` were introduced in Epic 2 (Stories 2.6, 2.7); this epic adds
  `Dropped` and `Collected` to the same enum/surface.
- Epic 5's Grace Day (FR-17) and silence intervention (FR-16) reuse the Ledger and notification
  patterns this epic establishes for Held/owed penalties, and Epic 5's referee escalation (FR-18)
  extends the Referee home surface built in Story 4.5.
