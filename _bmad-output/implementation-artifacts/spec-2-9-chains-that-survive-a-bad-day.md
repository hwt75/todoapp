---
title: 'Story 2.9 — Chains that survive a bad day'
type: 'feature'
created: '2026-08-19'
status: 'approved'
baseline_commit: '932e3e5'
review_loop_iteration: 0
story_key: '2-9-chains-that-survive-a-bad-day'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-19 by hwt75** — all five. Frozen from here.

## Intent

**Problem:** A failed day currently erases nothing and records nothing. One miss out of five
reads exactly like five misses out of five, because there is no number anywhere saying the other
four have been holding for weeks. The whole argument of this story is in its title: the evidence
that things held has to survive the day something did not.

**Approach:** Settlement freezes what each commitment did on the day it closes. The chain is
derived from those frozen facts rather than kept as a counter, so there is no number to drift
and no repair path to build (AD-8). The chain then appears on the Today rows, in the VoiceOver
label, in the day summary, and on the Chains detail surface beside the longest chain ever run.

## Decisions

### D1. The chain is derived from frozen facts, not counted, and not recomputed

Settlement writes one row per day with an aggregate `verdict` and `missed_count`. A chain is per
commitment, so the per-commitment outcome has to come from somewhere. Three ways:

1. **A counter column** on `commitment`, incremented or zeroed by settlement.
2. **Derived live** from `commitments_owing(subject, day)` over past days.
3. **Frozen facts**: settlement writes one row per commitment it judged, and the chain is a view
   over those rows.

(1) is a number that can be wrong with no way to fix it — AD-8 says settlement is the only
writer and no other path repairs derived state, which means a counter that drifts stays drifted.
(2) is worse and less obviously so: `commitments_owing` computes from the commitment's
**current** configuration, so editing a commitment's cadence — or deleting it — would silently
rewrite what happened in June. A chain that changes when you edit a setting is not evidence.

**Proposed: (3).** Settlement writes a `settlement_commitment` row per commitment judged, with
its outcome, in the same transaction as the verdict. The chain is a view over those rows. There
is no counter, so nothing can drift; history is frozen at the moment it happened; and the
Chains-detail calendar of held and missed days gets its data as a side effect rather than as a
second mechanism.

### D2. Silence breaks a chain

Three kinds of day exist for one commitment: it held, it was missed, and it was never owed (a
cadence that does not include that day). A fourth appeared with expiry: **it was owed and never
answered.**

- **Not owed → skipped.** Not a break and not an extension. A weekly commitment would otherwise
  reset every Tuesday.
- **Missed → break.** Obviously.
- **Unanswered → break.** Proposed, and the one worth arguing about.

Two reasons. The narrow one: settlement already charges 500,000₫ for an unanswered commitment
that carries a penalty, so a chain that survived silence would mean *you paid and your chain
held* — two numbers describing the same day, disagreeing about it. The broad one: a chain is
evidence that something held, and silence is not evidence of anything. A chain that runs through
days he never answered counts days elapsed, not days held, and then the number stops meaning
what he reads it as meaning.

### D3. The chain sits beside the pill, not inside it — and is never coloured

`EXPERIENCE.md` contradicts itself here, and the contradiction has to be resolved rather than
picked from:

> § Component Patterns: *"Status pill reflects one of: chain count (held), quota position …,
> not-yet (neutral)."* — the chain is **in** the pill, and only when the state is held.

> § Accessibility: *"commitment rows announce name, state, and chain as one label."* — name,
> state, **and** chain: three things, so the chain is not the state.

The second is the one that survives contact with the build. Today's rows have no state by
construction — FR-10 forbids anything announcing mid-day that the day is lost, `stateToday`
returns `not_yet` for everything, and a day is only judged after it ends. So a chain living
inside the pill on the `held` state would **never render at all**, on any row, ever.

**Proposed:** the pill keeps the state. The chain is its own element on the row, and it reads
`day 12` rather than `12`, because a bare number beside a status pill is a quantity of something
unnamed.

**And it stays uncoloured.** DESIGN.md rations the `held` family deliberately; a green chain on
every row makes the entire screen the colour that is supposed to mean something.

### D4. This story builds the Chains detail surface, because nothing else will

One acceptance criterion is *"Given the Chains detail surface, the longest chain is shown
adjacent to the current one."* That surface is `spine-only`, UX-DR17 specifies it by table rather
than mockup, and no later story in `epics.md` claims it. If 2.9 does not build it, the criterion
is never met by anyone.

**Proposed:** build it — one commitment's current chain, its longest chain adjacent, and the
calendar of held and missed days that the frozen facts from D1 already contain. This is the
largest single piece of the story and it is called out here rather than discovered halfway
through.

The adjacency is not a layout preference. A reset read against zero says *you have nothing*;
read against a record it says *you have done better than this and you did it yourself*, which is
the difference between a number that helps on a bad day and one that makes it worse.

### D5. Two pieces of specified copy become true here

Story 2.8 shipped the day summary without its chain clause because nothing counted chains. It can
now say what was specified: *"… Morning exercise held though — day 12. Start there tomorrow."*
The 2.8 body measured 91 characters against a 120 ceiling, so it fits.

The morning gate's specified copy is *"Morning. Day 5 is waiting."* — naming what is at stake to
protect before asking, which is the whole reason the gate is allowed to say anything beyond the
question. But the gate can be asking about **several** commitments at once, and there is no
honest composite of three different chains.

**Proposed:** the gate names the chain only when it is asking about exactly one commitment. With
more than one it stays as it is today. Never a sum, never the longest, never "your chains" — an
invented number in the one place he is asked to answer honestly is a bad trade for a slightly
warmer sentence.

## Boundaries & Constraints

**Always:**
- Chains are written only by settlement, in the same transaction as the verdict (AD-8, AD-3).
- A chain reset is never a notification's headline (`EXPERIENCE.md` § Component Patterns).
- Wherever a current chain is shown, the longest chain is shown adjacent to it.
- The frozen per-commitment outcome is append-only; a correction is a new row (AD-9), and the
  supersession the Ledger already reads applies unchanged.

**Ask First:**
- Any chain that survives a day the commitment was owed and not answered.
- Showing a chain anywhere the state it belongs to is not also shown.

**Never:**
- Never let a failed day reset a chain belonging to a commitment that held. This is the story.
- Never colour the chain, and never let it be the loudest thing on a row.
- Never recompute a past day's outcome from current configuration.
- Never a repair path, a backfill endpoint, or an admin correction that writes a chain. If a
  chain is wrong the facts under it are wrong, and those are fixed by a new row, not a patch.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Daily held | Settlement runs | Chain extends by one | Only settlement writes it |
| Failed day, one miss | Four held, one missed | Four chains extend, one resets to zero | Never a wholesale reset |
| Expired day | Owed, unanswered | Chain breaks (D2) | Consistent with the penalty charged |
| Day not owed | Cadence excludes it | Chain unchanged — neither extended nor broken | |
| First ever day | No history | Chain reads `day 1` after it holds, nothing before | Never `day 0` on a row |
| Chain reset | Was 12, now 0 | Longest still reads 12 | A reset read against a record |
| Commitment edited | Cadence changed today | June's outcomes unchanged | The reason for D1 |
| Settlement runs twice | Same day | One set of outcomes | AD-5, the same unique constraint |
| Superseded settlement | A correction row exists | The chain follows the correction | Reads `*_current`, never base tables |
| VoiceOver on a row | Any state | One label: name, state, chain | Never three separate announcements |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260819220000_settlement.sql` — the `settlement` table, and the shape a
  per-commitment child table has to match.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql` — `settle_day`, and
  `settlement_current`, which every client read must go through.
- `supabase/migrations/20260819250000_day_summary.sql` — where D5's chain clause lands.
- `lib/commitment-state.ts` — `STATE_PRESENTATION.held` carries a note saying 2.9 replaces its
  label with the chain count. D3 says it does not; the note gets corrected.
- `components/today.tsx`, `components/commitment-row.tsx` — the row, the pill, and `rowLabel`.

## Tasks & Acceptance

**Execution:**
- [ ] Migration — `settlement_commitment`, written by `settle_day` in the same transaction; RLS
  read-own, no client write path; a `chain_current` view giving current and longest per
  commitment, derived, reading through supersession.
- [ ] `lib/chain.ts` + test — the rules as pure functions: what extends, what breaks, what is
  skipped, and how a chain reads.
- [ ] `lib/commitment-state.ts` — correct the stale note; a chain is not a state.
- [ ] Today row + `rowLabel` — chain beside the pill, uncoloured, in the single spoken label.
- [ ] Chains detail surface — current, longest adjacent, calendar of held and missed days.
- [ ] Day summary — the `— day 12` clause; morning gate — the single-commitment case only.

**Acceptance Criteria:**
- Given a failed day with four of five holding, then four chains extend and one resets.
- Given an owed commitment never answered, then its chain breaks.
- Given a day the commitment was not owed, then its chain is unchanged.
- Given a chain that reset, then the longest chain is still shown beside it.
- Given a commitment edited today, then a chain covering last month does not change.
- Given settlement running twice, then one set of outcomes exists.
- Given a row read aloud, then name, state and chain arrive as one label.

## Verification

**Commands:**
- `npm test` — the chain rules pass alongside the existing 374
- Advisor after applying — expected: no new lints

**Manual checks:**
- Settle a failed day for a test account with several commitments; confirm only the missed chain
  resets and the others extend
- Settle an expired day; confirm the chain breaks and the longest is unchanged
- Edit a commitment's cadence; confirm no past outcome moves

## Verification record

**Verified against the live project on 2026-08-19.** Five days seeded for a three-commitment
account: three clean, one where Gym alone slipped, one clean again.

```
Gym        current 1  longest 3
No fap     current 5  longest 5
TryHackMe  current 5  longest 5
```

The failed day reset one chain and left two at five. That is the story, and it is the first
time the product can tell the difference between one miss and a collapse.

The summary for the failed day: *"Two of three on Thursday. That's 500.000₫. No fap held
though — day 4. Start with Gym tomorrow."* — 95 characters. It names the chain that survived
and never mentions the three-day chain that broke in the same breath.

**Silence broke all three chains and the record survived.** An expired day settled `expired`,
wrote three `unanswered` outcomes, sent no summary, and left the longest chains at 3, 5 and 5 —
which is exactly the property D4 argued for: a reset that is read against a record.

**A day not owed cost nothing.** Archiving one commitment produced no outcome row for it and
left its chain untouched.

**A correction moved the chain with it.** Superseding the expired settlement with a clean one
(AD-9, a new row rather than an edit) took the three chains to 3/3, 7/7 and 6/6 — the gap
closed, the history rewritten only by a correction that is itself recorded.

**Re-running settlement produced no duplicate outcomes**, and the gate said *"Day 7 is waiting.
1 commitment is unanswered for 2026-08-18, as of 17:29."* With two outstanding it said nothing
about chains at all, which is D5 holding.

Test account deleted, every table at zero, advisor clean.

## What went wrong, and what it cost

**`min(uuid)` does not exist.** The gate's chain clause used it to find the single outstanding
commitment. The migration applied cleanly and the function only failed when it was actually
called — which in production is a `pg_cron` job at 07:30, the one place nobody is watching.
Caught here only because the verification called it by hand. This is the third time a migration
has applied cleanly and been wrong: the `CASE`-to-enum cast in `settle_day`, the column grant
that granted nothing, and now this. **Applying is not passing.**

**The survivor was being chosen arbitrarily.** Story 2.8 picked the surviving commitment by
`created_at` because nothing counted chains and one survivor was as good as another. Seeing real
data made it obvious: a day where a three-day chain and a seven-day chain both survived was
naming whichever was created first. Now the longest chain wins, ties fall back to `created_at`
so a re-run says the same sentence. This is what the story was for, and it was not in the spec.

**The chain nearly took the `figure` type role.** DESIGN.md reserves that size for exactly two
things — the debt total and a running focus timer — and the second is unbuilt, so the slot was
free. Taking it would have put the chain at the same visual weight as the money, which is the
comparison this product spends most of its design budget refusing to make.

**No signed-in UI verification.** The chain on the row and the Chains detail were verified by
build and by their data path, not by being looked at with real data in a browser. Signing in
requires entering a password, which is not something to do here; the surfaces should be checked
on the author's own account the next time it has settled days behind it.
