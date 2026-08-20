# Database checks

The rules that decide days, money and chains live in plpgsql. `npm test` cannot reach any of
them — it covers the TypeScript side, and three of those modules are mirrors of these functions
with no production caller at all. These files are where the database is actually exercised.

They exist because of a finding in the Epic 2 retrospective: every story recorded a careful
"verified end to end" paragraph, and **nine of the ten carried no command anyone could run
again**. A defect that was suspected in the shipped SQL then could not be confirmed or refuted by
reading, which is how it ended up in a document as an open question instead of being fixed or
dismissed in five minutes.

**So the rule is: a story's verification leaves a file here, not a paragraph in its spec.**
Prose explains why; this is what proves it, on the next machine and in six months.

## Running them

```
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-5-settlement.sql
```

Each file is one transaction that **rolls back at the end**. Nothing persists, no account needs
deleting afterwards, and a crash mid-run leaves the database as it was.

Each assertion raises with a message saying what the specification promised and what the database
actually did, so a failure is a finding rather than a puzzle. `-v ON_ERROR_STOP=1` is what makes
the failure a non-zero exit code.

## Where they can run — and where they cannot

**Not against the author's own project.** `settle_day` refuses `p_override` whenever it meets a
profile with `is_live_doer` set, and it *raises* rather than skipping that account
(`20260819241000_expiry_and_supersession.sql:105-110`) — so one live account disables the override
path for the entire call. The only way past it is to set `app.settlement_invocation` by hand, which
is precisely what AD-16 exists to prevent.

That leaves a local stack or a preview branch:

```
npx supabase init        # no supabase/config.toml exists yet
npx supabase start       # needs Docker
npx supabase db reset    # applies every migration in order
```

Every file's first step checks for a live doer account and refuses with that explanation rather
than failing somewhere confusing later.

## What is here

| File | Covers |
|---|---|
| `2-5-settlement.sql` | One Failed Day costs exactly one 500,000₫ penalty however many commitments were missed (FR-13); an all-held day is clean and a penalty-free miss costs nothing; a day still being answered stays open and announces nothing (FR-10); a retried or overlapped pass is a no-op (AD-5); both AD-16 guards refuse; the settlement tables carry no write policy (AD-8). |
| `2-7-supersession.sql` | An answer given in time but delivered after the deadline takes back the expiry, the penalty stops counting, and **the day comes back to the chain** — the last of which is the question the retrospective could not answer by reading. |

Neither file has been executed yet. They were written on 2026-08-20 on a machine with no `psql`,
`docker` or `supabase` binary available, so they have never been parsed by a server. Treat them as
unverified until each has run once; the first run is as likely to find a mistake in the fixture as
in the product.

## Still uncovered

Story 2.1's RLS and role helpers, 2.2's constraints and cross-account writes, 2.4a's
`outbox_claim` skip-locked behaviour, 2.8's summary copy, and 2.9's chain arithmetic. Each was
verified by hand once, and each has a paragraph rather than a file.
