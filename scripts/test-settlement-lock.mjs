// The settler and both correction passes wait for the account key (20261005090000).
//
// supabase/tests/the-settler-takes-the-account-lock.sql can only see that each function's text
// contains the lock. Whether the function actually waits on it is visible to a second session and
// nowhere else, so this holds the key the way any other writer would -- grace_day_validate(),
// mark_penalty_collected(), object_to_day(), sign_off_day() -- and asserts that each of the three
// scheduled writers blocks on it rather than reading the account's day underneath it:
//
//   settle_day()           the race deferred-work.md recorded against Story 8.2
//   supersede_expiries()   the race recorded against Epic 6 retrospective item 36's review
//   apply_grace_days()     Epic 6 retrospective item 44, which moved it onto frozen rows
//
//   node scripts/test-settlement-lock.mjs
//
// Modelled on scripts/test-current-penalty-race.mjs. It creates isolated local fixture accounts
// and deletes them afterwards, so it writes to the database it runs against -- hence the
// live-doer refusal in setup(), the same guard every file under supabase/tests/ carries.

import { randomUUID } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';

const container = process.env.SUPABASE_DB_CONTAINER ?? 'supabase_db_todoapp';
const timeoutMs = 15_000;
const runTag = randomUUID().slice(0, 8);
const activeSessions = new Map();
const ids = {
  failedOwner: randomUUID(), // a day that settles failed, then is forgiven by a Grace Day
  expiredOwner: randomUUID(), // a day that expires, then is corrected by a timely late answer
  failedCommitment: randomUUID(),
  expiredCommitment: randomUUID(),
};

const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;

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

async function waitForAdvisoryLock(applicationName, waiter, description) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = psql(`
      select count(*)
        from pg_stat_activity
       where application_name = ${quote(applicationName)}
         and wait_event_type = 'Lock'
         and wait_event = 'advisory';
    `);
    if (Number(result.stdout.trim()) === 1) return;
    const finished = await Promise.race([
      waiter.closed.then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), 50)),
    ]);
    if (finished) {
      throw new Error(
        `${description} finished while another session held the account key, so it read the ` +
          `account's day without waiting for that writer:\n${waiter.output()}`,
      );
    }
  }
  throw new Error(`${description} never waited on the account key:\n${waiter.output()}`);
}

function assertRows(sql, expected, description) {
  const actual = psqlValue(sql);
  if (actual !== expected) {
    throw new Error(`${description}: expected ${expected}, got ${actual || '<empty>'}`);
  }
}

// Computed once, in JavaScript, so a run that crosses local midnight cannot plant the fixture on
// one day and settle another.
const today = psqlValue("select (now() at time zone 'Asia/Ho_Chi_Minh')::date::text;");
const failedDay = psqlValue(`select (${quote(today)}::date - 2)::text;`);
// Four days back: the untimed deadline -- the morning hour on D+3 -- has passed, so the day can
// genuinely expire (2-7-supersession.sql's reasoning).
const expiredDay = psqlValue(`select (${quote(today)}::date - 4)::text;`);
const morningAfter = (day) =>
  `((${quote(day)}::date + 1)::timestamp + interval '7 hours 31 minutes') at time zone 'Asia/Ho_Chi_Minh'`;

function setup() {
  const liveDoers = Number(psqlValue('select count(*) from public.profile where is_live_doer;'));
  if (liveDoers > 0) {
    throw new Error('Refusing to run against a database containing the live doer account (AD-16).');
  }

  psql(`
    begin;
    insert into auth.users
      (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
       created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
    select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
           id::text || '@settlement-lock.test', 'not-a-real-password', now(), now(), now(),
           '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
      from unnest(array[
        ${quote(ids.failedOwner)}::uuid,
        ${quote(ids.expiredOwner)}::uuid
      ]) as fixture(id);

    insert into public.commitment
      (id, owner_id, idempotency_key, name, kind, cadence, carries_penalty, created_at)
    values
      (${quote(ids.failedCommitment)}::uuid, ${quote(ids.failedOwner)}::uuid, gen_random_uuid(),
       'Settlement lock', 'abstain', 'daily', true, now() - interval '90 days'),
      (${quote(ids.expiredCommitment)}::uuid, ${quote(ids.expiredOwner)}::uuid, gen_random_uuid(),
       'Settlement lock', 'abstain', 'daily', true, now() - interval '90 days');

    -- The failed owner admits the slip for his day; the expired owner says nothing for his.
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (${quote(ids.failedOwner)}::uuid, ${quote(ids.failedCommitment)}::uuid,
            gen_random_uuid(), 'slipped', ${morningAfter(failedDay)});
    commit;
  `);

  // The expired owner's day is closed before anything races, so that the supersede leg has an
  // expiry to correct. The failed owner's day is left for the settle leg.
  psql(`select public.settle_day(${quote(expiredDay)}::date, true);`);

  assertRows(
    `select verdict from public.settlement
      where subject = ${quote(ids.expiredOwner)}::uuid and period = ${quote(expiredDay)}::date
        and kind = 'day' and supersedes is null;`,
    'expired',
    'Fixture: the expired owner day closed expired',
  );

  // His answer, given in time and delivered late -- what supersede_expiries() exists for.
  psql(`
    insert into public.declaration (owner_id, commitment_id, idempotency_key, answer, answered_at)
    values (${quote(ids.expiredOwner)}::uuid, ${quote(ids.expiredCommitment)}::uuid,
            gen_random_uuid(), 'held', ${morningAfter(expiredDay)});
  `);
}

// One leg: a session holds `owner`'s key, `call` must wait on it, and once the holder commits it
// must complete and leave `check` reading `expected`.
async function waitsForTheKey({ name, owner, call, check, expected }) {
  const holder = openSession(
    `settlement-lock-holder-${name}-${runTag}`,
    `select pg_advisory_xact_lock(hashtext(${quote(owner)}));
     select 'HOLDER_READY';`,
  );
  await waitFor(holder, (output) => output.includes('HOLDER_READY'), `the ${name} key holder`);

  const waiterName = `settlement-lock-waiter-${name}-${runTag}`;
  const waiter = openSession(waiterName, `${call}\ncommit;`);
  waiter.child.stdin.end();

  await waitForAdvisoryLock(waiterName, waiter, name);

  // Nothing written while it waits: the holder's transaction is the only one in the account.
  assertRows(check, '0', `${name} wrote nothing while it waited`);

  holder.child.stdin.end('commit;\n');

  const [holderResult, waiterResult] = await withTimeout(
    Promise.all([holder.closed, waiter.closed]),
    `the ${name} sessions to close`,
  );
  if (holderResult.code !== 0) throw new Error(holderResult.stderr || holderResult.stdout);
  if (waiterResult.code !== 0) throw new Error(waiterResult.stderr || waiterResult.stdout);

  assertRows(check, expected, `${name} completed once the key was released`);
}

async function terminateSessions() {
  if (activeSessions.size === 0) return;
  const sessions = [...activeSessions.values()];
  const applications = [...activeSessions.keys()].map(quote).join(', ');
  psql(`
    select pg_terminate_backend(pid)
      from pg_stat_activity
     where application_name = any(array[${applications}]::text[])
       and pid <> pg_backend_pid();
  `);
  await withTimeout(Promise.all(sessions), 'terminated sessions to close');
}

function cleanup() {
  const owners = `${quote(ids.failedOwner)}::uuid, ${quote(ids.expiredOwner)}::uuid`;
  // Corrections first: `supersedes` is `on delete restrict`. Everything else cascades from the
  // profile, which cascades from auth.users.
  psql(`
    begin;
    delete from public.settlement where subject in (${owners}) and supersedes is not null;
    delete from public.settlement where subject in (${owners});
    delete from auth.users where id in (${owners});
    commit;
  `);

  const left = psqlValue(`
    select (select count(*) from public.profile where id in (${owners}))
         + (select count(*) from public.commitment where owner_id in (${owners}))
         + (select count(*) from public.settlement where subject in (${owners}))
         + (select count(*) from public.grace_day where owner_id in (${owners}));
  `);
  if (left !== '0') throw new Error(`Cleanup left ${left} fixture row(s) behind.`);
}

let setupComplete = false;
let passed = false;
let interruptedBy;
let primaryError;
const requestShutdown = (signal) => {
  interruptedBy = signal;
  process.exitCode = signal === 'SIGINT' ? 130 : 143;
  void terminateSessions().catch(() => {});
};
process.once('SIGINT', () => requestShutdown('SIGINT'));
process.once('SIGTERM', () => requestShutdown('SIGTERM'));

try {
  setup();
  setupComplete = true;

  await waitsForTheKey({
    name: 'settle_day',
    owner: ids.failedOwner,
    call: `select public.settle_day(${quote(failedDay)}::date, true);`,
    check: `select count(*) from public.settlement
             where subject = ${quote(ids.failedOwner)}::uuid
               and period = ${quote(failedDay)}::date and verdict = 'failed';`,
    expected: '1',
  });
  if (interruptedBy) throw new Error(`Interrupted by ${interruptedBy}.`);

  await waitsForTheKey({
    name: 'supersede_expiries',
    owner: ids.expiredOwner,
    call: 'select public.supersede_expiries();',
    check: `select count(*) from public.settlement
             where subject = ${quote(ids.expiredOwner)}::uuid and supersedes is not null;`,
    expected: '1',
  });
  if (interruptedBy) throw new Error(`Interrupted by ${interruptedBy}.`);

  // The Grace Day is filed in its own committed transaction first: grace_day_validate() takes the
  // same key, so filing it inside the holder would make the holder the writer under test.
  psql(`insert into public.grace_day (owner_id, for_day)
        values (${quote(ids.failedOwner)}::uuid, ${quote(failedDay)}::date);`);

  await waitsForTheKey({
    name: 'apply_grace_days',
    owner: ids.failedOwner,
    call: 'select public.apply_grace_days();',
    check: `select count(*) from public.settlement
             where subject = ${quote(ids.failedOwner)}::uuid and supersedes is not null
               and verdict = 'clean';`,
    expected: '1',
  });
  if (interruptedBy) throw new Error(`Interrupted by ${interruptedBy}.`);

  passed = true;
} catch (error) {
  primaryError = error;
} finally {
  const cleanupErrors = [];
  try {
    await terminateSessions();
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
    throw new AggregateError(cleanupErrors, 'Session cleanup failed.');
  }
}

if (passed) {
  console.log(
    'PASS: settle_day(), supersede_expiries() and apply_grace_days() each wait for the account ' +
      'key another writer holds, and complete once it is released.',
  );
}
