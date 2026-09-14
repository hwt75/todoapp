---
title: "Story 8.2 — The referee's decision, and what a refusal costs"
type: 'feature'
created: '2026-09-14'
status: 'in-review'
review_loop_iteration: 2
baseline_commit: 'd9a4dda93d85146c5f8b048bdbb89440b710459a'
story_key: '8-2-the-referee-s-decision-and-what-a-refusal-costs'
context:
  - '{project-root}/_bmad-output/specs/spec-commitments-the-referee-signs-off/SPEC.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-8-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-8-1-a-commitment-can-ask-for-the-referee-s-signature.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-09-14 by hwt75** — including all four decisions below, and specifically decision 1,
> which reads SPEC.md's landing-guard constraint as holding for two of the three rules it names. Also
> approved at full length, above the 1600-token guidance, on the same grounds Story 8.1 was: the Code
> Map is what keeps the implementer out of a blind search, and the body it must not disturb is 300
> lines long. Frozen from here.
>
> **RENEGOTIATED 2026-09-14 by hwt75**, after review iteration 1 found the intent underdetermined in
> one place and wrong in another. Two additions, both his: a refusal now requires a photograph, read
> by the RPC itself rather than left to Story 8.4's list query (AD-1 — the server is the only judge);
> and a refusal is refused on `daily_hours_quota`, which reverses nothing he decided in Story 8.1 but
> stops the RPC reporting success for a decision `commitments_owing()` can never read. The matrix
> rows below carry both. See the Spec Change Log for what triggered them.

## Intent

**Problem:** Story 8.1 put the flag on the commitment and deliberately left nothing reading it. The
referee still has only the 48-hour objection, which supersedes a settled day, writes a correction,
voids a penalty and mints a replacement — the most intricate path in the schema, and it applies
whether the author asked for it or not.

**Approach:** A decision table the referee writes once per flagged commitment-day through one
`security definer` RPC, and one arm in `commitments_owing()` that turns a refusal into that day's own
`missed`. No supersession, no correction, no voided-and-reminted penalty. Server only: no UI, no
notification, no storage policy.

## Boundaries & Constraints

**Always:** The decision is its own table, keeping `objection`'s care — `referee_id` with `on delete
restrict`, the reason stored verbatim, the day and the commitment stored rather than derived. It is
append-only: no update policy, no delete policy, no withdrawal. The flag is read **only** through
`requires_referee_approval_as_of()`, never live, in both the RPC and the settlement arm. A refusal
lands strictly inside the local day it names. A flagged commitment is unreachable by `object_to_day()`,
enforced in SQL. Silence changes nothing: with no decision row, every settlement path behaves exactly
as it does today, and the pre-existing SQL files prove it by passing **unmodified**.

**Ask First:** Any grant to `authenticated` beyond the one RPC. Any read of `requires_referee_approval`
that is not through the `_as_of()` door. Any change to `settle_day()`'s deadline gate, to
`commitment_deadline()`, or to the day-boundary helpers. Taking the per-account advisory lock (see
decision 3). Making an approval change any outcome.

**Never:** No UI, no notification, no outbox call, no storage or evidence policy change — those are
Stories 8.3, 8.4, 8.5, 8.6. No change to appeals, collection, Grace Days, the morning question, or
the objection path for unflagged commitments. No second round between author and referee. No
withdrawal or edit of a decision. No day held open waiting for a person.

## The four decisions worth your attention

**1. Only two of `object_to_day()`'s four landing guards survive the move before midnight.** The SPEC
constraint names three and the code has four; both describe a path that supersedes a *settled* day.
Guard (a) — penalty state other than `owed`, `20260906080451:266-286` — cannot apply: `penalty` is
keyed by `settlement_id`, and a day that has not closed has no settlement and therefore no penalty.
Guard (c) — the `unanswered > 0` would-land-`expired` refusal, `:307-333` — cannot apply either: it
counts the *frozen rows of the settlement being superseded*, and at refusal time there are none; the
author still has until his deadline to answer. What survives is exactly the pair that is a fact about
the commitment rather than about a settlement: `carries_penalty_as_of()` false, and cadence
`weekly_quota`. Both are refused, both with `object_to_day()`'s own sentences adapted.

This contradicts the letter of SPEC.md's own constraint, which names the penalty-state guard among
the three it says are reused. **Resolved by hwt75 on 2026-09-14 in favour of two guards**, on the
grounds that the other two have nothing to read before a day settles: translating them would mean
inventing new rules under old names, not carrying old rules across. Recorded in the epic's
`.memlog.md`.

**2. The rule must fire identically for a timed and an untimed flagged commitment.** *(Mechanism
superseded at iteration 2 — see the Spec Change Log. A separate `refused` output column removes the
`case` entirely, so the placement hazard below is structurally gone rather than avoided. The intent
this decision exists for is unchanged and still load-bearing: the refusal reaches both shapes, and the
test must still prove it by construction rather than by inspection.)*

`20260829090000:323-331` is a `case` whose first arm returns `d.answer`
verbatim for every untimed commitment. Sign-off implies `requires_photo` (`20260911090000:73-74`) but
implies **nothing** about `due_time`, so an arm placed at the photograph test would silently never
fire for a flagged untimed commitment — a rule honoured by one reader and not another, which is the
exact shape of the three defects Epic 6 retrospective item 50 named. The refusal arm is first, and it
is gated on `requires_referee_approval_as_of(c.id, p_day)` as well as on the decision row: if the two
ever disagree the day holds, which fails toward the author.

**3. The RPC takes no advisory lock, unlike `object_to_day()`.** That function takes
`pg_advisory_xact_lock(hashtext(subject::text))` at `20260906080451:185` because it reads Penalty
state and currentness and then moves money. This one writes a single row and moves nothing; its only
contention is two decisions on one commitment-day, which the unique constraint plus `on conflict do
nothing` serialises — `object_to_day()`'s own race-loser idiom at `:348-351`. Holding the account key
for a write that decides nothing at write time would put a referee in the way of the author's Grace
Day for no gain.

**4. For an untimed flagged commitment, the referee necessarily decides before the author answers.**
His window closes at `day_ends_at(D)`; the author's own deadline for day D is
`declaration_deadline(D, morning_hour)`, the *next* morning (`20260829090000:82-97`). So the refusal
is written against a photograph, not against a claim, and it overrides whatever the author later says.
That is CAP-5 working as intended, and it is recorded here because nothing in the epic says it out
loud. A refusal also makes the commitment count as *answered*, so it pushes the day toward `failed`
rather than `expired`, which is the direction a Grace Day can reach. *(Mechanism superseded at
iteration 2: this is carried by the `refused` column and `settle_day()`'s derived `effective_answer`,
not by writing `'slipped'` into `answer` — because `answer` is also what three non-settlement readers
use to decide whether the **author** has gone quiet. The behaviour stated here is unchanged, and it is
what compels `settle_day()` to read the new column.)*

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Silence | Flagged commitment, photograph, no decision row | Day settles exactly as the unflagged case: same verdict, same frozen outcomes, same penalty, same chain | N/A |
| Approval | Referee approves before midnight | Row written; every settlement output byte-identical to the silence case | N/A |
| Refusal, timed | Flagged + timed, declared `held` with photo, refused at 21:00 | That commitment freezes `missed`; day reads `failed`; one `owed` penalty; a Grace Day still reaches it; every other commitment on the day settles as it would have | N/A |
| Refusal, untimed | Flagged, no `due_time`, commitment-day photo, refused before midnight, author never answered | Same as above — the arm fires above the `due_time is null` short-circuit | N/A |
| Flag off as of that day | Decision row would name a day the flag was off | Refused by the RPC; and if one existed, the settlement arm ignores it and the day holds | `That commitment did not ask for your signature on that day.` |
| Too late | `now() >= day_ends_at(p_for_day)` | Refused | `That day has closed. A signature lands before midnight or not at all.` |
| Not yet | `now() < day_begins_at(p_for_day)` | Refused | `That day has not started yet.` |
| No money on it | `carries_penalty_as_of()` false, refusal | Refused | names the broken chain no Grace Day could reach |
| Weekly Quota | `cadence = 'weekly_quota'`, refusal | Refused | names week close |
| Hours quota | `cadence = 'daily_hours_quota'`, refusal | Refused | names that measured minutes, never one day, decide it |
| No proof | Refusal on a commitment-day with no photograph | Refused | `There is no photograph on that day yet, so there is nothing to refuse.` |
| Author archives after a refusal | Refused at 21:00, archived at 21:30 | The refusal still lands: the day freezes `missed` with its penalty | N/A |
| Author turns the money off after a refusal | Refused at 21:00, `carries_penalty` off at 22:00 | The refusal still costs what it cost at 21:00 | N/A |
| Author changes cadence after a refusal | Refused at 21:00, cadence moved to **either** quota at 22:00 | The refusal still lands as a daily miss | N/A |
| Author archived it before the refusal | Archived at 08:00, refusal attempted at 21:00 | Refused — an archived commitment is not resurrected by a decision | `That commitment is archived, so its days are no longer being judged.` |
| Refusal counted as the author's answer | A refused day is read by the silence detector and the monthly answer rate | Neither counts it: the author answered nothing, and a third party's write must not make him look present | N/A |
| Second decision | A row already exists for that commitment-day | Refused, and the first row stands | `That day has already been decided, and a decision is final.` |
| Not the referee | Doer or `anon` calls the RPC | Refused **before any row is read** | `Only the referee may sign off a day.` |
| Wrong account | Paired to a different doer, or unpaired | Refused | `That commitment belongs to an account you are not paired to.` |
| Refusal with no reason | `p_approved = false`, reason blank or absent | Refused by the RPC before the CHECK fires | `A refusal has to say why. Give a reason.` |
| Objection on a flagged commitment | `object_to_day()` called on it | Refused | `That commitment asks for your signature on the day itself, not here.` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20260903140000_the_referee_may_object.sql:174-256` — **the table to copy the
  care from.** `referee_id … on delete restrict` with its reasoning `:178-186`; `reason text not null`
  with the verbatim comment `:196-198`; `objection_reason_is_said` `:206-211`; RLS `:241`, the single
  read-own policy `:245-247`, and `:249-256` — *no insert, update or delete policy for anyone, referee
  included.* **Depart from one thing:** `objection_once_per_day unique (subject, for_day)` `:223` is
  day-scoped because its correction freezes the whole day; this table is keyed per commitment-day,
  and the comment must say why the two differ. Also `:150-158` `objection_deadline()` — the shape not
  to reuse, since it is a function of `settled_at` and there is no `settled_at` before midnight.
- `supabase/migrations/20260906080451_collection_follows_the_current_penalty.sql:117-428` — the
  **live** `object_to_day()`. This is the body to `create or replace` with one guard added; do not
  start from the 6.7 file, which has neither the advisory lock nor the under-lock re-read. The four
  landing raises: (a) `:266-286`, (b-i) `:293-297`, (b-ii) `:301-305`, (c) `:307-333`. The
  `carries_penalty_as_of()` call at `:293` is the pattern for reading a money flag historically. The
  race-loser idiom is `:341-351`. Grants `:441-442`.
- `supabase/migrations/20260829090000_midnight_decides_the_day.sql:308-360` — `commitments_owing()`,
  the function to `create or replace`. The `case` is `:323-331`; `carries_penalty_as_of()` at `:322`
  and `due_time_as_of()` at `:335` are how an `_as_of()` reader is already called here. Filters
  `:338-359` (note `daily_hours_quota` excluded outright at `:339`). **Read-only, must not change:**
  `settle_day()` `:397-556`, its deadline gate `:472-476`, the counts `:439-448`, the verdict
  `:478-482`, penalty minting `:494-497`, the frozen write `:502-509`, `commitment_deadline()`
  `:82-97`, `day_ends_at()` `:39-46`, `day_begins_at()` `:55-62`.
- `supabase/migrations/20260819150000_commitment.sql:97-102` — `commitment: edit own`. The author may
  update `archived_at`, `carries_penalty` and `cadence` freely, all day, which is why a refusal has to
  be made of facts it froze rather than facts it will re-read. `components/commitment-list.tsx:205`
  is the archive path.
- `supabase/migrations/20260827130000_carries_penalty_freezes_by_day.sql:98-123` —
  `carries_penalty_as_of()`. **Read line 109 before trusting the name:** the cutoff is
  `(p_day + 1) midnight`, so it freezes at the day's end and a mid-day read predicts nothing.
- `supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql:51-53` — the three
  parentages an `evidence` row can have; the photograph test needs the claim-parented and the
  commitment-day arms both.
- `supabase/migrations/20260826110000_the_long_view_including_whether_this_still_works.sql:323` —
  `monthly_report` cross-joins `commitments_owing()` over a whole month, which is why the new arm's
  cheap test goes first.
- `supabase/migrations/20260911090000_a_commitment_can_ask_for_the_referee_s_signature.sql:184-245` —
  `requires_referee_approval_as_of()`, the one door. Revoked from `public, anon, authenticated`
  `:244-245`, so both new readers are `security definer` and call it internally. `:325-347`
  `has_paired_referee()` is the grant idiom; `:60-77` the three CHECKs already on the flag.
- `supabase/migrations/20260825090000_the_referee_rules.sql:88-149` — `rule_appeal()`, the write-RPC
  shape: `role_from_table() is distinct from 'referee'` as the **first statement before any row is
  read** `:110-112` (`is distinct from`, never `<>` — `:105-109` says why), null-argument guard
  `:118-120`, a distinct message for a bogus id `:124-126`. **Its `outbox_enqueue` call `:141-149` is
  what this story does not do.**
- `supabase/migrations/20260907160000_a_referee_belongs_to_one_doer.sql:57-79` — `paired_doer_id()`,
  `security definer`, revoked from `authenticated`; the RPC calls it internally.
- `supabase/migrations/20260819120000_account_and_roles.sql:44-57` — the rule: `role_from_token()` for
  reads, `role_from_table()` for every write and anything that moves money. `lib/roles.test.ts:60-87`
  fails the build if a `with check (...)` calls the token helper.
- `supabase/migrations/20260825100000_the_app_does_the_asking.sql:21-33` — **the prior incident.**
  Granting the referee `select` on `settlement_commitment` is also a grant on `chain_current`, a
  `security_invoker` view over it. Do not add a referee read policy to anything; he reads through a
  definer function in Story 8.4.
- `supabase/tests/6-7-the-referee-may-object.sql` — the test file to model. Step 1 `:426-463` is the
  *no referee action* baseline, the direct analogue of silence-approves. Step 11 `:1333-1548` is the
  landing guard, all arms. The refusal idiom (`v_refused` + `sqlerrm ilike '%fragment%'`) and
  `:679-681` — **`is distinct from`, never `<>`**, because `NULL <> 'missed'` is NULL and `if` treats
  it as false. Impersonation `:483-485`, restore `:525`.
- `supabase/tests/6-8-a-photo-i-can-keep-against-any-commitment.sql:16-22` — **the precedent for this
  story's most important proof**: the regression that matters is the pre-existing files passing
  unmodified, not a new assertion.
- `supabase/tests/8-1-a-commitment-can-ask-for-the-referee-s-signature.sql:23-53` — the
  `has_function_privilege` precondition to copy for the new RPC's grant; `:86-97` the user/referee
  fixture; `:111-117` why log stamps are set by hand.
- `supabase/tests/README.md:118-143` — an `evidence` row needs its `storage.buckets` and
  `storage.objects` rows staged first, **including rows expected to be refused**. `:145-174` the
  "What is here" table to add a row to. `:58-90` the `ci-clock-window` marker and when a file needs one.
- `supabase/tests/2-1-roles-and-rls.sql:470-548` — the catalog sweep. The new internal function goes
  in the must-be-revoked array; the new RPC goes in the commented exclusions beside `object_to_day()`
  and `referee_day_lookup()` at `:513-517`.

## Tasks & Acceptance

**Execution:**

- [x] `supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql` — one
      migration, four parts. **(i)** `public.referee_decision` with `subject` (cascade), `referee_id`
      (`on delete restrict`, carrying `objection`'s reasoning), `for_day`, `commitment_id` (cascade),
      `approved boolean not null`, `reason text` nullable, `carries_penalty` and `cadence` frozen at
      decision time, `created_at`; a CHECK that a refusal says why in 1–2000 characters and an
      approval carries no reason; `referee_decision_once_per_commitment_day unique (subject, for_day,
      commitment_id)` with the comment explaining the departure from `objection_once_per_day`; RLS on,
      one read-own `select` policy, and no insert/update/delete policy for anyone. **(ii)** the RPC,
      `security definer set search_path = ''`, refusals in the matrix's order with the role gate first
      and the pairing check above any read of the author's, `on conflict do nothing` plus a race-loser
      raise, revoked from `public, anon` and granted to `authenticated`. **(iii)** `create or replace
      public.commitments_owing()` — the full body from `20260829090000:308-360` with the new first
      `refused` output column, the `left join lateral`, and **every** cadence read moved onto the
      frozen value including the two in the `where` clause, per Design Notes. `drop function` +
      `create` because the signature changes, and re-issue the `revoke`. **(iv)** `create or replace
      public.object_to_day()` — the full body from `20260906080451:117-428` with one added guard
      refusing a flagged commitment, read through `requires_referee_approval_as_of()` with `is true`.
      **(v)** `create or replace public.settle_day()` — the full body from `20260829090000:397-556`
      with one derived `effective_answer` consumed by the deadline gate, the counts and the frozen
      write, and nothing else moved. **(vi)** `create or replace public.supersede_expiries()` — the
      same two reads, for the same reason. It carries `settle_day()`'s `admitted` shape at
      `20260829090000:607` and its outcome mapping at `:636`, and a correction it writes for an expired
      day would otherwise restore a refused commitment to `held` and make the penalty disappear. These
      two functions have shared a defect once already — `deferred-work.md`'s Story 3.3 entry records
      `supersede_expiries()` having the identical `weekly_quota` bug and being fixed in the same pass.
      This is the epic's standing instruction (Epic 6 retrospective item 50) applied to the last
      reader: every one of them moves through the door in the same change.
- [x] `scripts/test-sign-off-race.mjs` — two concurrent sessions decide the same commitment-day; the
      loser must raise and exactly one row must survive. The single-session test cannot reach the
      `on conflict do nothing` branch at all, because the check-then-act read always raises first, so
      decision 3's whole no-advisory-lock argument is currently unverified. Model it on
      `scripts/test-current-penalty-race.mjs` and wire it into `.github/workflows/ci.yml` beside the
      two race steps already there.
- [x] `supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql` — the live-doer
      preflight as step 0 (it calls `settle_day` with `p_override`), the `has_function_privilege`
      precondition for the new grant and its `anon` counterpart, then: the silence baseline asserted
      field by field against an unflagged twin; an approval changing nothing; a refusal on a timed and
      on an untimed commitment; **every row of the matrix, including the three author-edit rows and
      the no-photograph refusal**; the `object_to_day()` exclusion asserted on a commitment whose flag
      was switched off after the day, so the historical read is what carries it; an unpaired referee
      (`role = 'referee'`, `referee_of` null) refused; the stored `referee_id` read back and compared
      to the caller; and a catalog step asserting RLS on and zero non-`SELECT` policies on the new
      table. Scope every `update public.commitment` in the fixture with a `where`. Cover all **four**
      author edits, `daily_hours_quota` among them, and make the `weekly_quota` edit land on a *timed*
      commitment proven by a commitment-day photograph so the second `where` predicate is exercised
      rather than inert. Assert `chain_current` for the refused day, not only for the baselines —
      breaking the chain is what the mechanism is for. Assert the silence detector and
      `commitment_answer_rate_for_month()` do **not** count a refusal as the author's answer. Assert
      the acceptance criterion that has never had a test: a refusal recorded, the flag then switched
      off, the day still settling `missed`. Drive the append-only claim from a client session that
      holds `insert` as well as `update` and `delete`, assert the referee himself reads zero rows, and
      exercise the CHECK directly as `postgres` including the accepted 2000-character boundary.
- [x] `supabase/tests/2-1-roles-and-rls.sql` — add the new RPC to the commented exclusions and any new
      internal function to the must-be-revoked array. Do not claim coverage that lives in another file.
- [x] `supabase/tests/README.md` — one row in the "What is here" table, and keep the pass-count
      sentence true about which files this story modified.
- [x] `_bmad-output/implementation-artifacts/sprint-status.yaml` — `8-2…` to `in-progress`, then
      `review`; `last_updated` to today.

**Acceptance Criteria:**

- Given the migration is applied, when every pre-existing file under `supabase/tests/` is run
  unmodified after a `supabase db reset`, then all of them pass — a settlement path that had learned
  about a decision nobody made could not do that.
- Given a flagged commitment and an unflagged twin on the same day with the same proof, when nobody
  decides and the day settles, then the two produce identical verdict, frozen outcome, penalty and
  chain.
- Given a refused commitment-day that settles `failed` with an `owed` penalty, when the author spends
  a Grace Day on it, then it is waived exactly as a machine-filed miss would be.
- Given a decision row exists, when any client attempts to update or delete it over the API, then it
  is refused, and the author can still read his own.
- Given the flag was switched off after a refusal was recorded, when the day settles, then the refusal
  still stands — the arm reads the flag as of that day, not live.

## Spec Change Log

### 2026-09-14 — iteration 2, `bad_spec`: the fix reached three of four edits, and `answer` was the wrong carrier

**Triggering findings.** Two layers converged independently on the same root cause: iteration 1's
freeze reached the select list only, so the two `where` predicates that read `cadence` still read the
live column, and moving a refused commitment to `daily_hours_quota` dropped it out of the day
entirely — a fourth edit in the class iteration 1 existed to close. The fix also opened a new hole:
the archived exception has no time ordering, so a commitment archived at 08:00 could be refused at
21:00 and charged for a day it had already left.

Separately, and larger: synthesizing `'slipped'` into `answer` changed what **three non-settlement
readers** see. `count(o.answer)` is how the Story 5.2 silence intervention decides the author has gone
quiet (`20260826090000:156`, `20260826130000:74`) and how `commitment_answer_rate_for_month()` computes
SM-6 (`20260826110000:321`). A referee's write made a day the author answered nothing on look
answered — a third party deciding whether the author looks silent. The spec reasoned only about
`settle_day()` and never asked who else reads that column.

And the accepted-race note was wrong in a way that mattered: `settle_day()` reads
`commitments_owing()` five times under READ COMMITTED with the counts before the freeze, so a late
refusal can be **half**-honoured — `clean` with no penalty, frozen `missed`, a broken chain no Grace
Day can reach — not merely unhonoured.

**Amended.** The refusal becomes its own `refused` output column and `answer` keeps meaning what the
author said, which fixes all three readers at the root rather than patching each. Every cadence read
moves onto the frozen value, the `where` clause included. The RPC refuses an archived commitment. The
flag read moves inside the lateral, because `AND` operand order is not contractual and iteration 2's
performance argument rested on it. `settle_day()` gains one derived `effective_answer` consumed in
four places — compelled by frozen decision 4, which requires a refusal to count as answered so the day
lands `failed` rather than `expired`. The race is narrowed by refusing a decision on an
already-settled day, the note now states the half-honoured consequence, and the real closure (giving
`settle_day()` the per-account advisory lock every other writer already takes) goes to
`deferred-work.md` as its own story. **hwt75 chose both directions on 2026-09-14** — the separate
column over patching the three readers, and narrow-and-record over changing `settle_day()`'s locking
here.

**Known-bad state avoided.** A settlement that is internally inconsistent — `clean` with no penalty
beside a frozen `missed` — which no later correction path knows how to repair, and which
`grace_day_validate()` refuses on both of its conditions at once.

**KEEP — must survive re-derivation.** Everything in iteration 1's KEEP list still stands, with two
changes. Decision 2's *mechanism* is superseded: there is no `case` arm to place, so the hazard is
structural rather than avoided. Its *intent* is not superseded — the rule must reach a timed and an
untimed flagged commitment alike, and the test must still prove that by construction. Add: the
`drop function` + `create` on `commitments_owing()` must re-issue the revoke, and `2-1-roles-and-rls.sql`
passing is the proof it did.

### 2026-09-14 — iteration 1, `bad_spec` + `intent_gap`: a refusal the author could switch off

**Triggering findings.** The edge-case layer, confirmed against the code before triage: three edits
`commitment: edit own` permits between a refusal and midnight each void it. Archiving drops the
commitment out of `commitments_owing()`; turning `carries_penalty` off drains the penalty, because
`carries_penalty_as_of()` cuts at the day's **end** and a mid-day read predicts nothing; moving the
cadence to a quota takes it out of `admitted`. The implementation carried a comment asserting the
opposite — *"turning the money off at 22:00 must not decide what a refusal at 21:00 meant"* — which
the function it names does not deliver. Two more: `not requires_referee_approval_as_of(…)` fails open
on NULL, and the RPC read the commitment row before establishing the pairing, handing any referee a
commitment-id oracle across every account.

**Root cause, and it was the spec's.** The frozen matrix promised the refused commitment freezes
`missed` with an `owed` penalty; nothing outside the frozen block told the implementer that the
author can make that false three ways before midnight, and the Code Map cited `object_to_day()`'s
race-loser idiom without citing the archive reasoning eleven lines above it that exists for precisely
this. The implementation followed the spec it was given.

**Amended.** Design Notes gain the freeze-the-facts design (`carries_penalty` and `cadence` stamped
onto `referee_decision`, one `left join lateral` serving four uses, one narrow archived-filter
exception), the NULL fail-open rule, the cheap-test-first ordering, and the caller-before-author
ordering. Code Map gains `commitment: edit own`, `carries_penalty_as_of()`'s real cutoff, the evidence
parentages and `monthly_report`'s month-wide cross join. Tasks gain the three author-edit matrix rows,
the unpaired-referee case and the `referee_id` read-back.

**Two questions were intent, not spec, and hwt75 answered both on 2026-09-14** — recorded in the
frozen block's renegotiation note. A refusal now requires a photograph, checked by the RPC rather than
left to Story 8.4's query, because AD-1 makes the server the judge. And a refusal is refused on
`daily_hours_quota`: Story 8.1's deferred entry left the flag settable there and said the cheapest
place to answer it was this story, and without the guard the RPC reports success for a decision
`commitments_owing()` excludes outright and can never read.

**Known-bad state avoided.** Shipping an enforcement mechanism the person being enforced against can
switch off — the exact thing `20260906080451:365-370` refuses to ship for objections, one story later
and one layer down. Also avoided: a `comment on function` stating a guarantee its own dependency does
not provide, which is worse than no comment because the next reader trusts it.

**KEEP — must survive re-derivation.**

- The four-part migration, and `object_to_day()` and `commitments_owing()` reproduced **verbatim**
  from their live definitions with only the named additions — iteration 1 diffed both to prove it, and
  that proof must be reproducible.
- Decision 2's arm placement above the `due_time is null` short-circuit, and the way iteration 1
  proved it non-vacuous: move the arm down inside a rolled-back transaction and watch the untimed
  flagged commitment's day stop settling.
- The `has_function_privilege` precondition in both directions, `authenticated` and `anon`.
- The silence baseline compared field by field against an unflagged twin — the assertion this story
  exists to make.
- Refusing an approval that carries a reason, with a sentence rather than a bare CHECK violation.
- `is distinct from` / `is not true` over `<>` and `not`, everywhere, for the reason
  `20260825090000:105-109` gives.

## Design Notes

The new first arm of `commitments_owing()`'s `case`, which must sit above `when t.due_time is null`:

```sql
when public.requires_referee_approval_as_of(c.id, p_day)
     and exists (select 1
                   from public.referee_decision r
                  where r.subject = p_owner
                    and r.for_day = p_day
                    and r.commitment_id = c.id
                    and not r.approved)
  then 'slipped'::public.declaration_answer
```

The unique index leads with `(subject, for_day)`, which is exactly how this reads it, so no second
index is needed — `objection`'s `:221-222` makes the same argument.

**`created_at` uses `now()`, not `clock_timestamp()`.** The `_change` log tables need the latter
because several rows land in one transaction and the log stops being orderable if they tie; here the
unique constraint permits exactly one row per commitment-day, so there is nothing to order.

**The fixture trap in the settlement steps.** `settle_day()` skips a whole day if *any* owed
commitment still has `answer is null` before its deadline (`20260829090000:472-476`), and an untimed
commitment's deadline is the next morning. Every commitment in a fixture that settles today must
therefore carry an answer, or the refusal step will silently assert against a day that never settled.
Give each one a declaration; do not move the clock. No `ci-clock-window` marker is needed — every
instant compared is one the file wrote itself.

**A refusal must survive everything the author can still do to the commitment that day.** This is the
part iteration 1 got wrong, and it is the reason the code was re-derived. Three edits the author can
make between a refusal and midnight each void it, and `commitment: edit own`
(`20260819150000:97-102`) permits all three:

- **Archive.** `commitments_owing()` drops any commitment whose `archived_at` date is on or before the
  day, so archiving at 21:30 removes a 21:00 refusal from settlement entirely — no `missed`, no
  penalty, no trace. `object_to_day()` names this exact attack at `20260906080451:365-370` and
  defeats it by copying frozen rows instead of recomputing; this path has no frozen rows to copy.
- **`carries_penalty` off.** `carries_penalty_as_of()` cuts at `changed_at <= (p_day + 1) midnight` —
  the day's **end**, not its start (`20260827130000:109`). Reading it at 21:00 therefore says nothing
  about what it will say at settlement. Any comment claiming a refusal at 21:00 is safe from a toggle
  at 22:00 is false; do not write one.
- **Cadence to a quota.** `settle_day()`'s `admitted` count excludes `weekly_quota` by reading
  `o.cadence` live through `commitments_owing()` (`20260829090000:441-443`).

The fix hwt75 chose is to **freeze the money-relevant facts onto the decision row** and have
`commitments_owing()` prefer them — the same shape Epic 4 retrospective item 27 used on
`file_auto_check_result()`. `referee_decision` gains `carries_penalty boolean not null` and `cadence
public.commitment_cadence not null`, both stamped by the RPC from the values its own guards just
read, so the row records the world the refusal was made in. Then one `left join lateral` serves all
four uses:

```sql
left join lateral (
  select r.carries_penalty, r.cadence
    from public.referee_decision r
   where r.subject = p_owner and r.for_day = p_day and r.commitment_id = c.id
     and not r.approved
     and public.requires_referee_approval_as_of(c.id, p_day) is true
) rd on true
```

**The refusal is its own output column, not a synthesized `answer`.** `commitments_owing()` gains
`refused boolean not null`, true exactly when `rd` matched. `answer` keeps meaning what it has always
meant — what the *author* said — and every existing expression that reads it is untouched.

- `refused` is output as `rd.* is not null`;
- `carries_penalty` is output as `coalesce(rd.carries_penalty, public.carries_penalty_as_of(c.id, p_day))`;
- `cadence` is output as `coalesce(rd.cadence, c.cadence)` — **and so is every other read of cadence,
  including the two in the `where` clause** (`c.cadence <> 'daily_hours_quota'` and the timed
  `weekly_quota` exclusion). Iteration 2 froze the cadence in the select list only, and a `where`
  predicate reading the live column still dropped a refused commitment out of the day when the author
  moved it to `daily_hours_quota` — the fourth edit, in the class iteration 1 was supposed to close;
- the archived filter gains one narrow exception: keep the row when `rd` matched.

A day with no matching decision reads `rd.*` as NULL throughout, every expression collapses to exactly
what it computes today, and `refused` is false — which is what the unmodified pre-existing files prove.

**The flag read goes inside the lateral, not beside it in a conjunction.** Putting it in the `where`
of the lateral evaluates it **once per decision row** rather than once per commitment per day.
Iteration 2 wrote it as `rd.approved is false and requires_referee_approval_as_of(…)` and argued the
cheap test would short-circuit — but `AND` operand order is not contractual in PostgreSQL, so that was
a hope, not a structure. It matters: `settle_day()` calls this five times per account per day and
`commitment_answer_rate_for_month()` cross-joins it over a whole month (`20260826110000:321-323`).

**`settle_day()` must read the new column in four places, and this is the only reason it changes.**
Frozen decision 4 requires a refusal to count as answered and push the day toward `failed` rather than
`expired`, because `expired` is the one verdict a Grace Day cannot reach. With `answer` left alone,
that behaviour has to come from `refused`: the deadline gate (`20260829090000:472-476`) must not wait
on a refused commitment, `answered` (`:439-448`) must count it, `admitted` (`:441-443`) must count it
when it carries a penalty and is not a `weekly_quota`, and the frozen-outcome mapping (`:502-509`) must
write `missed`. Express it once as a derived `effective_answer` rather than separate conditions, so
they cannot drift apart — and then route **every** read that asks "does this commitment have an
answer" through it, counting the AD-13 Auto-check gate. Do not exempt one on the grounds that a
flagged commitment cannot carry an Auto-check: `commitment_sign_off_not_with_auto_check` is a CHECK on
the **live** row, and `commitment: edit own` lets the author unflag at 22:00 and attach a check a
second later, at which point the gate holds the whole account's day open for up to 96 hours. An
exemption argued from a live-row CHECK is the same false equivalence as the `carries_penalty` comment
above, one gate along. Nothing else in `settle_day()` moves — in particular
`commitment_deadline()` and the day-boundary helpers do not.

**Adding a column means `drop function` and `create`, not `create or replace`.** A `returns table`
signature cannot be changed in place. `drop function` destroys the ACL and a bare `create` in `public`
hands EXECUTE straight back to PUBLIC, `anon` included — the hazard
`20260903090000:43-47` records for `outbox_enqueue`. Re-issue
`revoke execute on function public.commitments_owing(uuid, date) from public, anon, authenticated`
in the same migration. `supabase/tests/2-1-roles-and-rls.sql:480` already asserts it and will catch a
miss, which is the point of that file.

**The RPC refuses an archived commitment.** Iteration 2's archived exception has no time ordering, so
a commitment archived at 08:00 and refused at 21:00 was pulled back into the day and charged — a
commitment the author retired before the referee ever looked at it. The exception stays as it is;
the ordering is enforced at the other end, by refusing to write a decision against an archived
commitment at all. Two narrow rules, each true on its own, rather than one timestamp comparison whose
correctness depends on reading both.

**`not f(...)` does not raise when `f(...)` is NULL.** `requires_referee_approval_as_of()` returns
NULL for a commitment with no log rows, so `if not public.requires_referee_approval_as_of(…) then
raise` fails open, and so does `if public.requires_referee_approval_as_of(…) then raise` in the
`object_to_day()` guard. Use `is not true` / `is true`. This is the same hazard the role gate already
guards with `is distinct from` rather than `<>` (`20260825090000:105-109`), one function along.

**A refusal needs a photograph, and the RPC is what checks it.** CAP-6 keeps photograph-less days off
the referee's list, but a condition that lives only in Story 8.4's query is not enforced — AD-1 says
the server is the sole judge. Both arms must count: a commitment carrying a `due_time` proves itself
with the claim-parented photograph, one without with the commitment-day photograph, per the SPEC's own
assumption. `20260903120000:51-53` is where the three parentages are declared. Match whatever Story
8.4's list will ask, because these two must not be able to disagree.

**Establish the caller before reading anything of the author's.** The pairing check belongs above the
commitment lookup, not below it: a referee who can tell `'No such commitment.'` from `'That commitment
belongs to an account you are not paired to.'` has a commitment-id oracle across every account.
`object_to_day()` orders itself this way (`20260906080451:143-179`) and says why at `:181-184`.

**The midnight race, narrowed — and it is worse than iteration 1 said.** `now()` is transaction-start
time, so a decision begun at 23:59:59.9 commits after midnight and may land while `settle_day()` is
running. Iteration 1 recorded the consequence as "simply not honoured, the day holds on the
photograph", which is wrong. `settle_day()` calls `commitments_owing()` in five separate statements
under READ COMMITTED (`20260829090000:449, 464, 473, 509, 520`), and the counts and the penalty insert
(`:439-497`) run *before* the frozen-outcome write (`:502-509`). A refusal committing between those
two produces a settlement reading `clean` with `missed_count = 0` and no penalty, while the frozen row
for that commitment reads `missed` — a broken chain with nothing for a Grace Day to attach to, which
is the exact state the landing guards exist to prevent. The refusal can be **half**-honoured.

Narrow it: the RPC refuses when a `kind = 'day'` settlement already exists for that subject and day.
That is check-then-act and does not eliminate the window, but it takes it from "the whole of
`settle_day()`'s run" down to the instant between the check and the insert, and it turns the common
case — a referee deciding a day the cron already settled — from a silent no-op into a sentence.

**Closing it properly is out of scope and recorded.** The real fix is the per-account advisory lock
`hashtext(owner_id::text)` that `grace_day_validate()`, `appeal_hold_penalty()`,
`mark_penalty_collected()` and `object_to_day()` all already take, and that `settle_day()` — alone
among the writers — does not. Giving it to `settle_day()` would close this and several older races
with it, and it is a change to the most load-bearing function in the schema. It belongs to its own
story, not to this one; it goes in `deferred-work.md` with this finding as its evidence.

## Verification

**Commands:**

- `npx supabase db reset` then every file under `supabase/tests/` — expected: all 47 pass, 0 fail,
  and **every pre-existing file unmodified**.
- `npm test` — expected: 1451+ green across 53 files (no client change in this story, so the count
  should not fall).
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check`, `npm run build` — expected: clean.
- `npm run migrations:check` — expected: reports the new file as not yet on the remote, which is what
  keeps this story out of `done` until it is pushed.

**Manual checks:**

- `git diff` shows zero changes to `commitment_deadline()`, `day_ends_at()`, `day_begins_at()`, and to
  every file under `supabase/tests/` except the new one, `README.md` and `2-1-roles-and-rls.sql`.
- The re-declared `settle_day()` differs from `20260829090000:397-556` only by the derived
  `effective_answer` and its four uses — diff it and say so, the way iteration 2 did for
  `object_to_day()`.
- `commitments_owing()` is revoked from `public, anon, authenticated` after the drop-and-create, and
  `2-1-roles-and-rls.sql` passes, which is what proves it.

## Suggested Review Order

**Start here — what a refusal is made of**

- The frozen facts are the whole design: a decision records the world it was made in.
  [`20260914090000:39`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L39)

- One lateral serves every use, and the flag read lives inside it, not beside it.
  [`20260914090000:600`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L600)

- The new output column: `answer` still means what the author said, and only that.
  [`20260914090000:545`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L545)

**The one door every reader goes through**

- The combiner. Every question of "does this have an answer" resolves here.
  [`20260914090000:495`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L495)

- `settle_day()`: the counts, the deadline gate, the frozen write, the summary.
  [`20260914090000:1089`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L1089)

- `supersede_expiries()`: the same two reads, plus `timely`, which had no answer to compare.
  [`20260914090000:1322`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L1322)

- The AD-13 gate, routed through the door: a live-row CHECK cannot be leaned on.
  [`20260914090000:1131`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L1131)

**What the referee may say, and what he may not**

- The RPC. Role gate first, pairing before any read of the author's, then the matrix in order.
  [`20260914090000:202`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L202)

- One guard added to a 300-line body, and machine-checked to remove nothing.
  [`20260914090000:673`](../../supabase/migrations/20260914090000_the_referee_s_decision_and_what_a_refusal_costs.sql#L673)

**The proofs that matter most**

- Silence: a flagged day nobody decided, compared field by field with its unflagged twin.
  [`8-2-…sql:876`](../../supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql#L876)

- The six edits the author can make after a refusal, each still landing `missed`.
  [`8-2-…sql:1060`](../../supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql#L1060)

- The refusal reaches an untimed commitment its author never answered.
  [`8-2-…sql:1020`](../../supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql#L1020)

- Every matrix row, one refusal sentence at a time.
  [`8-2-…sql:1322`](../../supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql#L1322)

**Peripherals**

- Append-only proved from a client session holding insert, update and delete.
  [`8-2-…sql:1656`](../../supabase/tests/8-2-the-referee-s-decision-and-what-a-refusal-costs.sql#L1656)

- The race-loser branch, unreachable from one session and therefore driven from two.
  [`test-sign-off-race.mjs:1`](../../scripts/test-sign-off-race.mjs#L1)
