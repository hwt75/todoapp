---
title: 'Story 1.2 findings — does a push reach a locked phone, and survive a reboot?'
story_key: '1-2-a-push-arrives-on-a-locked-phone-and-survives-a-reboot'
status: 'awaiting-device-runs'
verdict: 'not-yet-determined'
---

# Story 1.2 findings

This file is the deliverable of Story 1.2. The code exists to produce the rows below; the rows are
what the rest of the project is decided on.

**The question:** on the author's own iPhone, does a Web Push reach a *locked* phone, stay legible
without unlocking, and keep arriving after a reboot and after the app has been left alone for at
least an hour?

**Why it is asked first:** the author has stated he does not open the app unless notified, and the
design takes that literally. If the answer is no, every capability downstream is built on sand, and
`stop` is a valid, expected outcome of this epic — not a failure of the work.

## Status

**The code is complete and verified as far as a machine can verify it.** What remains is the part
only the author can do: deploy, install, subscribe, lock, reboot, wait. Until the table below has
three recorded sends, this story is not done and nothing should be built on the channel.

Procedure: [`README.md` → Proving push reaches the phone](../../README.md#proving-push-reaches-the-phone-story-12).

## Environment

Fill this in when the runs happen — a result is only as meaningful as the device it came from, and
iOS push behaviour has changed between versions.

| | |
|---|---|
| Device | _(e.g. iPhone 14 Pro)_ |
| iOS version | _(exact, including point release)_ |
| Deployed URL | _(the Vercel URL the app was installed from)_ |
| Install date | _(when the home-screen app was added)_ |
| Subscription endpoint host | _(host only — never paste the full endpoint, it identifies the device)_ |

## Sends

One row per run of `npm run push`. Record the status **verbatim**, whichever way it goes — a failure
recorded honestly is the most valuable row this table can hold.

| # | Sent at | Status | Body returned | Arrived? | Locked? | Legible on lock screen? | Notes |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | Immediate, phone locked |
| 2 | | | | | | | After a reboot |
| 3 | | | | | | | After ≥1h idle, app untouched |

**Arrived?** means a notification appeared on the phone, and its body matched the send time printed
by the CLI. A notification left over from an earlier send is not an arrival.

## Verdict

> _To be written once the three sends are recorded. State it plainly — "the delivery channel is
> viable" or "it is not" — and do not hedge. The value of this story is a clear answer, and a hedged
> one costs more than a negative._

**Answer:** _not yet determined_

**Evidence:** _reference the rows above_

## If the answer is no

Do not work around it. That is an explicit constraint of this story, and the reason is that a
workaround would hide the very thing worth knowing. Instead:

1. Record the failing rows exactly as they came, including the status code and body.
2. Write what was tried and what was ruled out — a `403` from mismatched keys is an operator mistake,
   not a platform finding, and the two must not be confused in this file.
3. Escalate for a human decision about whether the product proceeds, and how.

Known operator mistakes that look like platform failures, so they can be ruled out before anything is
escalated:

- Launched from a Safari tab rather than the home-screen icon — the probe refuses and says so.
- `NEXT_PUBLIC_VAPID_PUBLIC_KEY` set on Vercel but not redeployed since — it is inlined at build time.
- `VAPID_PUBLIC_KEY` and `NEXT_PUBLIC_VAPID_PUBLIC_KEY` holding different keys — sends fail `403`.
- Phone not actually locked, or the app foregrounded during the wait.

## What this story deliberately did not prove

The push here is sent by a local CLI, not by the production path. So a positive result proves Apple
delivers to an installed web app on this device — it does **not** prove the outbox, Edge Function
worker and `pg_cron` schedule in AD-3 work. That stronger proof is recorded in `deferred-work.md` and
is the next thing to build, once this answer is known.
