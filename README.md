# todoapp

Commitments with real stakes and a real person holding you to them.

Planning artifacts live in `_bmad-output/planning-artifacts/`. The architecture spine is the
consistency contract; read it before changing anything structural.

## Running locally

```bash
npm install
npm run dev
```

Local development is fine for markup, but **the phone cannot reach `localhost`**, and a PWA needs real
HTTPS. Anything involving installation or notifications has to be tested against a deployed URL.

## Deploying

1. Push the branch: `git push -u origin <branch>`
2. On Vercel: **Add New → Project**, import `hwt75/todoapp`, and set the deploy branch to the working
   branch rather than `main`.
3. Deploy. The result is a public HTTPS URL.

## Installing on iPhone

The order matters, and each step has a way of failing quietly.

1. Open the deployed URL **in Safari**. Other iOS browsers can add to the home screen, but Safari is
   the path with no surprises.
2. Share button → **Add to Home Screen** → Add.
3. **Launch it from the home-screen icon, not from a Safari tab.** This is the step people get wrong.
   On iOS, notifications are delivered only to an app launched from its icon; open the same URL in a
   tab and notification work fails in ways that look like broken code rather than a wrong launch.
4. When notification work exists, grant permission **from inside the installed app**.

If *Add to Home Screen* is not offered, the manifest or the icon set is the cause — iOS needs valid
raster icons at declared sizes and `display: standalone` before it will offer installation.

## Proving push reaches the phone (Story 1.2)

Every load-bearing capability of this product is a notification, so this is the experiment the
project is staked on. The code is done; these steps are the story, and each one has a way of failing
quietly. **Record every send in `_bmad-output/implementation-artifacts/story-1-2-findings.md` as you
go** — that file, not the code, is the deliverable.

### 1. Generate a VAPID key pair

```bash
npx web-push generate-vapid-keys
```

Copy `.env.example` to `.env` and fill in the pair. `VAPID_SUBJECT` must be a real `mailto:` — push
services reject sends without one. The same public key goes in **both** `NEXT_PUBLIC_VAPID_PUBLIC_KEY`
and `VAPID_PUBLIC_KEY`; if they drift apart the push service rejects the send with a `403` that reads
like an authentication bug.

`.env` is gitignored. The private key never leaves this machine — in this story nothing server-side
sends, so Vercel never needs it.

### 2. Set the public key on Vercel, then deploy

In the Vercel project, set `NEXT_PUBLIC_VAPID_PUBLIC_KEY` to the public key, then deploy.

**Order matters.** `NEXT_PUBLIC_*` values are inlined into the bundle at build time, so setting the
variable after a deploy changes nothing until you redeploy. If the probe says the key is missing,
this is why.

### 3. Subscribe the device

1. Install the app to the home screen (see above) and **launch it from its icon**.
2. Tap **Subscribe this device** and allow notifications.
   iOS offers the permission prompt once. If you deny it, you have to delete the home-screen app and
   reinstall to be asked again.
3. Copy the JSON it shows into `.push-subscription.json` in the project root.

That file identifies a real device endpoint and is gitignored. If the probe refuses instead, it says
why — read the refusal literally; each one names a different mistake.

### 4. The three sends

```bash
npm run push
```

Reads `.env` and `.push-subscription.json`, sends one push, and prints the status verbatim. Run it
three times, and **lock the phone before each one** — a notification seen on an unlocked, foregrounded
phone proves nothing about the case the product depends on.

| # | When | What it answers |
|---|---|---|
| 1 | Immediately after subscribing, phone locked | Does a push reach a locked phone at all? |
| 2 | After rebooting the phone and unlocking it once | Does the subscription survive a reboot? |
| 3 | After at least **one hour** of the app untouched | Does iOS keep delivering once the app is truly idle? |

Send 3 is the one worth being patient about. An hour is the minimum; longer is better, and overnight
is the most honest version of the question. Do not open the app during the wait — opening it is what
the product cannot rely on.

Check the body of each notification against the send time the CLI printed. That is what separates a
fresh delivery from one that arrived earlier and was still sitting on the lock screen.

### Reading the result

- **Status `201`, notification on the lock screen** — that send passed. Record it and continue.
- **Status `201`, nothing arrives** — the push service accepted it and Apple dropped it. A real
  finding, and the most important one this story can produce. Record it and stop.
- **`404` or `410`** — the subscription is gone. Record it and stop; this is the reboot/idle failure
  the story was written to catch, not a bug to retry.
- **`403`** — almost always the two public keys disagreeing, or a changed key without a redeploy.

There is no workaround branch here. If push proves unreliable, that is a valid outcome: write it up
and escalate, because everything downstream is built on this working.

## Icons

`public/icons/*.png` are placeholders generated by `npm run icons` — solid fills, no brand meaning.
The design system defines colour, type and shape but has never defined a logo or app icon. Replace
them before anyone but the author sees this.
