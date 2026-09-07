---
title: 'A referee belongs to one doer'
type: 'feature'
created: '2026-09-07'
status: 'done'
baseline_commit: '77978b5'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The maintainer wants every account to be able to invite its own referee. Two things
stand in the way, and only one of them is the one people notice. `invite-referee` refuses a caller
who is not the live doer — but removing that check alone achieves nothing, because
`profile_single_referee` (20260824160000:23) makes at most one referee exist in the entire system,
ever, and the second account still meets "A referee is already paired."

The real obstacle is underneath both. Seven RLS policies grant the referee **unscoped** reads —
`appeal`, `evidence`, `settlement`, `penalty`, `commitment`, `silence_episode`, and the evidence
bucket — every one of them `using (role_from_token() = 'referee')` with no owner comparison at all.
That was a deliberate, documented trade: `paired_doer_id()`'s own comment says
`role_from_table() = 'referee'` "is not scoping — `profile_single_referee` makes the referee global,
and 20260824160000 accepted that unscoped reach explicitly because it was read-only." The safety
rests on there being exactly one referee, authorised by the one real account. Allowing a referee per
account breaks that chain at both ends, and the moment a second referee exists, referee B reads
account A's appeals, evidence photos, settlements, penalties and commitments.

**Approach:** Make the pairing explicit and scope every read to it, **before** opening the gate.
Stage 1 tightens only: a referee gets a recorded doer, and each of the seven policies gains
`= paired_doer_id()`. Nothing new is permitted and nothing existing changes for the one referee
that exists. Stage 2 then opens invitation to any doer without a referee, which is safe only
because Stage 1 already landed.

## Boundaries & Constraints

**Always:** Land Stage 1 before Stage 2, and verify Stage 1 on its own — it can only remove access,
so it cannot enable a leak even if wrong; scope every one of the seven policies, including the
storage one; keep the referee read-only on every table he could already only read; keep
`role_from_table()` as the role check and add pairing beside it, never instead of it.

**Ask First:** Change what a referee may *write* (ruling, collecting, objecting); allow more than
one referee per doer or more than one doer per referee; change the invitation TTL, the token model
or the password flow; re-pair or unpair an existing referee.

**Never:** Remove the `is_live_doer` gate while any policy is still unscoped — that single line is
the whole difference between "a feature" and "every self-registered account can mint a reader of
everyone's data"; drop `profile_single_referee` in the same migration that scopes the policies;
weaken any doer-facing policy.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Existing referee, own doer's row | Paired referee reads an appeal of the doer who invited him | Reads it, exactly as before | N/A |
| Existing referee, another doer's row | Same referee reads another account's appeal, settlement, penalty, commitment, silence episode or evidence | **Refused** — invisible, as if it did not exist | RLS returns no row |
| Evidence object of another doer | Referee requests an object under another doer's parent | **Refused** | RLS returns no row |
| Referee with no recorded pairing | `referee_of` null | Sees nothing at all rather than everything | RLS returns no row |
| Doer reading own rows | Any doer, any table | Unchanged | N/A |
| Stage 2: a doer with no referee invites | Ordinary doer, no referee yet | Invitation minted | N/A |
| Stage 2: a doer who already has one | Doer whose referee is paired | Refused, per account rather than globally | 409, per-account message |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql:23` —
  `profile_single_referee`, the index that makes the referee global. Stage 2's, not Stage 1's.
- `.../20260824160000...sql:56,62,90,96,125` — the unscoped `appeal`, `appeal_evidence`,
  `settlement`, `penalty` and `commitment` policies.
- `.../20260826100000_the_friend_is_told_i_have_disappeared.sql:378` — `silence_episode`.
- `.../20260903120000_a_photo_i_can_keep_against_any_commitment.sql:346,359` — the current
  `evidence` and `storage.objects` policies, already narrowed by parent kind but not by owner.
- `.../20260903140000_the_referee_may_object.sql:101` — `paired_doer_id()`, today derived from
  accepted invitations with an `is_live_doer` fallback. Revoked from `authenticated`, so a policy
  cannot call it until that changes.
- Owner columns, confirmed against the live schema: `owner_id` on `appeal`, `commitment`,
  `evidence`, `silence_episode`; `subject` on `settlement` and `penalty`. `storage.objects` has
  none, so it needs a path-to-owner helper.

## Tasks & Acceptance

**Stage 1 — scope every read (this change):**
- [x] Migration: `profile.referee_of`, backfilled from accepted invitations; `paired_doer_id()`
      redefined to read it and granted to `authenticated`; a helper resolving an evidence object
      path to its owning doer; all seven policies rewritten to compare against `paired_doer_id()`.
- [x] `supabase/tests/a-referee-belongs-to-one-doer.sql` — two doers, each with data, one paired
      referee: every one of the seven surfaces returns the paired doer's rows and none of the
      other's. Plus a referee with no pairing seeing nothing.
- [x] Existing referee suites (4-5, 4-6, 4-7, 6-7) stay green.

**Stage 2 — open the invitation (after Stage 1 verified):**
- [x] Drop `profile_single_referee`; add "at most one referee per doer".
- [x] `invite-referee` / `pair-referee`: replace the `is_live_doer` gate with "caller is a doer and
      has no referee yet"; the existing-referee check becomes per account.
- [x] `accept-referee-invite` / `pair-referee`: record `referee_of`.

**Acceptance Criteria:**
- Given a paired referee, when he reads any of the seven surfaces, then he sees his own doer's rows
  and none belonging to any other account.
- Given Stage 1 alone, when the existing referee uses every surface he uses today, then nothing he
  could do before is refused.
- Given Stage 2, when a doer with no referee invites one, then it is minted; when a doer who
  already has one invites, then it is refused for that account rather than globally.

## Spec Change Log

- 2026-09-07 — the maintainer chose to proceed without a sprint-change-proposal, knowing this
  changes Story 4.5's declared Non-Goal ("at most one referee, ever"). Recorded here so the
  decision has an artifact even though the proposal step was skipped.

## Design Notes

The staging is the safety property, not ceremony. Stage 1 can only ever *remove* access: every
policy gains a conjunct, and no gate is opened. If its pairing logic is wrong, the failure mode is a
referee who sees too little — visible, harmless, reversible. Stage 2 opens the gate, and is only
sound once Stage 1 is proven, because the thing it opens is exactly what Stage 1 constrains.

Pairing is recorded on the profile rather than re-derived from invitations on every read. The
derivation exists today and has a fallback to "the live doer", which is already fragile — the live
project currently has **two** accounts flagged `is_live_doer`, so that scalar subquery would raise
rather than answer if the first branch were ever null. A column is deterministic, indexable, and
readable by a policy without a round trip through the invitation history.

## Verification

**Commands:**
- SQL test-first: the new file fails before the migration (the referee reads both doers' rows) and
  passes after.
- `npx supabase db reset`, then all `supabase/tests/*.sql` — expected: zero failures, and in
  particular 4-5, 4-6, 4-7 and 6-7 unchanged.
- `npm test`, `npm run lint`, `npm run format:check`, `npm run build` — clean.
- On the live project after any push: the existing referee still resolves to a pairing, and reads
  the same rows he read before.

**Results (2026-09-07):**

- Test-first — `supabase/tests/a-referee-belongs-to-one-doer.sql` failed before the scoping
  migration on its first assertion: *"The referee read 1 row(s) of `commitment` belonging to an
  account he was never paired to."* All three steps pass after it.
- The security guard held me honest. My first draft granted `paired_doer_id()` to `authenticated`
  so the policies could call it; `2-1-roles-and-rls.sql:504` lists that function as one no client
  may reach, and failed. The policies now inline the lookup instead — the caller's own profile row,
  which `profile: read own` already allows — rather than editing a security test to fit new code.
- **The two stages turned out to be coupled**, contrary to the plan above. Stage 1's scoping made
  the existing referee suites fail, and two of them (`4-6`, `6-7`) drive one referee across seven
  and fourteen accounts, which the per-doer model cannot express without Stage 2's index drop. The
  staging still paid: Stage 1 was verified on its own before anything opened.
- Fixture repair, and it was smaller than feared: `6-7` was **already** written for a per-account
  referee — it repoints one accepted invitation before each scenario and says so in its own header
  — so it needed only the new pairing column kept in step with the repoint, in 13 places. `4-6` got
  the same treatment across its 9 session switches. `4-5`, `4-5a`, `5-3`, `6-8` and
  `scripts/test-current-penalty-race.mjs` each needed the pairing recorded.
- Two assertions encoded the old Non-Goal directly and were rewritten rather than deleted: `4-5`
  and `4-5a` now prove that a doer may not have two referees **and** that two doers may each have
  their own. `4-5`'s cross-account expectations became isolation assertions.
- `npx supabase db reset` — passed; all 72 migrations apply from scratch.
- All 41 `supabase/tests/*.sql` — passed.
- Both race harnesses — passed.
- `npm test` — passed, 51 files and 1350 tests.
- `npm run lint`, `npm run format:check`, `npm run build` — passed.
- `npm run migrations:check` — expected non-zero: `20260907160000` and `20260907170000` are
  local-only until a separately authorized push.

**Not yet on the live project, and deliberately so.** This is the only change today that alters who
may read whose data. The two migrations and the three Edge Functions have to go together: pushing
the migrations without deploying the functions leaves invitations still gated on `is_live_doer`
(harmless), and deploying the functions without the migrations would let a second referee be paired
against policies that are still unscoped (**not** harmless). Migrations first, then functions.
