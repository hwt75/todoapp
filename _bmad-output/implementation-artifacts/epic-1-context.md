# Epic 1 Context: Prove it can reach him

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Establish, on the author's own iPhone, that this product is physically possible before anything is
built on the assumption that it is. Every load-bearing capability is a notification — the author has
stated he does not open the app unless notified, and the design takes that literally. So the first
thing built is not a feature but a proof: an installable web app that can push to a locked phone and
keep doing so after a reboot. Alongside it, one external dependency is settled. This is the only epic
whose valid outcome may be *stop*: if push is unreliable in his hands, everything downstream is built
on sand, and learning that in a day is far cheaper than learning it in two months.

## Stories

- Story 1.1: An installable shell, and the tokens everything else is built from
- Story 1.2: A push arrives on a locked phone and survives a reboot
- Story 1.3: Settle whether TryHackMe can be read from outside

## Requirements & Constraints

- **A capability reachable only by opening the app unprompted is not a capability.** This governs
  every later feature and is why this epic comes first.
- The product ships as a single installable web app serving two roles from one codebase, with role
  resolved server-side. It is not native; that path is blocked on an Apple Developer account, since a
  free Apple ID cannot sign the push entitlement.
- On iOS, push is delivered only to a web app installed to the home screen. Installation is a hard
  prerequisite for the primary user and irrelevant for the second, whose channel is email.
- Proof means *in the author's hands*, not "the platform supports it": the notification must reach a
  locked phone, be legible without unlocking, and still arrive after a reboot and an idle period.
- A failed proof is a valid, recorded outcome. Write up the finding and stop for a decision rather
  than working around it.
- One external service must be confirmed readable from a server with no browser session, or
  documented as impossible so the product proceeds with one fewer automatic check.

## Technical Decisions

- **Stack:** Next.js 16 (App Router, TypeScript); Serwist for the service worker; Supabase for
  Postgres, Auth, Storage and Edge Functions; `pg_cron` and `pg_net` for scheduling; `web-push` with
  VAPID; Vercel for hosting. Vitest for tests.
- **Migrations only.** Every schema and function change arrives as a numbered migration.
- **Row-level security from the first table.** Authorization lives in RLS, never in application code.
- **The server is the sole judge.** Clients submit observations, never conclusions. Nothing in this
  epic exercises settlement, and no client-side verdict logic may be introduced here.
- **Secrets:** VAPID private keys and service credentials live only in server environments. The
  client holds the VAPID public key and nothing else.
- **No literal visual values.** Every colour, radius and spacing value resolves to a named token,
  which is why tokens belong to this epic rather than to the first screen.
- **Device- and browser-dependent behaviour is extracted into pure functions** and tested there,
  never left inside a component where only a real device can exercise it.

## UX & Interaction Patterns

- **Four state colour families, one meaning each** — held, urgent, failed, neutral — with tint, ink
  and a dark-mode counterpart. A colour that means two things means nothing.
- **Button fills sit one step darker than their tint families**, so a coloured area reads as pressable
  versus labelling without reading its text. Mode-stable; no dark variant needed.
- **Typography roles are restricted by contract:** the large `figure` role may be claimed by exactly
  two elements in the whole product, the serif `quoted` role by exactly one string. Do not spend them
  here.
- **Pill radius is reserved to non-interactive elements.** Nothing pressable is ever pill-shaped.
- **Surfaces are flat** — 0.5px hairlines and one tonal step, no shadows.
- **No screen ever goes fully red**, in any state, on any surface.
- Notification bodies are self-sufficient and legible on a lock screen. Never "You have an update."
- When opened without being installed, the app must say plainly that without installation there is no
  push, and without push there is no product.

## Cross-Story Dependencies

- **Story 1.2 does not depend on Story 1.1's token layer.** Numbering is not build order: 1.2 needs
  only a deployed installable app and a subscription, and it decides whether the project continues.
  The shell half of 1.1 is its real prerequisite and has been built and reviewed; the token half is
  deliberately held back.
- Story 1.3 is independent of both and can run in parallel.
- **Epic 2 depends on both halves of this epic** — on 1.1 for tokens and the deployed shell, and on
  1.2 for the delivery channel every later notification requirement assumes.
- A negative result in 1.3 removes the external-account Auto-check from Epic 4 and leaves the timer as
  the only one, without affecting Epic 2 or Epic 3.
