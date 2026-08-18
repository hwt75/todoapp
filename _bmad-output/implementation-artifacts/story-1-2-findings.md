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

**Sends 1 and 2 passed. The idle-hour test remains.** The subscription survived a reboot and still
delivers to a locked phone. One send in between was accepted and never arrived, which is recorded
below as row 2a — it is not a failure of the reboot test, but it is the most consequential thing
this story has turned up so far.

### Acceptance criterion 1 — met, 2026-08-18

> Given the app is launched from its home-screen icon and permission is granted, when the probe is
> used, then a subscription is produced and can be saved for the CLI.

The subscription's endpoint host is `web.push.apple.com`, which is worth stating plainly: it is
Apple's own push service, issued to an installed web app. Permission was granted, the service worker
registered on the device, and `pushManager.subscribe` succeeded against the VAPID public key. That
rules out a whole class of failure — manifest, install state, service worker registration, key
mismatch — before a single send. Whatever the sends show now is about **delivery**, not setup.

Key lengths were checked against the spec (`p256dh` 87 chars, `auth` 22) so a truncated paste could
not be mistaken later for a delivery failure.

Procedure: [`README.md` → Proving push reaches the phone](../../README.md#proving-push-reaches-the-phone-story-12).

## Environment

Fill this in when the runs happen — a result is only as meaningful as the device it came from, and
iOS push behaviour has changed between versions.

| | |
|---|---|
| Device | _(to fill: e.g. iPhone 14 Pro)_ |
| iOS version | _(to fill: exact, including point release)_ |
| Deployed URL | _(to fill: the Vercel URL the app was installed from)_ |
| Install date | 2026-08-18 |
| Subscription endpoint host | `web.push.apple.com` |

## Sends

One row per run of `npm run push`. Record the status **verbatim**, whichever way it goes — a failure
recorded honestly is the most valuable row this table can hold.

| # | Sent at | Status | Body | Arrived? | Locked? | Legible locked? | Condition |
|---|---|---|---|---|---|---|---|
| 1 | 17:16:08 | `201` | (empty) | **Yes** | Yes | **Yes** | Immediate |
| 2a | 17:21:37 | `201` | (empty) | **No — never appeared** | Yes | — | After reboot, device likely still offline |
| 2b | 17:22:58 | `201` | (empty) | **Yes** | Yes | **Yes** | After reboot, network restored |
| 3 | | | | | | | After ≥1h idle, app untouched |

**Arrived?** means a notification appeared on the phone, and its body matched the send time printed
by the CLI. A notification left over from an earlier send is not an arrival.

**Row 1, 2026-08-18.** `201 Created` from `web.push.apple.com`, empty body, which is the success
shape for Apple's push service. The notification appeared on the locked phone and its body was
legible without unlocking — the specific thing the product depends on, since the author has stated
he does not open the app unless notified. Row 1 cannot be a stale leftover: it was the first push
ever sent to this subscription, so there was nothing prior to mistake it for.

What row 1 does **not** establish: that the subscription survives a reboot, or that iOS keeps
delivering once the app has been genuinely idle. Those are rows 2 and 3, and they are the rows that
have historically broken this kind of channel.

**Rows 2a and 2b, 2026-08-18 — the reboot survived, and a notification was lost.** Both sends
returned `201`. Neither returned `404` or `410`, so **the subscription is not invalidated by a
reboot** — that is the reboot question answered, and answered positively.

But 2a never appeared on the phone, while 2b, sent 81 seconds later, arrived immediately and
legibly. The author's reading is that the device had not yet rejoined Wi-Fi at 17:21:37. That
explanation fits, and it carries a consequence bigger than the row itself:

> **A push sent while the device is offline was not delayed. It was lost.**

2a did not arrive late, and it did not arrive alongside 2b. It never arrived at all. Whether the
cause is APNs discarding it, or retaining only the most recent notification per device and letting
2b displace it, is not established here — but the observable behaviour is the same either way, and
it is the behaviour the product has to survive.

**Why this matters more than it looks.** The premise of this product is that every load-bearing
capability is a notification, and that the author does not open the app unless notified. A delivery
path that silently drops a notification when the phone is off the network is therefore not a
delivery path — it is a delivery path *most of the time*, which for a Failed Day that costs money is
not the same thing at all. A phone is offline every night in a tunnel, on a plane, on bad signal,
and for several minutes after every reboot.

**What this obliges the deferred outbox work to do** (AD-3, recorded in `deferred-work.md`):

- A send that returns `201` **must not** be treated as delivered. `201` means accepted by Apple, and
  row 2a proves those are different things.
- The outbox needs delivery to be **acknowledged by the device or the user**, not assumed from the
  status code — otherwise a Failed Day can be settled against a notification the author never saw.
- Anything time-critical needs re-sending until it is acted on, not sending once and trusting it.

This was found by accident, one minute after a reboot. It would have been found much more expensively
after the outbox was built on the assumption that `201` meant delivered.

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
