// Two sessions deciding the same commitment-day at the same instant.
//
// Both sessions are the SAME referee, and that is not a shortcut: one doer has exactly one
// referee (`profile.referee_of` is unique per doer, 20260907160000), so two *different* referees
// racing over one commitment-day is a state this schema cannot reach. What it can reach, and what
// this reproduces, is one person with the app open on a phone and a laptop, or one tap retried
// over a slow connection — two connections carrying one `sub`.
//
// `sign_off_day()` takes no advisory lock, unlike `object_to_day()` — it writes one row and moves
// no money, so its only contention is two decisions on one commitment-day, and what serialises
// that is `referee_decision_once_per_commitment_day` plus `on conflict do nothing`. That argument
// is the whole of Story 8.2's decision 3, and **a single-session test cannot reach it at all**:
// the RPC's own check-then-act read ("That day has already been decided") raises first, so the
// `on conflict do nothing` branch below it is unreachable from one connection and the decision's
// reasoning would ship unverified.
//
// So: two real psql sessions. The winner holds its transaction open past the insert; the loser
// runs the same call and must block on the unique index rather than sail past a read that saw
// nothing. When the winner commits, the loser's insert finds its own conflict, inserts nothing,
// and the RPC turns that into the same sentence a plain repeat gets — never a silent no-op, and
// never a second row.
//
//   node scripts/test-sign-off-race.mjs
//
// Modelled on scripts/test-current-penalty-race.mjs, which proves the same shape one lock up. It
// creates isolated local fixture accounts and deletes them afterwards, so unlike every
// transactional file under supabase/tests/ it does write to the database it runs against — hence
// the live-doer refusal in setup(), which is the same guard those files carry.

import { randomUUID } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';

const container = process.env.SUPABASE_DB_CONTAINER ?? 'supabase_db_todoapp';
const timeoutMs = 15_000;
const runTag = randomUUID().slice(0, 8);
const activeSessions = new Map();
const ids = {
  doer: randomUUID(),
  referee: randomUUID(),
  commitment: randomUUID(),
};

// Computed once, in JavaScript, and interpolated everywhere below. Computed twice in SQL, a run
// that crosses local midnight between the fixture's evidence row and the RPC's own window check
// plants the photograph on yesterday and the script fails with "There is no photograph on that
// day yet" instead of racing — a red run that says nothing about what it tests.
const localDay = psqlValue("select (now() at time zone 'Asia/Ho_Chi_Minh')::date::text;");

const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
const claims = JSON.stringify({
  sub: ids.referee,
  role: 'authenticated',
  app_role: 'referee',
});

function psqlValue(sql) {
  return psql(sql).stdout.trim();
}

function psql(sql, { allowFailure = false } = {}) {
  const result = spawnSync(
    'docker',
    [
      'exec',
      '-i',
      container,
      'psql',
      '-X',
      '-q',
      '-A',
      '-t',
      '-U',
      'postgres',
      '-d',
      'postgres',
      '-v',
      'ON_ERROR_STOP=1',
    ],
    { input: sql, encoding: 'utf8', timeout: timeoutMs },
  );

  if (result.error) throw result.error;
  if (!allowFailure && result.status !== 0) {
    throw new Error(result.stderr || result.stdout || `psql exited ${result.status}`);
  }
  return { code: result.status, stdout: result.stdout, stderr: result.stderr };
}

function openSession(applicationName, statements) {
  const child = spawn(
    'docker',
    [
      'exec',
      '-i',
      container,
      'psql',
      '-X',
      '-q',
      '-A',
      '-t',
      '-U',
      'postgres',
      '-d',
      'postgres',
      '-v',
      'ON_ERROR_STOP=1',
    ],
    { stdio: ['pipe', 'pipe', 'pipe'] },
  );
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });
  child.on('error', (error) => {
    stderr += `${error.stack ?? error.message}\n`;
  });

  const closed = new Promise((resolve) => {
    child.on('close', (code) => {
      activeSessions.delete(applicationName);
      resolve({ code, stdout, stderr });
    });
  });
  activeSessions.set(applicationName, closed);
  child.stdin.write(`set application_name = ${quote(applicationName)};\nbegin;\n`);
  child.stdin.write('set local role authenticated;\n');
  child.stdin.write(`select set_config('request.jwt.claims', ${quote(claims)}, true);\n`);
  child.stdin.write(`${statements}\n`);
  return { child, closed, output: () => stdout + stderr };
}

async function withTimeout(promise, description) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`Timed out waiting for ${description}.`)),
          timeoutMs,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function waitFor(session, predicate, description) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate(session.output())) return;
    const finished = await Promise.race([
      session.closed.then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), 25)),
    ]);
    if (finished) break;
  }
  throw new Error(`Timed out waiting for ${description}. Output:\n${session.output()}`);
}

// The tuple lock, not the advisory one: sign_off_day() takes no advisory lock at all, and that is
// the property under test. A second insert against referee_decision_once_per_commitment_day waits
// on the first transaction's unsettled tuple, which pg_stat_activity reports as a `tuple` lock
// wait (or `transactionid`, depending on which half of the wait it is in when this looks).
async function waitForRowLock(applicationName, loser) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = psql(`
      select count(*)
        from pg_stat_activity
       where application_name = ${quote(applicationName)}
         and wait_event_type = 'Lock'
         and wait_event in ('tuple', 'transactionid');
    `);
    if (Number(result.stdout.trim()) === 1) return;
    const finished = await Promise.race([
      loser.closed.then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), 50)),
    ]);
    if (finished) {
      throw new Error(
        `The losing session exited before waiting on the unique index. Nothing serialised the ` +
          `two decisions, so both could have been written:\n${loser.output()}`,
      );
    }
  }
  throw new Error(`The losing session never waited on the unique index:\n${loser.output()}`);
}

// And the negative that keeps the check above honest: it must NOT be waiting on an advisory lock.
// If sign_off_day() ever grows one it would put a referee in the way of the author's own Grace
// Day, which is exactly what decision 3 refuses.
function assertNoAdvisoryWait(applicationName) {
  const result = psql(`
    select count(*)
      from pg_stat_activity
     where application_name = ${quote(applicationName)}
       and wait_event_type = 'Lock'
       and wait_event = 'advisory';
  `);
  if (Number(result.stdout.trim()) !== 0) {
    throw new Error(
      'The losing session is waiting on an advisory lock. sign_off_day() decides nothing at ' +
        "write time and must not hold the author's per-account serialization key (decision 3).",
    );
  }
}

function expectRefusal(result, fragment) {
  const output = result.stdout + result.stderr;
  if (result.code === 0 || !output.toLowerCase().includes(fragment.toLowerCase())) {
    throw new Error(
      `Expected refusal containing ${quote(fragment)}, got exit ${result.code}:\n${output}`,
    );
  }
}

function assertRows(sql, expected, description) {
  const actual = psql(sql).stdout.trim();
  if (actual !== expected) {
    throw new Error(`${description}: expected ${expected}, got ${actual || '<empty>'}`);
  }
}

// Whether this run is the one that created the bucket. `on conflict do nothing` makes setup
// idempotent, but it also makes it silent about which run owns the row — and cleanup must not
// delete a bucket the local stack itself configured for the app. Read before inserting.
let createdBucket = false;

function setup() {
  const liveDoers = Number(
    psql('select count(*) from public.profile where is_live_doer;').stdout.trim(),
  );
  if (liveDoers > 0) {
    throw new Error('Refusing to run against a database containing the live doer account (AD-16).');
  }

  // The bucket is `config.toml` configuration the CLI creates through the Storage API, not a
  // migration, so a database started with `-x storage-api` has the schema and not the row. Staged
  // here when it is missing — and remembered, so cleanup removes only what this run added.
  createdBucket =
    psqlValue("select count(*) from storage.buckets where id = 'appeal-evidence';") === '0';
  if (createdBucket) {
    psql("insert into storage.buckets (id, name) values ('appeal-evidence', 'appeal-evidence');");
  }

  psql(`
    begin;
    insert into auth.users
      (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
       created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
    select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
           id::text || '@sign-off-race.test', 'not-a-real-password', now(), now(), now(),
           '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
      from unnest(array[
        ${quote(ids.doer)}::uuid,
        ${quote(ids.referee)}::uuid
      ]) as fixture(id);

    -- paired_doer_id() reads profile.referee_of, which lives on the referee's own row and points
    -- at the doer. No backticks in here: this is a JS template literal, and one would end the
    -- string.
    update public.profile
       set role = 'referee', referee_of = ${quote(ids.doer)}::uuid
     where id = ${quote(ids.referee)}::uuid;

    -- Flagged, penalty-carrying, untimed: the shape a refusal actually lands on. The pairing
    -- above has to exist first -- commitment_sign_off_needs_a_referee() fires at write time.
    insert into public.commitment
      (id, owner_id, idempotency_key, name, kind, cadence, carries_penalty, requires_photo,
       requires_referee_approval, created_at)
    values
      (${quote(ids.commitment)}::uuid, ${quote(ids.doer)}::uuid, gen_random_uuid(),
       'Sign-off race', 'do', 'daily', true, true, true, now() - interval '30 days');

    -- The photograph the refusal is made against, object before row. One local day, computed
    -- once above and interpolated, so the two dates here and the RPC's window check below cannot
    -- straddle midnight.
    insert into storage.objects (bucket_id, name, owner)
    values ('appeal-evidence',
            ${quote(ids.commitment)} || '/race.jpg',
            ${quote(ids.doer)}::uuid);

    insert into public.evidence (commitment_id, for_day, owner_id, storage_path, captured_on)
    values (${quote(ids.commitment)}::uuid,
            ${quote(localDay)}::date,
            ${quote(ids.doer)}::uuid,
            ${quote(ids.commitment)} || '/race.jpg',
            ${quote(localDay)}::date);
    commit;
  `);
}

async function terminateRaceSessions() {
  if (activeSessions.size === 0) return;
  const sessions = [...activeSessions.values()];
  const applications = [...activeSessions.keys()].map(quote).join(', ');
  psql(`
    select pg_terminate_backend(pid)
      from pg_stat_activity
     where application_name = any(array[${applications}]::text[])
       and pid <> pg_backend_pid();
  `);
  await withTimeout(Promise.all(sessions), 'terminated race sessions to close');
}

function cleanup() {
  // storage.protect_delete() refuses a direct DELETE on storage.objects: the Storage API is meant
  // to own that table, and a row removed behind its back orphans the file. There is no Storage
  // API in this harness -- the object it staged is a metadata row with no file behind it -- so the
  // trigger is stood down for exactly that one statement, in a transaction of its own.
  //
  // **Its own transaction on purpose.** `session_replication_role = replica` disables foreign-key
  // triggers along with user ones, so an `auth.users` delete made under it would leave the
  // `profile` rows that cascade from it behind. Everything that depends on a cascade is therefore
  // deleted with the triggers on, below.
  psql(`
    begin;
    set local session_replication_role = replica;
    delete from storage.objects where owner = ${quote(ids.doer)}::uuid;
    ${
      createdBucket
        ? "delete from storage.buckets where id = 'appeal-evidence';"
        : '-- the bucket predates this run; leave it alone'
    }
    commit;
  `);

  psql(`
    begin;
    delete from public.referee_decision where subject = ${quote(ids.doer)}::uuid;
    delete from public.evidence where owner_id = ${quote(ids.doer)}::uuid;
    delete from public.commitment where owner_id = ${quote(ids.doer)}::uuid;
    delete from auth.users where id in (
      ${quote(ids.doer)}::uuid,
      ${quote(ids.referee)}::uuid);
    commit;
  `);

  // Said out loud rather than trusted: this harness is the only thing under supabase/tests/ or
  // scripts/ that really writes, so a cleanup that half-worked would poison every later run --
  // including `settle_day`'s AD-16 live-doer guard if a stray profile were ever marked live.
  const left = psql(`
    select (select count(*) from public.profile where id in (
              ${quote(ids.doer)}::uuid, ${quote(ids.referee)}::uuid))
         + (select count(*) from public.commitment
             where id = ${quote(ids.commitment)}::uuid)
         + (select count(*) from public.evidence
             where owner_id = ${quote(ids.doer)}::uuid)
         + (select count(*) from storage.objects
             where owner = ${quote(ids.doer)}::uuid)
         + (select count(*) from public.referee_decision
             where subject = ${quote(ids.doer)}::uuid)
         ${
           createdBucket
             ? "+ (select count(*) from storage.buckets where id = 'appeal-evidence')"
             : ''
         };
  `).stdout.trim();
  if (left !== '0') {
    throw new Error(`Cleanup left ${left} fixture row(s) behind.`);
  }
}

async function bothDecideAtOnce() {
  const call = (reason) =>
    `select public.sign_off_day(${quote(ids.commitment)}::uuid,
       ${quote(localDay)}::date, false, ${quote(reason)});`;

  const winner = openSession(
    `sign-off-race-winner-${runTag}`,
    `${call('The photograph is of the car park.')}
     select 'WINNER_READY';`,
  );
  await waitFor(winner, (output) => output.includes('WINNER_READY'), 'the winning decision');

  const loserName = `sign-off-race-loser-${runTag}`;
  const loser = openSession(
    loserName,
    `${call('I say the same thing, a millisecond later.')}
     select 'LOSER_UNEXPECTEDLY_SUCCEEDED';
     commit;`,
  );
  loser.child.stdin.end();

  // It must block, and it must block on the index rather than on an advisory lock it should never
  // be taking. The check-then-act read above the insert sees nothing — the winner has not
  // committed — so the only thing standing here is the unique constraint.
  await waitForRowLock(loserName, loser);
  assertNoAdvisoryWait(loserName);

  winner.child.stdin.end('commit;\n');

  const [winnerResult, loserResult] = await withTimeout(
    Promise.all([winner.closed, loser.closed]),
    'the sign-off race sessions to close',
  );
  if (winnerResult.code !== 0) throw new Error(winnerResult.stderr || winnerResult.stdout);

  // The loser raises, in the same words a plain repeat gets, rather than silently doing nothing.
  expectRefusal(loserResult, 'already been decided');

  assertRows(
    `select count(*) || '|' || count(*) filter (where not approved) || '|' ||
            coalesce(min(reason), '<none>')
       from public.referee_decision
      where subject = ${quote(ids.doer)}::uuid
        and commitment_id = ${quote(ids.commitment)}::uuid;`,
    '1|1|The photograph is of the car park.',
    'Exactly one decision survives, and it is the winner',
  );
}

async function repeatAfterTheFact() {
  const repeat = psql(
    `begin;
     set local role authenticated;
     select set_config('request.jwt.claims', ${quote(claims)}, true);
     select public.sign_off_day(${quote(ids.commitment)}::uuid,
       ${quote(localDay)}::date, true);`,
    { allowFailure: true },
  );
  expectRefusal(repeat, 'already been decided');
}

let setupComplete = false;
let passed = false;
let interruptedBy;
let primaryError;
const requestShutdown = (signal) => {
  interruptedBy = signal;
  process.exitCode = signal === 'SIGINT' ? 130 : 143;
  void terminateRaceSessions().catch(() => {});
};
process.once('SIGINT', () => requestShutdown('SIGINT'));
process.once('SIGTERM', () => requestShutdown('SIGTERM'));

try {
  setup();
  setupComplete = true;
  if (interruptedBy) throw new Error(`Interrupted by ${interruptedBy}.`);
  await bothDecideAtOnce();
  if (interruptedBy) throw new Error(`Interrupted by ${interruptedBy}.`);
  await repeatAfterTheFact();
  if (interruptedBy) throw new Error(`Interrupted by ${interruptedBy}.`);
  passed = true;
} catch (error) {
  primaryError = error;
} finally {
  const cleanupErrors = [];
  try {
    await terminateRaceSessions();
  } catch (error) {
    cleanupErrors.push(error);
  }
  if (setupComplete) {
    try {
      cleanup();
    } catch (error) {
      cleanupErrors.push(error);
    }
  }

  if (primaryError && cleanupErrors.length > 0) {
    throw new AggregateError([primaryError, ...cleanupErrors], primaryError.message);
  }
  if (primaryError) throw primaryError;
  if (cleanupErrors.length > 0) {
    throw new AggregateError(cleanupErrors, 'Race-session cleanup failed.');
  }
}

if (passed) {
  console.log(
    'PASS: two concurrent decisions on one commitment-day serialise on the unique index with no ' +
      'advisory lock taken, the loser raises rather than no-ops, and exactly one row survives.',
  );
}
