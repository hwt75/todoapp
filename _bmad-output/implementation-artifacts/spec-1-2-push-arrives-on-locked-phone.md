---
title: 'Story 1.2 — A push arrives on a locked phone and survives a reboot'
type: 'feature'
created: '2026-08-12'
status: 'in-progress'
baseline_commit: '5af3e70'
review_loop_iteration: 0
story_key: '1-2-a-push-arrives-on-a-locked-phone-and-survives-a-reboot'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every load-bearing capability of this product is a notification — the author does not
open the app unless notified, and the whole design takes that literally. Whether an installed web app
can push to his locked iPhone, and keep doing so after a reboot, has been verified only as platform
documentation and never in his hands. Nothing else should be built on that assumption until it holds.

**Approach:** On top of the installed shell, register a service worker that shows notifications,
subscribe the device with VAPID, and send pushes from a local CLI at three moments: immediately,
after a device reboot, and after at least an hour idle. Prove the channel with the smallest
apparatus that can answer the question; the production path through the outbox is built afterwards,
once the answer is known.

## Boundaries & Constraints

**Always:**
- The VAPID private key lives only in a local server-side environment; the browser holds the public
  key alone.
- The notification body is legible on a lock screen with no interaction, and names its send time so a
  fresh delivery can be told from a cached one.
- Every send's outcome is recorded verbatim, including the push service's status code, whichever way
  the answer goes.

**Ask First:**
- Persisting the subscription anywhere other than a local gitignored file.
- Any change that would give this story a dependency on a database, an API route, or deployed
  server-side code.

**Never:**
- No database, migrations, RLS, outbox, Edge Function, or `pg_cron`. That is the production delivery
  path and it is deliberately deferred until this channel is known to work — see `deferred-work.md`.
- Do not rebuild the app shell. It exists, was reviewed, and is committed; rebuilding it here would
  put this story back over the size limit it was split to escape.
- No design tokens, colour system, or component work — that is Story 1.1's remaining half, held back
  so a negative result here costs no design work.
- No locally raised `showNotification` presented as evidence. A notification the page triggers itself
  proves nothing about the delivery channel.
- No workaround if push proves unreliable. A negative result is written up and escalated.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Subscribe | Launched from the home-screen icon, permission granted | Subscription produced and rendered for saving | Surface the denial reason verbatim; never retry silently |
| Subscribe from a tab | Opened in Safari, not from the icon | Refused, with the reason: iOS grants push only to an installed app | Platform constraint, not a bug — do not work around it |
| Send while locked | Valid subscription, phone locked | Notification on the lock screen, legible without unlocking | Print status and body; a 4xx is a finding, not a retry |
| Send after reboot, and again after ≥1h idle | Same subscription | Notification still arrives; subscription still valid | `404`/`410` = expired. Material finding: record and stop |
| Send with no saved subscription | CLI run before subscribing | Names the missing file and what to do, exits non-zero | No stack trace as the primary message |

</frozen-after-approval>

> **RENEGOTIATION RECORD — written 2026-08-20, unapproved.** The Intent above is not the one this
> spec was written with. It was replaced wholesale in `f1021c3`, the same commit that implemented
> the story, while `status` moved from `draft` to `in-progress` — and nothing recorded that it had
> been renegotiated. Epic 1's retrospective raised it; Epic 2's found the record still missing.
> This block is the record, reconstructed from `git diff 2b1d9c1 f1021c3` rather than from memory.
>
> **What changed.** The original Approach was the full production path: a Supabase schema holding
> subscriptions and a transactional outbox, an Edge Function worker draining it on its own
> `pg_cron` schedule, and Web Push signed with VAPID inside that worker. The replacement is the
> smallest apparatus that can answer the question — a service worker, a probe, and a local CLI —
> with the outbox explicitly deferred to "afterwards, once the answer is known". The Boundaries
> changed with it: the AD-3 rules about dedupe keys, at-least-once delivery and migrations-only
> schema changes left this spec, because none of them applies to a CLI.
>
> **Why, in the commit's own words** (`f1021c3`): "Nothing downstream should be built until it is
> answered, so this deliberately stops at the smallest apparatus that can answer it … No outbox, no
> worker, no cron; that stronger proof is recorded in deferred-work.md and comes next." The
> judgement was sound and the sequencing held — the outbox was built as Story 2.4a and proven
> unattended, and `deferred-work.md` carries the entry that promised it. What was missing is the
> record, not the reasoning.
>
> **Two things this record does not do.** It does not re-freeze the text: only `hwt75` can do that,
> by replacing this paragraph with a dated `APPROVED` stamp naming the current Intent, the way
> every Epic 2 spec carries one. And it does not pretend the change was approved in advance — it
> was not, and a control that can be applied retroactively is not a control. Epic 1 retrospective
> action item 3 stays open until the stamp is written.

## Code Map

**Precondition:** the installable shell exists and is committed (`2b1d9c1`). What remains is
deployment to a public HTTPS URL, which only the author can do — the phone cannot reach `localhost`.

- `_bmad-output/implementation-artifacts/epic-1-context.md` -- read-only. Epic constraints and why
  this story may end the project.
- `app/page.tsx:6` -- client component holding install state; extend, do not restructure.
- `lib/install-state.ts:29` -- `resolveInstallState` already separates installed from browser; reuse
  it to gate subscribing rather than re-deriving the check.
- `next.config.ts` -- only `reactStrictMode` today; Serwist wiring lands here.
- `README.md`, `.gitignore` -- extend both; deploy steps and `.env*` coverage already exist.

## Tasks & Acceptance

**Execution:**
- [ ] `next.config.ts`, `app/sw.ts`, `package.json` -- wire `@serwist/next` and add a service worker
  with `push` and `notificationclick` handlers rendering title and body from the payload -- the
  service worker is what receives a push while the app is closed, which is the whole mechanism.
- [ ] `components/push-probe.tsx` -- a client component that requests permission, subscribes with the
  public VAPID key, and renders the subscription JSON for copying; refuses with an explanation when
  install state is not `installed` -- opening from a tab is the likeliest operator mistake and its
  symptoms look like broken code.
- [ ] `app/page.tsx` -- mount the probe -- keeps the page's existing structure and install messaging.
- [ ] `scripts/send-push.mjs` -- read the saved subscription, send via `web-push`, print status and
  body verbatim, exit non-zero on failure -- the operator-driven half of the experiment.
- [ ] `.env.example`, `.gitignore` -- document `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
  `VAPID_SUBJECT` and ignore the subscription file -- it identifies a real device endpoint.
- [ ] `README.md` -- add generating VAPID keys, subscribing, and the three sends with the reboot and
  idle waits -- the author runs these by hand and they are easy to get subtly wrong.
- [ ] `_bmad-output/implementation-artifacts/story-1-2-findings.md` -- record each send with
  timestamp and verbatim status, then state plainly whether the delivery channel is viable -- this
  file is the actual deliverable of the story.

**Acceptance Criteria:**
- Given the app is launched from its home-screen icon and permission is granted, when the probe is
  used, then a subscription is produced and can be saved for the CLI.
- Given a saved subscription and a locked phone, when the CLI runs, then the notification appears on
  the lock screen and is legible without unlocking.
- Given the phone has been rebooted and left idle at least an hour, when the CLI runs again, then the
  notification still arrives and the subscription has not been invalidated.
- Given any send returns a non-2xx status or fails to arrive, then it is recorded verbatim and the
  story stops for a human decision rather than being worked around.
- Given the delivery path is traced end to end, then no VAPID private key appears in any
  client-reachable file or client-exposed environment variable.

## Design Notes

**Why a CLI and not the production path.** An alternative version proved this through the real
outbox, worker and cron. It is stronger — it would prove AD-3's mechanism, not just Apple's
permission — and is recorded in `deferred-work.md` to build next. Not now, because it fuses proving
an assumption with constructing infrastructure: a negative result would leave a finished outbox
serving a product that just lost its delivery channel.

**The device steps are the author's** — deploy, install, grant, lock, reboot, wait. The code is
complete before he runs them; the story is not.

## Verification

**Commands:**
- `npx web-push generate-vapid-keys` -- expected: a public/private pair for the environment
- `npm run build` -- expected: clean build, service worker emitted
- `npm test` -- expected: existing suite still passes
- `node scripts/send-push.mjs` with no saved subscription -- expected: a named error and a non-zero exit
- `grep -rn "VAPID_PRIVATE_KEY" app components lib` -- expected: no matches

**Manual checks (if no CLI):**
- From the home-screen icon: permission prompt appears, subscription renders
- From a Safari tab: subscribing is refused with the standalone explanation
- Phone locked, CLI run: notification legible on the lock screen
- After reboot and an hour idle, CLI run again: notification still arrives
