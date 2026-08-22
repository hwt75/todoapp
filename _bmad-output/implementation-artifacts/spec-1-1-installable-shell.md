---
title: 'Story 1.1 (shell) — An installable app shell'
type: 'feature'
created: '2026-08-11'
status: 'done'
baseline_commit: '40b37baced1a8a0bca3f813eabc78d3c94a64b11'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing can be tested on the author's phone until something is installable on it. On iOS,
push is delivered only to a web app added to the home screen, so the delivery channel this whole
product rests on cannot even be subscribed to, let alone proven, without an installable shell first.

**Approach:** Scaffold the smallest Next.js project that iOS will accept as a home-screen app — a valid
manifest, the icon sizes iOS requires, and a page that says plainly what installation is for. Deliberately
unstyled: the design token layer is Story 1.1's remaining half and is held back until push is proven.

## Boundaries & Constraints

**Always:**
- The manifest declares standalone display, and the icon set covers the sizes iOS needs to offer
  *Add to Home Screen*.
- The page states, when not running installed, that without installation there is no push and without
  push there is no product.
- Respect the existing `.gitignore` and `.gitattributes`; LF endings, no regeneration.

**Ask First:**
- A package manager other than npm, or a host other than Vercel.
- Introducing any styling system, CSS framework, or component library.

**Never:**
- No design tokens, colour families, typography scale, or components — that is the second half of
  Story 1.1 and is deliberately deferred until push is proven.
- No service worker, no push subscription, no VAPID — that is Story 1.2 and must not start here.
- No database, auth, migrations, or application features of any kind.
- Do not invent a brand identity. Icons are explicit placeholders (see Design Notes).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Installed launch | Opened from the home-screen icon | Runs standalone, no browser chrome, no install message | N/A |
| Browser launch | Opened as a normal Safari tab | Shows the message explaining that installation is required for push | N/A — expected iOS constraint |
| Manifest fetch | Any request for the manifest | Serves valid JSON with standalone display and every declared icon reachable | A missing icon is a build failure, not a runtime warning |

</frozen-after-approval>

## Code Map

Greenfield. The repository holds no application source — only `.claude/`, `_bmad/`, `_bmad-output/`,
`.gitignore`, `.gitattributes`. Nothing to reuse; no existing code conventions to ratify.

- `_bmad-output/implementation-artifacts/epic-1-context.md` -- read-only. Stack, constraints, and why
  this epic exists.
- `.gitignore` -- already Node/Next aware, including `.next/`, `node_modules/`, `.env*`.
- `.gitattributes` -- enforces LF across the repo. Do not regenerate.

## Tasks & Acceptance

**Execution:**
- [x] `package.json`, `tsconfig.json`, `next.config.ts` -- scaffold Next.js 16 with the App Router and
  TypeScript, strict mode on -- the smallest base the rest of Epic 1 builds on.
- [x] `app/layout.tsx` -- root layout with viewport and `apple-mobile-web-app-capable` metadata --
  iOS reads these when deciding how a home-screen launch behaves.
  *Implemented as `mobile-web-app-capable`: the apple-prefixed tag is deprecated, and standalone
  launch on iOS is driven by the manifest's `display` value. Verified in the served HTML.*
- [x] `app/manifest.ts` -- declare name, short name, `display: 'standalone'`, `start_url`, background
  and theme colour, and the icon set -- without a valid manifest iOS does not offer installation at all.
- [x] `public/icons/` -- generate placeholder PNGs at 180×180, 192×192 and 512×512 from a script or
  committed source -- iOS needs real raster files at specific sizes; an SVG or a missing size silently
  removes the install option.
- [x] `app/page.tsx` -- render the app name and, when `display-mode: standalone` does not match, the
  message explaining that push requires installing to the home screen -- this is the one thing a
  first-time user must understand and would otherwise hit blind.
- [x] `README.md` -- record the deploy steps and the *Add to Home Screen* sequence -- the author performs
  these by hand every time this is tested, and they are easy to get subtly wrong.
- [x] `lib/install-state.ts`, `lib/install-state.test.ts`, `app/manifest.test.ts`, `package.json`
  -- added during the matrix audit, which no task had covered. The install-state rule was extracted
  from the component into a pure function so both matrix rows can be tested without a device, and the
  manifest's shape and icon files are asserted. The project had no test framework and the architecture
  spine had never chosen one; Vitest was agreed with the author and recorded in the spine's
  Consistency Conventions.

**Acceptance Criteria:**
- Given the project is checked out, when `npm run build` runs, then it completes with no type errors.
- Given the app is deployed over HTTPS and opened in Safari on iPhone, when the share sheet is opened,
  then *Add to Home Screen* is offered.
- Given the app has been added to the home screen, when it is launched from its icon, then it opens
  standalone with no address bar and shows no install message.
- Given the app is opened as an ordinary browser tab, then it explains that installation is required
  for push, without blocking anything else on the page.
- Given the manifest is fetched, then it declares standalone display and every icon it references
  resolves.

## Design Notes

**Icons are placeholders, and that is a real gap.** The UX phase produced colour, typography and shape
tokens but never a logo or app icon — the subject never came up. iOS requires raster icons at fixed
sizes before it will offer installation, so this ships flat-colour placeholders drawn from the existing
palette. They are not a brand decision and should be replaced before anyone but the author sees the app.

**Unstyled on purpose.** This shell will look plain. The token layer exists in `DESIGN.md` and is
deliberately not implemented until Story 1.2 proves the delivery channel works, so that a negative
result costs no design work.

## Verification

**Commands:**
- `npm run build` -- expected: clean production build, no type errors
- `npm run dev` then fetch `/manifest.webmanifest` -- expected: valid JSON, `display: standalone`, all icon URLs resolve

**Manual checks (if no CLI):**
- Deploy, open in Safari on iPhone, share sheet: *Add to Home Screen* is offered
- Launch from the icon: standalone, no address bar, no install message
- Open the same URL in a tab: the install message is shown

## Suggested Review Order

**How the app knows whether it is installed**

- The whole story turns on this rule; kept pure so a device is not needed to test it.
  [`install-state.ts:29`](../../../lib/install-state.ts#L29)

- Reads globalThis, tolerates a missing matchMedia, and accepts three installed display modes.
  [`install-state.ts:44`](../../../lib/install-state.ts#L44)

- Server-renders the hint and fails toward showing it; hydration only refines.
  [`page.tsx:22`](../../../app/page.tsx#L22)

- CSS hides the hint on an installed launch before JavaScript runs — no flash, no hydration needed.
  [`layout.tsx:22`](../../../app/layout.tsx#L22)

**What makes iOS offer installation at all**

- `id` and `scope` pin app identity so a later `start_url` change cannot orphan the install.
  [`manifest.ts:7`](../../../app/manifest.ts#L7)

- The apple-prefixed icon link older iOS needs; without it the home-screen icon can be a screenshot.
  [`layout.tsx:16`](../../../app/layout.tsx#L16)

- Hand-rolled PNG encoder, no image dependency, placeholder fills only.
  [`generate-icons.mjs:44`](../../../scripts/generate-icons.mjs#L44)

**Tests and configuration**

- Asserts icons are real PNGs at their declared size — existence alone would pass a corrupt file.
  [`manifest.test.ts:44`](../../../app/manifest.test.ts#L44)

- Covers the legacy-iOS path and the missing-matchMedia path, both invisible on a desktop browser.
  [`install-state.test.ts:34`](../../../lib/install-state.test.ts#L34)

- `prebuild` regenerates icons so a deploy can never reference stale or missing files.
  [`package.json:9`](../../../package.json#L9)

- Mirrors the tsconfig `@/*` alias, which Vitest does not read on its own.
  [`vitest.config.mts:6`](../../../vitest.config.mts#L6)
