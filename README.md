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

If _Add to Home Screen_ is not offered, the manifest or the icon set is the cause — iOS needs valid
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

**This is now a diagnostic, not the delivery path.** The product sends through the outbox and its
worker (see _The outbox, and the two secrets it needs_). The CLI is kept because when a notification
does not arrive it is the one tool that separates "Apple or the subscription" from "the outbox or the
worker" — it talks to the push service directly, with nothing in between.

Reads `.env` and `.push-subscription.json`, sends one push, and prints the status verbatim. Run it
three times, and **lock the phone before each one** — a notification seen on an unlocked, foregrounded
phone proves nothing about the case the product depends on.

| #   | When                                             | What it answers                                      |
| --- | ------------------------------------------------ | ---------------------------------------------------- |
| 1   | Immediately after subscribing, phone locked      | Does a push reach a locked phone at all?             |
| 2   | After rebooting the phone and unlocking it once  | Does the subscription survive a reboot?              |
| 3   | After at least **one hour** of the app untouched | Does iOS keep delivering once the app is truly idle? |

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

## Database and sign-in (Story 2.1)

Schema lives in `supabase/migrations/`. Every change arrives as a migration; nothing is
applied by hand in the dashboard and back-filled into a file afterwards.

### The rule every migration follows

A table and its row-level security ship in the **same** migration. Not a follow-up. A table
that exists for one deploy without policies has been readable by anyone holding the
publishable key for the length of that deploy. `npm test` fails the build if a migration
creates a table without enabling RLS, or without at least one policy.

Role is resolved two ways, and which one a policy may use is not a matter of taste:

| Function                   | Use it in                                       | Why                                                   |
| -------------------------- | ----------------------------------------------- | ----------------------------------------------------- |
| `public.role_from_token()` | `using (...)`                                   | Free, and **stale** until the access token refreshes  |
| `public.role_from_table()` | `with check (...)`, and anything touching money | Always current — revoking a referee bites immediately |

A `with check` clause that calls `role_from_token()` fails the suite by name. That guard is
what makes having two sources of truth affordable.

### Two dashboard steps this code cannot do for you

Both are one-time, and both are in the Supabase dashboard.

1. **Authentication → Hooks → Customize Access Token** — select
   `public.custom_access_token_hook`. Until this is on, `role_from_token()` returns null and
   every policy built on it **denies**. That is the correct direction to fail, but read paths
   will look broken rather than open.

2. **Authentication → Sign In / Providers → Email → Confirm email: off.** Sign-in is email
   and password, and no email is sent at any point.

   That is not the first choice. An emailed six-digit code would be better, but Supabase
   refuses to let the email template be edited without custom SMTP, so `{{ .Token }}` cannot
   be added and the code never reaches the message. A magic link is worse still: on iOS a
   link tapped in Mail opens Safari, not the installed home-screen app, so it signs you into
   the browser and leaves the one surface that can receive push signed out.

   With two users and no email in the loop, the cost is that a mistyped address goes
   unnoticed and a forgotten password is reset from the dashboard. Both are survivable here
   and neither would be in a product with strangers signing up.

   **Custom SMTP is still coming.** The referee's channel is email, so Epic 4 and Epic 5 need
   it regardless. It was not made a prerequisite for signing in.

### Applying migrations

```bash
npx supabase link --project-ref <your-project-ref>
npx supabase db push
```

After any schema change, run the security advisor. It caught two real holes in the first
migration within seconds of it being applied, neither of which was visible by reading the SQL.

### Delete means archive

A commitment is referenced by every declaration, failed day and penalty that ever touched it, so
removing the row would break those references or silently rewrite the author's own history. The
button says Delete and the row gets `archived_at`; every list filters on `archived_at is null`.
There is deliberately no delete policy on `commitment` — removal is an update.

The cost is honest: a commitment created by mistake and deleted a minute later leaves a row behind
forever. That is the cheaper of the two mistakes.

### The outbox, and the two secrets it needs

Settlement never sends anything. It writes the verdict and the work-to-send in one
transaction, so a pass that rolls back takes the notification with it. A worker drains the
queue on **its own** `pg_cron` schedule — not settlement's, because a queue whose only
consumer is triggered by its producer looks exactly like a working system right up until
the producer stops.

Until both secrets below exist, the cron job **fails every minute on purpose** and says why
in `cron.job_run_details`. That is the intended state: a silent no-op here would be the
exact failure the design warns about.

**1. The worker's VAPID keys.** These live in the Edge Function's own environment and
nowhere else — not this repo, not a migration, not a Vercel variable.

```bash
npx supabase secrets set --project-ref hxzalpnlrunctbajgtkv VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:you@example.com
```

Use the same pair as `.env`. A different public key means the browser subscribed to one
server and the worker signs as another, and the push service refuses with `403`.

**2. What lets `pg_cron` call the worker.** Two Vault secrets, set once from the SQL editor:

```sql
select vault.create_secret('<your service_role key>', 'outbox_worker_key', 'Authorizes the outbox cron job');
select vault.create_secret('https://hxzalpnlrunctbajgtkv.supabase.co', 'project_url', 'Base URL for the outbox worker');
```

The service-role key is read at call time and never written into a migration. It is still
the key that bypasses every policy — it belongs in Vault and in the function's environment,
and nowhere a person can read it by opening a file.

### Watching the queue

```sql
select status, count(*) from public.outbox group by status;
select status, return_message, start_time from cron.job_run_details order by start_time desc limit 5;
```

A row marked `sent` means the push service accepted it. It does **not** mean the author saw
it — Story 1.2 established that those are different things, and it is why every payload
carries its own timestamp and no notification describes the present.

### The key that must never be here

`service_role` (newer projects call it `secret`) bypasses every policy in
`supabase/migrations`. It is not in `.env`, not in `.env.example`, and must never be a Vercel
environment variable. When an Edge Function needs it, it is set in Supabase's own server
environment. If it ever leaks, rotate it in the dashboard — deleting the message it appeared
in does nothing.

## Icons

`public/icons/*.png` are placeholders generated by `npm run icons` — solid fills, no brand meaning.
The design system defines colour, type and shape but has never defined a logo or app icon. Replace
them before anyone but the author sees this.

## Working on this

### Database checks

The rules that decide days, money and chains live in plpgsql, and `npm test` cannot reach any of
them. `supabase/tests/` holds nine files that can, each one transaction that rolls back. They need
a database with no live doer account — a local stack or a preview branch, never the author's own
project, because `settle_day` refuses every override against it (AD-16). See
[`supabase/tests/README.md`](supabase/tests/README.md) for how to run them and what each covers.

### Commit subjects, and the hook that keeps them

Every commit that changes the product names the story it belongs to, using the **full** story key
from `_bmad-output/implementation-artifacts/sprint-status.yaml`:

```
fix(2-7-silence-is-not-a-way-out): a correction has to carry the day
```

Not `fix(2-7)`. The short form is what the convention decayed into by the end of Epic 2, and the
attribution script cannot match it. `.githooks/commit-msg` enforces it: a `feat` or `fix` must
carry a scope and the scope must be a real key; anything with a scope must use a full key; `docs`
and `chore` commits that genuinely span stories may go without one. Hooks are not cloned, so
enable it once per clone:

```bash
git config core.hooksPath .githooks
```

### Spec approval

A spec's frozen block is stamped `APPROVED <date> by <name>` in **its own commit**, before the
commit that implements it. All ten Epic 2 specs were stamped in the same commit as their
implementation, so the record shows that approval happened but not that it happened first — and a
gate whose timing is not evidenced is not a gate.

### Spike stories and specs

A **research spike** — a story whose deliverable is an answer rather than a feature — may skip the
full spec. What it may not skip is writing down its question before it goes looking. The artifact
is a findings file, `_bmad-output/implementation-artifacts/story-<key>-findings.md`, with:

- front matter carrying `story_key`, `status`, `verdict` and the date tested;
- **the question, stated before any code was written**, and why it is being asked now;
- what was tested and what came back, in enough detail to be re-run;
- what the answer changes — and the answer written into the artifact the next decision will read,
  not left in this file alone;
- how to re-test it, because a negative result about somebody else's service has a shelf life.

The reason a spike is exempt: a spec fixes an intent and a set of tasks, and a spike that already
knows its tasks is not a spike. The reason it is exempt only that far: Story 1.3 skipped its spec,
nobody recorded that this was allowed, and Epic 1's retrospective could not tell a deliberate
exemption from an omission. `story-1-3-findings.md` is the shape above and is what this convention
is generalised from — including its second acceptance criterion, satisfied at `prd.md:324`, where
the answer lives now.

Adopted 2026-08-20, closing Epic 1 retrospective action item 1. A spike that has already run
without a findings file writes one before its story is called done.
