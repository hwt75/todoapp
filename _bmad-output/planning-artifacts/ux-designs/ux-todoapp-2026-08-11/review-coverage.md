# Coverage review — todoapp UX spines

Two-way trace between `prd.md` FRs and `EXPERIENCE.md` surfaces. Verdict: **adequate with four real
gaps.** 26 FRs, 22 fully realised by a named surface, 4 with holes.

## FR → surface

| FR | Surface | Verdict |
|---|---|---|
| FR-1 Commitment configuration | Task setup | ok |
| FR-2a Whose word settles | Task setup banner, Appeal | ok |
| FR-2 Judging by Cadence | Day Close, Week close | ok |
| FR-3 Push-resident, persistent | Notification contract | ok |
| FR-4 Quota-aware reminders | Notification contract, Today pill | ok |
| FR-5 Focus prompt | KF-2 | ok |
| FR-6 Location Auto-check | Task setup | **conflict** |
| FR-7 Movement Auto-check | Task setup | ok |
| FR-8 External account Auto-check | Task setup | **gap** |
| FR-9 Blocking Declaration | Morning Declaration | **conflict** |
| FR-10 Day Close | Today, Day summary | ok |
| FR-11 Focus Session | Focus Session | ok |
| FR-12 Quota progress visibility | Notification contract | ok |
| FR-13 Penalty accrual | Ledger | ok |
| FR-14 Same-day Appeal | Appeal | ok |
| FR-15 Ruling deadlines | Appeal hold text, referee timeout note | ok |
| FR-16 Silence intervention | Today state, KF-4 | **conflict** |
| FR-17 Grace Days | Silence intervention, Settings | **gap** |
| FR-18 Escalation to Referee | — | **gap** |
| FR-19 Referee account | Login | ok |
| FR-20 Rule on Appeal | Appeals and collections | ok |
| FR-21 Collection | Appeals and collections | ok |
| FR-22 Day summary | notification | ok |
| FR-23 Week Close | Week close | ok |
| FR-24 Monthly report | Monthly report | ok |
| FR-25 Chains | Chains detail, Today pills | ok |

## Findings

**critical — The silence intervention and the blocking Declaration contradict each other.**
`EXPERIENCE.md` § Notification contract states the morning slot is reserved for the Declaration and
"nothing else may occupy it". § Voice and Tone and KF-4 both state the day-two intervention *replaces*
the morning's notifications. Silence is by definition caused by unanswered Declarations (FR-9), so
the intervention fires exactly when Declarations are outstanding — and then suppresses them. Nothing
says what happens to those open days. They cannot close (FR-10 needs every Declaration filed), so
they accrue no Penalty, hold no verdict, and the Chain neither breaks nor continues.
*Fix:* decide explicitly. Either the intervention carries the outstanding Declaration inside it (one
message, one question, still blocking), or Declarations older than N days expire to a defined state.
The second needs a rule for whether expiry is a miss — and FR-15's "timeouts resolve in the author's
favour" would say it is not, which means going quiet is cheaper than answering honestly.

**high — FR-18 escalation has no referee surface.**
The referee's home is specified with four states: empty, appeals pending, collections outstanding,
both. None of them is "he has gone quiet". FR-18 requires the referee be notified after sustained
silence, and this is the escalation that the brief's top-ranked risk depends on. There is nowhere for
it to land, and no copy for it — while every other referee-facing string is specified verbatim.
*Fix:* add a fifth referee state and its string. It is also the only message where the referee is
asked to act as a person rather than a process, so its voice matters more than the others.

**high — A Grace Day can only be spent inside the silence intervention.**
FR-17 says the author can spend a Grace Day to void a day's Penalty. The only surface offering that
action is the day-two intervention. A normal Failed Day — slipped once, answered honestly, still
engaged — has no path to a Grace Day at all. That inverts the incentive: to use the allowance you
must first go quiet for two days, which is the exact behaviour the product exists to suppress.
*Fix:* offer it from the Day summary and from the Ledger row for an owed day.

**medium — FR-8 has no account-linking surface.**
"Account elsewhere" appears as a toggle in Task setup, but nothing specifies how the external account
is connected, where credentials or a username go, or what the toggle shows before it is linked.
*Fix:* specify it inside Task setup as a sub-state of the toggle, or state that v1 accepts a public
profile URL only and needs no auth.

**medium — Permission loss is a UX state with no FR behind it.**
`EXPERIENCE.md` lists a Today state for "a check is configured but its permission is revoked", and
Settings shows permission states with consequences. No FR covers this. Location permission on iOS can
be downgraded silently, and under FR-2a a penalty-carrying Commitment with a broken Auto-check would
report a miss the author cannot correct directly.
*Fix:* add an FR. A revoked permission must behave like an unavailable service under FR-8 — reported
as unavailable, never as a miss.
