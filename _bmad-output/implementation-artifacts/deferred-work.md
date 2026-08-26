# Deferred Work

Carved out of specs during planning. Each entry names work that left a spec's scope and why.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: The installable app shell — a minimal Next.js 16 App Router project with a web app manifest, iOS icons, and standalone-mode detection, deployed over HTTPS.
  evidence: Split out on token count (the combined spec estimated ~2150 tokens against a 1600 ceiling). This is not deferred in time — it is a **prerequisite** and must be built and deployed before the push proof can run, because a subscription cannot be created without an installed app. It is the first acceptance criterion of Story 1.1, carried out ahead of that story's token layer, which stays deferred so a negative push result costs no design work.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: "[DONE 2026-08-19 by Story 2.4a] Prove the delivery channel through the real architecture" — `push_subscription` and `outbox` tables, an Edge Function worker that alone holds the VAPID private key, and a `pg_cron` job waking it through `pg_net` — rather than through a local CLI.
  evidence: A fully worked alternative version of this spec proposed exactly this, and it is stronger in one real way: a push that arrives through the outbox proves AD-3's delivery mechanism works, not merely that Apple permits push. Deferred on sequencing, not merit. It fuses proving an assumption with building infrastructure, so a negative push result would leave a finished outbox, worker, cron and migration set serving a product that just lost its delivery channel — the exact outcome the story was split to avoid. Build it once the channel is known to work; the CLI proof answers the life-or-death question first, and every piece of this plan survives that answer.
  resolution: Built and proven on 2026-08-19. `pg_cron` woke the worker on its own schedule, the worker claimed one row and sent it, and the notification reached the author's phone with nobody running a command. `scripts/send-push.mjs` is kept deliberately, but reframed in the README as a diagnostic rather than the delivery path — when a push does not arrive it is the only tool that separates Apple-or-the-subscription from the outbox-or-the-worker. The AD-3 divergence in the *product* path is closed.
  constraint_from_story_1_2: Story 1.2 observed a send return `201` while the device was offline just after a reboot; it did not appear when first checked, and arrived once the device rejoined the network, landing on the lock screen next to a later send. Delivery is therefore store-and-forward and survives an offline window — but it can be **materially late**. This outbox must not assume a notification arrived at the moment it was sent, and every notification body must carry its own timestamp rather than saying "now". (An earlier reading of this same evidence concluded the push had been lost and that `201` could not be trusted at all; that was wrong — see `story-1-2-findings.md`, rows 2a and 2b.)

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

- source_spec: `_bmad-output/implementation-artifacts/spec-2-4-answer-for-yesterday.md`
  summary: The push half of the morning gate — a notification that re-delivers on a schedule until the declaration is answered. Needs the AD-3 outbox, worker and `pg_cron` schedule.
  evidence: `EXPERIENCE.md` is explicit that the gate is two mechanisms and that neither alone is sufficient: the push reaches the author at 07:30 when he is not thinking about the app, and the modal is what remains when the push was swiped away. Story 2.4 can build only the modal, because scheduled repeating delivery needs infrastructure that is itself deferred. **This leaves the gate weaker than designed**, and weaker in exactly the direction that matters — a modal only asks once he opens the app, and not opening the app is his documented failure mode. Story 1.2 proved the channel with a local CLI so this could be built once the channel was known to work, and it now is. **Resolved by reversing the order on 2026-08-19:** the author chose to build the outbox first, as Story 2.4a, so the gate is born with both legs rather than having the second retrofitted. `SOLUTION-DESIGN.md` sequences it the same way — the outbox and its worker are step 4 and the doer's surfaces step 5 — so the original proposal to build the modal first was the wrong order and the architecture already said so.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-8-the-day-tells-me-how-it-went.md`
  summary: The day summary's copy rules exist in two languages — `lib/summary.ts` as tested functions and `public.day_summary_body` as the implementation settlement actually calls. One rule, two copies, kept in step by hand.
  evidence: Settlement runs in Postgres, so the sentence has to be built there; the TypeScript version is where the rules are testable. They drifted **within minutes of being written**: `to_char`'s group separator follows the database's `lc_numeric` and produced `500,000₫` while `formatDong` produces the Vietnamese `500.000₫`, so the rendering the author would have seen on his lock screen was the wrong one. Fixed by making the separator explicit, but the seam remains. The honest resolution is for a surface to need the summary — at that point one side becomes the source and the other reads it — or for the outbox to carry facts and let the worker, which is already TypeScript, render the body. The second is probably right and was not done here because it means widening the payload contract that Story 2.4a's constraints depend on.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: No security header policy — next.config.ts carries only reactStrictMode, with no CSP or Referrer-Policy.
  evidence: Raised by review. A service worker and push subscription land in the very next story; headers are far cheaper to establish on an empty shell than after a service worker is caching responses. Worth settling at the start of Story 1.2.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: The whole page is a client component; the install hint could be a small client island inside a server component.
  evidence: Raised by review. Only the legacy-iOS branch needs browser APIs — the CSS display-mode rule now covers the modern path without JavaScript. This is the first component in the codebase and sets a precedent worth getting right, but splitting it now would be shaping a convention around a page that exists only to be replaced.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: "[DONE 2026-08-19] theme-color has no dark-mode variant and viewportFit:'cover' has no safe-area insets."
  resolution: Both closed by the design token layer, which is where this entry said they belonged. `app/layout.tsx` now emits two `theme-color` metas keyed on `prefers-color-scheme`, verified in a browser as `#F1EFE8` light and `#1C1C1E` dark; `app/globals.css` insets the body with `max(var(--space-4), env(safe-area-inset-*))` on all four sides.
  evidence: Raised by review. Both are real: on an iPhone in dark mode the standalone status bar is a light band, and edge-to-edge with no env(safe-area-inset-*) padding puts content under the notch. Deferred deliberately to the design token layer — the remaining half of Story 1.1 — rather than hand-placing values this shell has no system for.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-push-arrives-on-locked-phone.md`
  summary: `app/page.tsx` resolves install state with setState inside useEffect, suppressed by an eslint-disable. Replace with `useSyncExternalStore`.
  evidence: Surfaced by the lint setup on 2026-08-18 — `react-hooks/set-state-in-effect`, and the rule is right. `useSyncExternalStore` is the correct shape for reading matchMedia, and it would also fix the separate deferred item about install state not being re-checked on display-mode change or bfcache restore, since a subscription re-reads on both. Not done on the spot because this value is the gate on whether the push probe subscribes at all: rewriting it days before a one-shot device test — where each retry costs a reboot or an idle hour — would risk breaking that test in a way that reads as an iOS failure. Same reasoning as the Turbopack deferral. Do it once the channel is proven.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-installable-shell.md`
  summary: Icon generation is not atomic and install state is not re-checked on display-mode change or bfcache restore.
  evidence: Raised by review. A throw partway through the size loop leaves a partial icon set, and a launch-mode change after mount leaves stale state. Both are low-consequence today — icons are committed and regenerated on every build, and display mode does not change mid-session in practice — but both are real.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-7-silence-is-not-a-way-out.md`
  summary: A superseded day gets its verdict, its money and its chain back, but never an evening summary.
  evidence: Recorded on 2026-08-20 while fixing A1, so it is a decision rather than the silent gap A3 was about. `settle_day` skips the summary for an `expired` day deliberately — a message saying "one of five today, start with X tomorrow" about a day he never answered is the product pretending it knows how his day went. When the answers turn out to have been given in time, `supersede_expiries()` now restores the outcomes and the chain, but still enqueues nothing: a correction is reached days after the evening it belongs to, so the sentence would arrive as advice about a tomorrow that has already been and gone. The day appears on the Ledger and on the Chains calendar as what it really was, and nothing is said out loud. Revisit only if the author reports missing the evening sentence for a day he answered offline.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-sign-in-as-the-doer.md`
  summary: Every client read depends on Supabase's default table privileges, which no migration in this repository grants — and the local stack does not reproduce them.
  evidence: Found on 2026-08-20, the first time the schema was applied to a database other than the author's own project. On the local stack (`supabase/postgres:17.6.1.159`) `pg_default_acl` gives `anon` and `authenticated` only `Dxtm` on tables created by `postgres` in `public`, so `has_table_privilege('authenticated','public.commitment','select')` is **false** — for `commitment`, `profile`, `declaration` and every `*_current` view alike. The app works against the live project because that project's defaults grant `arwdDxt`, which `20260819201000_close_role_self_promotion.sql` says out loud in passing ("the table-wide UPDATE that Supabase's default privileges had already granted"). So the product's read access is inherited from how one project happened to be provisioned, is not in version control, and would not survive a restore into a fresh project. RLS is unaffected — the policies are all in migrations — and this is why the SQL checks under `supabase/tests/` assert policies and `security_invoker`, never grants. The fix is explicit `grant select` (and the narrow writes) per table in a migration; not done today because it belongs with a pass over every table at once, and because getting it wrong in the *other* direction is how the two privilege defects of Epic 2 happened.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-4a-the-outbox-and-its-worker.md`
  summary: "[DONE 2026-08-20] The push payload rule lived in `lib/outbox.ts` and nothing ever called it."
  resolution: Moved into the database as `public.push_body_is_sendable` and a check constraint on `public.outbox` (`20260820101000_outbox_body_rule_where_it_runs.sql`), which is the only place it can refuse anything — bodies are built in SQL and queued by `outbox_enqueue`. `supabase/tests/2-4a-outbox-body-rule.sql` proves it refuses an empty, absent, present-tense or undated body, that `outbox_enqueue` itself fails with a check violation, and that both sentences the product actually sends still get through — the summary via `day_summary_body` and the morning reminder via a real `enqueue_gate_reminders()` run. The constraint is `not valid`: it judges everything queued from now on and does not re-judge what has already been sent.
  evidence: Epic 2 retrospective, A7/T3. `payloadProblems` and `bodyIsSelfDating` had no production caller, and the only database guard was `payload ? 'sent_at'` — a check that a key exists, saying nothing about what the sentence claims. `lib/outbox.ts` is now labelled non-production and names the function that holds the rule.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-8-the-day-tells-me-how-it-went.md`
  summary: `lib/summary.ts` and `lib/expiry.ts` are still mirrors of plpgsql with no production consumer, and no test executes both sides.
  evidence: Recorded on 2026-08-20 for the two mirrors that could not be resolved the way `lib/outbox.ts` was. Both are now labelled non-production in their own headers, naming the function that holds the real rule — `public.day_summary_body` and `public.declaration_deadline` — and the false claim at `lib/expiry.ts:11` ("the tests hold them together") is deleted, because nothing held them together. The seam closes properly only when the worker renders the sentence, which is an Epic 3 story with unproven risk: nobody has shown that a Deno edge function can import the Next app's `lib/` through the Supabase bundler, and compiling is not the test — deploying is. Until then the SQL is the source and these two files are reference copies.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-8-the-day-tells-me-how-it-went.md`
  summary: The evening summary spells its counts from a fixed list of eleven words, so anything above ten renders as "Ten of ten".
  evidence: Found on 2026-08-20 while writing `supabase/tests/2-8-summary-copy.sql`. `day_summary_body` indexes `array['none'..'ten']` with `least(p_held, 10) + 1`, so eleven of twelve commitments reads "Ten of ten on Tuesday" — wrong, and quiet about being wrong. Not fixed today because the author has five commitments and the honest fix is a decision rather than a patch: numerals past ten read as a machine ("11 of 12 on Tuesday") in a message whose register is deliberately spoken, so the choice is between a wrong word and a wrong voice. The clamp is asserted in the check file as a known limit, so changing it fails a line rather than surprising someone.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-4-answer-for-yesterday.md`
  summary: There is no Settings surface at all — the morning hour cannot be changed, and notification permission is granted only through Story 1.2's diagnostic push probe.
  evidence: Recorded on 2026-08-20, closing the one gap in Epic 2 that was neither built nor written down (retrospective A3/T2). `components/settings.tsx` is a task in spec 2.4 and a declared acceptance criterion in `epics.md` Story 2.4 per UX-DR17. The back end has been ready since `20260819200000_declaration.sql`: `morning_hour` is `not null default 7`, range-checked, with a column grant to `authenticated` and a policy that lets an account set its own — `supabase/tests/2-1-roles-and-rls.sql` drives exactly that write. What is missing is a way in. `lib/use-gate.ts:51` reads the column with a hardcoded fallback of 7, so the blocking morning gate is pinned at 07:00 for everyone, and `components/push-probe.tsx:85` holds the only `Notification.requestPermission()` call in the codebase — the switch that turns on the product's only delivery channel is a debugging tool from a proof-of-concept story. That is a story, not a missing file, and it belongs at the front of Epic 3.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: Overlapping focus sessions are unconstrained in the database — two rows covering the same wall-clock minutes both bank, and `focus_day_minutes` sums them.
  evidence: Raised by review on 2026-08-20. "One session at a time" lives only in `startSession`'s read of this device's local storage; the schema has no exclusion constraint. The reachable routes are a second device and a restored storage snapshot, neither of which a one-author, one-phone product has today — and D1 already records that clearing storage mid-session *loses* the session rather than duplicating it. Left out because the honest fix is `exclude using gist (owner_id with =, tstzrange(started_at, stopped_at) with &&)`, which needs the `btree_gist` extension and a decision about whether a genuine correction should ever be refused. Worth doing before a second device exists, and worth doing before Story 3.4 judges a week on these totals — inflating the number the author is asked to trust is the one failure this cadence cannot absorb.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: Nothing automated ever runs `supabase/tests/*.sql`, so every rule that lives only in Postgres is verified by hand or not at all.
  evidence: "[RESOLVED 2026-08-21] Raised by review on 2026-08-20. `.github/workflows/ci.yml` ran lint, format, test, build and the `public/sw.js` assertion; there was no Postgres service, no `supabase db reset`, no psql step, and `package.json` had no script touching `supabase/tests/`. The files were real and strong — they exit non-zero on failure and print `PASS.` — but ran only when someone remembered. Fixed: a new `db-tests` job installs the Supabase CLI (`supabase/setup-cli@v3`), starts only the `db` container (`supabase start -x gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor` — everything else in the stack exists for the app to talk to, and this job never does), runs `supabase db reset`, then loops every file under `supabase/tests/` through `docker exec ... psql -v ON_ERROR_STOP=1`. Dry-run verified locally against the exact command sequence: all fourteen files pass against a freshly reset stack with only the database container running. `supabase/tests/README.md` documents the job and now lists all fourteen files (it had drifted to naming only twelve)."

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: `focus_session` and `focus_day_minutes` join the set of tables whose read and write privileges no migration grants.
  evidence: Recorded on 2026-08-20 alongside the existing `pg_default_acl` entry, which names `commitment`, `profile`, `declaration` and the `*_current` views. `supabase/tests/3-1-focus-session.sql` grants `select, insert` on the table and `select` on the view in-fixture, for the same reason the other test files do — the local stack does not reproduce the live project's defaults. Two more objects now depend on how one project happened to be provisioned. The fix is still a single pass granting every table explicitly, and it is still not worth doing piecemeal.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: A permanent rejection that resolves after a new session has been started paints "Not banked." underneath the session that has just begun.
  evidence: Raised by review on 2026-08-20. `stop()` clears the running record synchronously, so the start control is available while the flush is still in flight; a rejection landing afterwards reads as though the *new* session failed. Narrow — it needs a refusal and a restart within the same flush — and the same shape exists in `components/morning-gate.tsx:103-108`, which is where it was copied from. Fix both at once, with a generation counter or by disabling start until the flush settles, rather than fixing one copy and leaving the other.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: Neither session instant has an upper bound — a device clock that jumps forward banks arbitrary hours, and a future `started_at` files a session under a day that has not happened.
  evidence: Raised by review on 2026-08-20. `focus_session_stops_after_it_starts` constrains only the ordering. The spec's Design Notes already accept that the client's clock is the only clock, exactly as `declaration.answered_at` does, so refusing a *skewed* session is out of scope — but a `stopped_at` in the future is refusable without trusting anything, and a row sitting in a future day is one the settlement pass will later walk over. Not added here because a `now()`-based check makes the constraint non-deterministic under the fixed clocks the SQL tests use, and that trade needs its own decision.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: An idle Focus Session screen (nothing running) left open across local midnight goes on showing the previous day's banked total until something touches it.
  evidence: Named by the implementer on 2026-08-20 while fixing the same gap for a *running* session, where the day is re-derived from the ticking clock. Fixing the idle case the same way would mean running a one-second interval while nothing is running, which review finding 10 (this story) forbids on purpose — a screen that ticked while idle would be the first thing in this product doing work nobody asked for. Narrow: it needs the screen open, idle, and left across the boundary with no tap. Revisit only if the author reports a stale total, and prefer a minute-granularity check over a second-granularity one if so.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-2-know-where-the-hours-stand-without-opening-anything.md`
  summary: An account whose `morning_hour` is late (21, 22 or 23) gets fewer than the four hourly focus-prompt attempts every other account gets, because the slot count is derived from hours remaining before local midnight rather than carried across the day boundary.
  evidence: Raised by review on 2026-08-20, found independently by two reviewers. `focus_prompt_hour()` caps the prompt hour at 23 by design (D1), specifically so a late `morning_hour` is checked the same calendar day rather than wrapping into the next one — but `enqueue_focus_prompts()` derives each pass's slot as `local_hour - prompt_hour` against the *same* day, so an account with `prompt_hour = 23` has exactly one reachable slot (23:00) before the day rolls over, `prompt_hour = 22` has two, and only `prompt_hour <= 20` reaches all four. This is a direct, mechanical consequence of the already-approved cap, not a defect in the cap's own reasoning — the alternative (carrying a remaining-attempts count across midnight) is a real design decision about whether "four attempts" is a per-day promise or a per-commitment one, and belongs to whoever revisits this rather than a silent patch. Narrow in practice: it needs `morning_hour >= 21`, which is late for a morning hour. Revisit if the author sets one that late, or moves `morning_hour` there deliberately.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-3-a-weekly-quota-that-counts-down.md`
  summary: "[CARRIED FORWARD 2026-08-22] The escalating push-notification pipeline for a Weekly Quota commitment — silent while there is slack, one push a day once sessions remaining equals days remaining (FR-4's own trigger), a second once overdue — with its own `EXPERIENCE.md` copy for the push body."
  evidence: Split from the original combined spec on 2026-08-20 at the author's request, to keep this spec to one shippable goal rather than two independently mergeable ones. The Today pill (quota position and days remaining, in the urgent family) is genuinely independent: it renders correctly the moment `weekly_quota_progress` and `week_days_remaining()` exist, needs no cron schedule, and needs no new push-body copy at all — `DESIGN.md` already specifies the pill's exact text (`1/3 · 3 days`). The reminder needs its own migration additions (`enqueue_weekly_quota_reminders()`, a cron registration offset from every other schedule, an escalation-timing SQL test, and the poisoned-commitment-name guard Story 3.2 established as required practice) and its own literal copy added to `EXPERIENCE.md` beside KF-6 before it can be built, per UX-DR26. The original spec had already designed this in full before the split — the escalation shape (silent → once-daily → twice-daily, keyed on `slack = days_remaining − sessions_remaining`) and the decision to build a second independent pipeline rather than branch inside `enqueue_gate_reminders()` — and that design should carry forward into whichever spec builds it next rather than being re-derived from scratch. `weekly_quota_progress` (built by the split-off pill spec) is the seam it reads, the same way `focus_day_minutes` was Story 3.2's. **Carried into `_bmad-output/implementation-artifacts/spec-3-5-the-loudest-thing-on-the-phone.md`** (drafted 2026-08-22, per Epic 3's retrospective F2) — spec awaiting approval, nothing built yet.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-3-a-weekly-quota-that-counts-down.md`
  summary: "[DONE 2026-08-20] **Live defect, pre-dates this story.** `commitments_owing()` excludes `daily_hours_quota` but not `weekly_quota` — so a Weekly Quota commitment with `carries_penalty = true` is judged on every single day it is not declared `held`, exactly like a Daily commitment, and a single honest `slipped` answer (or a silently-expired day) triggers a real 500,000₫ penalty. This directly contradicts FR-2: 'A Weekly Quota Commitment is judged only at Week Close; being at 0 of 3 mid-week is never a miss.'"
  resolution: Fixed in `20260820140000_weekly_quota_is_not_judged_daily.sql`, landed before Story 3.4 as this entry recommended. Not the same shape as `daily_hours_quota`'s own exclusion — a Weekly Quota commitment still had to stay inside `commitments_owing()` so it keeps being asked, keeps holding the day open until answered, and keeps freezing into `settlement_commitment` for Story 2.9's day-chain and Story 3.3's own `weekly_quota_progress` view. So `cadence` was added to `commitments_owing()`'s row instead, and only the two counts that turn a miss into money — `admitted` and `silent`, in both `settle_day()` and `supersede_expiries()` (which shared the identical bug, traced separately below) — now exclude `weekly_quota`. Verified with new cases in `supabase/tests/2-5-settlement.sql` (step 9) and `supabase/tests/2-7-supersession.sql` (step 5): a Weekly Quota commitment's own slip or silence now closes the day `clean` with zero penalties, while its outcome still freezes as `missed` so the chain is unaffected. **Not retroactive** — a day already settled `failed` and a penalty already charged before this migration ran are untouched; per the original constraint below, worth checking `penalty` for any real Weekly Quota commitment with `carries_penalty = true` that predates 2026-08-20.
  evidence: Found on 2026-08-20 while investigating whether a Weekly Quota row's existing day-chain (`chain_current`) and this story's new quota pill would read sensibly side by side — the chain itself turned out to rest on the same defect. Traced directly: `commitments_owing()` (`20260819220000_settlement.sql:67-88`) excludes `c.cadence <> 'daily_hours_quota'` at line 83 and names its reason ("FR-2 judges an hours quota against measured minutes, not a statement") — but applies no equivalent exclusion for `weekly_quota`, and no comment anywhere explains why not. `settle_day` (current definition `20260819262000_summary_names_the_strongest_survivor.sql:58-90`) then treats every commitment `commitments_owing()` returns identically: `admitted := count(*) filter (where o.carries_penalty and o.answer = 'slipped')`, and `admitted > 0` sets the day's verdict to `'failed'` and inserts a real `penalty` row (`:71-90`) — with no cadence check anywhere in that path. Verified the client offers no guard either: `MorningGate` (`components/morning-gate.tsx:51,142`) offers both `held` and `slipped` for any commitment `commitmentsOwing()` returns, and `lib/declaration.ts`'s own `questionFor` (`:123-134`) phrases a *different question* for `weekly_quota` ("Did you do X on...") but does not exempt it from being asked, answered `slipped`, or settled. Nothing in `commitment.sql` or `commitment-form.tsx` restricts `carries_penalty` by cadence — any Weekly Quota commitment can be created with it `true` through the ordinary form, same as any other cadence. **Not found anywhere before now**: no prior spec, retrospective, or deferred-work entry names this. Not touched by Story 3.3, which reads `weekly_quota_progress` (a new, separate, read-only view) and does not modify `commitments_owing()`/`settle_day` — this spec's own Boundaries require asking first before touching either. The fix is almost certainly the same shape as `daily_hours_quota`'s own exclusion: add `and c.cadence <> 'weekly_quota'` to `commitments_owing()` (and decide what, if anything, `MorningGate` should still ask a Weekly Quota commitment day-to-day — recording *some* per-day fact is presumably still wanted, since Story 3.3's own `weekly_quota_progress` view sums exactly those `declaration` rows; the fix has to keep the answer being recorded while stopping it from being separately judged and penalized before Week Close). This almost certainly belongs to Story 3.4 (Week Close), which is where FR-2's actual weekly judgment is supposed to land — but the exclusion itself should probably land *before* 3.4 ships, since it is what stops the wrong judgment from happening today, independent of what the right one looks like.
  constraint: If the author has any live `weekly_quota` commitment with `carries_penalty = true`, check `public.penalty` for any charged before 2026-08-20 against it — those predate the fix and are not retroactively reversed by it.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-3-a-weekly-quota-that-counts-down.md`
  summary: "`components/today.tsx` only checks the `commitment` query's own error; a failed `weekly_quota_progress` read (like the pre-existing `chain_current`/`penalty_current` reads beside it) is silently swallowed, rendering as if nothing were held rather than surfacing the failure."
  evidence: "[RESOLVED 2026-08-21] Raised by review on 2026-08-20, found independently by two reviewers. Fixed in the uniform pass this entry always said the honest fix required: `load()` now destructures and checks the `error` field of all four parallel reads (`commitment`, `penalty_current`, `chain_current`, `weekly_quota_progress`) and shows `failed` if any one of them errored. Applied at the same time to `components/ledger.tsx` (five reads) and `components/chains-detail.tsx` (two reads), which shared the identical shape. A new test per component drives each secondary read failing in turn and asserts the failure surfaces. [components/today.tsx, components/ledger.tsx, components/chains-detail.tsx, and their tests]"

- source_spec: `_bmad-output/implementation-artifacts/spec-3-4-the-week-closes-and-settles.md`
  summary: Held Penalty resolution (AD-15's `'held'`/`'collected'` states) for a Failed Week. `settle_week` writes a penalty exactly the way `settle_day` does — `penalty_state` has only `'owed'` — and nothing anywhere resolves it.
  evidence: Named explicitly as out of scope in the spec's own "Never" boundary. Nothing exists yet to resolve until Epic 4's appeal flow adds the `'held'`/`'collected'` states; building resolution against a state machine that has only one value would be speculative. Revisit when Epic 4 lands.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-4-the-week-closes-and-settles.md`
  summary: No week-level supersession/correction pass — a 2.7 equivalent for weeks. A late-but-timely Declaration arriving after its week has already closed is not retroactively corrected the way `supersede_expiries()` corrects a day.
  evidence: Named explicitly as out of scope in the spec's own "Never" boundary, mirroring 2.7's shape for days but deliberately not built here. A Weekly Quota commitment's own declarations can still arrive up to 48 hours late (the same 2.7 window a Daily commitment gets) and land inside `weekly_held_count`'s window fine as long as `settle_week` has not yet run for that period — the gap is specifically a declaration answered *after* the week has already settled `failed`, which today stands uncorrected exactly as if 2.7 had never shipped for weeks. Revisit if the author reports a week's verdict disagreeing with a Declaration he in fact made in time.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-4-the-week-closes-and-settles.md`
  summary: "`components/ledger.tsx`'s two new `kind = 'week'` reads (`settlement_current`, `penalty_current`) join the pre-existing `penalties`/`misses` reads in having their errors silently swallowed — only the first query's (`settlements`, `kind = 'day'`) error is checked."
  evidence: "[RESOLVED 2026-08-21] Raised by three-layer review on 2026-08-20, found independently by all three reviewers, and re-confirmed by the 2026-08-21 four-layer review (see the line below). Fixed in the same uniform pass as the `today.tsx` entry above — see its resolution, which also covers `components/chains-detail.tsx`. [components/ledger.tsx; components/ledger.test.tsx]"

- source_spec: `_bmad-output/implementation-artifacts/spec-3-4-the-week-closes-and-settles.md`
  summary: "`week_summary_body()`'s self-dating (`to_char(p_period, 'FMDay')`, a named weekday) depends on the database's `lc_time` locale. Under any non-English locale, the weekday name would not match `push_body_is_sendable`'s `(Monday|Tuesday|...)` regex, and `settle_week()`'s `outbox_enqueue` call — inside the same transaction as the verdict — would fail its check constraint, rolling back the whole pass for that account."
  evidence: Raised by review on 2026-08-20 (blind-hunter layer). This exact class of bug — `to_char` output following server locale rather than the product's fixed voice — already hit this project once: `day_summary_body`'s amount formatting followed `lc_numeric` and produced the wrong grouping character until Story 2.8 made the separator explicit (recorded above in this file). Not fixed here because the local stack and, by strong inference, the live Supabase project both default to `en_US.UTF-8` (verified locally: `show lc_time` returns `en_US.UTF-8`, `to_char(current_date, 'FMDay')` returns `'Thursday'`), so there is no live failure — but the dependency is implicit and undefended the way `lc_numeric` was before 2.8. Revisit by spelling the weekday from a fixed English array (mirroring `day_summary_body`'s own `array['none'..'ten']` pattern) if the project's locale is ever anything other than the current default.

## Deferred from: code review of spec-3-4-the-week-closes-and-settles (2026-08-21)

- summary: "A commitment created mid-week is judged against its full `weekly_target` for that first, partial week — the `created_at` cutoff only excludes a commitment created after the candidate week already elapsed (the case Step 11 now tests), not one created partway through a week still open. Created on day 6 of its own week with target 3, it is near-certain to settle `failed` and cost a full penalty for a week it existed 1–2 days."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Human decision on 2026-08-21 — keep as-is rather than exempt or prorate the first partial week, matching `weekly_quota_progress`'s own live behavior (which shows the same commitment as already short on day 1, not exempt). Revisit if the author reports being penalized for a commitment he had no real chance to meet in its first week.

- summary: "Archiving a Weekly Quota commitment after its week has ended but before the hourly `:45` sweep actually settles it erases the closed week's verdict and penalty entirely — `archived_at is null` is evaluated at settle time, not at the week's own boundary, so this is a real (if narrow) window to avoid a Failed Week's penalty by archiving within the hour."
  evidence: Raised by the 2026-08-21 review (edge-case-hunter). Human decision on 2026-08-21 — defer rather than tighten the guard now; the matrix only blesses the mid-week archive case (a commitment archived before its week ends, correctly excluded), and this is a distinct, narrower race that shares its reasoning with the missing week-level supersession pass already deferred by this spec's own "Never" boundary. Revisit alongside that work — the fix (`archived_at is null or archived_at >= <the week's own settlement boundary>`) is small once that boundary has a name.

- summary: "[RESOLVED 2026-08-21] Error swallowing on 4 of 5 `components/ledger.tsx` parallel reads — re-confirmed by the 2026-08-21 four-layer review; recorded above (entry from this story's own diff, 2026-08-20). Fixed in the same uniform pass as the entry above it — see that entry's resolution."

- summary: "`week_summary_body`'s locale coupling is wider than the `FMDay`/`lc_time` entry above records: `translate(to_char(p_amount, 'FM999G999G999'), ',', '.')` only corrects locales whose group separator is a comma (a space or non-breaking-space `G` output would pass through wrong), and the function is declared `immutable` while `to_char` on dates/numbers is `stable` (locale-dependent) — a mislabel it shares with `day_summary_body` itself."
  evidence: Raised by the 2026-08-21 review (blind-hunter layer). Deferred for the same reason as the `FMDay` entry above — the stack's locale is `en_US.UTF-8` everywhere today, and the pattern (including the `immutable` label) is mirrored verbatim from `day_summary_body`, so the honest fix is one pass over both functions (fixed English weekday array, explicit separator arithmetic, `stable`), not a divergence in the newer one.

- summary: "Bounded lookback orphan: `settle_due_weeks()` sweeps `today - 14 .. today - 8` (widened from `today - 13 .. today - 7` during this same review, to clear the settle gate's own `p_period + 8` boundary), so after a cron outage longer than ~6 days, weeks that fell out of the window are never settled — no verdict, no penalty, silently."
  evidence: Raised by the 2026-08-21 review (edge-case-hunter + blind-hunter). Mirrors `settle_due_days`'s own bounded `today - 5 .. today - 1` window, which has the identical property for days and was accepted without a record; recorded now for both. Revisit if pg_cron reliability ever becomes a real operational concern — widening the window is cheap (`settle_week` no-ops on open weeks and is idempotent on settled ones), the cost is only scan time.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-4-the-week-closes-and-settles.md`
  summary: The Ledger's "Everything held" text (both the day-row and, now, the week-row copy) is shown whenever `verdict = 'clean'`, including a day/week where a penalty-free commitment actually slipped or fell short — "clean" means "nothing charged," not "nothing happened," and the Ledger says the second when it means the first.
  evidence: Raised by review on 2026-08-20 while auditing the week row's copy. Confirmed pre-existing for days, not introduced by this story: `components/ledger.tsx`'s `misses` query is filtered to `carries_penalty: true` before `buildLedger` ever sees it, so a penalty-free `slipped` declaration never reaches `row.missed`, and a day where only that commitment slipped already showed "Everything held" before 3.4 touched anything. `components/ledger.tsx`'s new week-row branch inherits the identical shape (`row.verdict === 'clean' ? 'Everything held' : ...`, with no per-commitment data available to say otherwise — 3.4's own "Never" boundary rules out per-commitment week freezing). `week_summary_body` itself is *not* affected the same way — it names the shortfall commitment whenever `shortfall_count >= 1` regardless of `carries_penalty`, so the push notification for this case reads correctly (e.g. "Reading, 1 of 3 held, week of..." with no amount); only the Ledger's own secondary-line text is wrong. Deferred rather than patched because the honest fix (a third state, distinct from both "held" and "failed", for "something slipped but nothing is owed") touches vocabulary both day and week rows share and is a real product-language decision, not a one-line patch.
  update_2026_08_25: The independent review of Story 5.1 found the identical symptom on a third
  cause — a `waived` day (Grace Day spent, `apply_grace_days()`'s corrective settlement also
  reads `verdict = 'clean'`) shows "Everything held" too, distinguishable from a genuinely clean
  day only by its pill and its screen-reader-only `aria-label`. Same root cause, same deferred
  reasoning: the honest fix is the same missing third state this entry already names, now with
  three causes (penalty-free slip, week shortfall, Grace Day) collapsing into one string instead
  of two.

## Deferred from: code review of spec-3-0-change-the-hour-i-am-asked (2026-08-21)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-0-change-the-hour-i-am-asked.md`
  summary: "Rapid consecutive hour changes can race in `components/settings.tsx`'s `setHour`: if an earlier call fails after a later one has already applied a newer optimistic value, the earlier call's stale `previous` closure reverts the field past the newer selection."
  evidence: "[RESOLVED 2026-08-21, same review] Raised by the edge-case-hunter layer, but a sibling `patch` finding from the same review (the frozen I/O matrix's 'field keeps the value the author typed' row) removed `setHour`'s revert-on-error path entirely — there is no more `previous` closure to go stale, so this race no longer exists. No action needed; kept here for the record rather than deleted."

- source_spec: `_bmad-output/implementation-artifacts/spec-3-0-change-the-hour-i-am-asked.md`
  summary: "`refusalBeforePrompting` (`lib/push-subscribe.ts:71`) gives `installState === 'unknown'` the identical 'not launched from the home screen' message it gives `'browser'`, which could misleadingly read as certain non-installation during the brief detection window before `app/page.tsx`'s install-state check resolves."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — in practice `installState` resolves on mount, before a user can navigate to Settings and reach this code path, so the window is narrow. Revisit if `'unknown'` is ever observed reaching this message live.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-0-change-the-hour-i-am-asked.md`
  summary: "Two entry points now call `subscribeThisDevice` — `components/push-probe.tsx` (always rendered) and the new Settings 'Turn on notifications' button — with no shared in-flight guard, so a near-simultaneous tap on both could race two `pushManager.subscribe()` calls."
  evidence: Raised by the 2026-08-21 review (edge-case-hunter + blind-hunter). Deferred — low likelihood (requires two taps within one network round trip), and `push_subscription`'s upsert is keyed on `endpoint`, so the worst case is a redundant upsert rather than corrupted data. Revisit if the probe is ever retired or the two paths are unified (spec 3.0, D3 already notes retiring the probe is a separate decision).

- source_spec: `_bmad-output/implementation-artifacts/spec-3-0-change-the-hour-i-am-asked.md`
  summary: "The `Failed.`/`Not saved.`/`Refused.` error paragraphs in `components/settings.tsx` carry no `role=\"alert\"`/`aria-live`, so a VoiceOver user is not told automatically when they appear."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — not required by any acceptance criterion in this story; the rest of `EXPERIENCE.md`'s Accessibility Floor is honored elsewhere in the codebase, so this is a real gap worth a dedicated pass over the app's error messaging generally, not a one-off patch to this one component.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-0-change-the-hour-i-am-asked.md`
  summary: "`supabase/tests/3-0-morning-hour.sql`'s post-hour-change re-settlement step asserts only row count, not `verdict`, so a regression that re-judges and overwrites the verdict while keeping one row would pass silently."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — a test-quality gap rather than a shipped defect; cheap to strengthen in a follow-up pass over the SQL test file rather than blocking this story on it.

## Deferred from: code review of spec-3-1-start-the-work-by-starting-a-clock (2026-08-21)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "`deliverSessions()` is uncaught in the mount/`online` `drain()` effect in `components/focus-session.tsx` — if `flush()`'s `send` callback throws rather than resolving `'failed'`/`'sent'`/`'duplicate'`, the drain silently stalls with an unhandled rejection and no user-facing signal."
  evidence: Raised by the 2026-08-21 review (edge-case-hunter + blind-hunter). Deferred — narrow (requires `send` to throw a raw exception rather than take the classified error path `supabase-js` normally takes) and self-healing (the next `online` event or screen open retries the same drain).

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "`stop()`'s single `catch` in `components/focus-session.tsx` always reports `FOCUS_COPY.deviceRefused` ('This device would not record the session…'), even when the throw happens after `enqueue()` has already queued the session locally — the message is technically imprecise in that narrow case (the session is not lost, only unsent)."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — narrow and low-consequence; no data loss, only an imprecise message in an already-rare failure path.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "The `'refused'` view in `components/focus-session.tsx` (`FOCUS_COPY.notAnHoursQuota`) reads identically whether the commitment has the wrong cadence or does not exist/belong to the caller."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — effectively unreachable in normal navigation, since Today only ever passes the author's own commitment ids to this screen.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "`load()`'s two read failures (`commitment`, `focus_day_minutes`) in `components/focus-session.tsx` collapse into one generic `unreadable` reason string, losing which read actually failed."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — cosmetic; the clock and Stop control remain available either way, which is the property the `unreadable`/`refused` split exists to protect.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "`rejections.join(' ')` in `components/focus-session.tsx` has no guaranteed punctuation between multiple distinct rejection messages collected in one flush pass."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — cosmetic and rare, requiring two or more distinct permanent rejections in the same pass.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "`<FocusSession>` is rendered in `app/page.tsx` with no `key` tied to `focusOf.id` — harmless today since nothing transitions `focusOf` directly between two non-null commitments, but undefended against a future change that would."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — defensive-only; add the `key` if `app/page.tsx` ever gains a way to switch `focusOf` from one commitment straight to another.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "`FOCUS_COPY.alreadyElsewhere` ('A clock is already running on another commitment. Stop that one first.') names no way to reach the commitment whose clock is already running."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — a UX nice-to-have rather than a defect; the author started the other clock himself, minutes or hours earlier, and knows which commitment it was.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-start-the-work-by-starting-a-clock.md`
  summary: "`readRunning()` in `lib/focus-session.ts` does not validate that a present `startedAt` parses as a date, so a corrupted record would render `NaN:NaN:NaN` rather than being refused the way a missing field already is."
  evidence: Raised by the 2026-08-21 review (edge-case-hunter). Deferred — requires a corrupted `localStorage` record (external tampering, or a bug elsewhere writing malformed data) to reach; the missing-field guard right beside it already covers the realistic failure mode.

## Deferred from: code review of spec-3-2-know-where-the-hours-stand-without-opening-anything (2026-08-21)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-2-know-where-the-hours-stand-without-opening-anything.md`
  summary: "No SQL test exercises cadence exclusion or the `role = 'doer'` filter directly in `enqueue_focus_prompts()`, and no SQL test exercises the fully-silent account case (every commitment already at target) — the shipped SQL is correct on inspection but these three branches are untested."
  evidence: "[RESOLVED 2026-08-21, same session] Raised by the 2026-08-21 review (blind-hunter). Initially deferred because this environment had no Docker/local Postgres running. Docker was started later the same session: `supabase/tests/3-2-focus-prompt.sql` gained steps 9–11 covering all three branches, step 9's exclusion was confirmed to depend on the real cadence filter (not an accident of role or archival state) by checking the same row would be visible without it, and all fourteen files under `supabase/tests/` pass against a freshly reset local stack."

- source_spec: `_bmad-output/implementation-artifacts/spec-3-2-know-where-the-hours-stand-without-opening-anything.md`
  summary: "The push body composed in `enqueue_focus_prompts()` (commitment name + banked/target/time) has no length guard — `push_body_is_sendable` screens only for banned phrasing and self-dating, never length."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — pre-existing and shared by every notification body in the codebase (gate reminders, day and week summaries all use the same `push_body_is_sendable` rule with the same absence of a length check); not introduced or worsened by this story. Revisit with one pass across every body-composing function if it is ever an issue in practice.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-2-know-where-the-hours-stand-without-opening-anything.md`
  summary: "`.quota-bar`/`.quota-bar-fill` (`app/globals.css`) have no `forced-colors`/high-contrast fallback and no minimum width for a very small non-zero fill, which can round to sub-pixel and effectively vanish."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — no element anywhere in this codebase handles `forced-colors: active` yet, so this is a systemic gap rather than one this story introduced; the minimum-width question is a design call (how many px reads as "some progress" without misrepresenting a near-zero fill), not an unambiguous bug fix. Revisit alongside a dedicated accessibility pass if Windows High Contrast use is ever reported.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-2-know-where-the-hours-stand-without-opening-anything.md`
  summary: "`bankedPercent()` in `lib/focus-session.ts` has no explicit guard against non-finite (`NaN`/`Infinity`) input propagating into the rendered bar's `width` style."
  evidence: Raised by the 2026-08-21 review (blind-hunter). Deferred — defensive-only; `targetMinutes` is guaranteed positive by `commitment_daily_hours_target`'s biconditional check and `bankedSeconds` always comes from a real numeric read, so the condition cannot occur in practice today.

## Deferred from: code review of spec-3-5-the-loudest-thing-on-the-phone (2026-08-23)

- source_spec: `_bmad-output/implementation-artifacts/spec-3-5-the-loudest-thing-on-the-phone.md`
  summary: "D4's day-scoped dedupe key fix (keying on `today` rather than `week_start`, so a commitment doesn't claim slot 0 only once for the whole week) is never proven by a test that actually advances to a second calendar day — the suite only exercises a same-hour retry and a same-day (simulated) twelve-hours-later pass."
  evidence: Raised by the 2026-08-23 review (blind-hunter). Deferred — correctness is supported by direct inspection (the dedupe key literally includes `today`), and unlike the hour-shifting trick already used for slots, there's no cheap way to advance the simulated calendar day without a mockable clock function. Revisit if a clock-mocking utility is ever added for this test suite.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-5-the-loudest-thing-on-the-phone.md`
  summary: "Slot 1 matches purely on hour-of-day (`(morning_hour + 12) % 24`), not on \"twelve hours after slot 0 fired\" — for a `morning_hour` late in the day (e.g. 20:00), slot 1's hour falls on the next calendar day, reading `weekly_quota_progress`'s numbers as of that later day (potentially a different week per D6) rather than continuing the day slot 0 fired on."
  evidence: Raised by the 2026-08-23 review (blind-hunter). Deferred — likely self-limiting since `morning_hour` is semantically a morning hour throughout the product (used the same way by `enqueue_gate_reminders`/`enqueue_focus_prompts`), but nothing in this diff constrains its value or discusses the boundary. Revisit if an account is ever observed setting an evening `morning_hour`.

## Deferred from: code review of spec-4-1-attach-a-check-that-answers-for-me (2026-08-23)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-1-attach-a-check-that-answers-for-me.md`
  summary: "Editing a still-linked commitment (e.g. changing its `auto_check_account_ref` without unlinking first) leaves `auto_check_last_checked_at` untouched client-side — `toRow()` sends `undefined` for that column whenever `autoCheckEnabled` stays true, so a changed account ref doesn't invalidate the 'last read' timestamp shown for the old one until the next hourly resolution pass overwrites it."
  evidence: Raised by the story's own implementing agent (2026-08-23) and confirmed by blind-hunter's independent review the same day. Deferred — not covered by the spec's boundaries, cosmetic (a stale display, self-corrects within the hour), and the `undefined`-strips-the-field convention is exactly what lets the client avoid racing the resolution pass's own writes to that column. Revisit if a later story needs the display to be exact rather than eventually-consistent.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-1-attach-a-check-that-answers-for-me.md`
  summary: "[RESOLVED 2026-08-24, second review pass] `resolve_auto_checks()`'s SQL test proves the resolver dispatch, the filer, and the dedupe/silence guarantees, but never constructs an archived+linked+undeclared commitment (to prove the pre-existing `archived_at is null` filter actually excludes it) and never attempts to call the three new `security definer` functions as an unprivileged role (to prove the `revoke execute` grants actually hold) — both are proven patterns elsewhere in this test suite (3-2/3-3/3-4 for archival, 2-1-roles-and-rls.sql for privilege checks) that this file's own test matrix omits."
  evidence: Raised by the 2026-08-23 review (blind-hunter), re-confirmed independently by the 2026-08-24 pass (blind-hunter + verification-gap on the same finding). Reclassified from deferred to patched once two independent layers converged on it with a concrete regression demonstration. Fixed: `supabase/tests/4-1-account-elsewhere.sql` step 5 gained an archived+linked+undeclared fixture (`v_archived`), and `2-1-roles-and-rls.sql`'s function array gained the three new functions.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-1-attach-a-check-that-answers-for-me.md`
  summary: "The commitment list view gives no visual indicator that a commitment has an Auto-check linked — the author has to open Edit to discover, e.g., that 'TryHackMe' has Account elsewhere attached."
  evidence: Raised by the 2026-08-24 review (blind-hunter). Deferred — a real product/design gap, but out of this story's frozen Intent (which only specifies the Task setup surface's unlinked/linked states, not a list-row indicator); adding one is a UI/design decision, not an unambiguous code fix. Revisit alongside Story 4.2 or a UX pass over the commitment list.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-1-attach-a-check-that-answers-for-me.md`
  summary: "`resolve_auto_checks()` has no per-row exception isolation (no savepoint/exception handler inside its loop) — an exception thrown partway through the hourly pass aborts the whole function, rolling back every commitment already resolved earlier in the same loop iteration, not just the one that failed."
  evidence: Raised by the 2026-08-24 review (blind-hunter). Deferred — today's only resolver (`resolve_account_elsewhere`) is a deterministic stub that cannot throw, and the one concrete failure mode identified (a concurrent unlink) was already closed by this same review's `and auto_check_kind is not null` guard. Real risk only appears once a future story adds a resolver that can genuinely fail (a live HTTP call). Revisit when that story is built — the fix (mirroring Story 3.2's own `continue when not push_body_is_sendable`-style per-row skip) is cheap once there's a real failure mode to guard against.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-1-attach-a-check-that-answers-for-me.md`
  summary: "The dispatcher query in `resolve_auto_checks()` (`where c.auto_check_kind is not null and c.archived_at is null and ...`) has no supporting partial index, so the hourly pass is a full-ish table scan as commitments grow."
  evidence: Raised by the 2026-08-24 review (blind-hunter). Deferred — matches the current, accepted pattern of every other reminder/settlement dispatcher in this schema (none of `enqueue_gate_reminders`, `enqueue_focus_prompts`, `settle_day`, `resolve_auto_checks`'s siblings has a dedicated index for its own WHERE clause either), so this is a systemic characteristic of the current scale, not a regression this story introduced. Revisit alongside a general indexing pass if query performance is ever observed to matter.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-1-attach-a-check-that-answers-for-me.md`
  summary: "`public.declaration` has no column distinguishing a machine-filed row (via `file_auto_check_result`) from a human-tapped one — once filed, a `held` declaration from the Auto-check pass is indistinguishable from one the author typed himself."
  evidence: Raised by the 2026-08-24 review (blind-hunter). Deferred — a real gap for any future audit trail, "auto-confirmed" UI treatment, or correction flow, but adding a column to a widely-read table is a design decision affecting every consumer of `declaration`, not a one-line fix this story's own boundaries authorize. Revisit if a later story needs to distinguish machine- from human-filed declarations (e.g., a correction/dispute flow for a wrongly auto-filed day).

- source_spec: `_bmad-output/implementation-artifacts/spec-4-1-attach-a-check-that-answers-for-me.md`
  summary: "A commitment archived concurrently between `resolve_auto_checks()`'s loop `select` and its later `file_auto_check_result`/`update` calls is not excluded mid-pass the way a concurrent unlink now is — `archived_at` isn't part of the final update's guard, so an archived commitment could still have `auto_check_last_checked_at` bumped (and, once a real resolver exists, a declaration wrongly filed) for that one pass."
  evidence: Raised by the 2026-08-24 review (edge-case-hunter). Deferred — narrower and lower-severity than the unlink race this same review closed: archiving doesn't touch `auto_check_kind`, so no check constraint is violated and the pass doesn't abort; worst case today is a cosmetic timestamp bump (v1's resolver never files). Revisit alongside the per-row exception-isolation item above, once a real resolver makes the filing consequence non-hypothetical.

## Deferred from: code review of spec-4-2-a-check-that-cannot-run-never-says-i-missed (2026-08-24)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-a-check-that-cannot-run-never-says-i-missed.md`
  summary: "`auto_check_pending()`'s day-boundary identity (`(auto_check_last_checked_at at HCM)::date - 1 < p_day`) is a hand-mirrored duplicate of the same math inside `resolve_auto_checks()` (`target_day := (now() at HCM)::date - 1`) rather than shared code — nothing keeps the two definitions in sync if either is ever edited independently."
  evidence: Raised independently by blind-hunter and verification-gap in the 2026-08-24 review of Story 4.2. Deferred — this duplication was a deliberate, disclosed tradeoff in the story's own spec ("no new column... reuses the exact identity"), not an oversight, and extracting a shared helper both functions call would touch `resolve_auto_checks()` (Story 4.1's own function) beyond this story's stated boundaries. Revisit if either function's day-boundary math is ever changed — at that point, extract one shared SQL expression/function both read.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-a-check-that-cannot-run-never-says-i-missed.md`
  summary: "No test exercises `auto_check_pending()`'s exact 96-hour grace boundary (`now()` immediately before vs. immediately after the cutoff) — every grace-related fixture in `supabase/tests/4-2-unavailable-is-not-missed.sql` is far past the edge (10 or 35 days old) rather than adjacent to it."
  evidence: Raised by blind-hunter in the 2026-08-24 review of Story 4.2. Deferred — the strict `now() < close + interval '96 hours'` comparison is simple enough that the far-past-edge fixtures already exercise the same boolean branch a boundary fixture would; a boundary-precision test adds real confidence but not new branch coverage, and this story's own round-1.5 correction (48h → 96h, closing a genuine inertness bug) already came from a targeted boundary test (Step 2b) rather than this one. Revisit if the grace constant or its base point ever changes again.

## Deferred from: independent code-review of commit 574d838 (2026-08-24)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-a-check-that-cannot-run-never-says-i-missed.md`
  summary: "settle_week's new AD-13 guard (a raw commitment scan) and its `quota` loop 30 lines later independently re-type the identical commitment-selection filter (owner_id/cadence='weekly_quota'/archived_at is null/week_start_day/created_at<p_period+7) rather than sharing one definition."
  evidence: Raised by an independent code-review pass (reuse + altitude angles) against commit 574d838. Deferred, not patched -- this exact class of duplication already caused one real, shipped-then-caught bug earlier in this same story (settle_day's guard originally missed a cadence exclusion its neighboring aggregate already had), so the risk is demonstrated, not hypothetical. Not fixed now because a shared-selection refactor (a CTE both the guard and the loop read) touches the shape of an already-tested, already-reviewed function; revisit alongside a broader settlement-function cleanup pass rather than bolting it onto this story's fourth round of changes.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-a-check-that-cannot-run-never-says-i-missed.md`
  summary: "settle_day and settle_week each hand-write their own version of 'which commitments can block this settlement' (one via commitments_owing() plus a cadence exclusion, one via a raw commitment scan plus the opposite cadence filter) instead of sharing one AD-13 eligibility definition."
  evidence: Raised by an independent code-review pass (altitude angle) against commit 574d838, citing this story's own round-2 drift (see the entry above) as direct evidence the duplication is a real, demonstrated risk rather than a hypothetical one. Deferred -- unifying the two would mean reconciling that one path reads owed commitments of every cadence and the other reads only weekly_quota ones for a whole period, which is a genuine architectural difference, not pure duplication; a shared helper is worth designing deliberately, not retrofitted under review pressure.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-2-a-check-that-cannot-run-never-says-i-missed.md`
  summary: "settle_day's AD-13 guard invokes commitments_owing() a second time in the same account/day iteration solely to check one boolean the first (aggregate) call already had the data for; auto_check_pending() also re-selects the commitment row once per (commitment, day) pair inside settle_week's 7-day generate_series loop rather than reusing columns the caller's cross join already has."
  evidence: Raised by an independent code-review pass (efficiency angle) against commit 574d838. Deferred -- matches the codebase's own established, already-accepted pattern of calling commitments_owing() multiple times per settle_day iteration (the aggregate, the settlement_commitment insert, the survivor and suggestion selects all already did this before Story 4.2), and is immaterial at this app's current single-doer-per-account scale. Revisit alongside a general settlement-query consolidation pass if this ever shows up in real query load.

## Deferred from: independent code-review of commit a6c92f9 (2026-08-24)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-3-when-money-rides-on-it-the-machine-s-word-stands.md`
  summary: "`declaration` still has no column distinguishing a machine-filed row from a human-typed one (first flagged in Story 4.1's review). Story 4.3's own conflict-detection copy now has to work around exactly that gap in prose — 'from another device, or by an Auto-check if one is attached' — because `classifyConflict` genuinely cannot tell the two apart. Story 4.4 (Appeal) will need to know which filed rows are appealable machine decisions versus ordinary human declarations."
  evidence: Raised independently by the round-2 (blind-hunter/edge-case-hunter) and round-3 (altitude) reviews of Story 4.3. Deferred, not built — a marker column is a design decision affecting every consumer of `declaration`, and this story's own boundaries explicitly excluded it. Two stories now depend on this gap in different ways (4.3's messaging works around not knowing; 4.4 will likely need to know to decide what's appealable) — worth resolving as part of Story 4.4's own design rather than retrofitted here.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-3-when-money-rides-on-it-the-machine-s-word-stands.md`
  summary: "Conflict detection in `morning-gate.tsx` is insert-then-select (two round trips, and a second RLS policy the write path was never designed to depend on) rather than atomic — e.g. an RPC returning `{outcome, existing_key}` from inside the same statement via `on conflict ... do update returning` or a plpgsql wrapper. Every legitimate own-retry (not only genuine FR-2a conflicts) now pays for the extra round trip before the gate can resolve."
  evidence: Raised by the round-3 (altitude, efficiency) review of commit a6c92f9. Deferred — a genuine architectural improvement, but a bigger redesign than this story's own scope (which deliberately kept `declaration` writes as plain client inserts, unchanged). Revisit if this path is ever observed to matter for latency, or alongside the machine/human marker column above (an RPC could return both facts atomically).

## Deferred from: independent code-review of commit bbcca81 (2026-08-24)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-4-contest-a-miss-the-machine-got-wrong.md`
  summary: "`void_expired_appeals()`'s guarded update joins on `a.penalty_id = p.id and a.deadline < now()` without restricting to the appeal currently responsible for the hold — once Story 4.6's ruling exists (`held → owed`), a Penalty resolved by one appeal's ruling and re-held by a second, later-eligible appeal on the same Failed Day could still be voided off a first appeal's stale, already-past deadline."
  evidence: Raised by an independent code-review pass (line-by-line angle) against commit bbcca81. Deferred — not reachable through the app today: nothing in the current schema can move a Penalty `held → owed` (that transition is Story 4.6's ruling, not yet built), so no appeal row can currently become "stale but pointing at a re-held Penalty." Revisit as part of Story 4.6's own design — the fix (a marker for "the appeal currently responsible for this hold," or re-deriving eligibility from `appeal_id = penalty.id`'s single current claimant) belongs with the ruling mechanism itself.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-4-contest-a-miss-the-machine-got-wrong.md`
  summary: "`appeal_hold_penalty()` reads `commitment.carries_penalty` live rather than from a frozen snapshot of what was true when the Penalty was created — `commitment: edit own` is a table-wide RLS UPDATE grant with no column restriction, so nothing in the schema stops `carries_penalty` from being toggled after the fact."
  evidence: Raised by an independent code-review pass (line-by-line angle) against commit bbcca81. Deferred — no UI path exposes editing `carries_penalty` post-creation, and toggling it via a direct REST call could only ever hurt the toggler (it can *refuse* an otherwise-eligible appeal, never forge one). Revisit only if a Settings/edit surface for `carries_penalty` is ever built.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-4-contest-a-miss-the-machine-got-wrong.md`
  summary: "The `storage.objects` ownership check (`exists (select 1 from public.appeal a where a.id::text = (storage.foldername(name))[1] and a.owner_id = auth.uid())`) is duplicated verbatim across the SELECT and INSERT policies on the `appeal-evidence` bucket rather than factored into a shared function."
  evidence: Raised by an independent code-review pass (altitude angle) against commit bbcca81. Deferred — only two call sites exist today; Story 4.5/4.6 will likely add a third (a referee's own read), which is the point at which a shared function pays for itself. Revisit then.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-4-contest-a-miss-the-machine-got-wrong.md`
  summary: "`evidenceObjectPath()`'s filename sanitizer (`lib/appeal.ts`) strips every character outside `[\\w-]`, including the `.` before a file extension, so `photo.jpg` is stored as `evidence-1-photo_jpg` — the extension is destroyed, not just path-traversal characters (only `/` matters for `storage.foldername` traversal, and that's already excluded without touching `.`)."
  evidence: Raised by an independent code-review pass (simplification angle) against commit bbcca81. Deferred — no consumer needs to know an evidence file's type from its stored name yet; Storage keys the object's real content type off the upload's own `content-type` header, and no referee/admin surface exists to read these files back (Story 4.5/4.6). Revisit once such a surface is built and needs to distinguish file types by name.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-4-contest-a-miss-the-machine-got-wrong.md`
  summary: "`ledgerPillLabel()` and `ledgerPillFamily()` (`lib/ledger.ts`) independently re-derive the same verdict/state decision tree to produce a label and a colour family, and `components/ledger.tsx`'s aria-label re-derives it a third time inline rather than building off either function — three copies that must be kept in lockstep by hand as more penalty states arrive (`collected` in 4.7, `waived` in 5.1)."
  evidence: Raised by an independent code-review pass (simplification + reuse angles) against commit bbcca81. Deferred — a real, growing duplication risk, but restructuring into one `{label, family}`-returning function that both the pill and the aria-label read is a small refactor better done as its own deliberate pass than folded into this story's fourth round of changes. Revisit before Story 4.7 or 5.1 adds another state.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-4-contest-a-miss-the-machine-got-wrong.md`
  summary: "`components/appeal-form.tsx` constructs the same `{ kind: 'held', appealId, deadline }` shape twice (once from the direct insert response, once from the reread-after-23505 response) and independently repeats the identical `{ kind: 'failed', reason: APPEAL_COPY.evidenceFailed }` at three separate error sites inside `uploadEvidence` with no behavioral difference between them."
  evidence: Raised by an independent code-review pass (simplification angle) against commit bbcca81. Deferred — cosmetic duplication with no observable behavior difference today; worth collapsing in a future pass over this component rather than as a late addition to this story.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-4-contest-a-miss-the-machine-got-wrong.md`
  summary: "`appeal_hold_penalty()` runs three sequential lookups (settlement/outcome, declaration.filed_by, penalty) that could be one joined query; the penalty is read and then separately written in the same trigger where the guarded UPDATE alone would suffice; the `storage.objects` policies cast the indexed `appeal.id` to `text` for comparison instead of casting the path segment to `uuid`; and `lib/ledger.ts`'s `appealableByDay`/`missedByDay` maps are built with `[...(arr ?? []), item]` per iteration (O(n²) allocation) rather than mutating in place."
  evidence: Raised by an independent code-review pass (efficiency angle) against commit bbcca81. Deferred — all four are real but immaterial at this app's current single-doer-per-account scale, matching the same "revisit if it ever shows up in real query load" judgment already recorded for Story 4.2's own settlement-query duplication above. Revisit alongside a general query-consolidation pass if this ever matters in practice.

## Deferred from: code review of spec-4-5-the-referee-has-his-own-way-in (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "The referee's new read policies on `appeal`, `appeal_evidence`, `settlement`, `penalty` and `commitment` (`20260824160000_the_referee_has_his_own_way_in.sql`) are not scoped to `is_live_doer`, so they grant the one paired referee a read of every doer account's rows, not only the live doer's. `pair-referee` refuses to create a referee unless the pairing caller is the live doer, but that only guarantees who *paired* the referee — it does not stop a stranger from self-registering an ordinary `role = 'doer'` account (`sign-in.tsx`'s own signup is open to anyone, uncapped) after pairing and adding incidental rows the referee's own wide policies would then expose."
  evidence: Raised in the migration's own header comment while writing Story 4.5 (2026-08-24), and recorded here as that comment promised. The exposure runs from a stranger's own incidental data toward the referee, never from the live doer's real data toward an unauthorized party — `profile_single_referee` still guarantees at most one referee, and that referee was paired by the real doer. Not fixed here because scoping every one of these policies to `is_live_doer` (a join or subquery added to five separate policies) is a larger change than a single-doer product's actual exposure surface warrants right now — the doer is, in practice, the only account with real data in it. Revisit if this product is ever run somewhere self-registration by strangers is a realistic scenario (a public deployment, not this author's own single-doer instance), or alongside a broader pass scoping every referee policy to `is_live_doer` at once.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`pair-referee`'s `is_live_doer` refusal (`index.ts:99`, the check that stops a self-registered stranger from pairing first and permanently claiming the one referee slot) has no test coverage anywhere. `supabase/tests/4-5-the-referee-has-his-own-way-in.sql`'s referee fixture is built with a direct service-role `update profile set role = 'referee'`, bypassing the function entirely, and no Edge Function in this repo has an automated test of any kind (`outbox-worker` has none either)."
  evidence: Raised by the 2026-08-25 review (verification-gap). Deferred rather than patched — closing it properly needs Deno test infrastructure for Edge Functions that does not exist anywhere in this codebase yet, which is bigger than this story's own scope; a manual walkthrough is the only verification this story ships (matching `outbox-worker`'s own precedent), and the spec's Verification section has been corrected to state plainly what was and wasn't exercised. Revisit if this codebase ever adds Deno-test coverage for its Edge Functions generally — `pair-referee`'s `is_live_doer` gate should be the first case covered, since it's the one Edge Function in this repo whose failure mode is a permanent, unrecoverable account-take (no unpair/re-pair path exists).

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`components/settings.tsx`'s referee-pairing row never checks whether a referee is already paired on mount — after a successful pairing, closing and reopening Settings shows the same email input and 'Pair referee' button again, as if nothing were paired. The doer only learns otherwise by resubmitting and reading the server's 409 refusal."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — no read policy exists today that would let a doer's own session learn "a referee exists" without either attempting to pair (the current behavior) or a new RLS policy exposing referee existence to a doer, which is a real access-control decision outside this story's frozen Boundaries (a plain read policy on `profile` scoped to `role = 'referee'` for any `doer` caller). Functionally harmless — the refusal is clear and creates nothing — but worth a real fix once a policy for "can a doer see that a referee exists" is deliberately designed rather than added as a side effect of a UI polish request.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`pair-referee` returns `409` for 'a referee is already paired' but a generic `500` for the structurally identical case of the target email already being registered to another `auth.users` account (surfaced only via `createError?.message` from `auth.admin.createUser()`) — two conflicts, one status code apiece, inconsistently."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred rather than patched — the correct fix depends on `auth.admin.createUser()`'s actual error shape for an email-already-registered failure (a specific `error.code`, distinct from other creation failures that legitimately are server errors), which needs verification against a live or local Supabase Auth instance to get right; guessing at the code without running it risks silently misclassifying a real `500` as a `409`. Revisit once Docker/a live project is available to confirm the exact error shape `auth.admin.createUser()` returns for a duplicate email.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "The one-time password shown in Settings after a successful pairing has no confirmation step before it can be dismissed — `onClose` is a plain button with no 'have you saved this?' guard — and pairing itself has no second-entry/confirm step before consuming the single, irreversible referee slot. Given this story's own Never boundary (no unpair/re-pair), a single misclick or a typo'd email permanently costs the only copy of the password or the only pairing attempt."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — both risks are the direct, accepted consequence of a design this story's own frozen spec chose deliberately ("No unpair/re-pair flow... a later story's own decision, not this one's default"), not an oversight; adding confirmation UX is a real product decision (what should recovery look like?) that the frozen Ask-First section explicitly found no open fork in. Revisit if the author reports losing a password or mis-pairing in practice, or when a later story reconsiders the no-recovery boundary.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "The new referee-pairing email input (`components/settings.tsx`) and both inputs on `components/referee-login.tsx` rely on placeholder text alone for their accessible name, with no `<label>`, `aria-label`, or `htmlFor`/`id` pairing."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — matches `components/sign-in.tsx`'s own pre-existing convention exactly (its email/password inputs are placeholder-only too), so this is a systemic, codebase-wide gap this story reproduced rather than introduced. Revisit as one pass over every form input in the app, not a one-off fix to the two new screens.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "None of this story's new async handlers (`app/page.tsx`'s role fetch, `components/referee-home.tsx`'s `load()`/`signOut()`, `components/referee-login.tsx`'s `submit()`, `components/settings.tsx`'s `pairReferee()`) catch a thrown promise rejection (as opposed to Supabase's own `{data, error}` result shape, which all of them do check) — a genuine network-level throw would leave the affected screen stuck on its loading/submitting state indefinitely with no retry affordance."
  evidence: Raised independently by the 2026-08-25 review's blind-hunter and edge-case-hunter layers. Deferred — verified against `components/sign-in.tsx` (this story's own explicit precedent for `referee-login.tsx`) and `components/settings.tsx`'s pre-existing `setHour`/`turnOnNotifications`: neither has a `try`/`catch` around its own Supabase calls either, so this is a codebase-wide, pre-existing pattern this story's new code faithfully reproduced rather than a regression. Revisit as one deliberate pass adding a top-level catch to every async handler in the app, not a patch to only the newest ones.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`pair-referee`'s cleanup path (`index.ts`, after a `profile_single_referee` race loses) calls `admin.auth.admin.deleteUser(created.user.id)` with no check of whether that call itself fails — if the cleanup delete also fails, the newly created `auth.users` row is left orphaned as an unpromoted, unreachable `role = 'doer'` account with no log of the failure."
  evidence: Raised by the 2026-08-25 review (edge-case-hunter). Deferred — narrow (requires the promote update to lose the `profile_single_referee` race *and* the subsequent delete to independently fail) and low-consequence (an orphaned ordinary `doer` row is clutter, not a security or correctness issue — `profile_single_referee` still guarantees only one real referee). Revisit alongside adding structured logging to Edge Functions generally, which this repo has none of today (`outbox-worker` doesn't either).

## Deferred from: independent code review of spec-4-5-the-referee-has-his-own-way-in (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`pair-referee/index.ts` sets `Access-Control-Allow-Origin: '*'` unconditionally, on an
  Edge Function that creates a privileged account. The function is only ever meant to be invoked
  from this app's own origin via `supabase.functions.invoke()`."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — no standalone
  vulnerability today, since every request still needs the caller's own valid, live-doer JWT
  (checked server-side); a wildcard origin only widens which page's JavaScript *could* relay an
  already-authenticated request, which is not this app's threat model absent an XSS elsewhere.
  Cheap hardening, worth doing alongside a pass scoping CORS on `outbox-worker` too if that
  function is ever given a browser-reachable trigger.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "Pairing leaves no audit trail — `profile` gains no `paired_at`/`paired_by` column in
  the new migration, and the Edge Function logs nothing beyond the row update itself. There is no
  way to later answer 'when was the referee paired,' for a one-shot, unrecoverable operation."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — a real gap but
  a schema decision, not an unambiguous patch; `auth.users.created_at` on the referee's own row is
  a rough proxy already available without a migration. Revisit if the author ever needs to
  reconstruct pairing history.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "The orphaned-account risk this story's own review already recorded (the cleanup
  `deleteUser` call itself failing after `promoteError`) is narrower than the real risk: the same
  orphaned, unpromoted `role = 'doer'` row also results — with zero cleanup attempt and zero
  record — if the process crashes or the connection drops between `createUser` succeeding and the
  promote `update` even starting."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred for the same
  reason as the existing entry — narrow, low-consequence (clutter, not a security or correctness
  issue; `profile_single_referee` still guarantees only one real referee), and belongs with
  structured logging for Edge Functions generally, which this repo has none of yet.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`referee-home.tsx`'s `penalty_current` read (`select('state,amount_dong')`) has no
  `.limit()`/pagination — it fetches every historical penalty row just to compute two aggregate
  numbers, growing without bound over the product's lifetime."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — unbounded
  growth is a years-out concern for a single-doer, daily/weekly-cadence product; revisit if the
  referee home screen is ever observed loading slowly.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "Neither `pair-referee` (callable repeatedly by a live doer session) nor
  `/referee/login`'s password sign-in has any rate limiting or backoff beyond Supabase Auth's own
  defaults, which this code doesn't configure or verify."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — matches
  `sign-in.tsx`'s own pre-existing pattern exactly (no rate limiting there either), a systemic gap
  this story reproduced rather than introduced. Revisit as one pass across every auth entry point.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`RefereeLogin` never checks for an existing session on mount — a referee who is
  already signed in and navigates to `/referee/login` sees the sign-in form again instead of being
  redirected to `/referee`, unlike `referee-home.tsx`'s own careful redirect handling for the
  reverse cases."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — cosmetic; the
  referee reaches `/referee` fine on submit regardless, this only affects an already-signed-in
  session revisiting the login URL directly.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-5-the-referee-has-his-own-way-in.md`
  summary: "`generatePassword()`'s 24-character/144-bit output isn't verified against
  `auth.admin.createUser()`'s own password-policy constraints (minimum length/complexity some
  Supabase Auth configurations enforce) — a future tightening of that policy elsewhere in the
  project could silently break pairing with nothing to catch it."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — no live failure
  observed; 144 bits comfortably clears any realistic policy today. Revisit if pairing ever starts
  failing after an Auth configuration change.

## Deferred from: code review of spec-4-6-the-referee-rules (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`rule_appeal()`'s admitted/silent recompute (`20260825090000_the_referee_rules.sql`) is now a third independent hand-copy of the same 'what counts toward a day's verdict' formula, alongside `settle_day()` and `supersede_expiries()` — three places that must be kept in sync by hand if the formula ever changes (e.g. a future cadence exclusion)."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — matches the exact judgment already recorded for Story 4.2's own settlement-query duplication (`settle_day`/`settle_week` above): real, but a shared-formula extraction is a deliberate refactor better done as its own pass than folded into a fourth function's own diff. Revisit alongside a general settlement-formula consolidation pass, especially if a future cadence or verdict rule change has to be applied in three places at once.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`rule_appeal()`'s `v_silent` (unanswered-commitment) branch of the admitted/silent recompute has no test exercising it — every fixture account's contested miss is machine-filed `'slipped'`, never left unanswered."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred rather than patched — the migration's own comment argues this branch is structurally unreachable in practice: a Held Penalty only ever sits on a settlement that read `failed`, and `failed` only happens once every commitment for the day has already answered (`answered = total` in `settle_day()`), so `silent` is always 0 by construction here. A test would have to contrive a state the function's own preconditions already rule out. Revisit only if `appeal_hold_penalty()`'s own eligibility ever loosens to allow holding a penalty before the day is fully answered.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`components/referee-appeal-detail.tsx` fetches each evidence item's signed URL sequentially inside a `for...of` loop with `await`, rather than in parallel with `Promise.all` — an appeal with several evidence photos pays their signed-URL round trips one at a time."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — real but low-impact at this app's typical evidence-per-appeal count (a handful of photos at most); worth a quick fix if evidence review is ever observed to feel slow in practice.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "The pending-appeals list (`components/referee-home.tsx`) orders only by `for_day` descending with no tiebreaker column (e.g. `id`) — ordering among two appeals filed the same day is left to whatever Postgres happens to return, not guaranteed stable across reloads."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — cosmetic (the list still shows both appeals, just possibly reordered between loads) and narrow (needs two appeals dated the same day, which the sole-live-referee/sole-live-doer scale of this product makes uncommon). Revisit if the author reports the list visibly reordering.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`components/referee-appeal-detail.tsx` renders no message and no ruling controls if `penaltyState` is ever a value outside the four it explicitly branches on (`held`/`voided`/`owed`/`dropped`) — a silent blank screen rather than a stated failure."
  evidence: Raised by the 2026-08-25 review (edge-case-hunter). Deferred — defensive-only; `penalty_state` is a closed Postgres enum this screen already reads exhaustively for every value that exists today, so this is unreachable unless a future migration adds a new state (`collected`, 4.7; `waived`, 5.1) without also updating this screen. Revisit when either of those states ships.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`components/referee-appeal-detail.tsx`'s `settlement_current`/`penalty_current` reads (to infer whether this appeal was already ruled) are two separate round trips, not one atomic read — a ruling landing between them could theoretically render a momentarily inconsistent view."
  evidence: Raised by the 2026-08-25 review (edge-case-hunter). Deferred — self-healing (a reload re-reads both consistently) and no money-safety consequence either way, since the actual ruling is enforced server-side by `rule_appeal()`'s own guarded transition regardless of what the client's read shows. Revisit only if this is ever observed causing real confusion.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`components/referee-home.tsx`'s pending-appeals count (from `penalty_current`) and its pending-appeals list (a separate query) are two independent reads that could momentarily disagree if a ruling or timeout lands between them."
  evidence: Raised by the 2026-08-25 review (edge-case-hunter). Deferred — matches the same accepted eventual-consistency pattern already recorded for `today.tsx`'s own parallel reads; self-heals on reload, no money-safety consequence.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "The new referee `storage.objects` read policy on `appeal-evidence` uses `role_from_token()`, so a referee demoted mid-session keeps reading private evidence (NFR4: visible to the submitting owner and the ruling referee, nobody else) until their JWT next refreshes."
  evidence: Raised independently by the 2026-08-25 review's blind-hunter and edge-case-hunter layers. Not patched — this matches Story 4.5's own deliberate, already-established convention (every referee read-only policy uses the token helper; only money-guarding writes use `role_from_table()`, per `lib/roles.ts`'s own documented rule), not a new deviation this story introduced. Recorded here because evidence is the one referee-read surface NFR4 names explicitly as sensitive, so the trade-off is worth a written record even though it isn't a regression. Revisit only if this codebase ever needs demotion to take effect faster than a token refresh.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`components/referee-appeal-detail.tsx` infers whether an appeal was approved by comparing `settlement_current`'s id against the appeal's own stored `settlement_id`, rather than reading an explicit ruling-status column — correct today only because approval is the sole thing that currently supersedes a day's settlement once a Held Penalty exists."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — the invariant holds under every mechanism that exists in this codebase today, and adding an explicit status column is a schema decision with its own migration cost, not a one-line fix. Revisit if a future story (e.g. a second correction mechanism) ever supersedes a `failed` day's settlement for a reason unrelated to an appeal ruling — at that point this inference would need to become an explicit column.

## Deferred from: independent code review of spec-4-6-the-referee-rules (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`components/referee-appeal-detail.tsx`'s `rule()` calls `setRuling(...)` /
  `setReloadToken(...)` after its `await supabase.rpc(...)` resolves with no `cancelled` check,
  unlike the same file's own `load()` effect, which tracks `cancelled` carefully for exactly this
  reason."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — matches the
  same codebase-wide, pre-existing pattern already recorded for Story 4.5's own async handlers
  (no top-level catch/unmount-guard on Supabase calls); narrow (requires navigating away in the
  brief window between click and RPC resolution) and self-healing on the next screen visit.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "No confirmation step before 'He did it'/'He didn't' — the referee's first-ever write,
  moving real money with no correction path once ruled (the guarded transition means a wrong
  ruling cannot be re-ruled)."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — matches this
  app's established pattern of no confirm dialogs anywhere (including Story 4.5's own accepted
  no-recovery pairing flow and Story 4.7's un-confirmed Mark Collected), not a gap specific to
  this story. Revisit only as a deliberate, app-wide confirmation-UX decision, not a one-off patch
  to this screen.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "The pending-appeals list (`components/referee-home.tsx`) has no `.limit()`/pagination
  — grows unbounded as appeals accumulate."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — same class of
  gap already recorded for Story 4.5's own unbounded penalty read; years-out concern at this
  product's scale.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "No index supports the new `penalty:penalty_id!inner(state)` embedded-filter query
  pattern the pending-appeals list introduces — the first use of `!inner` in this codebase."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — premature at
  this product's single-referee, small-appeal-count scale; revisit if the pending-appeals list is
  ever observed loading slowly.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "The referee's new `storage.objects` read policy on `appeal-evidence` is tested only
  for the positive case (referee reads) and the pre-existing negative case (a doer cannot read) —
  no test proves the referee still cannot insert/update/delete evidence objects."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — the policy
  itself is declared `for select` only, so there is no corresponding write policy to test against;
  real gap in explicit negative-case coverage, cheap to add alongside a broader storage-policy
  test pass.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "The new `!inner`-filtered appeal query (`referee-home.tsx`, `.eq('penalty.state',
  'held')` on a `penalty:penalty_id!inner(state)` embed) is unverified against real PostgREST
  semantics — `referee-home.test.tsx`'s mock `.eq()` ignores its own arguments entirely, so a
  dropped or misapplied `!inner` qualifier would show stale or resolved appeals with every
  existing test still passing."
  evidence: Raised by the independent 2026-08-25 review (verification-gap). Deferred — closing it
  properly needs a real-PostgREST test (this repo's CI `db-tests` job explicitly excludes
  PostgREST — `.github/workflows/ci.yml`), the same kind of gap already accepted for `pair-referee`'s
  own untested authorization gate. Revisit alongside a pass adding PostgREST-backed integration
  tests generally.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`rule_appeal()`'s approval path isn't discussed for what happens if the final
  `outbox_enqueue` call itself fails after the `settlement`/`penalty`/`settlement_commitment`
  inserts succeed — unlike similar partial-failure paths called out elsewhere in this file."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — almost
  certainly safe (the whole function runs in one transaction, so an `outbox_enqueue` failure would
  roll back the corrective settlement too, not leave it half-applied), but not stated explicitly
  anywhere. Revisit only if this function's transactional boundary is ever changed.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-6-the-referee-rules.md`
  summary: "`referee-home.tsx` and `referee-appeal-detail.tsx` both reuse `formatDeadline` (named
  and documented around deadlines) to render `for_day`, a calendar date with different semantics
  from a deadline."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — works correctly
  today (both are plain dates formatted the same way); a naming-only mismatch, not a functional
  defect. Revisit if `formatDeadline`'s own formatting ever needs to diverge from a plain calendar
  date's.

## Deferred from: independent code review of spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "No test in `supabase/tests/4-7-...sql` queries `public.outbox` — the spec's own
  'Never' boundary ('No outbox notification to the author on collection') is documented in prose
  but never proven, unlike Story 4.6's own test file, which explicitly asserts outbox row counts
  for both a ruling outcome and a refused one."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — the behavior is
  correct by inspection (`mark_penalty_collected()`'s own SQL performs no `outbox_enqueue` call at
  all), and cheap to add alongside a broader pass strengthening this test file's own assertions.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "`referee_missed_commitments()`'s own migration comment claims it correctly excludes a
  `held`, `dropped`, `voided`, or already-`collected` Penalty's settlement, but the test file only
  exercises the `held` case — the other three named states are untested."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter), and subsumes a related
  finding (no test drives a single Penalty through the held -> owed -> collected lifecycle
  checking this function's output at each stage). Deferred — the `state = 'owed'` scoping this
  function's own `exists` clause enforces is exercised for `held`; the remaining three follow the
  identical single-column check and share the same low marginal risk. Revisit alongside a general
  pass widening this test file's own state coverage.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "Two different doer accounts, each with an identically-named commitment missed on the
  same day, would produce two owed-penalty rows with an identical accessible name on both the Copy
  and Mark Collected buttons."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — the same
  underlying, already-accepted trade-off Story 4.5's own deferred entry records (the referee's
  read policies aren't scoped to `is_live_doer`), not a new gap this story introduces; this
  product has exactly one real doer account today.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "No component-level test proves a `collected`-state Penalty is excluded from the 'Owed
  penalties' list, unlike the equivalent Held-Penalty exclusion, which is component-tested."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — the underlying
  filter (`state === 'owed'`) is the same one already proven to exclude `held`; cheap to add
  alongside the SQL-level state-coverage gap recorded above.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "`collectionMessage()` (`lib/referee.ts`) hardcodes an English sentence with a
  `vi-VN`-formatted amount (`formatDong`) inside it — a localized money format inside an
  English-only sentence, with no note on whether the mix is intentional."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — matches every
  other user-facing string in this codebase, all of which are English-only today; a real
  localization decision, not a one-off patch to this message.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "No confirmation step before Mark Collected — a single click discharges a debt with no
  undo."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — matches the
  identical, already-recorded no-confirm-dialog pattern for Story 4.6's own ruling controls; a
  deliberate, app-wide design choice, not a gap specific to this story.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "`markStatus`/`markErrors`/`copyStatus` in `components/referee-home.tsx`, all keyed by
  `penalty.id`, are never pruned — entries for rows no longer rendered accumulate over a
  long-lived session with many collections."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — minor; a
  referee's session is not long-lived enough in practice for this to matter today.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "`referee_missed_commitments(p_settlement_ids uuid[])` has no server-side bound on the
  size of the incoming array — accepted and processed with no defensive cap."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — `security
  definer` but still gated to `authenticated`, and the row filter (`role_from_table() =
  'referee'`) limits what any call can ever read regardless of array size; a single-referee
  product has no realistic path to an oversized array today.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "The 'Owed penalties' section has no empty-state affordance — it simply doesn't render
  when the list is empty, giving the referee no confirmation the list was checked versus broken or
  still loading."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — matches the
  pending-appeals list's own identical pattern (Story 4.6), not unique to this diff; a real UX gap
  worth a shared fix across both lists.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "`markCollected`/`copyMessage` in `components/referee-home.tsx` set state after their
  own `await` with no `cancelled` guard, the same class of gap already recorded for Story 4.6's
  `rule()`."
  evidence: Raised by the independent 2026-08-25 review (edge-case-hunter). Deferred — narrow and
  self-healing, same reasoning as the Story 4.6 entry it matches.

## Deferred from: code review of spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "Neither the owed-penalties list nor the pre-written collection message names which doer account a row belongs to. Since the referee's RLS grants read every doer account's Penalties, not only the live doer's (a trade-off Story 4.5 already accepted and recorded), two different accounts' owed Penalties would render with no way to tell them apart."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — this is the same underlying, already-accepted trade-off Story 4.5's own deferred entry above records (the referee's read policies aren't scoped to `is_live_doer`), not a new gap this story introduces; in practice this app has exactly one real doer account, so the ambiguity is theoretical today. Revisit alongside that same entry if this product is ever run somewhere more than one real doer account is realistic.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "If `referee_missed_commitments()` fails, `components/referee-home.tsx` discards the whole screen (including the already-fetched appeals list and owed-penalty summary) for a bare 'Failed.' message, rather than degrading only the affected list the way Story 4.6's own evidence-loading failure does (per-item, not whole-screen)."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — real, but the fix is a genuine restructuring of `load()`'s error handling (partial-failure state, not a single `failed` variant), bigger than a one-line patch; the failure is also rare (a working RLS/RPC call failing only on infrastructure trouble) and self-heals on reload. Revisit alongside a broader pass making every referee/doer screen's error handling per-section rather than whole-screen.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "No test exercises `referee_missed_commitments()` returning an error — `components/referee-home.tsx`'s handling for that branch is untested."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred alongside the whole-screen-failure entry above — testing the current behavior isn't worth much on its own if that behavior is likely to change once per-section error handling is built.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "`mark_penalty_collected()`'s NULL-role refusal (`role_from_table() is distinct from 'referee'`, guarding against a caller with zero `profile` rows) is never actually tested — every SQL test fixture uses a session with a real `role = 'doer'` row, never a session with no profile row at all."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — every `auth.users` row gets a `profile` row automatically via the `on_auth_user_created` trigger (`20260819120000_account_and_roles.sql`), so a zero-profile-row session is not reachable through ordinary use; the same untested-but-structurally-rare gap already exists for `rule_appeal()`'s identical guard (Story 4.6), not new to this story. Revisit only if a path is ever found that creates an `auth.users` row without the trigger running.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "The owed-penalties list's 'oldest first' ordering has no deterministic tiebreaker — rows are sorted only by `created_at`, and two Penalties created in the same batch settlement run can share an identical timestamp, leaving their relative order unspecified."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — matches the identical, already-recorded tiebreaker gap in Story 4.6's own pending-appeals list ordering; cosmetic (both rows still appear, just possibly reordered between loads). Revisit together with that entry if the author reports either list visibly reordering.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "The Mark Collected and Copy-message buttons' `busy`/`disabled` state while their respective async call is in flight is never exercised by any test — every test resolves the mocked call immediately."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — a real test-coverage gap, but low-value on its own; worth adding alongside a broader pass adding pending-state assertions across the referee surface's async controls generally.

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "Double-clicking a row's Copy-message button before the first `navigator.clipboard.writeText()` call settles can let the two calls' results resolve out of order, showing 'Copied.'/'Could not copy.' for the wrong click."
  evidence: Raised by the 2026-08-25 review (edge-case-hunter). Deferred — narrow (needs two rapid clicks within one clipboard round trip) and low-consequence (worst case is a momentarily wrong status message on a control that can simply be clicked again).

- source_spec: `_bmad-output/implementation-artifacts/spec-4-7-the-app-does-the-asking-the-referee-does-the-collecting.md`
  summary: "A day-kind owed Penalty whose `referee_missed_commitments()` lookup legitimately returns zero rows (a data gap) would render identically to the intentional week-kind fallback ('A commitment') — nothing distinguishes 'no commitment data exists for this kind' from 'something is wrong for a kind that should always have data'."
  evidence: Raised by the 2026-08-25 review (edge-case-hunter). Deferred — structurally near-unreachable in normal operation: a day-kind settlement only ever produces an `owed` Penalty when `settle_day()`'s own `admitted + silent > 0`, which requires at least one `settlement_commitment` row with `outcome = 'missed'` to exist for that settlement by construction. Revisit only if this is ever observed happening for a genuine day-kind row.

## Deferred from: independent code review of spec-5-1-a-countable-way-to-be-forgiven (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "`apply_grace_days()` is never tested through its real production entry point,
  `settle_due_days()` — `supabase/tests/5-1-...sql` calls `apply_grace_days()` directly. A
  regression dropping the one line wiring them together (`settled := settled +
  public.apply_grace_days();`) would ship undetected — the fold-in would silently stop happening
  in production while every existing test kept passing."
  evidence: Raised by the independent 2026-08-25 review (verification-gap). Deferred — closing it
  needs a test step calling `settle_due_days()` itself rather than the inner function, matching
  this same gap's already-accepted shape for `2-7-supersession.sql`. Revisit alongside a pass
  strengthening this test file's own entry-point coverage.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "Neither per-account advisory lock — `grace_day_validate()`'s original one, nor the
  one this same review's own patch added to `appeal_hold_penalty()` and `mark_penalty_collected()`
  (`20260825120000_the_same_lock_the_same_day.sql`) — has an automated concurrent-session test.
  This test suite's format (a single transaction, sequential `do $$ ... $$` block) cannot express
  two genuinely overlapping transactions."
  evidence: Raised by the independent 2026-08-25 review (verification-gap), and applies equally
  to the same review's own fix. Deferred — the same kind of gap already accepted for `pair-referee`'s
  own untested authorization gate (Story 4.5) and the `!inner`-filtered query (Story 4.6): closing
  it needs test infrastructure (two real concurrent connections, or a PostgREST-backed harness)
  this repo does not have yet. The fix itself was verified by careful reading (the lock key and
  timing exactly mirror the already-reasoned-through original), not by a passing concurrent test.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "`GRACE_DAY_COPY.alreadySpent` (`lib/grace.ts`) is defined but never referenced — both
  `components/ledger.tsx` and `components/today.tsx` deliberately collapse the `'spent'` and
  `'already-spent'` outcomes into the same UI state (a reasoned, commented choice: a `grace_day`
  row exists for this day either way), leaving this string genuinely dead."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — not a defect,
  the collapse is deliberate and correct; either remove the unused constant or use it to
  distinguish the messaging, a real but low-value choice either way.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "The Day summary's Grace Day control (`components/today.tsx`) shows only the date and
  the remaining-allowance sentence — never the amount that spending it would forgive, nor which
  commitment(s) were missed, unlike the equivalent control on a Ledger row."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — a user deciding
  whether to spend one of only two non-carrying monthly allowances has less context from Today
  than from the Ledger; real, but a UI enhancement rather than a defect, and the Ledger already
  offers the fuller view for the same decision.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "This story introduces several new user-facing strings (`GRACE_DAY_COPY`'s spend/
  spending/spent/failed/unreachable/alreadySpent text, the Settings 'Grace Days' row, `referee-
  appeal-detail.tsx`'s `gracedAfterRejection`) with no corresponding update to `EXPERIENCE.md`,
  despite `epic-5-context.md`'s own Naming Conventions bullet requiring copy to originate there
  first."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — a documentation
  gap, not a functional defect; the shipped copy itself was independently verified against the
  frozen spec's own verbatim requirements. Revisit as a documentation pass reconciling
  `EXPERIENCE.md` with every story that has shipped copy since it was last touched (Story 3.5).

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "The frozen I/O Matrix's 'Appeal then Grace Day' row (`supabase/tests/5-1-...sql`,
  step 7) is proven by directly `UPDATE`-ing the penalty to `held`, not by inserting a real
  `appeal` row and letting `appeal_hold_penalty()` derive that state itself — weaker proof than
  its sibling row ('Grace Day then Appeal', step 14), which exercises the real insert path."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — the guard under
  test (`grace_day_validate()`'s own `state <> 'owed'` check) is simple and shared with every
  other eligibility check this same function already proves via direct state manipulation
  elsewhere in the file; cheap to strengthen alongside a general pass tightening this test file's
  own fixture realism.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "`apply_grace_days()`'s corrective `settlement_commitment` freeze depends on
  `commitments_owing()` returning every commitment for that day at fold-in time; a commitment
  archived between the original Failed Day and the fold-in would silently narrow the freeze,
  covering fewer rows than the original miss did."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — narrow (needs a
  commitment archived in the up-to-an-hour window between spend and fold-in) and matches the
  identical, already-accepted risk shape `commitments_owing()`'s own `archived_at` filter carries
  everywhere else it's used. Revisit alongside a general audit of `commitments_owing()`'s
  archival-window behavior if one is ever done.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "No test exercises a graced day's interaction with `weekly_quota_progress` for a
  commitment that also has weekly-cadence tracking — the 'day-scoped only' boundary is asserted
  structurally (`graceable` is hardcoded `false` on a week row) but not proven against a live
  weekly-quota commitment's own progress count."
  evidence: Raised by the independent 2026-08-25 review (blind-hunter). Deferred — `apply_grace_days()`
  never touches `settlement_commitment` for any cadence other than what `commitments_owing()`
  already returns for a `kind = 'day'` settlement, the same scoping every other day-level
  correction in this codebase already relies on untested for this specific cross-cadence case.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "The Ledger's Contest button isn't hidden once a Grace Day is spent on that row —
  cosmetic; the server already refuses the resulting appeal attempt (`appeal_hold_penalty()`'s own
  grace_day guard)."
  evidence: Raised by the independent 2026-08-25 review (edge-case-hunter). Deferred — no
  incorrect state results, only a confusing click followed by a clear server refusal.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "The `grace_day` insert's promise rejection (as opposed to a `{data, error}` result) is
  uncaught in both `components/ledger.tsx` and `components/today.tsx`."
  evidence: Raised by the independent 2026-08-25 review (edge-case-hunter). Deferred — matches the
  same codebase-wide, pre-existing pattern already recorded for Story 4.6's own async handlers.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "`apply_grace_days()`'s own fold-in loop has no per-row exception isolation — one bad
  `grace_day` row raising inside the loop would abort the whole hourly `settle_due_days()` pass,
  including the `settle_day()`/`supersede_expiries()` work already done in the same call."
  evidence: Raised by the independent 2026-08-25 review (edge-case-hunter). Deferred — verified by
  reading `supersede_expiries()`'s own identical loop shape (`20260819241000_expiry_and_
  supersession.sql:189-231`): no per-row exception isolation there either. A systemic,
  pre-existing pattern this story reproduces, not a regression it introduces; matches the
  product's own stated observability model (`epic-5-context.md`: "if settlement stops running for
  any reason, the visible symptom is that the daily summary stops arriving... nothing in this
  epic assumes a separate monitoring layer exists"). Revisit alongside a general pass adding
  per-row exception isolation to every scheduled batch function at once.

## Deferred from: code review of spec-5-1-a-countable-way-to-be-forgiven (2026-08-25)

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "`grace_allowance_remaining` (`security_invoker`) would misreport for a referee session: its lateral subquery counts `grace_day` rows under the *caller's own* `auth.uid()`, which never matches any doer's `owner_id`, so a referee reading this view for a paired doer would always see the full `grace_days_per_month()` regardless of how many the doer has actually spent."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — not currently reachable through any UI: nothing in this story (or any prior one) exposes `grace_allowance_remaining` on the referee's own surfaces (`referee-home.tsx`, `referee-appeal-detail.tsx`) — it is read only by the doer's own Day summary, Ledger, and Settings screens. Revisit if a future story ever surfaces Grace Day information to the referee.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "`grace_day_owner_idx on (owner_id)` may be redundant: the table's own `unique (owner_id, for_day)` constraint already creates a btree index with `owner_id` as its leftmost column, which already serves an owner-only lookup via prefix matching."
  evidence: Raised by the 2026-08-25 review (blind-hunter). Deferred — harmless (a small extra write cost, no correctness impact) and not confirmed to be strictly redundant without checking the query planner's actual index choice; not worth a migration revision on its own. Revisit alongside a general index-audit pass if one is ever done.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-1-a-countable-way-to-be-forgiven.md`
  summary: "The client has no awareness of an unprocessed (spent-but-not-yet-folded-in) `grace_day` row — a reload within the up-to-an-hour fold-in window shows the same 'Spend a Grace Day' control again (since the Penalty still reads `owed` until the next pass), rather than a 'Pending — clears within the hour' state."
  evidence: Raised by the 2026-08-25 review (blind-hunter), the root cause behind the double-decrement bug patched the same round (see the review's own fix list). The double-count *consequence* is fixed; this is the remaining cosmetic root cause — the control still re-offers a day that is, in fact, already spoken for, until the next full page load re-fetches `grace_day` and the correction lands. Self-healing within an hour, no double-spend possible (the unique constraint still refuses it), no money-safety consequence. Revisit if a dedicated 'pending' UI state is ever wanted — would need the client to also query `grace_day` for unprocessed rows, not only `penalty`.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-the-app-notices-i-have-gone-quiet.md`
  summary: The Silence intervention's push-notification body (`enqueue_gate_reminders()` in `20260826090000_the_app_notices_ive_gone_quiet.sql`) is a third, self-dated ad-hoc string, distinct from both `SILENCE_COPY` in-app variants and never added to `EXPERIENCE.md`; no test asserts its actual title/body text.
  evidence: Raised by the 2026-08-26 review (blind-hunter). Matches this codebase's own pre-existing, already-acknowledged pattern of push bodies diverging from their in-app equivalent — `day_summary_body()`'s own migration comment already names this exact "second source of copy" gap for Story 2.8's day summary — so this is a systemic pattern the story reproduces, not a regression it introduces. Revisit alongside a general push-copy/EXPERIENCE.md reconciliation pass if one is ever done, rather than patching this one push body in isolation.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-the-app-notices-i-have-gone-quiet.md`
  summary: After answering the last outstanding Declaration from inside the Silence intervention's own nested `MorningGate`, the screen does not return to Today until the next reload — it re-renders showing the "no Declarations pending" copy instead, with no navigation affordance to leave it sooner.
  evidence: Raised by the 2026-08-26 review (blind-hunter). The spec's own frozen I/O Matrix scoped this deliberately ("Declaration answered mid-episode... next load renders routine content again"), and `components/silence-intervention.tsx`'s own doc comment records the same accepted boundary — so this is not a spec violation, but the resulting screen genuinely has no way out short of a manual reload, which is worse than the boundary's own wording implies. Revisit if `app/page.tsx` ever gains a lightweight way to re-check `silence_episode` after `onAnswered` fires, without turning this into the "component reacts live within the same session" shape the spec explicitly ruled out.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-the-app-notices-i-have-gone-quiet.md`
  summary: The Silence intervention's copy (`silenceDayNames`, "...close tonight") is derived once from `silence_episode.started_day` and never re-evaluates against elapsed time — the named days and the "closes tonight" claim go stale the longer an episode stays open before the author reopens the app.
  evidence: Raised by the 2026-08-26 review (blind-hunter). No AC in this story requires the copy to update while unopened, and the underlying Declaration deadlines are independently enforced server-side regardless of what the copy says — so this is a copy-accuracy gap, not a correctness one. Revisit if user research ever shows author confusion from a stale-dated intervention message.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-the-app-notices-i-have-gone-quiet.md`
  summary: No test exercises the streak-detection query (`enqueue_gate_reminders()`) against an account too new to have had two full days of commitment history — only accounts with a genuine two-day-old streak are covered.
  evidence: Raised by the 2026-08-26 review (blind-hunter). Correct behavior follows by construction (`owing_total > 0` on both days is required, so a day before the account's first commitment existed can never read "quiet"), not by an explicit assertion — a regression here would currently ship unnoticed. Revisit alongside any future change to `commitments_owing()` or the streak window.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-2-the-app-notices-i-have-gone-quiet.md`
  summary: Both new async reads this story adds (`components/silence-intervention.tsx`'s `grace_allowance_remaining` fetch, `app/page.tsx`'s `silence_episode` fetch) handle a resolved `{data, error}` shape but not a rejected promise (a synchronous throw or network-level failure before Supabase's own error field is populated) — a rejection would leave the view stuck on "loading"/the previous state forever.
  evidence: Raised by the 2026-08-26 review (verification-gap and edge-case-hunter, independently). Matches `components/today.tsx`'s own identical unguarded-`.then()` shape for its parallel reads — a systemic pattern across this codebase's client components, not something this story introduces. Revisit alongside a broader pass adding `.catch()` guards to every such read, rather than patching this story's two call sites in isolation.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-3-the-friend-is-told-i-have-disappeared.md`
  summary: "`email-worker`'s `mark()` (and `outbox-worker`'s own identical `mark()`) writes the outbox row's terminal status without checking whether that `update` itself returned an error — a DB-level failure right after a successful Resend send would leave the row `pending`, so the next tick's `outbox_claim` re-sends an email that already went out."
  evidence: Raised by the 2026-08-26 review (blind-hunter). Not introduced by this story — `supabase/functions/outbox-worker/index.ts`'s own `mark()` (Story 2.4a) has had the identical gap since it shipped, and `email-worker` was built by cloning that exact shape. Revisit both workers together, not this story's `mark()` in isolation.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-3-the-friend-is-told-i-have-disappeared.md`
  summary: Neither `email-worker` nor `outbox-worker` has any automated test — the two Deno-only I/O Matrix rows this story's spec explicitly assigns to `email-worker`'s own code ("no referee paired", "Resend API failure") are consequently proven only by code inspection, not execution.
  evidence: Raised by the 2026-08-26 review (blind-hunter). Pre-existing gap, not unique to this story: `outbox-worker` (Story 2.4a) has never had a test either, and this codebase has no established Deno-test convention to follow. Revisit as infrastructure work (a Deno test harness, or an integration test hitting a locally-served function) rather than inventing a one-off pattern for this story alone.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-3-the-friend-is-told-i-have-disappeared.md`
  summary: The Resend call sends `text` only (no `html` alternative), and `RESEND_FROM_EMAIL` is used as a bare address with no display name — plain and unstyled compared to how a transactional email from a named product would typically present.
  evidence: Raised by the 2026-08-26 review (blind-hunter). Functionally correct and deliverable as built; deferred because it's a polish decision (an `html` body, a `"todoapp <...>"` from-header) rather than a defect, and this is the product's first outbound email to a real external person — worth a deliberate pass rather than a default picked mid-story.

- source_spec: `_bmad-output/implementation-artifacts/spec-5-4-the-long-view-including-whether-this-still-works.md`
  summary: No index exists on `penalty.collected_at` or `appeal.ruled_at`, both of which `components/monthly-report.tsx` now range-filters (`gte`/`lt`) on every report load.
  evidence: Raised by the 2026-08-26 review (blind-hunter). Negligible at this app's current single-tenant scale (a handful of rows per account per month), and neither column exists on a table large enough yet to make a sequential scan visible. Revisit if either table's row count ever grows enough for this to matter.

- source_spec: `_bmad-output/implementation-artifacts/epic-5-retro-2026-08-26.md`
  summary: "Grace Day spend logic (the `GraceRowState` type, the `mounted`-ref pattern, `spendGraceDay`, and the row JSX) is duplicated wholesale between `components/today.tsx` and `components/ledger.tsx`, acknowledged in each file's own comments rather than shared via a hook."
  evidence: Raised by the Epic 5 retrospective's diff-scope review (2026-08-26, code-review skill, reuse angle). A behavior fix to grace-day spending has to be applied twice by hand today. Revisit by extracting a `useGraceDaySpend(ownerId)` hook plus a shared `<GraceDayRow>` presentational component the next time either file needs a grace-day-spend change.

- source_spec: `_bmad-output/implementation-artifacts/epic-5-retro-2026-08-26.md`
  summary: "The `grace_allowance_remaining` fetch/error/no-row-handling pattern, including an identical literal error string, is copy-pasted independently across `components/today.tsx`, `components/ledger.tsx`, `components/settings.tsx`, and `components/silence-intervention.tsx`."
  evidence: Raised by the Epic 5 retrospective's diff-scope review (2026-08-26, reuse angle). If the "no row" message or the doer-only-view invariant it encodes ever changes, some call sites can silently drift out of sync. Revisit by extracting a `useGraceRemaining()` hook the four surfaces share.

- source_spec: `_bmad-output/implementation-artifacts/epic-5-retro-2026-08-26.md`
  summary: "`lib/monthly-report.ts`'s `foldPenaltyFigure` sums `amount_dong` with a bare `reduce` instead of calling the existing `lib/money.ts` `totalOwed()` helper (already a sibling import in the same file), losing that helper's `isStorableAmount` validation."
  evidence: Raised by the Epic 5 retrospective's diff-scope review (2026-08-26, reuse angle). If a corrupted or negative `amount_dong` ever reached this fold, `totalOwed` would throw and surface it loudly; `foldPenaltyFigure` would instead silently produce a wrong SM-C1 total on the Referee-facing monthly report. Revisit by switching the call.

- source_spec: `_bmad-output/implementation-artifacts/epic-5-retro-2026-08-26.md`
  summary: "`app/page.tsx` manages 6 independent overlay-navigation `useState`s (`showLedger`, `showSettings`, `showMonthlyReport`, `chainOf`, `focusOf`, `appealOf`) with no type-level mutual exclusion — correctness depends entirely on the order of a 7-branch ternary, and this file has gained one new overlay per recent story."
  evidence: Raised by the Epic 5 retrospective's diff-scope review (2026-08-26, altitude angle). A future overlay inserted at the wrong ternary position would never render because a stale boolean from an earlier navigation is still `true`. Revisit by replacing the booleans with a single discriminated-union `Screen` state (optionally a small stack, for the existing "return to caller" behavior) the next time a new overlay is added.

- source_spec: `_bmad-output/implementation-artifacts/epic-5-retro-2026-08-26.md`
  summary: "`supabase/functions/email-worker/index.ts`'s `mark()`/`json()` and the migration's `wake_email_worker()` are byte-for-byte copies of `outbox-worker`'s equivalents and `wake_outbox_worker()` — no shared `_shared` module or `wake_worker(target_path)` helper was extracted despite the code's own comments saying it 'mirrors... exactly.'"
  evidence: Raised by the Epic 5 retrospective's diff-scope review (2026-08-26, reuse angle). A future change to the retry/timeout/error-reporting shape has to be made in both workers by hand; miss one and the two workers' behavior silently diverges. Revisit if a third outbox-channel worker is ever added, at which point the duplication triples.
