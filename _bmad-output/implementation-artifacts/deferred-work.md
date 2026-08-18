# Deferred Work

Carved out of specs during planning. Each entry names work that left a spec's scope and why.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: The installable app shell — a minimal Next.js 16 App Router project with a web app manifest, iOS icons, and standalone-mode detection, deployed over HTTPS.
  evidence: Split out on token count (the combined spec estimated ~2150 tokens against a 1600 ceiling). This is not deferred in time — it is a **prerequisite** and must be built and deployed before the push proof can run, because a subscription cannot be created without an installed app. It is the first acceptance criterion of Story 1.1, carried out ahead of that story's token layer, which stays deferred so a negative push result costs no design work.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: Prove the delivery channel through the real architecture — `push_subscription` and `outbox` tables, an Edge Function worker that alone holds the VAPID private key, and a `pg_cron` job waking it through `pg_net` — rather than through a local CLI.
  evidence: A fully worked alternative version of this spec proposed exactly this, and it is stronger in one real way: a push that arrives through the outbox proves AD-3's delivery mechanism works, not merely that Apple permits push. Deferred on sequencing, not merit. It fuses proving an assumption with building infrastructure, so a negative push result would leave a finished outbox, worker, cron and migration set serving a product that just lost its delivery channel — the exact outcome the story was split to avoid. Build it once the channel is known to work; the CLI proof answers the life-or-death question first, and every piece of this plan survives that answer.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: Move the service worker build onto Turbopack, so `npm run build` no longer needs the `--webpack` flag.
  evidence: Next 16 makes Turbopack the default bundler, but `@serwist/next` v9 is a webpack plugin and the build fails outright under Turbopack. Serwist offers two forward paths — the experimental `@serwist/turbopack`, and configurator mode, which is Turbopack-compatible but adds `@serwist/cli`, a separate build step and manual service worker registration. Both were rejected *for this story only*: it exists to get an unambiguous yes or no about Apple's push delivery, and an experimental or newly-wired bundler in the path would make a negative result impossible to attribute. `next build --webpack` is one flag and webpack remains fully supported in Next 16. Revisit once the channel is known to work, and before Next drops webpack.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: "[DONE 2026-08-18] No lint or format setup — no eslint-config-next, no Prettier, no .editorconfig backing the LF rule in .gitattributes."
  resolution: Done during the Story 1.2 wait. ESLint 9 flat config on eslint-config-next 16 (core-web-vitals + typescript), Prettier with eslint-config-prettier last so formatting is settled once, and .editorconfig backing the LF rule — which also ended the CRLF warning on every commit. Prettier is scoped away from `_bmad-output/`, `_bmad/` and `.claude/skills/`: reflowing planning prose would churn hundreds of lines and destroy the diffs that make a spec's history readable.
  evidence: Raised by review. This is the commit that sets conventions for the project, and eslint-config-next catches Next-specific mistakes that `next build` no longer reports. Deferred rather than rejected because choosing a lint and format stance is a project-wide decision like the test framework was, and it was not in this spec's scope.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: "[DONE 2026-08-18] Nothing runs the test suite automatically — no CI workflow and no pretest/prebuild chain gating the deploy."
  resolution: Done during the Story 1.2 wait. `.github/workflows/ci.yml` runs lint, format, test and build on every branch, and asserts `public/sw.js` was emitted — a service worker that fails to compile is invisible to Vitest and would kill the push channel silently. The build runs with no VAPID key set, on purpose: a build that needed the secret to compile would mean the secret had reached the bundle.
  evidence: Raised by review. The suite exists and passes but no gate executes it before the deploy that three of five acceptance criteria depend on. Cheap to add once a host is actually connected.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: No security header policy — next.config.ts carries only reactStrictMode, with no CSP or Referrer-Policy.
  evidence: Raised by review. A service worker and push subscription land in the very next story; headers are far cheaper to establish on an empty shell than after a service worker is caching responses. Worth settling at the start of Story 1.2.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: The whole page is a client component; the install hint could be a small client island inside a server component.
  evidence: Raised by review. Only the legacy-iOS branch needs browser APIs — the CSS display-mode rule now covers the modern path without JavaScript. This is the first component in the codebase and sets a precedent worth getting right, but splitting it now would be shaping a convention around a page that exists only to be replaced.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: theme-color has no dark-mode variant and viewportFit:'cover' has no safe-area insets.
  evidence: Raised by review. Both are real: on an iPhone in dark mode the standalone status bar is a light band, and edge-to-edge with no env(safe-area-inset-*) padding puts content under the notch. Deferred deliberately to the design token layer — the remaining half of Story 1.1 — rather than hand-placing values this shell has no system for.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: `app/page.tsx` resolves install state with setState inside useEffect, suppressed by an eslint-disable. Replace with `useSyncExternalStore`.
  evidence: Surfaced by the lint setup on 2026-08-18 — `react-hooks/set-state-in-effect`, and the rule is right. `useSyncExternalStore` is the correct shape for reading matchMedia, and it would also fix the separate deferred item about install state not being re-checked on display-mode change or bfcache restore, since a subscription re-reads on both. Not done on the spot because this value is the gate on whether the push probe subscribes at all: rewriting it days before a one-shot device test — where each retry costs a reboot or an idle hour — would risk breaking that test in a way that reads as an iOS failure. Same reasoning as the Turbopack deferral. Do it once the channel is proven.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: Icon generation is not atomic and install state is not re-checked on display-mode change or bfcache restore.
  evidence: Raised by review. A throw partway through the size loop leaves a partial icon set, and a launch-mode change after mount leaves stale state. Both are low-consequence today — icons are committed and regenerated on every build, and display mode does not change mid-session in practice — but both are real.
