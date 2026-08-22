// Fails if any local migration file has not been applied to the linked remote project.
//
// `npm test` and CI's `db-tests` job both run every migration against a fresh local
// Postgres, so a passing suite has never meant the same schema exists on the project the
// deployed app actually queries — Epic 3's retrospective found the entire epic's schema
// (nine files) sitting local-only for two days before anyone noticed, discovered only
// because that run happened to query the live project directly. This is the check that
// would have caught it sooner: a story that adds a migration should not be promoted to
// `done` while this fails.
//
// Diffs `supabase migration list`'s Local/Remote columns rather than trusting file count,
// because a remote-only migration (applied by hand, no local file) is a real drift too —
// see the `gate_chain_uuid_aggregate` case the same retrospective found.

import { spawnSync } from 'node:child_process';

function fail(message) {
  console.error(message);
  process.exit(1);
}

const result = spawnSync('npx', ['supabase', 'migration', 'list'], {
  encoding: 'utf8',
  shell: true,
});

if (result.error) {
  fail(`Could not run \`npx supabase migration list\`: ${result.error.message}`);
}

// A linked-but-unauthenticated or unlinked CLI exits non-zero here rather than printing
// an empty table, so surfacing stderr is what tells the two apart from "clean, nothing to
// push" instead of misreporting one as the other.
if (result.status !== 0) {
  fail(
    [
      '`supabase migration list` failed — the CLI is likely not linked or not authenticated.',
      (result.stderr || result.stdout || '').trim(),
      '',
      'Run `npx supabase link --project-ref <your-project-ref>` (see README "Applying',
      'migrations"), then re-run this check. This is a hard failure, not a skip: an',
      'unreachable check is exactly the state that let migrations go unpushed for two days.',
    ].join('\n'),
  );
}

const rows = result.stdout
  .split('\n')
  .map((line) => line.split('|').map((cell) => cell.trim()))
  .filter((cells) => cells.length >= 2 && /^\d{14}$/.test(cells[0]));

const localOnly = rows.filter(([, remote]) => !remote).map(([local]) => local);
const remoteOnly = rows
  .filter(([local, remote]) => !local && /^\d{14}$/.test(remote))
  .map(([, remote]) => remote);

if (localOnly.length === 0 && remoteOnly.length === 0) {
  console.log(`All ${rows.length} migrations match between local and remote.`);
  process.exit(0);
}

if (localOnly.length > 0) {
  console.error(
    `${localOnly.length} local migration(s) not on the remote project:\n` +
      localOnly.map((v) => `  ${v}`).join('\n') +
      '\n\nRun `npx supabase db push` before promoting any story that added these to `done`.',
  );
}

if (remoteOnly.length > 0) {
  console.error(
    `\n${remoteOnly.length} remote migration(s) with no matching local file:\n` +
      remoteOnly.map((v) => `  ${v}`).join('\n') +
      '\n\nThese were applied directly (e.g. via `apply_migration`) without a local file at the ' +
      'same version — reconcile with `supabase migration repair` or by renaming the local file ' +
      'to match, or a future `db push` will try to reapply what already exists and fail.',
  );
}

process.exit(1);
