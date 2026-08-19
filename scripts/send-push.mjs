// Sends one Web Push to the saved subscription and reports exactly what the push
// service said.
//
// This is the operator-driven half of Story 1.2. It exists to answer one question
// — does a push reach a locked iPhone, and does it keep working after a reboot —
// so it never retries, never smooths over a failure, and exits non-zero when the
// send does not succeed. A silent retry would hide the finding this story is for.
//
// Every failure below names itself. That is not politeness: on iOS the permission
// prompt is offered once, so an operator sent back through install-and-subscribe by
// a misleading message pays for it by deleting the app and starting over.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import webpush from 'web-push';

const SUBSCRIPTION_FILE = join(process.cwd(), '.push-subscription.json');
const ENV_FILE = join(process.cwd(), '.env');

function fail(message) {
  console.error(message);
  process.exit(1);
}

// Loaded here rather than by `node --env-file=.env` in the npm script, because that
// flag makes the file mandatory: with no .env, Node exits before this file runs and
// every message below becomes unreachable — including the one explaining what to do.
// Guarded on existence because process.loadEnvFile landed in Node 20.12 and this
// project supports 20.9; without it, exported shell variables still work.
if (existsSync(ENV_FILE) && typeof process.loadEnvFile === 'function') {
  process.loadEnvFile(ENV_FILE);
}

const { VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT } = process.env;
if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY || !VAPID_SUBJECT) {
  fail(
    [
      'Missing VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY or VAPID_SUBJECT.',
      'Generate a pair with `npx web-push generate-vapid-keys`, then either put them',
      `in ${ENV_FILE} or export them in your shell before running this.`,
    ].join('\n'),
  );
}

// Existence and parsing are checked separately on purpose. Collapsing them reports a
// truncated paste as a missing file, which sends the operator back through install,
// permission and subscribe when the real fix is one character.
if (!existsSync(SUBSCRIPTION_FILE)) {
  fail(
    [
      `No subscription at ${SUBSCRIPTION_FILE}.`,
      'Open the app from its home-screen icon, tap "Subscribe this device", and save',
      'the JSON there.',
    ].join('\n'),
  );
}

let subscription;
try {
  subscription = JSON.parse(readFileSync(SUBSCRIPTION_FILE, 'utf8'));
} catch (error) {
  fail(
    [
      `${SUBSCRIPTION_FILE} exists but is not valid JSON: ${error.message}`,
      'This is usually a truncated copy — check the braces at the very end.',
      'Fix the file; you do not need to reinstall the app or subscribe again.',
    ].join('\n'),
  );
}

if (!subscription?.endpoint) {
  fail(
    [
      `${SUBSCRIPTION_FILE} parsed but has no "endpoint".`,
      'Save the whole object the probe printed, not just part of it.',
    ].join('\n'),
  );
}

// Guarded because this validates the keys and throws, and an unguarded throw prints a
// stack trace as the primary message — which the spec rules out for operator errors.
// A trailing space picked up while copying a long base64 key lands exactly here.
try {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
} catch (error) {
  fail(
    [
      `VAPID details rejected: ${error.message}`,
      'Check for a stray space or newline picked up when copying the keys, and that',
      'VAPID_SUBJECT is a mailto: or https: URL.',
    ].join('\n'),
  );
}

// The send time is in the body on purpose: after a reboot it is the only way to
// tell a fresh delivery from a notification left over from before.
const sentAt = new Date().toLocaleTimeString('en-GB');
const payload = JSON.stringify({
  title: 'todoapp',
  body: `Test push, ${sentAt}. Reading this on the lock screen means the channel works.`,
});

try {
  const result = await webpush.sendNotification(subscription, payload);
  console.log(`status: ${result.statusCode}`);
  console.log(`body: ${result.body || '(empty)'}`);
  console.log(`sent at: ${sentAt}`);
  console.log('\nRecord this in _bmad-output/implementation-artifacts/story-1-2-findings.md');
} catch (error) {
  console.error(`status: ${error.statusCode ?? '(none)'}`);
  console.error(`body: ${error.body ?? String(error)}`);
  if (error.statusCode === 404 || error.statusCode === 410) {
    console.error(
      '\n404/410 means the subscription is gone. This is a material finding, not a bug to retry:\n' +
        'record it and stop before building anything else on this channel.',
    );
  }
  process.exit(1);
}
