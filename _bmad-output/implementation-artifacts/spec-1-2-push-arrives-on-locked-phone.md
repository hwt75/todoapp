---
title: 'Story 1.2 — A push arrives on a locked phone and survives a reboot'
type: 'feature'
created: '2026-08-12'
status: 'draft'
review_loop_iteration: 0
story_key: '1-2-a-push-arrives-on-a-locked-phone-and-survives-a-reboot'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every load-bearing capability in this product is a notification, yet nobody has proven a
Web Push can reach the author's locked iPhone and keep working after a reboot. Story 1.1 (the shell)
has not been built, so the push channel has nothing to stand on.

**Approach:** Build the smallest deployable substrate that makes the test possible — a Next.js 16 PWA
with a Serwist service worker and a manifest, a Supabase schema holding subscriptions and a
transactional outbox, and an Edge Function worker that drains the outbox and signs Web Push with
VAPID on its own `pg_cron` schedule. Ship a runbook the author executes on his own device, with a
findings block that records a negative result as a decision rather than a workaround.

## Boundaries & Constraints

**Always:**
- Push is sent server-side only, through the outbox drained by the effects worker (AD-3). The worker
  reads and writes the `outbox` table and nothing else — the subscription is copied into the outbox
  payload at enqueue time so the worker never reaches into subscription storage.
- Every outbox row carries a dedupe key and must be safe to execute twice (at-least-once delivery).
- The VAPID private key exists only in the worker's environment. The browser holds the public key
  and nothing else.
- Schema and function changes arrive only as numbered migrations under `supabase/migrations/`.
  Nothing is created in the Supabase dashboard.
- Notification bodies are fully legible on the lock screen with nothing opened (NFR1).
- Table names are singular snake_case; a new domain noun is added to the PRD Glossary first.

**Ask First:**
- Any change that makes the client compute, schedule, or re-deliver a notification itself (AD-11).
- Introducing authentication, accounts, or role resolution — that is Story 2.1, not this spike.
- Adding a UI dependency, CSS framework, or component library.

**Never:**
- No design tokens, no theming, no custom CSS. This spec ships the probe UI with browser default
  styling so Story 1.1 still owns the token layer intact and no literal color or spacing value
  enters the repository.
- No product copy invented here. The probe's notification body is a diagnostic string, explicitly
  not reusable by Epic 2 without being added to the experience document's voice set first.
- No settlement logic, no verdicts, no money, no `notification` lifecycle table.
- No browser-triggered `showNotification` used as evidence — a locally raised notification proves
  nothing about the delivery channel.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Register subscription | POST with `endpoint`, `keys.p256dh`, `keys.auth` | 201, one row keyed on `endpoint` | N/A |
| Re-register same device | Same `endpoint` posted again | Upsert on `endpoint`; still one row, keys refreshed | N/A |
| Malformed payload | Missing `endpoint` or either key | 400, nothing written | Typed message, no raw exception text |
| Duplicate drain | Outbox row already `sent`, worker runs again | Skipped, no second push | N/A |
| Dead subscription | Push service answers 404 or 410 | Row marked `gone` with the error recorded | No retry loop; subscription pruning deferred |
| Empty outbox | Worker woken with nothing queued | No-op, success response | N/A |
| Send failure | Push service answers 5xx | Row stays `pending`, attempt counted, retried next tick | Stops retrying past the attempt ceiling |

</frozen-after-approval>

## Code Map

Greenfield: the repository contains `_bmad/`, `_bmad-output/`, `.gitignore`, `.gitattributes` and no
application code. Every path below is new. Read-only evidence:

- `_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md`
  -- AD-3 (outbox), AD-4 (idempotency), AD-7 (RLS), AD-16 (migrations), § Stack (pinned versions),
  § Structural Seed (the directory layout this spec must land in), § Consistency Conventions.
- `_bmad-output/implementation-artifacts/epic-1-context.md` -- epic goal, constraints, story gating.
- `_bmad-output/planning-artifacts/epics.md:318-337` -- the three acceptance blocks for this story.
- `_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/EXPERIENCE.md:42-58` -- the
  notification contract; `:100-134` -- Voice and Tone (source of all future product copy).
- `_bmad-output/planning-artifacts/prds/prd-todoapp-2026-08-11/prd.md:126` -- Glossary insertion
  point; `:700` -- Open Questions, where the runbook's finding is recorded.
- `.gitignore` -- already covers `node_modules/`, `.next/`, `.env*`. No change needed.
- `.gitattributes` -- forces LF; PNG icons are declared binary already.

## Tasks & Acceptance

**Execution:**
- [ ] `package.json`, `tsconfig.json`, `next.config.ts`, `.env.example` -- initialize Next.js 16 App
      Router + TypeScript, wire `@serwist/next`, declare the client env vars (Supabase URL, VAPID
      public key) and the server-only service-role key -- the substrate everything else needs.
- [ ] `app/manifest.ts`, `app/layout.tsx`, `scripts/generate-icons.mjs`, `public/icon-192.png`,
      `public/icon-512.png`, `public/apple-touch-icon.png` -- standalone-capable manifest and icons
      generated by a zero-dependency script -- iOS grants Web Push only to an installed PWA.
- [ ] `app/sw.ts` -- Serwist service worker with `push` and `notificationclick` handlers rendering
      title and body from the payload -- the receiving half of the channel.
- [ ] `app/page.tsx`, `components/push-probe.tsx` -- detect standalone launch, state plainly that
      push requires installation, request permission, subscribe with the VAPID public key, POST the
      subscription; show the returned state. Unstyled by intent.
- [ ] `lib/supabase-admin.ts` -- server-only Supabase client using the service-role key, never
      imported into a client component -- RLS stays deny-all until Story 2.1 brings real auth.
- [ ] `app/api/push/subscribe/route.ts` -- validate the payload per the I/O matrix and upsert on
      `endpoint` -- the only API route the spine permits at this stage.
- [ ] `supabase/migrations/0001_push_channel.sql` -- create `push_subscription` and `outbox`
      (dedupe key unique, status, attempts, last_error, timestamptz columns), enable RLS with no
      policies -- the outbox is the contract Epic 2 inherits.
- [ ] `supabase/migrations/0002_enqueue_test_push.sql` -- `enqueue_test_push(body text)` copying each
      stored subscription into an outbox payload with a time-based dedupe key -- keeps the worker
      dependent on the outbox alone.
- [ ] `supabase/functions/effects-worker/index.ts` -- claim pending outbox rows, sign and send Web
      Push with VAPID, mark `sent`/`gone`/`failed` with attempt counting -- the only place the VAPID
      private key exists.
- [ ] `supabase/migrations/0003_outbox_worker_schedule.sql` -- `pg_cron` job waking the worker each
      minute through `pg_net`, reading the worker URL and key from Vault -- the outbox must drain
      even when nothing enqueued it.
- [ ] `vitest.config.ts`, `tests/subscribe-route.test.ts` -- cover the register, re-register and
      malformed rows of the I/O matrix.
- [ ] `docs/story-1-2-push-runbook.md` -- deploy, install, permission, send, reboot-and-wait steps
      with expected results, plus a Findings block covering the negative outcome and the instruction
      to record it in the PRD's Open Questions before any Epic 2 work starts.
- [ ] `_bmad-output/planning-artifacts/prds/prd-todoapp-2026-08-11/prd.md` -- add **Push
      Subscription** to the Glossary -- the spine requires a new domain noun to land there first.
- [ ] `README.md` -- env vars, Vault secrets, deploy and migration commands.

**Acceptance Criteria:**
- Given the app deployed and installed to the home screen with permission granted, when
  `enqueue_test_push` is called and the worker's next tick runs, then the notification appears on the
  locked device and its body is legible without opening anything.
- Given a delivered subscription, when the phone is rebooted and left at least one hour with the app
  unopened, then a newly enqueued push still arrives and the stored subscription is unchanged.
- Given the push proves unreliable at either step, when the runbook's Findings block is completed,
  then the failure and its conditions are written down and recorded in the PRD's Open Questions, and
  the project stops for a decision rather than continuing.
- Given the whole delivery path, when it is traced from enqueue to device, then no push is signed or
  sent outside the effects worker and no VAPID private key appears in client-reachable code or env.

## Design Notes

**Why the subscription is copied into the outbox payload.** The spine constrains the effects worker
to the outbox table alone. Rather than weaken that, `enqueue_test_push` snapshots the endpoint and
keys into the row it writes, so the worker needs no other read. Staleness is acceptable: a snapshot
of a dead subscription fails with 404/410 and is recorded, which is exactly the signal this story
exists to detect.

**Deviation from AD-7, bounded and temporary.** There is no auth yet, so RLS is enabled with zero
policies (deny-all to anon and authenticated) and the subscribe route reaches the table with the
service-role key server-side. This is the spike's only authorization shortcut. Story 2.1 replaces it
with account-scoped policies; the outbox and worker shapes survive unchanged.

**The probe's notification body is diagnostic, not product copy.** It names the send time so the
reboot-survival test can distinguish a fresh delivery from a cached one — e.g. `Test push, 14:32.
Readable on the lock screen means the channel works.` Product copy comes from the experience
document, and nothing here may be reused without being added there first.

## Verification

**Commands:**
- `npm run build` -- expected: Next.js build succeeds and the service worker is emitted
- `npx tsc --noEmit` -- expected: no type errors
- `npm run lint` -- expected: clean
- `npx vitest run` -- expected: all subscribe-route cases pass
- `npx supabase db reset --linked` (or `db push`) -- expected: all three migrations apply in order
- `grep -rn "VAPID_PRIVATE_KEY" app components lib` -- expected: no matches

**Manual checks (if no CLI):**
- The deployed app launches standalone from the home screen with no browser chrome, and the manifest
  and registered service worker are both visible in Safari's inspector.
- The physical push, reboot and one-hour-wait steps are executed by the author against his own
  iPhone, following `docs/story-1-2-push-runbook.md`. This story's device-level acceptance criteria
  are not met until he reports the result; the code is complete before then, the story is not.
