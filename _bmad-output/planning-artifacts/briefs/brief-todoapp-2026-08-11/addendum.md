---
title: "Addendum: todoapp brief"
status: draft
created: 2026-08-11
updated: 2026-08-11
---

# Addendum

Depth from the brief conversation that downstream documents will need, and rationale for options that
were considered and set aside. Not part of the brief itself.

## The author's eight real weekly commitments

The raw list, sorted by how each could be confirmed. This drove the Three Kinds of Task model and the
verification tiering, and it should drive PRD task modelling.

| Commitment | Kind | Cadence | Verification tier | Notes |
|---|---|---|---|---|
| Gym | Do | **Weekly quota — 3 sessions** | Machine | GPS geofence + dwell time; gameable by sitting still inside. Author has also asked for same-day referee approval, which conflicts with the machine tier — unresolved |
| Morning exercise | Do | Daily | Machine | Phone motion data; misses sessions without the phone |
| One TryHackMe lesson | Do | Daily | Machine | Completed-room history; external access not yet confirmed |
| Build a horoscope agent | Open-ended | Unstated | Referee | Commits could proxy progress, but "building" has no finish line |
| Financial-report research | Open-ended | Unstated | Referee | Knowledge work; only self-created notes as artifact |
| VHM news tracking | Open-ended | Daily (implied) | Referee | Same |
| Company work | Open-ended | Daily | Referee | Author's own words: duration unpredictable. Has no completion criterion at all — must be modelled as a commitment to time or output, never to completion |
| No fap | Abstain | Daily | Self-reported / referee | The task he most wants help with and has repeatedly failed. Unobservable by any technical means |

Cadences not marked above were never stated and must be settled in the PRD. The author has separately
confirmed that some tasks exist for a single day only, so the one-off cadence is real even though none
of these eight is an example of it.

Three of eight are machine-verifiable. The most important one is not verifiable at all.

## Verification approaches considered

| Approach | Anti-cheat strength | Coverage | Verdict |
|---|---|---|---|
| Sensor / device data | Strong, automatic | Very narrow | Adopted for the three Do tasks |
| Third-party integration | Strong | Narrow, ecosystem-dependent | Adopted for TryHackMe |
| Photo / video evidence | Weak — old photos, staged shots | Broad | Adopted only as input to referee approval, never as proof on its own |
| Human confirmation | Strongest for general tasks | Broadest | Adopted as the core mechanism |

The design converges on something close to StickK's referee model, where a named human — not the
software — rules on completion and stakes ride on that ruling. Beeminder's contrasting philosophy
(honour system, cheating only hurts you) was noted but does not fit a user who has already failed this
task repeatedly on his own.

## Options considered and rejected

**Deferring real money to phase 2.** Proposed as: run four weeks with penalties displayed and reported
but not collected, validating the recovery mechanism before adding pressure the author's own history
suggests could backfire. The argument originally rested on build cost — payment flows being expensive.
That argument collapsed once the author clarified that the payment system is a notification plus a
checkbox, with no integration at all. Only the psychological sequencing argument survived, judged not
strong enough to override the author's preference. **Rejected; phase 1 carries real money.**

**In-app payment processing.** Rejected early and decisively. Would have brought chargebacks, refunds,
disputes, money-transmission and gambling-adjacent regulatory questions, and App Store rules on
non-digital money flows — any one of which could sink a solo project. Money moves between two people
who know each other; the app only instructs and records.

**Huawei wearable integration.** The author wears a Huawei watch and uses Huawei Health. Huawei Health
on iOS does not feed Apple HealthKit, and Huawei's own Health Kit API is a gated cloud service whose
availability to an individual developer was unconfirmed. The entire money-backed automation would have
depended on an approval that might never come. The author elected to drop it. The phone's own sensors
cover the same three tasks with no external dependency. **Rejected; phone-only.**

**Referee workload models.** Considered: witness-only at transfer time (lowest burden, no daily
verification power); daily approval of one or two critical tasks; daily approval of everything
self-ticked; report-only with no approval action. The author specified a fuller role — approving
submitted evidence, approving tasks that require sign-off, and confirming collection — with a
dedicated account. This maximises verification strength and correspondingly maximises the risk of
referee burnout, which is why that risk now ranks first in the brief.

## Technical constraints for the architecture phase

- **Web push is weak**, especially on iOS Safari, where it requires the PWA to be installed to the
  home screen. This is why persistent reminders live only on the iOS surface. The referee's web app
  does not need aggressive notification and must not be designed as if it does.
- **A referee account makes this multi-user from day one**: authentication, two distinct roles, a
  synchronising backend, evidence upload and storage, and a submit → pending → approve/reject →
  notify-back flow. Sizing must reflect this; it is not a local todo app.
- **Gym geofencing needs dwell time**, not simple entry, or it is defeated by walking in and out.
- **TryHackMe completion history** must be confirmed readable from outside the site before the
  TryHackMe commitment can be placed in the machine-verified tier.
- **The author's iOS/Swift experience is unstated.** Technology selection was deliberately delegated to
  the architecture phase, but phase 1 cannot be sized realistically without this answer. Ask it first.
- No deadline has been set. The author works alone.

## Parked for later

- Product name — "todoapp" is a placeholder.
- Platform vision: the unsolved problem is referee supply. A friend who genuinely cares does not
  scale, a stranger has no reason to chase you, and a paid referee changes the economics and reopens
  the regulatory questions phase 1 was designed to avoid.
- Reducing what the referee must actually say out loud. Chasing a friend for money is unpleasant to
  do; a design where the app delivers the uncomfortable message and the referee only confirms may be
  what keeps the referee alive past week eight.
