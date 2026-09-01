---
title: 'Story 6.5 — Today shows where the window stands'
type: 'feature'
created: '2026-08-30'
status: 'done'
review_loop_iteration: 0
baseline_commit: '93267c6306cd53c433ff6ba32512d1421a1b5798'
story_key: '6-5-today-shows-where-the-window-stands'
context:
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/lifecycle.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-4-midnight-decides-the-day.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 6.1–6.4 built the whole state machine in `lifecycle.md` and Today renders none
of it. Every timed commitment shows the same `Not yet` pill all day, beside a *Claim* button
offered identically at 08:00 (four hours early), at 20:35 (shut, refused on tap), and again after a
reload of a day already claimed. A window that shut unproven — the state that costs money at
midnight — is indistinguishable from one still waiting for its hour. That is CAP-7 unbuilt, on the
one screen the author opens under reluctance.

**Approach:** One server view supplies the two facts a client cannot know — was it claimed today,
did a photo land — and the client supplies the clock. `lib/timed-window.ts` folds those with the
commitment's own `due_time`/`late_window_minutes` into the states `lifecycle.md` names, rendered
through the `StatusPill` override seam Story 3.3 already built for the Weekly Quota position.

## Boundaries & Constraints

**Always:**
- The states shown are `lifecycle.md`'s own — ahead, open, claimed, proven, shut — not a second
  vocabulary invented here.
- Shut-unproven must be visibly *and* audibly distinct from ahead, and must become so while the
  screen sits open, without a refresh or a tap (CAP-7's own success condition).
- Colour is never the sole carrier of state: every pill carries a word, and the row's one spoken
  sentence carries the same fact (`EXPERIENCE.md` § Accessibility).
- All boundaries resolve in `Asia/Ho_Chi_Minh` through `lib/declaration.ts`'s existing helpers.
  The client computes what to *display*; it never derives a date for storage.
- `components/today.tsx` reads positions through views, never raw `declaration` or `evidence`
  rows (AD-8).
- An untimed commitment's row is untouched — same pill, same sentence, same controls.

**Ask First:**
- Any change to `commitments_owing()`, `settle_day()`, or anything else that decides a verdict.
  This story shows the day; it does not judge it.
- Giving the pill a live countdown of minutes remaining rather than a state word.

**Never:**
- Do not let the client's window arithmetic become the rule that *accepts or refuses* a claim.
  `declaration_derive_day()` refuses in the author's own words and stays the only judge; the
  client may decline to *offer* a control, and never invents a refusal message locally.
- Do not build the reminder (6.6) or anything the referee can see (6.7).
- Do not show a verdict for today. FR-10 stands: `held`/`missed` still belong to a day that ended.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Untimed commitment | No `due_time` | `Not yet`, unchanged in pill, sentence and controls | — |
| Timed, before `due_time` | 08:00, due 20:30 | `20:30` pill, neutral; no claim control; spoken "window opens at 20:30" | — |
| Timed, inside window | 20:35, due 20:30 +30 | `Open now`, urgent; the claim control is offered | — |
| Window shuts while on screen | 21:00 passes, screen open | Pill flips to `Shut` (failed family) with no interaction | — |
| Timed, past window, unclaimed | 22:00 | `Shut`, failed family; no claim control; spoken says shut and unproven | — |
| Claimed today, no photo yet | Declaration exists, no evidence | `Photo due`, urgent, until midnight; photo control offered | — |
| Claimed today, photo landed | Evidence row exists | `Proven`, held family; no claim control, no second upload | — |
| Reload after claiming | Claim made earlier today | Still `Photo due`, with the upload control — never a second *Claim* | — |
| Claim queued offline | No row on the server | The device's own `queued` state still wins over the view's silence | — |
| Timed weekly-quota row | Both positions exist | The window state takes the pill; the week's position stays in the sentence | — |
| The view's read fails | Error from Supabase | The whole screen fails as it already does for every other read | Existing `failed` view |

</frozen-after-approval>

## Code Map

- `components/today.tsx:59` — `SELECT` already pulls `due_time,late_window_minutes`. `:105` the
  parallel-read `Promise.all` every position is added to, each error checked. `:340` the timed
  block whose own comment names this story as the thing that replaces it, including the
  "offered a second time after a reload" defect. `claimState`/`evidenceState` (`:47`, `:57`)
  stay: a queued claim has no server row, so the device's own state still wins.
- `components/commitment-row.tsx:70` — `quotaPosition` → `weeklyQuotaOverride` + `spokenOverride`.
  The exact seam this story's state plugs into; add a sibling prop, do not reshape it.
- `lib/weekly-quota.ts` — the file to mirror: a position in, `label`/`spoken`/`family`/`override`
  out, no arithmetic beyond what it is given. `lib/timed-window.ts` is its twin.
- `lib/commitment-state.ts:66` — `StateFamily`; `rowLabel()`'s `spokenOverride` (`:97`).
  `stateToday()` still returns `not_yet` and is not touched — a window state is not a verdict.
- `lib/declaration.ts:33` `calendarMoment()` — the only zone-correct clock read; `ZONE` is fixed.
- `supabase/migrations/20260820150000_the_week_closes_and_settles.sql:69` —
  `weekly_quota_progress`: the `security_invoker` view shape, the `where cadence = ... and
  archived_at is null` scoping, and the `comment on view` discipline to copy.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:308` —
  `commitments_owing()`'s `exists (select 1 from evidence where declaration_id = d.id)`: the
  identical proof test, in the function this story must not touch. Cross-reference both ways.
- `supabase/migrations/20260828140000_a_claim_lands_on_the_day_it_was_made.sql:83` — the window
  arithmetic in seconds-from-midnight, and why `time + interval` is wrong. The client mirror
  copies that shape, half-open at both ends.
- `supabase/migrations/20260828150000_evidence_detaches_from_an_appeal.sql:37` —
  `evidence.declaration_id`; `20260824130000:299` — `evidence: read own`; and
  `20260819200000_declaration.sql:106` — `declaration: read own`. Both make the view safe under
  `security_invoker`.
- `supabase/tests/2-1-roles-and-rls.sql:443` — the revoked-function list; a view is asserted by
  reading it under two accounts instead, in the new test file.
- `components/today.test.tsx:22` — the `fromCalls` mock harness the new read must register in;
  `components/commitment-row.test.tsx`, `lib/weekly-quota.test.ts` — the test shapes to mirror.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20260830090000_today_shows_where_the_window_stands.sql` — create
      `public.timed_claim_today` (`security_invoker`), one row per open timed commitment of the
      caller: `owner_id, commitment_id, declaration_id, proven`. Today's claim only, resolved in
      `Asia/Ho_Chi_Minh`; `proven` is the existence of an `evidence` row on it. `comment on view`
      states that it reports facts and never a verdict, and names `commitments_owing()` as the
      sibling copy of the proof test with the reason it is not extracted here.
- [x] `lib/timed-window.ts` — `TimedWindowState` (`ahead|open|claimed|proven|shut`), a pure
      `timedWindowState(position, now)`, and `label`/`spoken`/`family`/`override` mirroring
      `lib/weekly-quota.ts`. Seconds-from-midnight, half-open at both ends.
- [x] `lib/timed-window.test.ts` — every matrix row a pure function can reach, both sides of the
      open and shut boundaries to the second, and the claimed/proven precedence over the clock.
- [x] `components/commitment-row.tsx` — a `windowState` prop feeding the same `override` +
      `spokenOverride` seam; on a row carrying both positions, the window state takes the pill and
      the week's position stays in the spoken sentence.
- [x] `components/today.tsx` — read the view alongside the existing parallel reads (error checked
      like every other); a `now` tick so the states advance unattended; pass `windowState` per row;
      offer *Claim* only while `open`, and the photo control whenever today's claim is unproven —
      including after a reload, seeded from the view's `declaration_id`.
- [x] `components/today.test.tsx`, `components/commitment-row.test.tsx` — the reload case, the four
      unclaimed states, the offline-queue precedence, and the untimed row's unchanged output.
- [x] `supabase/tests/6-5-today-shows-where-the-window-stands.sql` — the view under RLS: one
      account sees only its own rows, `proven` flips with an evidence row, an untimed and an
      archived commitment never appear, and yesterday's claim is not today's.

**Acceptance Criteria:**
- Given a screen open across the instant a window shuts, when nothing is tapped, then the row
  changes state on its own.
- Given a commitment claimed earlier today with no photo, when the app is reopened, then the
  upload control is offered and the *Claim* control is not.
- Given an account with no timed commitments, when Today loads, then every row, sentence and
  control is what it was before this story.
- Given a second account's timed commitment, when the view is read, then no row for it is returned.

## Spec Change Log

## Design Notes

The pill's five states, and why each family is what it is:

| State | Family | Label | Spoken |
|---|---|---|---|
| ahead | neutral | `20:30` | window opens at 20:30 |
| open | urgent | `Open now` | window open now, until 21:00 |
| claimed | urgent | `Photo due` | claimed, photo still needed by midnight |
| proven | held | `Proven` | claimed and proven |
| shut | failed | `Shut` | window shut, nothing claimed |

`urgent` for both `open` and `claimed` because both are still actionable and both cost money if
left; `failed` for `shut` because at that point only a Grace Day can help, which is the same thing
`missed` means elsewhere. `held` stays rationed to the one state that is genuinely finished.

## Verification

**Commands:**
- `npm test` — expected: all existing tests pass, plus the new `lib/timed-window.test.ts` and the
  new component cases.
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check` — expected: clean.
- `npx supabase db reset` then every file under `supabase/tests/` — expected: 35 pass, 0 fail.
- `npm run migrations:check` — expected: the new migration reported as not yet pushed.

## Close — 2026-08-30 (stops here for the done checkpoint)

**Everything runnable ran, and passed.** `npm test` — 1191 tests across 49 files.
`npx supabase db reset` applied the new migration and all 35 files under `supabase/tests/` pass:
**35 pass, 0 fail**, including the new `6-5-today-shows-where-the-window-stands.sql`.
`tsc --noEmit`, `eslint` and `prettier --check` are clean. `npm run migrations:check` reports
`20260829090000` and `20260830090000` as not yet pushed. The dev server compiles and serves the
app, which is the most a machine can say about a screen whose whole subject is a real clock.

**Three things the work found that the spec did not anticipate:**

1. **A shut window drew an empty bordered card.** The controls block was gated on "not ahead",
   which let a shut row through to render a frame around nothing. It is now gated on whether the
   row has anything to offer at all (`offersSomething()`), and the shut test asserts no
   `.card-pad` exists — the pill above carries the whole state, and a frame around nothing is the
   screen saying something it has nothing to say.
2. **A phone left open overnight would tick on yesterday's answers.** The clock advances every
   fifteen seconds, but every read on this screen — the claims, the debt, the graceable days —
   was true only for the day it loaded on, so yesterday's proven claim would have read as today's
   `Proven` under a live clock. The reads are now keyed to the local day (`localDay`), so they
   re-run exactly once, at midnight. This was not in the matrix and is the one defect the ticking
   clock introduced rather than exposed.
3. **The claim copy gained the commitment's name.** With more than one timed commitment the card
   would otherwise have shown two identical "Claimed for today." lines with nothing to tell them
   apart. Two existing assertions in `components/today.test.tsx` moved from an exact string to a
   pattern.

**Deliberately not built, and why.** The reminder still lands at `:05` past the hour (Story 6.6),
and the referee still gets nothing (Story 6.7). `commitments_owing()` keeps its own inline copy of
the evidence-existence test rather than sharing one with the view: extracting it means recreating
the function every settlement path reads, in the one story that must move no money. It is
cross-referenced from both sides, and it is the second caller that should move with the first when
a story touches that function anyway.

**No longer true:** this migration was local-only until 2026-09-01, when it was pushed to the live
project. `npm run migrations:check` reads 59/59 matched, and the security advisor was re-run after
the push: no new finding.

## Done checkpoint

What a browser cannot prove on its own: that a real window, on a real phone, shuts while the
author is looking at it — and that the screen he comes back to hours later still knows what he did.

1. Set a time on a commitment a few minutes ahead. Open Today and leave it open. The pill must
   change from the hour, to `Open now`, to `Shut` without a refresh and without a tap.
2. Claim it inside the window, then close the app and reopen it. The claim control must be gone
   and the photo control must be there — before this story, that reload lost the day.
3. Attach the photo. The pill must read `Proven` and nothing more must be asked of him.

## Suggested Review Order

**The two facts a clock cannot supply**

- The whole server side of the story: today's claim, and whether a photo landed on it.
  [`20260830090000:24`](../../supabase/migrations/20260830090000_today_shows_where_the_window_stands.sql#L24)

- The id that makes a reload survivable — before it, a claim closed the app and lost the day.
  [`20260830090000:36`](../../supabase/migrations/20260830090000_today_shows_where_the_window_stands.sql#L36)

- The same existence test `commitments_owing()` applies, and why it is not extracted here.
  [`20260830090000:48`](../../supabase/migrations/20260830090000_today_shows_where_the_window_stands.sql#L48)

**Where the window stands**

- What happened outranks the clock, in both directions — the rule a timer alone gets wrong.
  [`timed-window.ts:91`](../../lib/timed-window.ts#L91)

- Seconds, not minutes: the same resolution `declaration_derive_day()` refuses a tap at.
  [`timed-window.ts:54`](../../lib/timed-window.ts#L54)

- Why shut earns `failed` and an open window does not.
  [`timed-window.ts:162`](../../lib/timed-window.ts#L162)

**The join, on the surface**

- Three sources folded once, so the pill and the control beneath it cannot disagree.
  [`today.tsx:108`](../../components/today.tsx#L108)

- The local clock, and why it ticks at all.
  [`today.tsx:178`](../../components/today.tsx#L178)

- The reads re-run at midnight rather than ticking on yesterday's answers.
  [`today.tsx:191`](../../components/today.tsx#L191)

- A window with nothing to offer draws nothing — not an empty card.
  [`today.tsx:96`](../../components/today.tsx#L96)

- Queued first, before anything the clock decides: the server has never seen that claim.
  [`today.tsx:548`](../../components/today.tsx#L548)

**One row, two positions**

- The window takes the pill; the week keeps its place in the sentence.
  [`commitment-row.tsx:98`](../../components/commitment-row.tsx#L98)

**Supporting**

- The view under RLS, and the day boundary a browser cannot cross on demand.
  [`6-5-today:88`](../../supabase/tests/6-5-today-shows-where-the-window-stands.sql#L88)
