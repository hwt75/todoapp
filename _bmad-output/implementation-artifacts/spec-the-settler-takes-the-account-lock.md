---
title: 'The settler takes the account lock, and the day lookup knows which door'
type: 'bugfix'
created: '2026-10-05'
status: 'in-progress'
review_loop_iteration: 0
baseline_commit: '41e90fe'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-6-retro-2026-09-07.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-8-2-the-referee-s-decision-and-what-a-refusal-costs.md'
  - '{project-root}/supabase/tests/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

hwt75 picked four backlog items on 2026-10-05 and answered the one question that needed an owner
before any code was written.

**1. `settle_day()` takes the per-account advisory lock.** It was the only writer of money-relevant
state without it. It reads `commitments_owing()` in five separate statements under READ COMMITTED,
so a referee's refusal committing between the counts and the frozen-outcome write left a `clean`
settlement beside a frozen `missed` that no correction path can repair (deferred-work.md, review of
Story 8.2). `supersede_expiries()` takes the key too, closing its recorded race with
`mark_penalty_collected()` (deferred-work.md, review of epic-6 retro item 36).

**Decision, by hwt75 on 2026-10-05: `sign_off_day()` takes the same key.** This reverses Story 8.2's
frozen decision 3, which had "taking the per-account advisory lock" on its Ask First list. Without
it the settler's key closes nothing against a refusal, because the refusal never waits. The cost
decision 3 named is a referee briefly waiting behind the author's Grace Day, for the length of one
short transaction.

**2. `apply_grace_days()` copies frozen rows** (Epic 6 retro item 44). A Grace Day correction
freezes every commitment the forgiven settlement froze, all `held`, rather than a live
`commitments_owing()` reading. It takes the key as well.

**3. The referee's day lookup stops offering the Object control on a flagged commitment.**
`referee_day_lookup()` reports `asked_for_signature`, read through the same
`requires_referee_approval_as_of()` door `object_to_day()` reads to refuse that row. The screen
mirrors the fact and says the day was his to sign on the day itself (deferred-work.md, review of
Story 8.2).

**4. Epic 7 closes.** Both stories are merged and done, and no third story was ever defined.

## Boundaries & Constraints

**Always:** each function is reproduced verbatim from its live definition except for the edits its
own comments name. A dropped function re-issues its ACL in the same file. Every writer takes the
account key before any row lock and before the commitment-day key.

**Never:** no change to what a Grace Day forgives: still the whole day, every row `held`. No change
to `settle_day()`'s verdict arithmetic, deadline gate or Auto-check gate. No change to what
`object_to_day()` refuses.

**One addition the intent forced:** under the key, `supersede_expiries()` leaves an expiry standing
once its Penalty is no longer `owed`. Serialization alone could not close the recorded race,
because a collector that wins the key still hands the pass a collected day to rewrite. This is the
refusal `object_to_day()` already makes for a Penalty in any state but owed.

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261005090000_the_settler_takes_the_account_lock.sql`: `settle_day()`,
  `supersede_expiries()`, `sign_off_day()`, `apply_grace_days()`.
- `supabase/migrations/20261005100000_the_day_lookup_knows_which_door.sql`:
  `referee_day_lookup()` gains `asked_for_signature`; drop, create and ACL re-issued.
- `lib/referee.ts`: `RefereeDayRow.askedForSignature`, `objectionIsOffered()`,
  `REFEREE_DAY_COPY.signedOnTheDay`.
- `components/referee-day-lookup.tsx`: maps the column, says the sentence, and suppresses
  "window closed" and "already objected" on that row.
- `supabase/tests/the-settler-takes-the-account-lock.sql`: the key in each writer; the Grace Day
  correction is the frozen day; a collected expiry stands while its owed neighbour is corrected.
- `supabase/tests/the-day-lookup-knows-which-door.sql`: the ACL; flagged and unflagged readings as
  of the day; `object_to_day()` refuses exactly the marked row.
- `scripts/test-settlement-lock.mjs` (new) and `scripts/test-sign-off-race.mjs` (loser now waits on
  the account key), both wired into `.github/workflows/ci.yml`.

## Verification

Run on this machine, 2026-10-05: `npm test`, `npm run lint`, `npm run format:check`, `npm run build`.

**Not run here.** The SQL files and both race harnesses need a local Supabase stack, and this
machine has no Docker. They run in CI's `db-tests` job on push. The story stays `in-progress`, and
retro item 44 stays `in-progress`, until that job is green and both migrations are on the remote
project (`npm run migrations:check`).
