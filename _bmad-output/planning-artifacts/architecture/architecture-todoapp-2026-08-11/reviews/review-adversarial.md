# Adversarial review — two compliant units that still build incompatibly

Method: construct pairs of units one level down that obey every AD to the letter and still collide.
Verdict: **four real holes.** The money path is well fenced (AD-8, AD-9); the holes are all in the
things *next to* money — chains, timing, and attribution — where no owner was named.

## Findings

**critical — `chain` has no single writer, and two compliant paths both want to write it.**
AD-8 fixes exactly one writer for `penalty`. Nothing does the same for `chain`. Two units can each
obey every AD: `settle_day()` extends or resets a chain at Day Close, while the grace-day path
(FR-17, "a Grace Day preserves a Chain") writes a correcting row under AD-9 and repairs the chain it
finds. Run both over the same day and the chain is extended twice, or reset then repaired to a
different value depending on ordering. Neither unit broke a rule.
*Fix:* extend AD-8's single-writer rule to every derived value — chain, ledger balance, quota
progress — naming settlement functions as the only writer, with grace and appeals emitting events
that settlement folds in rather than repairing state themselves.

**high — Nothing orders the external Auto-check read against Day Close.**
AD-10 says absence of a result is `unavailable`. It never says when absence is evaluated. A builder
scheduling `settle_day()` at 00:05 and the external-check drain at 00:10 produces a system where the
TryHackMe check is *always* `unavailable` — permanently falling through to a Declaration the author
must answer every morning for a commitment he configured precisely so he would not be asked. Both
units obey every AD.
*Fix:* an AD fixing the order — external checks for day D must resolve before `settle_day()` runs
for D, and settlement must refuse to run for a day whose checks have not been attempted.

**high — "Which day does a focus session belong to" is undefined.**
`focus.started` at 23:50, `focus.stopped` at 00:20. AD-6 fixes the timezone, so both builders agree
what a day *is* — and can still disagree about attribution: one credits the start day, one the stop
day, a third splits it at midnight. All three obey AD-1, AD-4, and AD-6. The daily hours quota then
differs by up to a full session, which under a flat penalty is the difference between a Failed Day
and a clean one.
*Fix:* an attribution rule in the conventions or an AD. Crediting the start day is simplest and
matches how the author experiences the session.

**high — Appeal ruling and Week Close can both resolve the same held penalty.**
FR-15: a held penalty resolves by the referee's ruling *or* by the period closing, whichever comes
first. AD-5 stops a period being settled twice, but does not stop `settle_week()` and an inbound
`appeal.ruled` event from resolving the same penalty in the same window — one dropping it on
timeout, the other converting it to owed. Both are compliant; the outcome depends on which lands
first, and one of the two outcomes takes 500,000 VND.
*Fix:* make resolution a single guarded transition on the penalty row — first writer wins, later
writers are no-ops — and state it as a rule.

## Probed and sound

- Two clients (doer, referee) cannot diverge on authorization: AD-7 puts the rule in RLS, so a
  client that forgets a check is denied by the database rather than silently permitted.
- Two clients cannot double-submit an offline event: AD-4's client-generated key is created at
  action time, not send time, which is the detail that makes the retry safe.
- No unit can write a penalty behind settlement's back (AD-8), and none can mutate a settled verdict
  (AD-9).
- A retried or overlapping cron cannot double-charge (AD-5).
- A client cannot schedule its own reminders and drift from the server's view (AD-11).
