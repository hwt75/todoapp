---
title: 'Story 1.2 findings — does a push reach a locked phone, and survive a reboot?'
story_key: '1-2-a-push-arrives-on-a-locked-phone-and-survives-a-reboot'
status: 'complete'
verdict: 'viable'
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

**Complete. All three conditions passed, 2026-08-18.** The channel is proven on the author's own
iPhone: a push reaches it locked, survives a reboot, survives an offline window, and still arrives
after nearly four hours of the app being untouched. Story 1.2 answers yes.

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
| 2a | 17:21:37 | `201` | (empty) | **Yes — delayed** | Yes | **Yes** | After reboot, device still offline; delivered on reconnect |
| 2b | 17:22:58 | `201` | (empty) | **Yes** | Yes | **Yes** | After reboot, network restored |
| 3 | 21:05:25 | `201` | (empty) | **Yes** | Yes | **Yes** | After **3h 42m** idle, app untouched |

Rows 2a and 2b ended up on the lock screen together, each showing its own send time — which is the
only reason the delay could be told apart from a duplicate.

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

**Rows 2a and 2b, 2026-08-18 — the reboot survived, and so did an offline send.** Both returned
`201`, neither returned `404` or `410`, and **both arrived**, each legible on the lock screen with
its own send time.

The interesting part is 2a. It was sent 81 seconds before 2b, at a moment when the phone had just
rebooted and had not yet rejoined Wi-Fi, and it was **not visible when first checked**. It arrived
afterwards, once the device was back on the network, and ended up on the lock screen alongside 2b.

> **A push sent while the device was offline was queued and delivered on reconnect. It was late, not
> lost.**

That is store-and-forward working the way the product needs it to. It is the single most reassuring
thing in this file, because "offline" is not an edge case for a phone — it is every night, every
tunnel, every flight, and several minutes after every restart.

**A correction is recorded here on purpose.** When 2a was first checked and nothing was on the
screen, this file briefly recorded it as lost, and drew a large architectural conclusion from that:
that `201` could not be trusted and the deferred outbox would need device-level delivery
acknowledgement. **That conclusion was wrong and has been removed.** The evidence for it was a
notification that had simply not arrived *yet*. It is kept in the history rather than quietly
deleted, because the mistake is instructive: on a channel that can deliver late, "I checked and it
wasn't there" is not the same observation as "it never came", and the difference between those two
readings was an entire piece of infrastructure.

**What it does still oblige** — a much smaller thing than what was first written, and it is already
handled:

- Notifications can arrive **materially later than they were sent**, so a notification body must
  carry its own timestamp and never say "now" or rely on the moment of arrival. `send-push.mjs`
  already puts the send time in the body, which is the only reason this delay was diagnosable at
  all rather than looking like a duplicate.
- Nothing may be settled on the assumption that a notification arrived *at* the time it was sent.

## Verdict

> _To be written once the three sends are recorded. State it plainly — "the delivery channel is
> viable" or "it is not" — and do not hedge. The value of this story is a clear answer, and a hedged
> one costs more than a negative._

**Answer: the delivery channel is viable.** The product is physically possible. Build on it.

Stated without hedging, as this section demands: on the author's own iPhone, an installed web app
receives a Web Push while the phone is locked, the notification is legible without unlocking, and it
keeps arriving after a restart and after the app has been genuinely abandoned for hours.

**Evidence — four sends, every one accepted and every one delivered:**

| Condition tested | Row | Result |
|---|---|---|
| Reaches a locked phone at all | 1 | Arrived, legible without unlocking |
| Subscription survives a reboot | 2a, 2b | No `404`/`410`; both arrived |
| Survives an offline window | 2a | Queued and delivered on reconnect — late, not lost |
| Survives a genuinely idle app | 3 | Arrived after **3h 42m** untouched |

Row 3 is the one that mattered most, and it was tested well past its own bar: the requirement was one
hour and it got three hours forty-two minutes, with the app never opened. That is the state this
product will spend almost all of its life in — the author does not open the app unless notified, and
the design takes that literally. It held.

No send returned anything but `201`. No subscription was invalidated. Nothing had to be worked
around, and the story's escalation path was never needed.

**What this unlocks.** Epic 1's purpose was to find out whether to continue, and the answer is yes.
The design token layer held back as Story 1.1's remaining half can now be built — it was deferred
precisely so a negative result here would cost no design work, and that insurance has now expired
unused. Epic 2 depends on this channel for every notification requirement it assumes, and is
unblocked.

**What it still does not prove.** These pushes were sent by a local CLI, not through the production
path. A positive result proves Apple delivers to an installed web app on this device; it does not
prove the outbox, Edge Function worker and `pg_cron` schedule in AD-3. That stronger proof is
recorded in `deferred-work.md` and is the next thing to build — now worth building, which was the
whole question.

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
