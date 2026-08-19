/**
 * The sentence that ends the day.
 *
 * This is the intervention against the author's documented pattern — a bad day becoming a
 * bad week — and it has to work read from a lock screen, without the app being opened. So
 * the rules governing it are copy rules, and they are here as a function rather than in a
 * template because a rule you cannot test is a rule that erodes.
 *
 * From `EXPERIENCE.md`: the register is coach. Second person, short, present tense, no
 * threat. It speaks like someone who knows the history and is not scandalised by it.
 *
 * Three rules do the real work:
 *   - **Never itemise the misses.** State the count and the amount once, then name
 *     something that survived. A list of failures is what this message exists to replace.
 *   - **Exactly one suggestion**, naming a specific commitment. Two is a to-do list.
 *   - **The amount once, after the fact.** Never while asking a question — that is the
 *     morning gate's rule and this message is the only place money may be named at all.
 */

import { formatDong } from './money';

export interface DaySummary {
  /** `YYYY-MM-DD`, the day being summarised. */
  day: string;
  /** How many commitments were judged. */
  total: number;
  /** How many held. */
  held: number;
  /** The penalty, if the day failed. Null on a clean day. */
  amountDong: number | null;
  /** Names of commitments that held, in the order they should be preferred. */
  heldNames: readonly string[];
  /** The one commitment to start with tomorrow. */
  suggestion: string;
}

const WORDS = [
  'None',
  'One',
  'Two',
  'Three',
  'Four',
  'Five',
  'Six',
  'Seven',
  'Eight',
  'Nine',
  'Ten',
];

/** Small counts read as words, which is the register. Larger ones as digits, which is legible. */
export function countWord(n: number): string {
  return n >= 0 && n < WORDS.length ? WORDS[n] : String(n);
}

/**
 * The weekday a `YYYY-MM-DD` falls on.
 *
 * Built from the date parts in UTC rather than parsed as an instant, so no timezone gets a
 * say — the string already names a local day and converting it twice is how it moves.
 */
export function weekdayOf(day: string): string {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', {
    weekday: 'long',
    timeZone: 'UTC',
  });
}

/**
 * The summary body, legible in full on a lock screen.
 *
 * It names the day rather than the clock time. A reminder is about a moment and carries
 * `HH:MM`; this is about a day, and read the next morning "Four of five on Tuesday" is
 * unambiguous in a way "Four of five today" is not — which is what the self-dating rule was
 * always for.
 */
export function daySummaryBody(summary: DaySummary): string {
  const parts: string[] = [
    // Both counts as words — "Four of five", the way it is said aloud, not "Four of 5".
    `${countWord(summary.held)} of ${countWord(summary.total).toLowerCase()} on ${weekdayOf(summary.day)}.`,
  ];

  // The amount, once, plainly, after the fact.
  if (summary.amountDong !== null) {
    parts.push(`That's ${formatDong(summary.amountDong)}.`);
  }

  const survivor = summary.heldNames[0];

  if (survivor) {
    // Something that held, named — never a list of what did not.
    parts.push(`${survivor} held though.`);
    parts.push(
      survivor === summary.suggestion
        ? 'Start there tomorrow.'
        : `Start with ${summary.suggestion} tomorrow.`,
    );
  } else {
    // Nothing held. No false comfort — but still a place to start, which is the whole
    // reason this message exists rather than a verdict.
    parts.push(`Start with ${summary.suggestion} tomorrow.`);
  }

  return parts.join(' ');
}

/**
 * Every reason a summary body would break its own rules.
 *
 * Returns messages rather than a boolean, and is used by the tests rather than at runtime —
 * the body is built by the function above and cannot violate these, so this exists to fail
 * loudly if that stops being true.
 */
export function summaryProblems(summary: DaySummary, missedNames: readonly string[]): string[] {
  const body = daySummaryBody(summary);
  const problems: string[] = [];

  for (const missed of missedNames) {
    // The suggestion is exempt, and that is the rule rather than a loophole. "Start with
    // Gym tomorrow" when Gym was missed today is exactly the right sentence — the rule is
    // never to *list* the misses, not never to name one as a place to begin.
    if (missed === summary.suggestion) continue;

    if (body.includes(missed) && !summary.heldNames.includes(missed)) {
      problems.push(`The body itemises a miss: "${missed}".`);
    }
  }

  const amountMentions =
    summary.amountDong === null ? 0 : body.split(formatDong(summary.amountDong)).length - 1;
  if (amountMentions > 1) {
    problems.push('The amount is stated more than once.');
  }

  if (!body.includes(summary.suggestion)) {
    problems.push('The body names no commitment to start with.');
  }

  if (!body.includes(weekdayOf(summary.day))) {
    problems.push('The body does not name the day it is about.');
  }

  return problems;
}
