# Deferred Work

Carved out of specs during planning. Each entry names work that left a spec's scope and why.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: The installable app shell — a minimal Next.js 16 App Router project with a web app manifest, iOS icons, and standalone-mode detection, deployed over HTTPS.
  evidence: Split out on token count (the combined spec estimated ~2150 tokens against a 1600 ceiling). This is not deferred in time — it is a **prerequisite** and must be built and deployed before the push proof can run, because a subscription cannot be created without an installed app. It is the first acceptance criterion of Story 1.1, carried out ahead of that story's token layer, which stays deferred so a negative push result costs no design work.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: No lint or format setup — no eslint-config-next, no Prettier, no .editorconfig backing the LF rule in .gitattributes.
  evidence: Raised by review. This is the commit that sets conventions for the project, and eslint-config-next catches Next-specific mistakes that `next build` no longer reports. Deferred rather than rejected because choosing a lint and format stance is a project-wide decision like the test framework was, and it was not in this spec's scope.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: Nothing runs the test suite automatically — no CI workflow and no pretest/prebuild chain gating the deploy.
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

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: Icon generation is not atomic and install state is not re-checked on display-mode change or bfcache restore.
  evidence: Raised by review. A throw partway through the size loop leaves a partial icon set, and a launch-mode change after mount leaves stale state. Both are low-consequence today — icons are committed and regenerated on every build, and display mode does not change mid-session in practice — but both are real.
