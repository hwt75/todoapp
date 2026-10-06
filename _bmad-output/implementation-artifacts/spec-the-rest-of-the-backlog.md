---
title: 'The rest of the Epic 6 retro and deferred-work backlog'
type: 'bugfix'
created: '2026-10-05'
status: 'in-progress'
review_loop_iteration: 0
baseline_commit: '65201ad'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-6-retro-2026-09-07.md'
  - '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-the-settler-takes-the-account-lock.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

On 2026-10-05 hwt75 asked for the rest of the backlog to be done. The Epic 7 and Epic 8
retrospectives are marked done without being run. Three decisions were his, and he made all three
that day:

- **Item 47: a timed window ends by 23:30.** It used to be allowed to end at 24:00. Thirty minutes
  are left between the last valid claim and the midnight that decides the day, so the photo can
  land in time.
- **Item 48: a claim stranded past midnight says so.** Today says plainly that it can no longer be
  proven, and names the Grace Day as the only way back if the day fails. The same change re-reads a
  claim whose id never came back (finding A5).
- **Story 8.1's deferred cadence rule is done.** An hours quota cannot carry the referee sign-off
  flag, which reverses his 2026-09-11 decision to leave it.

Everything else is decision-free work the retrospective or deferred-work already specified:

- Item 45: one evidence write path.
- Item 46: a kept photo's textual signal.
- Item 50: the one-door rule, written into AGENTS.md.
- Deferred-work entries:
  - aria-describedby on the greyed controls.
  - Evidence refusals keyed off a hint, not a message.
  - The referee photo component.
  - Paged evidence reads.
  - The complete SQL index.

Item 49 was already done (`20260907180000`).

## Boundaries & Constraints

**Always:** every function a migration replaces is reproduced verbatim except for the edits its own
comments name. No refusal message changes. Each screen keeps its own copy; shared code returns
outcomes, not sentences.

**Never:** no change to how a day settles, what a Grace Day forgives, or what the referee may decide.

</frozen-after-approval>

## Code Map

| Item | Migration | Client | Tests |
| --- | --- | --- | --- |
| 47 | `20261005110000_a_window_leaves_time_for_its_photo.sql` | `lib/commitment.ts` `LATEST_WINDOW_END_MINUTES`, `TIMED_COMMITMENT_COPY.windowTooLate` | `6-1` both edges; `6-6` widens within the rule; two clock-bound files declare `ci-clock-window: 0-22` |
| 8.1 cadence | `20261005120000_an_hours_quota_has_no_day_to_sign.sql` | `canBeSignedOff(kind, cadence)`, `withCadence()`, `REFEREE_SIGN_OFF_COPY.hoursQuota` | `sign-off-is-not-for-an-hours-quota.sql`; `8-2` builds the flagged-then-moved path |
| 46 | — | `components/kept-photos.tsx`, `EVIDENCE_COPY.photosKept` | `components/kept-photos.test.tsx` |
| 48 + A5 | — | `lib/queued-claim.ts`, `components/today.tsx` | `lib/queued-claim.test.ts`, `components/today.test.tsx` |
| 45 | — | `lib/evidence-write.ts`; Today and the appeal form call it | `lib/evidence-write.test.ts` |
| refusal copy | `20261005130000_an_evidence_refusal_names_itself.sql` | `evidenceRefusal()`, `EVIDENCE_COPY.refusals` | `an-evidence-refusal-names-itself.sql` |
| a11y | — | `components/commitment-form.tsx` | `components/commitment-form.test.tsx` |
| referee photos | — | `components/referee-photos.tsx` on three screens | `components/referee-photos.test.tsx` |
| pagination | — | `readKeptPhotos()` pages by `EVIDENCE_ROWS_PER_PAGE` | `lib/evidence.test.ts` |
| index | — | `supabase/tests/README.md` | `lib/sql-tests-readme.test.ts` |
| 50 | — | `AGENTS.md` | — |

## Verification

- **Run on this machine:** `npm test`, `npm run lint`, `npm run format:check`, `npm run build`.
- **Not run here:** the SQL suite. This machine has no Docker, so CI's `db-tests` job is the first
  run of the changed and new SQL files.
- **Read-only check on the live project, 2026-10-05:** no `evidence` row lacks its object, which
  answers the item-42 diagnostic question without building the function.
- **Still to do:** the three migrations are not on the remote project. The items stay
  `in-progress` until this branch merges green and `npm run migrations:check` matches.
- **Manual checks:** the stranded-claim sentence and the referee photo re-sign were not exercised
  on a device.
