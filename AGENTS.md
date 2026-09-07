# Repository guidance for Codex

## Project orientation

- This repository is a mobile-first accountability PWA built with Next.js 16 (App Router), React 19, TypeScript, Serwist, Supabase, and Vitest.
- Communicate with the maintainer in Vietnamese. Keep committed planning and implementation artifacts in English, matching the existing BMad configuration.
- Before starting work, read `_bmad-output/implementation-artifacts/sprint-status.yaml` and the artifact for the selected story. Treat the sprint file as the work queue, but verify its status against the story front matter and Git history before changing it.
- Product intent lives in `_bmad-output/planning-artifacts/prds/prd-todoapp-2026-08-11/prd.md` and its `addendum.md`. Architecture invariants live in `_bmad-output/planning-artifacts/architecture/architecture-todoapp-2026-08-11/ARCHITECTURE-SPINE.md`. UX and copy decisions live in `_bmad-output/planning-artifacts/ux-designs/ux-todoapp-2026-08-11/`.
- Do not change text inside a story's `frozen-after-approval` block unless the maintainer explicitly renegotiates that intent.

## Repository map

- `app/`: Next.js routes, layout, manifest, service worker, and global styles.
- `components/`: shared UI; keep behavior tests beside components.
- `lib/`: domain logic and Supabase clients; keep pure domain behavior testable here.
- `supabase/migrations/`: the only source of truth for schema, functions, RLS policies, and cron schedules.
- `supabase/functions/`: outbound effect workers. Settlement must never call external services directly.
- `supabase/tests/`: transactional SQL behavior and security tests. Follow `supabase/tests/README.md`.
- `_bmad-output/`: product, architecture, UX, story, review, retrospective, and sprint-tracking artifacts.
- `_bmad/`: installer-managed BMad configuration. Do not edit `_bmad/config.toml`; durable team overrides belong in `_bmad/custom/config.toml`.

## Non-negotiable architecture rules

- Clients submit observations; database settlement functions alone decide verdicts, penalties, chains, quotas, and other derived state.
- Settlement runs in one Postgres transaction. External effects go through the transactional outbox and must be idempotent.
- Use client-generated UUID idempotency keys for logical client actions and reuse the same key on retries.
- Store instants as `timestamptz`; compute all day, week, and deadline boundaries explicitly in `Asia/Ho_Chi_Minh`. Clients do not derive dates for storage.
- Authorization is enforced with RLS, not only application checks. A table and its RLS policies ship in the same migration.
- Verdict history is append-only. Corrections are new rows; deletion of a commitment means setting `archived_at`.
- An unavailable external check must never become a miss.
- Never test settlement overrides against the live doer account. Use a local Supabase stack or a preview branch for database tests.
- Never commit service-role/secret keys, VAPID private keys, push subscriptions, or production credentials. Keep the Supabase service-role key out of `.env`, Vercel, migrations, logs, and artifacts.

## Implementation workflow

1. Inspect `git status`, the sprint status, the selected story artifact, and relevant architecture/UX sections before editing.
2. Preserve unrelated user changes. Do not rewrite or delete existing work to make a change easier.
3. Work test-first where practical: add or adjust the smallest failing test, implement the behavior, then refactor.
4. Keep user-facing copy aligned with `EXPERIENCE.md` and visual values aligned with `DESIGN.md`/`app/tokens.css`; do not introduce literal color values in components.
5. For schema or database behavior, add a new numbered migration. Never repair production by editing an old applied migration or making an undocumented dashboard change.
6. Update the story artifact and sprint status only when their evidence and Git state agree. Do not mark a schema-carrying story done before local SQL verification and remote migration parity are established.
7. Use the full sprint story key in scoped commit subjects, for example `fix(6-6-the-reminder-lands-inside-the-window): describe the correction`.

## Verification

- Targeted TypeScript/UI test: `npm test -- <path-or-pattern>`
- Full TypeScript/UI suite: `npm test`
- Lint: `npm run lint`
- Formatting check: `npm run format:check`
- Production build: `npm run build`
- SQL suite: follow `supabase/tests/README.md`; run only against local/preview infrastructure.
- Migration parity after any schema-carrying work: `npm run migrations:check`
- PWA installation, push delivery, service-worker behavior, and timing-sensitive reminders need real-device verification on the deployed HTTPS app when the story requires it; automated tests are not sufficient evidence.

## Completion standard

- Report the files changed and the checks actually run.
- Call out any check that could not run and why; never imply unrun checks passed.
- Keep known deferred work in `_bmad-output/implementation-artifacts/deferred-work.md` rather than silently expanding a story.
- Do not commit, push, deploy, apply migrations, rotate secrets, or change live service configuration unless the maintainer explicitly asks.
