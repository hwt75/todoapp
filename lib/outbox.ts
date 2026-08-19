/**
 * The shape of an effect the outbox carries, and the rule Story 1.2 paid for.
 *
 * A push arrived minutes late during that story — queued while the phone was off Wi-Fi
 * after a reboot, delivered once it reconnected. It was late, not lost, which is the good
 * outcome. But it means a notification is read at a time the sender cannot know.
 *
 * So a payload states when it was sent, in its body as well as its metadata, and never
 * describes the present. "You have not answered yet" is a claim about a moment that may
 * have passed by the time it is read; "Yesterday is still unanswered as of 07:30" is not.
 */

export interface PushPayload {
  title: string;
  /** Legible on a lock screen with no interaction, and self-dating. */
  body: string;
  /** ISO-8601. The database refuses a payload without it. */
  sent_at: string;
}

/**
 * Words that make a notification describe the present.
 *
 * Deliberately small and deliberately blunt. It cannot catch every way of writing a claim
 * that expires, but it catches the ones people reach for first, and it fails loudly enough
 * that the next person thinks about it.
 */
const PRESENT_TENSE_TRAPS = ['right now', 'just now', 'currently', 'at the moment'];

export function payloadProblems(payload: PushPayload): string[] {
  const problems: string[] = [];

  if (payload.title.trim() === '') problems.push('A notification needs a title.');
  if (payload.body.trim() === '') problems.push('A notification needs a body.');

  if (Number.isNaN(Date.parse(payload.sent_at))) {
    problems.push('sent_at must be an ISO-8601 instant.');
  }

  const lower = payload.body.toLowerCase();
  for (const trap of PRESENT_TENSE_TRAPS) {
    if (lower.includes(trap)) {
      problems.push(
        `The body says "${trap}", which is a claim about the moment it is read rather ` +
          'than the moment it was sent. A push can arrive minutes late — Story 1.2 saw one do it.',
      );
    }
  }

  // The finding's other half: the reader has to be able to tell a fresh delivery from one
  // that has been sitting on the lock screen. That is only possible if the time is visible
  // without opening anything.
  if (!bodyStatesItsTime(payload)) {
    problems.push(
      'The body does not state the time it was sent, so a notification left on the lock ' +
        'screen cannot be told from a new one.',
    );
  }

  return problems;
}

/** True when the body contains the hour and minute of `sent_at`, in 24-hour form. */
export function bodyStatesItsTime(payload: PushPayload): boolean {
  const at = new Date(payload.sent_at);
  if (Number.isNaN(at.getTime())) return false;
  const hh = String(at.getHours()).padStart(2, '0');
  const mm = String(at.getMinutes()).padStart(2, '0');
  return payload.body.includes(`${hh}:${mm}`);
}

/** Builds a payload that satisfies the rules above, stamping the time into the body. */
export function buildPayload(title: string, sentence: string, at: Date): PushPayload {
  const hh = String(at.getHours()).padStart(2, '0');
  const mm = String(at.getMinutes()).padStart(2, '0');
  return {
    title,
    body: `${sentence} (${hh}:${mm})`,
    sent_at: at.toISOString(),
  };
}
