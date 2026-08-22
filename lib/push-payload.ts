/**
 * Turns a raw push payload into the title and body a notification will show.
 *
 * This lives here rather than in the service worker because a service worker is
 * reachable only from a real device — and on iOS, only from an installed one.
 * A rule that can only be exercised by rebooting a phone is a rule that never
 * gets exercised, so the decision is made here as a pure function and tested,
 * and `app/sw.ts` is left with nothing but the plumbing.
 */

export interface PushNotificationContent {
  title: string;
  body: string;
}

/**
 * Shown when the payload cannot be understood.
 *
 * There is deliberately no "silent" option. The subscription is made with
 * `userVisibleOnly`, which promises a visible notification for every push; a
 * push that shows nothing can cost the subscription, and a lost subscription
 * looks exactly like the delivery failure Story 1.2 exists to detect. Showing
 * the wrong words is recoverable. Showing nothing is not.
 */
export const PUSH_FALLBACK: PushNotificationContent = {
  title: 'todoapp',
  body: 'A push arrived, but its payload could not be read.',
};

/** Rejects the empty string too: a blank notification is as useless as none. */
function usableString(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== '';
}

/**
 * Resolves what to show, field by field.
 *
 * Falls back per field rather than all-or-nothing: a payload carrying a good
 * body and a missing title should still deliver the body, which is the half
 * that has to be legible on a lock screen.
 */
export function resolvePushContent(raw: string | null | undefined): PushNotificationContent {
  if (!usableString(raw)) return PUSH_FALLBACK;

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return PUSH_FALLBACK;
  }

  if (typeof parsed !== 'object' || parsed === null) return PUSH_FALLBACK;

  const { title, body } = parsed as { title?: unknown; body?: unknown };

  return {
    title: usableString(title) ? title : PUSH_FALLBACK.title,
    body: usableString(body) ? body : PUSH_FALLBACK.body,
  };
}
