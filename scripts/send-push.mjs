// Sends one Web Push to the saved subscription and reports exactly what the push
// service said.
//
// This is the operator-driven half of Story 1.2. It exists to answer one question
// — does a push reach a locked iPhone, and does it keep working after a reboot —
// so it never retries, never smooths over a failure, and exits non-zero when the
// send does not succeed. A silent retry would hide the finding this story is for.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import webpush from 'web-push';

const SUBSCRIPTION_FILE = join(process.cwd(), '.push-subscription.json');

function fail(message) {
  console.error(message);
  process.exit(1);
}

const { VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT } = process.env;
if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY || !VAPID_SUBJECT) {
  fail(
    'Missing VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY or VAPID_SUBJECT.\n' +
      'Generate a pair with `npx web-push generate-vapid-keys` and set them in your environment.',
  );
}

let subscription;
try {
  subscription = JSON.parse(readFileSync(SUBSCRIPTION_FILE, 'utf8'));
} catch {
  fail(
    `No subscription at ${SUBSCRIPTION_FILE}.\n` +
      'Open the app from its home-screen icon, tap "Subscribe this device", and save the JSON there.',
  );
}

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

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
