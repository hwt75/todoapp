---
title: 'Story 2.2 — Create and edit a commitment'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '51c9cb5'
review_loop_iteration: 0
story_key: '2-2-create-and-edit-a-commitment'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/DESIGN.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75** — both decisions below: archive rather than remove, and no
> Auto-check table in this story. Frozen from here.

## Intent

**Problem:** The author has no way to say what he is held to. Five commitments exist as a table in
the PRD and nowhere else. Until they are rows he can create and change, every screen after this one
has nothing to render and the settlement rules have nothing to judge.

**Approach:** One table and the shape of a commitment: a name, a Kind that decides what "done" can
mean, a Cadence that decides when it can be judged failed, the targets each Cadence needs, and the
flag for whether it carries the Penalty. Row-level security so a commitment belongs to exactly one
account, written with the two role helpers Story 2.1 established. A setup surface to create, edit and
remove them.

## Boundaries & Constraints

**Always:**
- A commitment belongs to exactly one account, and that ownership is enforced by policy, never by a
  client-side filter (AD-7).
- Every write carries a client-generated idempotency key, generated at the moment of the action and
  reused by retries (AD-4). A double-tap must not create two commitments.
- Cadence and its targets are consistent by constraint, not by the form remembering to ask. A weekly
  quota without a target is not a valid row and the database must say so.
- The money flag defaults to **off**. Turning it on is a deliberate act.

**Ask First:**
- Storing anything a settlement function would later own. Derived state has exactly one writer and
  it is settlement (AD-8); a commitment row holds configuration, never progress.
- Any date or day-of-week value derived on the client. The client sends an instant, the server
  derives the day, and every boundary is `Asia/Ho_Chi_Minh` (AD-6).

**Never:**
- No Auto-check execution, no Declaration, no day, no penalty, no chain. This story ends at what a
  commitment *is*.
- Do not colour the create or edit controls by outcome. The destructive button is the one place a
  filled colour appears on a control, and it appears only on delete.
- Do not spend the `figure` or `quoted` type roles here.

## The two decisions worth your attention

**1. "Delete" should mean archive, not remove.** The acceptance criterion says delete, and the
button will say delete. But a commitment is referenced by every Declaration, Failed Day and Penalty
that ever touched it, and removing the row would either break those references or silently rewrite
the author's own history — the ledger would stop explaining itself. So the row is marked
`archived_at` and disappears from every list, and the history keeps its referent.

The cost is honest and worth stating: a commitment created by mistake and deleted a minute later
leaves a row behind forever. That is the cheaper of the two mistakes.

**2. There is no Auto-check table in this story.** The acceptance criteria only require the
Auto-check *section* to render disabled for an Abstain commitment, with the explanation that nothing
can check it. Storage for Auto-checks belongs with the code that runs them, in Epic 4 — and Story 1.3
already established that the one Auto-check reaching outside the product has no target, so what is
left to store is smaller than the PRD assumed. Building the table now would be guessing at the shape
of code that does not exist.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Create, daily | Name, Kind, Cadence `daily` | Row owned by the signed-in account, penalty off | — |
| Create, weekly quota | Cadence `weekly_quota`, target 3, week start | Target and week start stored | A missing target is refused by constraint, not by the form alone |
| Create, daily hours | Cadence `daily_hours_quota`, 180 minutes | Duration stored in minutes | Minutes, never hours — one unit, no conversion at rest |
| Kind is `abstain` | Auto-check section rendered | Every Auto-check disabled and greyed, with the reason stated | Presentation only; nothing is stored either way |
| Double-tap create | Same idempotency key twice | One row. The second is a no-op, not an error | — |
| Another account's commitment | Authenticated as a different account | Zero rows on read; refused on write | RLS filters reads and refuses writes |
| Referee reads commitments | Signed in as `referee` | Zero rows. The referee sees appeals and penalties, nothing else | — |
| Delete | Confirmed | Row archived, vanishes from lists, history keeps its referent | Confirmation before acting, per the destructive-button rule |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819120000_account_and_roles.sql` -- the conventions this story copies:
  table and RLS in one migration, `search_path` pinned, and which role helper each clause may call.
- `lib/roles.ts` -- `ROLE_HELPERS.write` is what every `with check` in this story must use.
  `lib/roles.test.ts` fails the build otherwise.
- `components/sign-in.tsx` -- the component shape to copy: a discriminated `Stage` union, verbatim
  error text, and no access decision made in the client.
- `app/tokens.css`, `app/globals.css` -- every colour, radius and spacing value comes from here.
  A literal value in a component is a defect the token suite already guards against.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_commitment.sql` -- `commitment_kind` and `commitment_cadence` enums,
  the `commitment` table with its ownership column, targets, `carries_penalty`, `idempotency_key`
  and `archived_at`, the cadence/target check constraints, RLS enabled in the same file, and
  owner-scoped policies whose `with check` calls `role_from_table()`.
- [ ] `lib/commitment.ts` -- the Kind and Cadence unions, and the pure function deciding which
  targets a Cadence requires and whether a draft is complete -- so the rule is testable without a
  database or a browser, which is where this codebase puts every rule that matters.
- [ ] `lib/commitment.test.ts` -- every Cadence's target requirements, the Abstain rule, and the
  defaults, including the money flag defaulting off.
- [ ] `components/commitment-form.tsx`, `components/commitment-list.tsx` -- create, edit, archive,
  and the disabled Auto-check section with its explanation.
- [ ] `app/page.tsx` -- mount the list for a signed-in account.
- [ ] `README.md` -- the archive-not-delete decision, so it is not rediscovered as a bug.

**Acceptance Criteria:**
- Given the setup surface, when a commitment is created, then a name, Kind and Cadence are stored and
  the money flag is off.
- Given Kind `abstain`, then every Auto-check control is disabled and the screen states that nothing
  can check this one and the morning answer is the record.
- Given Cadence `weekly_quota`, then a target count and week start day are stored; given
  `daily_hours_quota`, then a target duration in minutes is stored; and given either without its
  target, then the database refuses the row.
- Given the same idempotency key twice, then exactly one row exists.
- Given a second account, then its commitments are invisible and unwritable, proved against the live
  project rather than by reading the policy.
- Given delete, then the control is the destructive fill, it confirms before acting, and the row is
  archived rather than removed.

## Design Notes

**Verified end to end against the live project on 2026-08-19**, with two throwaway accounts deleted
afterwards (`auth.users`, `profile` and `commitment` all back to zero). One commitment of each
cadence inserted; a weekly quota missing its target refused by `commitment_weekly_quota_targets`;
a repeated idempotency key refused by the unique constraint, and accepted as a silent no-op once the
insert goes through `on_conflict=idempotency_key` with `resolution=ignore-duplicates`; a write for
another account's `owner_id` refused `42501` by policy; account B saw none of account A's rows and
could not rename one — the PATCH affected zero rows and the name was unchanged. Archive removed the
row from the active list while leaving it in the table.

**Two false alarms during that verification, both worth recording.** A `PATCH` sent without `-X
PATCH` is a `POST`, so `curl -d` silently tested the insert policy instead of the update policy and
produced a `42501` that looked like a broken update rule. Earlier, an `UPDATE` without a `WHERE`
clause was rejected by PostgREST before RLS ever ran. Both looked like authorization defects and
neither was. The lesson is the same one Story 1.2 recorded about a late push: a failure observed is
not yet a failure understood.

**Minutes, not hours, at rest.** The Cadence is called Daily Hours Quota and the UI will say hours,
but the stored unit is minutes. One unit at rest means no rounding decision is ever made twice, and
a focus session that banks 90 minutes has somewhere exact to go.

**`week_start_day` is stored, not assumed.** The PRD's gym commitment is three times a week, and when
that week begins decides which side of a boundary a session lands on. AD-6 puts every boundary in
`Asia/Ho_Chi_Minh`; this column is what that computation reads, and it is stored per commitment
because the author may reasonably want a gym week and a work week to start on different days.

**The referee is excluded by policy, not by omission.** AD-7 gives the referee appeals and penalties
and nothing else. A commitment list he cannot see is a rule expressed in the policy, so a later
screen built for him cannot accidentally read one.

## Verification

**Commands:**
- `npm test` -- expected: the commitment rules and the migration guards pass alongside the existing 79
- `npm run build && npm run lint && npm run format:check` -- expected: clean
- Advisor after applying -- expected: no new lints

**Manual checks (if no CLI):**
- Create one of each Cadence; confirm the targets land and the money flag starts off
- Switch Kind to Abstain; confirm the Auto-check section greys out and says why
- Delete; confirm the button is the destructive fill, that it asks first, and that the row leaves the
  list
