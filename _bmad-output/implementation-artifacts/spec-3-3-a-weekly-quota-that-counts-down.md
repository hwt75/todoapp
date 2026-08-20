---
title: 'Story 3.3 — A weekly quota that counts down'
type: 'feature'
created: '2026-08-20'
status: 'ready-for-dev'
baseline_commit: '397da780862a06753855fa53094f2dcaa487cb8f'
review_loop_iteration: 0
story_key: '3-3-a-weekly-quota-that-counts-down'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-20 by tmtuan123** — all three decisions, the split that carved the escalating
> reminder into its own deferred spec, and the narrowed ~2,900 tokens kept rather than split further.
> One goal: the Today pill's live quota position, sourced from one view, nothing else. Frozen from
> here.
>
> Stamped in its own commit, before any implementation, as every Epic 3 story before it (retro P2b).

## Intent

**Problem:** A Weekly Quota commitment (gym, 3×/week) has had `weekly_target` and `week_start_day`
since Story 2.2, and it is already asked for an ordinary Declaration every day exactly like a Daily
commitment — but nothing ever sums those answers into a week's standing. The Today row shows only the
setup target (`3×`), by design (`commitment-row.tsx` refuses to show a progress it cannot know), so
the author has no way to see where the week stands without doing the arithmetic himself.

**Approach:** One live Postgres view sums this week's held declarations against the target and the
days left, the same discipline `focus_day_minutes` established for the other quota (AD-8, one source,
no client arithmetic). The Today pill reads it — `1/3 · 3 days`, always the urgent family while the
week is open, `held` the moment the target is met.

**Split from the original combined spec.** The escalating reminder that also reads this view (FR-4:
silent while comfortable, once daily as the week tightens, twice once overdue) is a separate,
independently shippable piece — it needs its own migration, its own cron schedule and its own copy in
`EXPERIENCE.md`, none of which the pill depends on. Deferred to its own spec, recorded in
`deferred-work.md` with the escalation design already carried over so it is not re-derived from
scratch.

## Decisions

### D1. "Days remaining" excludes today, and the formula is derivable from the story's own example

No document states whether today counts. `EXPERIENCE.md`'s KF-6 gives two numbers, though: Thursday
reads "3 days remaining," Saturday reads "1 day remaining." With `week_start_day = 1` (Monday, ISO),
Thursday is the week's 4th day and Saturday its 6th — `7 − 4 = 3` and `7 − 6 = 1`. Both match exactly.

**Proposed:** `week_days_remaining(p_day, p_week_start_day)` returns `6 − ((isodow(p_day) −
p_week_start_day + 7) mod 7)` — the count of days from tomorrow through the end of this account's own
week, wherever it starts. Verified against both of KF-6's numbers, not assumed.

### D2. The pill is always the `urgent` family while the week is open, and `held` once it is met

The story's own example — 0 of 3 on a Tuesday, five days still open — is called `urgent` in the AC
even though nothing is remotely tight yet. `DESIGN.md`'s "fewer days left than sessions owed" reads
as one illustration of the family, not its gate: the AC overrides a narrower reading.

**Proposed:** every open Weekly Quota commitment's pill is `urgent` with `<held>/<target> · <days>
day(s)`, for every day of the week it has not yet met its target — regardless of slack. The moment
`held ≥ target`, the pill flips to `held` (DESIGN.md's own "only family that reads as good") and drops
the days count, since there is nothing left to count down. A met quota sitting in urgent orange for
the rest of the week would tell the author to keep worrying about something already finished.

### D3. `StatusPill` takes an optional override; `stateToday()` and its five states are untouched

A live quota position is not a settlement verdict — inventing a sixth `CommitmentState` for it would
be exactly the collapse `lib/commitment-state.ts`'s own header warns against (a family standing for
two different kinds of thing).

**Proposed:** `StatusPill` accepts an optional `override?: { family: StateFamily; label: string }`
that replaces the state-derived rendering when present; every existing caller is unaffected since it
is optional. `rowLabel` gains a parallel optional `spokenOverride` so the row's one accessibility
label states the same position a sighted reader sees, rather than falling back to "not yet done today"
while the pill says `1/3 · 3 days` beside it.

## Boundaries & Constraints

**Always:**

- The count and the days-remaining figure both come from one Postgres view (AD-8); no client-side
  tally of raw `declaration` rows.
- The pill's text is exactly what `DESIGN.md` already specifies (`1/3 · 3 days`) — no new copy is
  authored for this spec; the format was ratified before this story existed.

**Ask First:**

- Building the escalating reminder in this same pass. It is deferred on purpose (see Intent) — its
  design already exists in `deferred-work.md` for whoever picks it up next.
- Showing quota position anywhere besides the Today row (no new screen is implied by any source doc).

**Never:**

- A sixth `CommitmentState` value for a live, unsettled position.
- Framing a mid-week shortfall as a miss, anywhere the pill or its accessible label can be read (FR-2).
- Any push notification, cron schedule, or outbox write — none of that belongs to this spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
| --- | --- | --- | --- |
| 0 of 3, Tuesday, `week_start_day = 1` | Nothing held yet, 5 days remain | Pill: `0/3 · 5 days`, urgent | N/A |
| 1 of 3, Thursday, matching KF-6 | One qualifying day held | Pill: `1/3 · 3 days`, urgent | N/A |
| 1 of 3, Saturday, matching KF-6 | Same account, two days later | Pill: `1/3 · 1 day` (singular) | N/A |
| 3 of 3 met mid-week | Target reached before week end | Pill flips to `held`, reads `3/3`, no days count | N/A |
| `week_start_day = 5` (Friday-start week) | Any day | `week_days_remaining` still verified by the derived formula, not re-guessed | N/A |
| A second Weekly Quota commitment, same account | Different position | Each row reads its own view row independently | N/A |
| Commitment archived mid-week | `archived_at is not null` | Excluded from the view and the Today row | N/A |
| Cross-account | Two different owners | Each account's view rows are scoped to itself only (RLS) | N/A |
| Urgent and Failed pills rendered together | e.g. a weekly quota beside a Ledger entry | Visually distinct at a glance — no shared token | N/A |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819150000_commitment.sql:31-32,57-64` — `weekly_target`,
  `week_start_day`, their constraints, and the comment already anticipating this story's boundary
  math.
- `supabase/migrations/20260820110000_a_session_lands_on_the_day_it_started.sql:143-155` —
  `focus_day_minutes`, the view-not-client-arithmetic precedent this story's own view follows.
- `supabase/migrations/20260819200000_declaration.sql:46-69` — `declaration`'s shape (`owner_id,
  commitment_id, answer, for_day`), the source table the new view reads.
- `supabase/tests/3-2-focus-prompt.sql` — model for the new SQL test's structure (minus its
  reminder-specific steps, which do not apply here).
- `lib/commitment-state.ts:17-63,89-102` — `CommitmentState`, `StateFamily`, `STATE_PRESENTATION`,
  `rowLabel`; extended, not replaced (D3).
- `components/status-pill.tsx` — gains the `override` prop (D3).
- `components/commitment-row.tsx:6-30,40-94` — `RowCommitment`, `target()`, the row itself; gains an
  optional `quotaPosition` prop.
- `components/commitment-row.test.tsx:73-85` — the AD-8 guard ("shows the target it is set up for,
  never a progress it cannot know"); stays true with no `quotaPosition` prop, and gains a sibling case
  for the prop-supplied path.
- `components/today.tsx:15,40-67` — the parallel-select pattern (`chain_current`, `penalty_current`)
  to imitate for the new `weekly_quota_progress` read.
- `lib/weekly-quota.ts` (new) — pure formatting: the visible label, the spoken label, and the family
  (held vs. urgent), mirroring `lib/focus-session.ts`'s split between formatting and the surface.
- `_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md:272-276` — KF-6,
  the source of D1's two verification numbers.

## Tasks & Acceptance

**Execution:**

- [ ] `supabase/migrations/20260820130000_the_week_counts_its_own_days.sql` — `week_days_remaining()`
      (D1) and `weekly_quota_progress` view (`security_invoker`), read-only — no function that writes
      anywhere.
- [ ] `supabase/tests/3-3-weekly-quota-progress.sql` — the matrix's database rows: the D1 formula
      against both of KF-6's own numbers and a non-Monday `week_start_day`, the view's count crossing
      from unmet to met, archived exclusion, cross-account isolation.
- [ ] `lib/weekly-quota.ts` + test — the visible label, the spoken label, the held/urgent family
      switch, singular "day" vs. plural "days".
- [ ] `lib/commitment-state.ts` + test — `rowLabel`'s optional `spokenOverride`; existing callers and
      tests unchanged.
- [ ] `components/status-pill.tsx` + test — the optional `override` prop; existing rendering
      unchanged when it is absent.
- [ ] `components/commitment-row.tsx` + test — the optional `quotaPosition` prop; the existing AD-8
      guard test untouched, a new case for the prop-supplied path.
- [ ] `components/today.tsx` + test — the `weekly_quota_progress` select, merged into rows by
      `commitment_id`, following the existing `chain_current`/`penalty_current` pattern.

**Acceptance Criteria:**

- Given a Weekly Quota commitment at 0 of 3 on a Tuesday, then nothing on screen calls it a miss, and
  its Today pill reads `0/3 · 5 days` in the urgent family.
- Given the week's target is met before the week ends, then the pill reads `held` with no days count.
- Given the urgent and failed families rendered side by side, then they remain visually distinct — no
  new token, this is Epic 2's own contrast guarantee holding under a new caller.

## Design Notes

**Why `held ≥ target` rather than `held = target` gates the flip to `held`.** A guard against overshoot
costs nothing, and an equality-only guard is one stray correction to a declaration away from staying
permanently `urgent` after the week is actually won.

**What this spec deliberately does not build.** The escalating reminder (FR-4), and any push,
notification, or cron schedule at all — see Intent. `weekly_quota_progress` is written so that spec
can read it directly, the same way `focus_day_minutes` served both Story 3.1's screen and Story 3.2's
reminder from one source.

## Verification

**Commands:**

- `npm test` — expected: the new `lib/weekly-quota` and updated `lib/commitment-state`,
  `components/status-pill`, `components/commitment-row`, `components/today` tests pass alongside the
  existing 581.
- `npx tsc --noEmit && npm run lint && npm run format:check` — expected: clean.
- `npx supabase db reset` then every file under `supabase/tests/` against the local stack — expected:
  `PASS.` for all, including the new `3-3-weekly-quota-progress.sql`.

**Manual checks (only the author can do these):**

- Open Today with a Weekly Quota commitment mid-week and confirm the pill's colour is legibly distinct
  from a Failed Day's ledger entry, side by side.
