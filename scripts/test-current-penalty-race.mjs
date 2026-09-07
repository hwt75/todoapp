import { randomUUID } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';

const container = process.env.SUPABASE_DB_CONTAINER ?? 'supabase_db_todoapp';
const timeoutMs = 15_000;
const runTag = randomUUID().slice(0, 8);
const activeSessions = new Map();
const ids = {
  referee: randomUUID(),
  objectionWinsOwner: randomUUID(),
  collectionWinsOwner: randomUUID(),
  objectionWinsCommitment: randomUUID(),
  collectionWinsCommitment: randomUUID(),
  objectionWinsSettlement: randomUUID(),
  collectionWinsSettlement: randomUUID(),
  objectionWinsPenalty: randomUUID(),
  collectionWinsPenalty: randomUUID(),
  inviteToken: randomUUID(),
};

const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
const claims = JSON.stringify({
  sub: ids.referee,
  role: 'authenticated',
  app_role: 'referee',
});

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

async function waitForAdvisoryLock(applicationName, loser) {
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
      loser.closed.then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), 50)),
    ]);
    if (finished) {
      throw new Error(
        `The losing session exited before waiting on the advisory lock:\n${loser.output()}`,
      );
    }
  }
  throw new Error(`The losing session never waited on the advisory lock:\n${loser.output()}`);
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

function setup() {
  const liveDoers = Number(
    psql('select count(*) from public.profile where is_live_doer;').stdout.trim(),
  );
  if (liveDoers > 0) {
    throw new Error('Refusing to run against a database containing the live doer account (AD-16).');
  }

  psql(`
    begin;
    insert into auth.users
      (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
       created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
    select id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
           id::text || '@penalty-race.test', 'not-a-real-password', now(), now(), now(),
           '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
      from unnest(array[
        ${quote(ids.referee)}::uuid,
        ${quote(ids.objectionWinsOwner)}::uuid,
        ${quote(ids.collectionWinsOwner)}::uuid
      ]) as fixture(id);

    update public.profile set role = 'referee' where id = ${quote(ids.referee)}::uuid;

    insert into public.referee_invite
      (email, token_hash, created_by, expires_at, accepted_at, accepted_by)
    values ('referee@penalty-race.test', ${quote(ids.inviteToken)},
            ${quote(ids.objectionWinsOwner)}::uuid, now() + interval '1 day', now(),
            ${quote(ids.referee)}::uuid);

    insert into public.commitment
      (id, owner_id, idempotency_key, name, kind, cadence, carries_penalty, created_at)
    values
      (${quote(ids.objectionWinsCommitment)}::uuid, ${quote(ids.objectionWinsOwner)}::uuid,
       gen_random_uuid(), 'Objection wins', 'do', 'daily', true, now() - interval '30 days'),
      (${quote(ids.collectionWinsCommitment)}::uuid, ${quote(ids.collectionWinsOwner)}::uuid,
       gen_random_uuid(), 'Collection wins', 'do', 'daily', true, now() - interval '30 days');

    insert into public.settlement (id, subject, period, kind, verdict, missed_count)
    values
      (${quote(ids.objectionWinsSettlement)}::uuid, ${quote(ids.objectionWinsOwner)}::uuid,
       (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1, 'day', 'failed', 1),
      (${quote(ids.collectionWinsSettlement)}::uuid, ${quote(ids.collectionWinsOwner)}::uuid,
       (now() at time zone 'Asia/Ho_Chi_Minh')::date - 1, 'day', 'failed', 1);

    insert into public.settlement_commitment
      (settlement_id, subject, commitment_id, outcome)
    values
      (${quote(ids.objectionWinsSettlement)}::uuid, ${quote(ids.objectionWinsOwner)}::uuid,
       ${quote(ids.objectionWinsCommitment)}::uuid, 'held'),
      (${quote(ids.collectionWinsSettlement)}::uuid, ${quote(ids.collectionWinsOwner)}::uuid,
       ${quote(ids.collectionWinsCommitment)}::uuid, 'held');

    insert into public.penalty (id, subject, settlement_id, amount_dong)
    values
      (${quote(ids.objectionWinsPenalty)}::uuid, ${quote(ids.objectionWinsOwner)}::uuid,
       ${quote(ids.objectionWinsSettlement)}::uuid, public.penalty_amount_dong()),
      (${quote(ids.collectionWinsPenalty)}::uuid, ${quote(ids.collectionWinsOwner)}::uuid,
       ${quote(ids.collectionWinsSettlement)}::uuid, public.penalty_amount_dong());
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
  psql(`
    begin;
    delete from public.objection where subject in (
      ${quote(ids.objectionWinsOwner)}::uuid, ${quote(ids.collectionWinsOwner)}::uuid);
    delete from public.settlement where subject in (
      ${quote(ids.objectionWinsOwner)}::uuid, ${quote(ids.collectionWinsOwner)}::uuid)
      and supersedes is not null;
    delete from public.settlement where subject in (
      ${quote(ids.objectionWinsOwner)}::uuid, ${quote(ids.collectionWinsOwner)}::uuid);
    delete from public.referee_invite where token_hash = ${quote(ids.inviteToken)};
    delete from auth.users where id in (
      ${quote(ids.referee)}::uuid,
      ${quote(ids.objectionWinsOwner)}::uuid,
      ${quote(ids.collectionWinsOwner)}::uuid);
    commit;
  `);
}

async function objectionWins() {
  const winner = openSession(
    `penalty-race-objection-winner-${runTag}`,
    `select public.object_to_day(${quote(ids.objectionWinsSettlement)}::uuid,
       ${quote(ids.objectionWinsCommitment)}::uuid, 'The proof does not show it.');
     select 'WINNER_READY';`,
  );
  await waitFor(winner, (output) => output.includes('WINNER_READY'), 'the objection winner');

  const loserName = `penalty-race-collection-loser-${runTag}`;
  const loser = openSession(
    loserName,
    `select public.mark_penalty_collected(${quote(ids.objectionWinsPenalty)}::uuid);
     select 'LOSER_UNEXPECTEDLY_SUCCEEDED';
     commit;`,
  );
  loser.child.stdin.end();
  await waitForAdvisoryLock(loserName, loser);
  winner.child.stdin.end('commit;\n');

  const [winnerResult, loserResult] = await withTimeout(
    Promise.all([winner.closed, loser.closed]),
    'the objection-wins sessions to close',
  );
  if (winnerResult.code !== 0) throw new Error(winnerResult.stderr || winnerResult.stdout);
  expectRefusal(loserResult, 'current Penalty');
  assertRows(
    `select count(*) || '|' || count(*) filter (where p.state = 'owed') || '|' ||
            count(*) filter (where p.state = 'collected')
       from public.penalty_current p
      where p.subject = ${quote(ids.objectionWinsOwner)}::uuid;`,
    '1|1|0',
    'Objection-wins state',
  );
  assertRows(
    `select count(*) || '|' || count(*) filter (where p.state = 'owed') || '|' ||
            count(*) filter (where p.state = 'collected') || '|' ||
            count(*) filter (where p.collected_at is not null)
       from public.penalty p
      where p.subject = ${quote(ids.objectionWinsOwner)}::uuid;`,
    '2|2|0|0',
    'Objection-wins historical and current Penalties',
  );
  assertRows(
    `select
       (select count(*) from public.settlement s
         where s.supersedes = ${quote(ids.objectionWinsSettlement)}::uuid) || '|' ||
       (select count(*) from public.objection o
         where o.subject = ${quote(ids.objectionWinsOwner)}::uuid
           and o.superseded_settlement = ${quote(ids.objectionWinsSettlement)}::uuid
           and o.commitment_id = ${quote(ids.objectionWinsCommitment)}::uuid) || '|' ||
       (select count(*) from public.outbox x
         join public.objection o on x.dedupe_key = 'objection-' || o.id::text
        where o.subject = ${quote(ids.objectionWinsOwner)}::uuid);`,
    '1|1|1',
    'Objection-wins correction, objection, and outbox state',
  );
}

async function collectionWins() {
  psql(`update public.referee_invite set created_by = ${quote(ids.collectionWinsOwner)}::uuid
         where token_hash = ${quote(ids.inviteToken)};`);

  const winner = openSession(
    `penalty-race-collection-winner-${runTag}`,
    `select public.mark_penalty_collected(${quote(ids.collectionWinsPenalty)}::uuid);
     select 'WINNER_READY';`,
  );
  await waitFor(winner, (output) => output.includes('WINNER_READY'), 'the collection winner');

  const loserName = `penalty-race-objection-loser-${runTag}`;
  const loser = openSession(
    loserName,
    `select public.object_to_day(${quote(ids.collectionWinsSettlement)}::uuid,
       ${quote(ids.collectionWinsCommitment)}::uuid, 'The proof does not show it.');
     select 'LOSER_UNEXPECTEDLY_SUCCEEDED';
     commit;`,
  );
  loser.child.stdin.end();
  await waitForAdvisoryLock(loserName, loser);
  winner.child.stdin.end('commit;\n');

  const [winnerResult, loserResult] = await withTimeout(
    Promise.all([winner.closed, loser.closed]),
    'the collection-wins sessions to close',
  );
  if (winnerResult.code !== 0) throw new Error(winnerResult.stderr || winnerResult.stdout);
  expectRefusal(loserResult, 'already been collected');
  assertRows(
    `select p.state || '|' || (p.collected_at is not null)::text || '|' ||
            (select count(*) from public.settlement c
              where c.supersedes = ${quote(ids.collectionWinsSettlement)}::uuid) || '|' ||
            (select count(*) from public.objection o
              where o.subject = ${quote(ids.collectionWinsOwner)}::uuid)
       from public.penalty p where p.id = ${quote(ids.collectionWinsPenalty)}::uuid;`,
    'collected|true|0|0',
    'Collection-wins state',
  );

  const repeat = psql(
    `begin;
     set local role authenticated;
     select set_config('request.jwt.claims', ${quote(claims)}, true);
     select public.mark_penalty_collected(${quote(ids.collectionWinsPenalty)}::uuid);`,
    { allowFailure: true },
  );
  expectRefusal(repeat, 'already been resolved');
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
  await objectionWins();
  if (interruptedBy) throw new Error(`Interrupted by ${interruptedBy}.`);
  await collectionWins();
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
    'PASS: both winner orders waited on the account advisory lock and preserved one current Penalty.',
  );
}
