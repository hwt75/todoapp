---
title: 'Story 3.0 — Change the hour I am asked, and see what is switched off'
type: 'feature'
created: '2026-08-20'
status: 'approved'
baseline_commit: 'bdc7362'
review_loop_iteration: 0
story_key: '3-0-change-the-hour-i-am-asked'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-2-retro-2026-08-20.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

> **APPROVED 2026-08-20 by hwt75** — all five decisions, including the two flagged as worth
> weighing: D3, which edits `push-probe.tsx` to share its refuse-before-prompting code, and D4,
> which leaves the referee-pairing and grace-day rows out entirely rather than showing them
> disabled. Frozen from here.
>
> Stamped in its own commit, before any implementation. That is the point of it: all ten Epic 2
> specs were stamped in the same commit as their code, so the record showed that approval happened
> but not that it happened first (retro P2b).

## Intent

**Problem:** The one blocking question in this product arrives at 07:00 and there is no way to
move it. `morning_hour` has been a real, range-checked, grantable column since Story 2.4's
migration, and `lib/use-gate.ts:51` reads it with a hardcoded fallback of 7 — so the back end has
been ready for a month and there is no way in. Story 2.4 declared the hour "configurable from
Settings, per UX-DR17" as an acceptance criterion, and Epic 2 shipped without it, without
deferring it and without recording it (retro A3).

The team discussion found the gap larger than one file (T2). **There is no Settings surface at
all.** Notification permission — the switch that turns on this product's only delivery channel —
is granted solely through `components/push-probe.tsx:85`, which describes itself as Story 1.2's
diagnostic apparatus and is the only `Notification.requestPermission()` call in the codebase. So
the product's most load-bearing switch lives in a debugging tool, and the hour that decides when
the author is interrupted is a constant.

**Approach:** One surface, four rows, and nothing invented. The morning hour writes to the
author's own profile through the column grant that already exists, so the database keeps deciding
what is allowed (AD-7). Notification permission and home-screen install state are **read and
explained** rather than toggled: each says what breaks while it is off, in plain language, because
a toggle that cannot honestly represent an OS-level permission is worse than a sentence. The rows
this epic cannot fill — referee pairing, grace days — are absent rather than shown disabled.

## Decisions

### D1. The hour is written straight to `profile`, with no RPC in front of it

`grant update (morning_hour) on table public.profile to authenticated` exists, and
`20260819201000_close_role_self_promotion.sql` revoked the table-wide UPDATE that once made that
grant decoration. `supabase/tests/2-1-roles-and-rls.sql` drives both halves: a session sets its own
morning hour and is refused when it tries to set `role` in the same way.

So a plain `update` from the client is already exactly as constrained as a `security definer`
function would be, and adds no place for a second copy of the rule. **Proposed: write the column
directly.** A wrapper function here would be ceremony that has to be kept in step with a grant
that is already correct.

The range check stays where it is. The form offers 0–23 because that is what an hour is, and the
database refuses anything else — a client that could send 25 gets an error rather than a silently
clamped hour, since a silently clamped hour is a question arriving at a time the author did not
choose.

### D2. Permission and install state are shown, not toggled

`EXPERIENCE.md` § Settings is explicit: "Permission states are shown with what breaks if they are
off, in plain language, not as toggles alone. Install state matters more than any other row."

A toggle implies the app can turn the thing off. It cannot: revoking notification permission is
done in iOS Settings, and un-installing is done by deleting the icon. A control that appears to do
something it cannot is the failure mode this product can least afford, because the symptom is
silence — and silence is indistinguishable from the product working and the author ignoring it.

**Proposed:** each row states its current state, one sentence on what breaks while it is off, and
a control only where the app genuinely has one — a **Turn on notifications** button, shown only
when permission is `default`. Once `granted` or `denied`, the row explains and names where the
real switch lives.

### D3. Permission is asked for here, and the probe stops being the only route

Asking is a one-shot on iOS: `Notification.requestPermission()` prompts once and every later call
returns the standing answer. The probe already guards this properly — it refuses a browser tab and
a missing VAPID key *before* prompting, because spending the single prompt on a misconfigured
build wastes it.

**Proposed:** the Settings row reuses that discipline rather than repeating it. Extract the
"refuse before prompting" checks and the subscribe-then-save path into `lib/push-subscribe.ts`,
called by both surfaces. The probe keeps its textarea and its CLI fallback — Story 1.2's
diagnostic value is real and `deferred-work.md` records why it survives — but it stops being the
only door.

**Not proposed:** deleting the probe. That is a separate decision and it belongs to whoever
retires the CLI path.

### D4. Rows this epic cannot fill are absent, not disabled

`EXPERIENCE.md` lists five rows: morning hour, notification permission, install state, referee
pairing, grace days remaining. The last two belong to Epic 4 and Epic 5 — there is no referee, and
`penalty_state` deliberately has only `owed` because "each state is added by the story that makes
it reachable, so no screen ever renders a state nothing can produce".

**Proposed:** build three rows and leave two out, with this spec naming both and the story that
brings each. A greyed-out *Referee pairing* row would be a promise with a date the author cannot
see, and Epic 2's own lesson is that an unbuildable control shown anyway is how a screen starts
lying quietly.

### D5. The hour moves the reminders too, and that is a consequence rather than work

`enqueue_gate_reminders()` already reads `p.morning_hour` per account and derives its slot from
it, and `settle_day` derives the expiry deadline from it through `declaration_deadline`. Nothing
in either needs changing: moving the hour moves the question, its reminders and the deadline
together, because all three read one column.

Worth stating because it is the reason this story is small. What it is **not** is retroactive: a
day already settled keeps the deadline it was judged against, since `settlement` froze its verdict
(AD-5). The spec's I/O matrix says so out loud.

## Boundaries & Constraints

**Always:**

- The hour is written to the author's own row through the existing column grant. No new RPC, no
  service-role path, no client deciding whose row it is (AD-7).
- Permission and install state are read from the browser and explained. Neither is stored in the
  database by this story.
- The surface is reachable from Today and returns to it, the same shape the Ledger and Chains
  detail already use — no navigation library, no route, because the app is one page by design.
- Every state has a sentence. A row that says only `denied` is a row that made the author search
  the internet.

**Ask First:**

- Storing permission state in `push_subscription` or `profile`. It is a browser fact that changes
  outside the app, and a stored copy is a stale copy.
- Any change to `push-probe.tsx` beyond extracting shared code — retiring it is a separate
  decision.
- Adding referee pairing or grace-day rows.

**Never:**

- A toggle for a permission the app cannot revoke.
- Clamping an out-of-range hour silently.
- A second read of `morning_hour` with its own fallback. `lib/use-gate.ts` has the one at 7; this
  story must not add a second constant that can disagree with it.

## I/O & Edge-Case Matrix

| Input / situation | Expected |
| --- | --- |
| Hour changed to 9 | `profile.morning_hour = 9`; tomorrow's gate, its reminders and the deadline all follow, because all three read the column |
| Hour changed while a day is already settled | The settled day keeps the deadline it was judged against (AD-5). No re-settlement, no back-dating |
| Hour sent outside 0–23 | Refused by `profile_morning_hour_range`; the surface shows the database's refusal rather than pretending it saved |
| Update refused by policy | The message is shown verbatim, the field keeps the value the author typed, and nothing claims to have saved |
| Permission `default` | A **Turn on notifications** control, and the sentence naming what does not arrive until it is on |
| Permission `granted` | Stated, with no control. The subscription is upserted if one does not exist yet |
| Permission `denied` | Stated, with the sentence that iOS will not ask again and where the real switch is. No control |
| Launched in a browser tab | The install row leads, and permission is not offered at all — a subscription made in a tab silently receives nothing |
| Signed out | The surface is not reachable. It has nothing to show and nothing to write |

## Code Map

- `components/settings.tsx` — the surface: the hour, the two state rows, and back to Today.
- `lib/push-subscribe.ts` (new) — the refuse-before-prompting checks and the subscribe-and-save
  path, extracted from `push-probe.tsx` so both callers share one copy (D3).
- `lib/settings.ts` (new) — how a permission state and an install state read as a sentence. Pure,
  so the copy is testable without a browser, the same way `lib/commitment-state.ts` is.
- `components/push-probe.tsx` — calls the extracted module; behaviour unchanged.
- `app/page.tsx` — a way in, alongside the Ledger.
- `lib/use-gate.ts` — unchanged, and deliberately: it already reads the column.

## Tasks & Acceptance

- [x] `lib/settings.ts` + test — permission and install states as sentences, every state covered,
      no state rendering as `undefined`.
- [x] `lib/push-subscribe.ts` + test — the two refusals before prompting, and the upsert that
      revives a device marked dead.
- [x] `components/push-probe.tsx` — call the extracted module, no behaviour change, existing tests
      still pass untouched.
- [x] `components/settings.tsx` + test — the hour writes and refuses; each state row shows its
      sentence; the control appears only at `default`; a browser tab leads with install state.
- [x] `app/page.tsx` — reachable from Today, returns to Today.
- [x] `supabase/tests/3-0-morning-hour.sql` — a session sets its own hour, an out-of-range hour is
      refused, and setting the hour does not move a settled day's deadline.

**Acceptance Criteria** (from `epics.md` § Story 3.0): the hour is written through the existing
column grant and the gate, reminders and deadline follow it; permission and install state are
shown with what breaks if they are off, in plain language rather than as toggles alone; permission
can be granted from inside the installed app so the probe is no longer the only route, and a
refusal names the answer the browser gave; rows this epic cannot fill are absent rather than empty.

## Verification

**Commands:**

- `npm test` — expected: the new `lib/` and component tests pass alongside the existing 480.
- `npx tsc --noEmit && npm run lint && npm run format:check` — expected: clean.
- `docker exec -i supabase_db_todoapp psql -U postgres -d postgres -v ON_ERROR_STOP=1 <
  supabase/tests/3-0-morning-hour.sql` — expected: PASS.

**On the device, and only the author can do these:**

- Change the hour to one a few minutes ahead, and confirm the morning question arrives at it the
  next day rather than at 07:00.
- Grant notification permission from Settings on the installed app, and confirm a push arrives
  without the probe having been opened.

## Verification record

**Built and checked on 2026-08-20**, on the branch this spec was approved on.

`npm test` — 512 passing across 28 files, up from 480. `npx tsc --noEmit`, `npm run lint` and
`npm run format:check` all clean. `supabase/tests/3-0-morning-hour.sql` passes against a local
stack: a session moves its own hour through the column grant; the same statement widened by one
column to set `role` is refused and the role does not move; 24 and -1 are both refused rather than
clamped, and a refused write leaves the hour where it was; the deadline follows the hour; and a day
already settled is not re-judged when the hour changes (AD-5).

`components/push-probe.test.tsx` was not touched and still passes — the extraction in D3 was meant
to be invisible to it, and it was.

**What was not built, by name.** This is the section Story 2.4 did not have, which is how its own
missing Settings surface went unnoticed for an epic (retro A4):

- **Referee pairing.** No referee account exists; Epic 4 Story 4.5 brings one. Left out entirely
  per D4, not shown disabled.
- **Grace days remaining.** `penalty_state` has only `owed`, and a grace day cannot be produced
  until Epic 5 Story 5.1. Same treatment.
- **A settings entry point on the Today screen itself.** The control sits beside Today rather than
  inside it: Today answers "where do I stand" and a settings link inside it would be the first
  thing to make it a menu.

**Left for the author, because no file here can answer it.** Changing the hour to one a few minutes
ahead and confirming the morning question arrives at it rather than at 07:00; granting notification
permission from Settings on the installed app and confirming a push arrives without the probe
having been opened. Both are why this story stays at `review` rather than moving itself to `done`.

**One consequence for Story 2.4.** Its criterion read "configurable from Settings, alongside
notification permission state and referee pairing, per UX-DR17". Two of the three now exist. The
third cannot exist in this epic, so 2.4 is no longer blocked on anything buildable — whether that
closes it is `hwt75`'s call rather than this spec's.

</frozen-after-approval>
