# Rubric review — is this a good spine?

Verdict: **the domain half is strong, the operational half is thin.** The invariants fix the
divergences that actually threaten this product, and the paradigm earns its keep. What is missing is
almost entirely the environmental envelope — the dimension a domain-focused draft skips.

## Judged against the checklist

**Fixes the real divergence points — adequate.** The money path, the settlement clock, offline
retry, timezone, and authorization are all fixed, and each AD names a divergence a builder could
genuinely fall into. Four holes remain, all found by the adversarial lens and all in derived values
rather than money itself.

**Every Rule is enforceable — strong.** Each AD states something a reviewer could check against a
migration or a diff. AD-5 and AD-4 name the actual constraint mechanism rather than an intention.
AD-1 is the exception worth noting: "no client computes a verdict" is enforceable only by review,
not by the schema — though AD-7 and AD-8 make violations harmless, which is the right compensation.

**Deferred cannot cause divergence — strong.** Every deferred item is a whole capability, not a
half-decided one, and the native client is explicitly cheap to swap because AD-1 made the client a
reporter.

**Named tech verified — adequate.** See the verification review; two rows are unpinned and one host
was assumed.

**Covers the driving documents — strong.** The Capability map reaches every FR including the two
added during the UX phase, and the paradigm is traceable to a PRD requirement rather than taste.

**Every dimension decided, deferred, or open — thin.** This is the real finding.

## Findings

**high — The environments dimension is entirely absent.**
There is no statement of what environments exist, how migrations are promoted, or whether the author
develops against production. For a solo builder with one Supabase project this is not a formality:
running `settle_day()` against live data while iterating is how a real penalty gets written during
development, and the ledger is append-only by design (AD-9), so it cannot be quietly cleaned up.
*Fix:* decide it — even "one project, and settlement functions refuse to run outside their
scheduled window unless an explicit flag is set" is a decision. Silence is not.

**medium — Observability is deferred without a detectable trigger.**
Deferred says "a settlement failure that stops the cron is silent today" and leaves it there. Given
the free-tier pausing behavior in the verification review, silent failure is the most likely way
this product dies — and it fails *in the author's favor*, so he has no reason to notice.
*Fix:* pair the deferral with the minimum viable detection, e.g. the daily summary is itself the
heartbeat — if it stops arriving, settlement stopped.

**medium — Storage of appeal evidence has no retention or access rule.**
Evidence photos go to Supabase Storage. EXPERIENCE.md says evidence is visible to the referee and no
one else; nothing in the spine binds that to a storage policy, and nothing says how long photos are
kept.
*Fix:* one line in Consistency Conventions tying evidence buckets to the same RLS-derived rule as
the appeal row.

**low — The event log has no growth or compaction story.**
At two users this will never matter. Worth a line under Deferred so it is a decision rather than an
oversight.
