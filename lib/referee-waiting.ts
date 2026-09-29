/**
 * Story 8.6 — whether the author's referee has looked at today's photograph yet.
 *
 * The answer is `waiting_on_my_referee()`, which reads the same definition the referee's own list
 * does (`commitment_days_waiting_on_referee()`), so the author is told his referee has not looked
 * at exactly the rows his referee is shown. Nothing here derives it: a row is waiting because the
 * server says so, never because this screen noticed a photo and a flag.
 */
import { createClient } from '@/lib/supabase/client';

/**
 * One answer, stamped with the local day it was read for.
 *
 * The stamp is what lets Today discard an answer read before midnight — the ids survive the
 * rollover, and a screen left open would otherwise go on saying yesterday's photo is unlooked-at
 * on today's row. The same shape `reachRead` has in `components/today.tsx`, for the same reason.
 */
export interface WaitingRead {
  day: string;
  ids: ReadonlySet<string>;
}

/**
 * Reads which of the author's commitments are waiting on his referee today.
 *
 * **Stamped with the server's day, not the device's.** `waiting_on_my_referee()` returns the day it
 * answered for beside each id, so a read sent just before midnight and answered just after carries
 * the day it is really about. An empty answer has no row to carry a day on, so it takes the day
 * asked for — which is harmless, because an empty answer shows nothing on any day.
 *
 * **A failed read is `null`, never an error on the screen.** The line this drives is information,
 * and its absence costs nothing: the day holds whether or not he is told that his referee has not
 * looked. `null` rather than an empty set so that Today can keep an answer it already has for the
 * same day instead of letting one dropped request take the line away while nothing has changed.
 */
export async function readWaitingOnReferee(askedFor: string): Promise<WaitingRead | null> {
  try {
    const { data, error } = await createClient().rpc('waiting_on_my_referee');
    if (error || !Array.isArray(data)) return null;

    const rows = data.filter(
      (row): row is { commitment_id: string; for_day: string } =>
        typeof row === 'object' &&
        row !== null &&
        typeof (row as { commitment_id?: unknown }).commitment_id === 'string' &&
        typeof (row as { for_day?: unknown }).for_day === 'string',
    );

    return { day: rows[0]?.for_day ?? askedFor, ids: new Set(rows.map((r) => r.commitment_id)) };
  } catch {
    return null;
  }
}

/**
 * What Today says on a row whose referee has not looked yet (CAP-8).
 *
 * **Information about his friend, never a task for him.** A row that says *waiting* invites him to
 * go and chase his friend, which is the opposite of what silence-approves exists for — so the
 * sentence never says it. It states the fact (he has not looked), the rule as an outcome (if he
 * never does, the day holds), and closes the door on chasing without naming a chore. The voice is
 * `REFEREE_SIGN_OFF_COPY.warning`'s, which told him when he turned sign-off on that reminding his
 * referee is not his job; EXPERIENCE.md's referee timeout note is the model for the register.
 *
 * It does not mention a refusal. That is true and it is not this sentence's to say: the author was
 * told what a refusal costs when he turned the flag on, and repeating it beside every photo would
 * turn information into worry.
 */
export const WAITING_ON_REFEREE_COPY = {
  line:
    'Your referee hasn’t looked at this yet. If he never does, it holds at midnight on your ' +
    'photo — nothing here needs you.',
} as const;
