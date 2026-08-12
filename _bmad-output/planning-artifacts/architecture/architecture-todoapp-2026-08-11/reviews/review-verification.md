# Verification review — was every committed decision reality-checked?

Verdict: **mostly yes, with two gaps that matter and one unpinned version.** The platform pivot
itself was driven by verification rather than assumption, which is the right way round.

## Verified against the web on 2026-08-11

| Claim | Status |
|---|---|
| iOS 26 / Xcode 26 / SwiftUI 7 current | verified — now moot after the PWA pivot |
| AlarmKit exists in iOS 26 and breaks through silent/Focus | verified; correctly moved to Deferred |
| Critical Alerts entitlement restricted to health/safety | verified; correctly rejected |
| Apple Developer Program required to sign for a real device | verified — no official path without it |
| Free Apple ID (Personal Team) cannot sign push entitlement | verified — this is what closed the sideload path |
| AltStore + AltServer runs on Windows and auto-refreshes 7-day certs | verified |
| iOS PWA push works on 16.4+ only when home-screen installed | verified |
| iOS 26 opens home-screen sites as web apps by default | verified |
| No Background Sync API on iOS; no background geolocation for web | verified — this is why two Auto-checks are deferred |
| CoreLocation has no built-in dwell; 20 regions; ~20s callback delay | verified; relevant again only if native returns |
| Next.js 16 + Serwist as the maintained next-pwa successor | verified |
| pg_cron available on all Supabase plans including free | verified — the settlement clock depends on this |
| Web Push via VAPID from a server | verified |

## Findings

**high — The outbox has a drain mechanism with no trigger, and its dependency is not in the Stack.**
AD-3 states a worker drains the outbox but nothing says what wakes it. `pg_cron` calls SQL directly
(which is why AD-2 needs no HTTP), but reaching an Edge Function from Postgres requires `pg_net`,
which appears nowhere in the Stack table or the diagrams. As written, the outbox fills and nothing
empties it — every notification, email, and external check silently never happens.
*Fix:* pin `pg_net` in the Stack, and state the drain trigger as a rule on AD-3.

**high — Supabase free-tier project pausing is a silent total failure and is not recorded.**
Free-tier projects pause after a period of inactivity. This was found during research and logged to
the memlog, but never reached the spine. For this product the consequence is not degraded service:
the settlement clock stops, no day closes, no declaration expires, no penalty accrues, and nothing
notifies anyone that the mechanism has died. The author would experience it as the product quietly
agreeing that he owes nothing.
*Fix:* record it — under Deferred at minimum, tied to the observability item, with the concrete
trigger that a missed settlement run must be detectable.

**low — Serwist and web-push are listed as "current" rather than pinned.**
The Stack table asks for versions. Two rows carry a word instead of a number.
*Fix:* pin at first install; acceptable to leave until the repo exists, since the code owns the
Stack once it does.

**low — Vercel is asserted, not verified.**
It is the conventional host for Next.js and nothing here depends on it, but it was never checked and
is the one stack row chosen from habit rather than evidence. Low because it is trivially swappable
and no AD depends on it.
