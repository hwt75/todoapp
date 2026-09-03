---
title: 'Story 6.7 — The referee may object'
type: 'feature'
created: '2026-09-03'
status: 'done'
review_loop_iteration: 1
baseline_commit: '92fef608be4fe82707dc587d65518fcb23c6dcc0'
story_key: '6-7-the-referee-may-object'
context:
  - '{project-root}/_bmad-output/specs/spec-timed-commitments-with-photo-proof/lifecycle.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-4-midnight-decides-the-day.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A photo holds a timed day by itself. Nothing lets the one person the arrangement exists
for say *that photo does not show what you claim it shows* — so the only check on the proof is the
author's own honesty, which is the thing the money was supposed to stand in for.

**Approach:** The referee may object to one settled day, in his own words, within 48 hours of it
settling. He is never given a list to work through and is never asked to act: he reaches a day only
by looking it up himself, and a day nobody objects to holds. An objection is final when he makes it
— it writes a correction superseding that day and the day costs what a failed day costs. The
author's recourse is the one he already has: a Grace Day.

## Boundaries & Constraints

**Always:**
- **The referee is never sent a queue, never obliged to act, and never notified in a way that
  demands a decision.** He reaches a day by looking it up. With no referee action at all every
  proven day settles as held, exactly as today. A design that makes a day depend on him acting is
  the wrong design, whatever else it gets right.
- An objection is one guarded transition on the day it names — first writer wins, later writers are
  refused, not silently ignored (AD-15).
- The referee may object only on the account he is paired to. The role check alone is not scoping:
  `profile_single_referee` makes the referee global, and `deferred-work.md` accepted an analogous
  wide read explicitly *because it was read-only*. This writes, and it mints a debt.
- A settled period is never re-settled, only superseded (AD-5, AD-9). `settlement_once_correction`
  allows at most one correction per original, so a day already corrected is superseded **at its
  correction**, never at the original.
- A correction freezes the **whole** day's commitment outcomes, not only the objected one, and it
  takes them from the superseded settlement's own frozen rows — never from a live recompute over
  today's commitments. A commitment archived since that day must still appear, with the outcome it
  was frozen with. An enforcement mechanism the author can switch off by archiving a row is not an
  enforcement mechanism.
- 48 hours measured from the superseded settlement's own creation, in `Asia/Ho_Chi_Minh` (AD-6).
- The referee must give a reason. It is stored and it is shown to the author verbatim.
- **A day that already carries a penalty in any state gets no second one.** One penalty per failed
  day (FR-13, `penalty_one_per_settlement`). A `collected` penalty is terminal and is never read,
  written or reasoned about by this feature.
- The author is told, through the outbox (AD-3), on the push channel.
- **An objection is permitted only where it lands the day as `failed` carrying an `owed` penalty**,
  so a Grace Day always answers it. Where the corrected day would read `expired`, where the objected
  commitment carries no penalty, or where the day's penalty is anything but `owed` — `waived`,
  `held`, `dropped`, `voided`, `collected` — the objection is refused in the referee's own words.
  `grace_day_validate()` requires `failed` + `owed`, so any other landing would leave the author
  with a broken chain and no recourse at all: no Grace Day, and no appeal (that path requires
  `filed_by = 'auto_check'`). This refusal is what makes the next line true rather than aspirational.
- The resulting penalty is an ordinary Failed Day penalty: the Ledger shows it and a Grace Day voids
  it, with no special case. That is deliberately the author's whole recourse.

**Ask First:**
- Anything that puts a list, count, badge or feed of the author's days on the referee's surface.
  A browsable list of proven days is a queue in everything but name.
- Any change to `appeal`, `rule_appeal()`, `void_expired_appeals()`, or the appeal deadline.
- Any widening of the referee's RLS beyond what looking up one named day requires.
- Any need to touch `settle_day`, `settle_week` or `commitments_owing()`.

**Never:**
- No answer step, no deadline, and no expiry pass on the author's side. The author's silence is not
  an input to anything here, so nothing can fire against him while he is quiet.
- No second penalty on a day that has one, and nothing that reads or alters a `collected` penalty.
- No objection outside the window, on an unsettled day, or on a day that is not the referee's to see.
- No forked correction chain, and nothing that leaves an in-flight appeal pointing at a superseded
  penalty — `void_expired_appeals()` and `rule_appeal()` must still reach the live row, or the
  objection must refuse the day while an appeal is open.
- No objection that can be defeated by an ordinary act of the author's.
- No notification to the referee, ever, arising from this feature.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Nobody objects | A proven day, 48h pass | The day holds. Nothing runs, nothing is enqueued | N/A |
| Objection on a clean day | Referee objects with a reason, inside the window | Correction supersedes it; that commitment freezes `missed`; the day becomes failed and carries one penalty; the author is notified | N/A |
| Objection on an already-failed day | The day already has a penalty | The commitment freezes `missed` and the day stays failed with the **same one** penalty — no second charge | N/A |
| Window has passed | More than 48h since that settlement | Refused in the referee's own words | Function raises; no write |
| Second objection | The day already carries a correction | Refused | Guarded transition; the loser is told it is already resolved |
| Penalty already collected | The day's penalty is `collected` | The objection is refused rather than charging twice for one day | Function raises |
| Not the referee | A doer, or a signed-out caller | Refused before any row is read | Role check first, then RLS |
| Author spends a Grace Day | Penalty an objection created, still owed | Voided like any other Failed Day, no special case | Existing path, unchanged |
| Author is in a Silence episode | An objection lands during one | Behaves identically — there is no deadline of the author's to expire | N/A |
| No recourse would remain | Corrected day would read `expired`, or the commitment carries no penalty, or the penalty is not `owed` | Refused — an objection never lands the author somewhere a Grace Day cannot reach | Function raises |
| Commitment archived since | The author archives it inside the window | The objection still lands, on the outcome frozen that day | N/A |
| Another account | The referee names a day belonging to an account he is not paired to | Refused | Function raises |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260825090000_the_referee_rules.sql:88-231` `rule_appeal()` — **the model.**
  `role_from_table() is distinct from 'referee'` raises at `:110` *before any row is read*, and the
  test asserts that ordering. `:131-139`/`:157-165` the AD-15 guarded update. `:188-219` a correction
  written by a referee RPC, minting a penalty outside a scheduled pass — the precedent that this is
  allowed at all. `:249-250` `security definer`, revoked from `anon`, granted to `authenticated`:
  the function *is* the privilege boundary. `:57-73` `appeal_ruling_body()`, the body-builder shape.
- `supabase/migrations/20260819241000_expiry_and_supersession.sql:9-25` — `settlement.supersedes`,
  and the two partial unique indexes that replaced `settlement_once`: `settlement_once_original`
  and **`settlement_once_correction on (supersedes)` — at most one correction per original, so the
  chain cannot fork.**
- `supabase/migrations/20260820102000_supersession_freezes_the_day.sql:76-91` — what a correction
  must carry: a full `settlement_commitment` freeze for **every** commitment owing that day, plus its
  own `penalty` row when the day still owes. Copying only the objected commitment is the known-bad
  shape this file exists to fix.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:308-335` `commitments_owing()` —
  a timed `held` claim resolves `held` only when an `evidence` row exists; `:502-508` `settle_day`'s
  freeze. **Read-only: the objection contests the row written at `:502`, and must not change how it
  is written.**
- `supabase/migrations/20260819230000_penalty.sql:28-47` — `penalty`, `penalty_one_per_settlement
  unique (settlement_id)`, and no insert/update/delete policy for anyone: every write is
  `security definer`. States at `20260825110000:70-77`. **`collected` is terminal — nothing in the
  schema transitions out of it.** `20260826110000:56-105` `mark_penalty_collected()`.
- `supabase/migrations/20260826110000_the_long_view...sql:41-49` `penalty_current`, and
  `20260827120000_settlement_current_spells_its_own_columns.sql:18-23` `settlement_current` — whose
  columns are now spelled out explicitly, so **a new column is appended last**.
- `supabase/migrations/20260819260000_chain.sql:73-116` `chain_current` — a day with no frozen
  outcomes vanishes from the chain rather than breaking it. A reverse-direction correction is the
  first thing to feed it a `missed` where a `held` stood.
- `supabase/migrations/20260824160000_the_referee_has_his_own_way_in.sql:90-94` — `settlement:
  referee reads day and week` already grants **every** day settlement including clean ones, so a
  single-day lookup needs no new grant. `:135-155` the reads he deliberately does **not** have
  (`declaration`, `chain_current`, `focus_session`) — and `referee_missed_commitments()` is the
  `security definer` shape used to give him a commitment's name without granting
  `settlement_commitment`, which would silently reopen `chain_current`.
- `supabase/migrations/20260819180000_outbox.sql:73-106` — `outbox_enqueue(owner, dedupe_key,
  payload, channel)`; the payload check needs `title`, `body`, and a body that passes
  `push_body_is_sendable` (`20260820101000:48`) — it must date itself. Kinds are only a
  `dedupe_key` prefix chosen at the call site; there is no enum to extend.
- `components/referee-home.tsx` — two counts, pending appeals, owed penalties, a passive gone-quiet
  line. **Where a lookup goes, and where a list must not.**
  `components/referee-appeal-detail.tsx` — the only ruling surface today, the shape to mirror.
- `supabase/tests/4-5-the-referee-has-his-own-way-in.sql` — asserts the **absence** of referee access
  to `declaration`, `chain_current`, `focus_session`, `push_subscription`. Any new referee-facing
  read risks tripping it; it must still pass unmodified. `4-6-the-referee-rules.sql` (refusal
  ordering, both AD-15 race directions), `2-7-supersession.sql`, `2-9-chain-arithmetic.sql`,
  `2-9-chain-calendar.sql`, `6-4-midnight-decides-the-day.sql` — the suites a reverse-direction
  correction is most likely to break. 38 files, house style is one `begin; do $$ … $$; rollback;`.

## Tasks & Acceptance

**Execution:**
- [x] One numbered migration — an `objection` row (day, commitment, referee's reason, the settlement
      it superseded) and `object_to_day(...)`: `security definer`, `search_path = ''`, role check
      first, window check, refusals for an already-corrected day and for a day whose penalty is
      `collected`, then the correction settlement with a **full** commitment freeze, at most one
      penalty, and the author's outbox row — all in one transaction. Prose comments give the reason
      and the rejected alternative, and quote any policy whose behaviour they assert.
- [x] `supabase/tests/6-7-the-referee-may-object.sql` — house style, asserting each I/O Matrix row
      against the specific constraint or message that refuses it, plus: the chain after a
      reverse-direction correction, and that a doer cannot call the function at all.
- [x] The referee's surface — a way to look up **one** named day and object to it with a reason.
      No list, no count, no badge, nothing that arrives unasked.
- [x] The author's surface — the objection's reason shown against that day wherever the day is
      already visible, and the notification body.
- [x] Client tests for both surfaces, including that the referee's home gains no list.

**Acceptance Criteria:**
- Given no referee action at all, when days settle, then every proven day holds and nothing about
  this feature runs — asserted, not assumed.
- Given an objection inside the window, when it is made, then the day is superseded with a full
  freeze, carries exactly one penalty, and the author is told with the referee's own reason.
- Given the author then spends a Grace Day, when the next pass runs, then that penalty voids exactly
  as any Failed Day's does.
- Given `supabase/tests/4-5-*.sql`, `4-6-*.sql`, `2-7-*.sql`, `2-9-*.sql` and `6-4-*.sql`, when they
  run, then they pass unmodified.

## Spec Change Log

### 2026-09-03 — iteration 1, `intent_gap`: the promised recourse did not exist on three paths

**Triggering findings.** Review found that the spec's central promise — "a Grace Day voids it, that is
deliberately the author's whole recourse" — is false wherever `grace_day_validate()`'s own
requirement (`failed` verdict **and** `owed` penalty) is not met: an objection landing on an
`expired` day, on a commitment carrying no penalty, or on a day whose penalty is already `waived`
leaves a broken chain, no Grace Day and no appeal. Separately: a Grace Day correction restamps
`settled_at`, so a day just forgiven reopened a fresh 48-hour objection window; the correction's
outcomes were recomputed from live commitments, so archiving a commitment inside the window defeated
the objection outright; and `object_to_day()` gated on the referee role without scoping to the
account he is paired to, turning a read exposure that `deferred-work.md` had accepted *because it was
read-only* into a write that mints a debt.

**Resolved with the author, 2026-09-03.** (1) Refuse the objection on all three no-recourse
landings, which makes the Grace Day promise true by construction rather than patching it afterwards
— and closes the reopened-window hole as a side effect, since a forgiven day's penalty reads
`waived`. (2) Keep the window measured from the current settlement; the author chose this knowingly.
(3) Close the archive hole by taking the correction's outcomes from the superseded settlement's own
frozen rows.

**Known-bad state avoided.** A referee action that breaks a chain and creates a debt the author has
no mechanism to answer, on the one code path in the project that moves a day toward `missed`.

**Also to log rather than leave silent.** Two places the implementation already departed from the
frozen text and should have said so: `object_to_day()` *reads* a `collected` penalty in order to
refuse it, which the Never bullet's wording forbade; and the author's push deliberately omits the
referee's free text (it would fail `push_body_is_sendable`), pointing at the Ledger instead, which
narrows the frozen AC "the author is told with the referee's own reason". Both are accepted; the
reason is still shown verbatim on the day it names.

**KEEP — must survive.** The guard ordering in `object_to_day()` (role first, before any row is
read). The refusal of a `collected` penalty. Carrying an existing penalty's state forward rather than
minting a fresh `owed` row. The full-day freeze itself. `referee_day_lookup()` as a `security
definer` single-settlement lookup rather than any RLS grant on `settlement_commitment`. The pull
shape of the referee's surface — one day, looked up, no list anywhere. `objection_body()` self-dating
so it passes `push_body_is_sendable`.

## Design Notes

**Why there is no case, no deadline and no expiry pass.** The author chose that the referee decides
outright. That removes the piece this story was blocked on: with no answer step there is no
deadline of the author's to expire, so nothing can fire against him while he is in a Silence
episode — the collision with Epic 5 disappears rather than being managed. It also means the
`appeal` skeleton cannot simply be pointed the other way: `appeal` has no state column at all, its
state lives on `penalty.state`, and the day an objection contests has no penalty to park state on.
What is reused is `rule_appeal()`'s *shape* — a referee-only `security definer` RPC that writes a
correction and mints a penalty — not the appeal table.

**Why this is the riskiest migration in the project.** Every correction written today goes one way:
`supersede_expiries()`, `rule_appeal()` approving, and `apply_grace_days()` all move a day toward
held, clean, or less money. This is the first that moves one toward missed, and the first to create
a debt on a day that previously cost nothing. Two guards carry that weight: the day must not already
carry a penalty in any state, and the correction must freeze the whole day rather than the objected
commitment alone.

**Why a lookup and not a list.** The referee reaching a day at all is in tension with never being
given a queue, and the tension is real rather than a wording problem. A lookup he initiates is pull;
a list is push wearing a different word. He objects when he already has a reason to — because he was
there, or because the author told him — not because the app showed him a page of days to work
through.

## Verification

**Commands:**
- `npm test` — expected: all existing tests pass, plus the new surface cases.
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check` — expected: clean.
- `npx supabase db reset`, then every file under `supabase/tests/` — expected: 39 pass, 0 fail, with
  `4-5-*`, `4-6-*`, `2-7-*`, `2-9-*` and `6-4-*` passing **unmodified**.
- `npm run migrations:check` — expected: the new migration reported as not yet pushed.

## Suggested Review Order

**The landing guard — read this first**

- Every refusal, in order, before anything is written. This is the story after the review.
  [`20260903140000…sql:399`](../../supabase/migrations/20260903140000_the_referee_may_object.sql#L399)

- Frozen rows copied, never recomputed — so archiving a commitment cannot defeat an objection.
  [`20260903140000…sql:645`](../../supabase/migrations/20260903140000_the_referee_may_object.sql#L645)

- Who the referee is paired to. A role check alone was never scoping.
  [`20260903140000…sql:101`](../../supabase/migrations/20260903140000_the_referee_may_object.sql#L101)

**What an objection is**

- The record: the day, the commitment, the reason verbatim, and who said it.
  [`20260903140000…sql:174`](../../supabase/migrations/20260903140000_the_referee_may_object.sql#L174)

- 48 hours from the settlement's own creation, never from the day it judges.
  [`20260903140000…sql:150`](../../supabase/migrations/20260903140000_the_referee_may_object.sql#L150)

- A body that self-dates, because a push that cannot say when is not sendable.
  [`20260903140000…sql:273`](../../supabase/migrations/20260903140000_the_referee_may_object.sql#L273)

**Pull, never push**

- One settlement, looked up by id — no range, no array, no feed.
  [`20260903140000…sql:335`](../../supabase/migrations/20260903140000_the_referee_may_object.sql#L335)

- The referee's whole surface for this: a date, a day, a reason. No list anywhere.
  [`referee-day-lookup.tsx:67`](../../components/referee-day-lookup.tsx#L67)

**What the author sees**

- The reason on the day it names, announced once, with no control of its own.
  [`ledger.tsx:316`](../../components/ledger.tsx#L316)
