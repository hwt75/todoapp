/**
 * Epic 6 retrospective item 40 — the reminder and the claim, in both orders.
 *
 * Two writers decide whether a due-time reminder should exist for one commitment on one day, and
 * the defect lived entirely in the gap between two statements: `enqueue_due_time_reminder()`
 * checked for a declaration and then inserted the outbox row, while
 * `declaration_cancels_due_time_reminder()` deleted that row after a claim was filed. A claim
 * committing between the check and the insert satisfied neither guard, and the author was reminded
 * at the moment his window opened to do a thing he had already done and told the app about.
 *
 * A gap between two statements cannot be reached from one session, which is why this file exists
 * outside the rollback-only SQL suite, alongside `test-current-penalty-race.mjs` and for the same
 * reason. Both winner orders are driven with real concurrent sessions, the loser is *proved* to be
 * waiting on the advisory lock rather than merely arriving late, and both orders are asserted to
 * end the same way: a claimed day carries no queued reminder.
 *
 *   node scripts/test-due-reminder-race.mjs
 *
 * Fixtures are created under generated uuids and removed at the end, whether or not an assertion
 * fails. Set SUPABASE_DB_CONTAINER when the local database container is not the repository
 * default.
 */

import { randomUUID } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';

const container = process.env.SUPABASE_DB_CONTAINER ?? 'supabase_db_todoapp';
const timeoutMs = 15_000;
const activeSessions = new Set();

const ids = {
  claimWinsOwner: randomUUID(),
  enqueueWinsOwner: randomUUID(),
  claimWinsCommitment: randomUUID(),
  enqueueWinsCommitment: randomUUID(),
};

const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;

const PSQL_ARGS = [
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
];

function psql(sql, { allowFailure = false } = {}) {
  const result = spawnSync('docker', PSQL_ARGS, {
    input: sql,
    encoding: 'utf8',
    timeout: timeoutMs,
  });

  if (result.error) throw result.error;
  if (!allowFailure && result.status !== 0) {
    throw new Error(result.stderr || result.stdout || `psql exited ${result.status}`);
  }
  return { code: result.status, stdout: result.stdout, stderr: result.stderr };
}

/**
 * One open transaction that stays open until it is told to finish.
 *
 * `asDoer` is what makes the claim session a genuinely client-originated statement:
 * `declaration_derive_day()` reads `current_user` to decide whether the window applies and whether
 * `filed_by` is forced, so a claim driven as `postgres` would exercise the machine branch while
 * appearing to exercise the author's.
 */
function openSession(applicationName, { asDoer = null, statements }) {
  const child = spawn('docker', PSQL_ARGS, { stdio: ['pipe', 'pipe', 'pipe'] });
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
      activeSessions.delete(session);
      resolve({ code, stdout, stderr });
    });
  });

  child.stdin.write(`set application_name = ${quote(applicationName)};\nbegin;\n`);
  if (asDoer) {
    const claims = JSON.stringify({ sub: asDoer, role: 'authenticated' });
    child.stdin.write('set local role authenticated;\n');
    child.stdin.write(`select set_config('request.jwt.claims', ${quote(claims)}, true);\n`);
  }
  child.stdin.write(`${statements}\n`);

  const session = { child, closed, applicationName, output: () => stdout + stderr };
  activeSessions.add(session);
  return session;
}

function finish(session, sql) {
  session.child.stdin.write(`${sql}\n\\q\n`);
  return session.closed;
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

/**
 * The assertion that makes this a serialization test rather than a timing coincidence.
 *
 * Without it the loser could simply have been slow, and the file would pass just as happily
 * against the unlocked code it exists to refuse.
 */
async function waitForAdvisoryLock(session) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = psql(`
      select count(*)
        from pg_stat_activity
       where application_name = ${quote(session.applicationName)}
         and wait_event_type = 'Lock'
         and wait_event = 'advisory';
    `);
    if (Number(result.stdout.trim()) === 1) return;
    const finished = await Promise.race([
      session.closed.then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), 50)),
    ]);
    if (finished) {
      throw new Error(
        `${session.applicationName} exited before it ever waited on the advisory lock. ` +
          `Nothing serialized these two writers:\n${session.output()}`,
      );
    }
  }
  throw new Error(
    `${session.applicationName} never waited on the advisory lock. The claim and the reminder ` +
      `are still deciding the same fact without seeing each other:\n${session.output()}`,
  );
}

function assertRows(sql, expected, description) {
  const actual = psql(sql).stdout.trim();
  if (actual !== expected) {
    throw new Error(`${description}: expected ${expected}, got ${actual || '<empty>'}`);
  }
}

const today = () => psql("select (now() at time zone 'Asia/Ho_Chi_Minh')::date;").stdout.trim();

function dedupeKey(commitmentId, day) {
  return `due-${commitmentId}-${day}`;
}

function remindersFor(commitmentId, day) {
  return `select count(*) from public.outbox where dedupe_key = ${quote(dedupeKey(commitmentId, day))};`;
}

function setup() {
  // AD-16. The override paths these fixtures lean on are disabled outright by one live account,
  // and a fixture account created beside real data is worse than a refusal.
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
           id::text || '@due-reminder-race.test', 'not-a-real-password', now(), now(), now(),
           '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
      from unnest(array[
        ${quote(ids.claimWinsOwner)}::uuid,
        ${quote(ids.enqueueWinsOwner)}::uuid
      ]) as fixture(id);

    -- One timed commitment each, with a window wide enough that the claim below lands inside it.
    insert into public.commitment
      (id, owner_id, idempotency_key, name, kind, cadence, due_time, late_window_minutes)
    values
      (${quote(ids.claimWinsCommitment)}::uuid, ${quote(ids.claimWinsOwner)}::uuid,
       gen_random_uuid(), 'Pill', 'do', 'daily', time '20:00', 60),
      (${quote(ids.enqueueWinsCommitment)}::uuid, ${quote(ids.enqueueWinsOwner)}::uuid,
       gen_random_uuid(), 'Pill', 'do', 'daily', time '20:00', 60);

    -- The commitment write offers its own reminder (20260903090000:516), which would leave a row
    -- queued before either race starts and hide the very thing being measured.
    delete from public.outbox
     where dedupe_key like 'due-' || ${quote(ids.claimWinsCommitment)} || '-%'
        or dedupe_key like 'due-' || ${quote(ids.enqueueWinsCommitment)} || '-%';
    commit;
  `);
}

function cleanup() {
  psql(
    `
    begin;
    delete from public.outbox
     where dedupe_key like 'due-' || ${quote(ids.claimWinsCommitment)} || '-%'
        or dedupe_key like 'due-' || ${quote(ids.enqueueWinsCommitment)} || '-%';
    delete from auth.users
     where id in (${quote(ids.claimWinsOwner)}::uuid, ${quote(ids.enqueueWinsOwner)}::uuid);
    commit;
  `,
    { allowFailure: true },
  );
}

/**
 * The claim commits first.
 *
 * The enqueuer must wait, and must then read a declaration that exists — which is exactly what it
 * could not do before, because its check ran before the claim was visible and its insert ran
 * after.
 */
async function claimWinsTheRace(day) {
  const commitment = ids.claimWinsCommitment;
  const claim = openSession('due-reminder-race-claim-first', {
    asDoer: ids.claimWinsOwner,
    statements: `
      insert into public.declaration
        (owner_id, commitment_id, idempotency_key, answer, answered_at, claimed_timed)
      values (${quote(ids.claimWinsOwner)}::uuid, ${quote(commitment)}::uuid, gen_random_uuid(),
              'held', (${quote(day)} || ' 20:05')::timestamp at time zone 'Asia/Ho_Chi_Minh', true);
      select 'claim filed';
    `,
  });
  await waitFor(claim, (out) => out.includes('claim filed'), 'the claim to be filed');

  // Half an hour before the window opens, which is where the hourly pass meets it.
  const enqueue = openSession('due-reminder-race-enqueue-second', {
    statements: `
      select public.enqueue_due_time_reminder(
        ${quote(commitment)}::uuid,
        ${quote(day)}::date,
        public.due_time_instant(${quote(day)}::date, time '20:00') - interval '30 minutes'
      );
      select 'enqueue decided';
    `,
  });

  await waitForAdvisoryLock(enqueue);

  await withTimeout(finish(claim, 'commit;'), 'the claim to commit');
  await waitFor(enqueue, (out) => out.includes('enqueue decided'), 'the enqueue to decide');

  if (!/^f$/m.test(enqueue.output())) {
    throw new Error(
      `The enqueue returned true for a day that had just been claimed. It waited for the lock ` +
        `and then queued anyway:\n${enqueue.output()}`,
    );
  }

  await withTimeout(finish(enqueue, 'commit;'), 'the enqueue to commit');

  assertRows(
    remindersFor(commitment, day),
    '0',
    'A day claimed before the pass reached it still ended with a queued reminder',
  );
  assertRows(
    `select count(*) from public.declaration where commitment_id = ${quote(commitment)}::uuid and for_day = ${quote(day)}::date;`,
    '1',
    'The claim itself did not survive its own race',
  );

  console.log('PASS: the claim commits first, the enqueue waits for it and then refuses.');
}

/**
 * The enqueue commits first.
 *
 * The claim must wait, and its cancellation must then find the row — which is what it could not do
 * before, because it looked for a row that had not been inserted yet.
 */
async function enqueueWinsTheRace(day) {
  const commitment = ids.enqueueWinsCommitment;
  const enqueue = openSession('due-reminder-race-enqueue-first', {
    statements: `
      select public.enqueue_due_time_reminder(
        ${quote(commitment)}::uuid,
        ${quote(day)}::date,
        public.due_time_instant(${quote(day)}::date, time '20:00') - interval '30 minutes'
      );
      select 'enqueue decided';
    `,
  });
  await waitFor(enqueue, (out) => out.includes('enqueue decided'), 'the enqueue to decide');

  if (!/^t$/m.test(enqueue.output())) {
    throw new Error(
      `The enqueue refused an unclaimed day inside its own window, so this order proves ` +
        `nothing:\n${enqueue.output()}`,
    );
  }

  const claim = openSession('due-reminder-race-claim-second', {
    asDoer: ids.enqueueWinsOwner,
    statements: `
      insert into public.declaration
        (owner_id, commitment_id, idempotency_key, answer, answered_at, claimed_timed)
      values (${quote(ids.enqueueWinsOwner)}::uuid, ${quote(commitment)}::uuid, gen_random_uuid(),
              'held', (${quote(day)} || ' 20:05')::timestamp at time zone 'Asia/Ho_Chi_Minh', true);
      select 'claim filed';
    `,
  });

  await waitForAdvisoryLock(claim);

  await withTimeout(finish(enqueue, 'commit;'), 'the enqueue to commit');
  await waitFor(claim, (out) => out.includes('claim filed'), 'the claim to be filed');
  await withTimeout(finish(claim, 'commit;'), 'the claim to commit');

  assertRows(
    remindersFor(commitment, day),
    '0',
    'The reminder queued a moment before the claim was filed outlived it',
  );

  console.log('PASS: the enqueue commits first, the claim waits for it and then cancels the row.');
}

async function main() {
  setup();
  const day = today();
  try {
    await claimWinsTheRace(day);
    await enqueueWinsTheRace(day);
    console.log(
      'PASS: both winner orders waited on the commitment-day advisory lock, and a claimed day ' +
        'ends with no queued reminder either way.',
    );
  } finally {
    for (const session of activeSessions) {
      session.child.stdin.write('rollback;\n\\q\n');
    }
    await Promise.allSettled([...activeSessions].map((session) => session.closed));
    cleanup();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
