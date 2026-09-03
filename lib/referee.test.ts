import { describe, expect, it } from 'vitest';
import {
  REFEREE_HOME_COPY,
  collectionMessage,
  daysSinceQuiet,
  formatOwedDay,
  isPairableEmail,
  isPairedReferee,
  refereeFunctionErrorMessage,
  summarizeReferee,
  OBJECTION_REASON_MAX,
  REFEREE_DAY_COPY,
  formatWindowClose,
  objectionIsOffered,
  type RefereeDayRow,
} from './referee';

describe('isPairableEmail', () => {
  it('accepts anything that looks like an address, leaving real validation to the server', () => {
    expect(isPairableEmail('ref@example.com')).toBe(true);
  });

  it('refuses what could not possibly be one', () => {
    expect(isPairableEmail('not an email')).toBe(false);
    expect(isPairableEmail('')).toBe(false);
  });
});

describe('isPairedReferee', () => {
  it('recognises the success shape', () => {
    expect(isPairedReferee({ email: 'ref@example.com', password: 'abc123' })).toBe(true);
  });

  it('refuses anything missing either field, rather than reading undefined as a password', () => {
    expect(isPairedReferee({ email: 'ref@example.com' })).toBe(false);
    expect(isPairedReferee({ password: 'abc123' })).toBe(false);
    expect(isPairedReferee(null)).toBe(false);
    expect(isPairedReferee('a string')).toBe(false);
  });

  it('refuses an empty email or password rather than rendering a blank pairing as real', () => {
    expect(isPairedReferee({ email: '', password: '' })).toBe(false);
    expect(isPairedReferee({ email: '', password: 'abc123' })).toBe(false);
    expect(isPairedReferee({ email: 'ref@example.com', password: '' })).toBe(false);
  });
});

describe('refereeFunctionErrorMessage', () => {
  it('reads the function’s own {error} body off a Response-shaped context', async () => {
    const error = {
      message: 'Edge Function returned a non-2xx status code',
      context: {
        json: () => Promise.resolve({ error: 'Only the doer account may pair a referee.' }),
      },
    };
    expect(await refereeFunctionErrorMessage(error)).toBe(
      'Only the doer account may pair a referee.',
    );
  });

  it('falls back to the generic message when there is no context to read', async () => {
    expect(await refereeFunctionErrorMessage({ message: 'network down' })).toBe('network down');
  });

  it('falls back rather than throwing when the context body is not JSON', async () => {
    const error = {
      message: 'network down',
      context: { json: () => Promise.reject(new Error('not JSON')) },
    };
    expect(await refereeFunctionErrorMessage(error)).toBe('network down');
  });

  it('never throws on a null error', async () => {
    await expect(refereeFunctionErrorMessage(null)).resolves.toEqual(expect.any(String));
  });
});

describe('summarizeReferee', () => {
  it('reads zero appeals pending and zero owed from an empty read', () => {
    expect(summarizeReferee([])).toEqual({
      pendingAppeals: 0,
      owedCount: 0,
      owedTotalDong: 0,
    });
  });

  it('counts held penalties as pending appeals — appeal_hold_penalty is the only writer of held', () => {
    const summary = summarizeReferee([
      { state: 'held', amountDong: 500_000 },
      { state: 'held', amountDong: 500_000 },
    ]);
    expect(summary.pendingAppeals).toBe(2);
    expect(summary.owedCount).toBe(0);
  });

  it('counts and totals owed penalties separately from held ones', () => {
    const summary = summarizeReferee([
      { state: 'owed', amountDong: 500_000 },
      { state: 'owed', amountDong: 500_000 },
      { state: 'held', amountDong: 500_000 },
    ]);
    expect(summary.owedCount).toBe(2);
    expect(summary.owedTotalDong).toBe(1_000_000);
    expect(summary.pendingAppeals).toBe(1);
  });

  it('excludes dropped penalties from both counts — a timeout resolved them in the author’s favour', () => {
    const summary = summarizeReferee([{ state: 'dropped', amountDong: 500_000 }]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 0, owedTotalDong: 0 });
  });

  it('excludes voided penalties from both counts — a won appeal resolved them, too', () => {
    // Unreachable through a real penalty_current read (a voided penalty's own settlement is
    // superseded by the ruling's own correction — 20260825090000), but the switch this
    // function runs is exhaustive on PenaltyState, so this still has to compile and resolve
    // sensibly rather than fall through to the `default` throw.
    const summary = summarizeReferee([{ state: 'voided', amountDong: 500_000 }]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 0, owedTotalDong: 0 });
  });

  it('excludes collected penalties from both counts — the debt has changed hands (Story 4.7)', () => {
    const summary = summarizeReferee([
      { state: 'collected', amountDong: 500_000 },
      { state: 'owed', amountDong: 500_000 },
    ]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 1, owedTotalDong: 500_000 });
  });

  it('excludes waived penalties from both counts — a Grace Day resolved them, never owed (Story 5.1)', () => {
    const summary = summarizeReferee([
      { state: 'waived', amountDong: 500_000 },
      { state: 'owed', amountDong: 500_000 },
    ]);
    expect(summary).toEqual({ pendingAppeals: 0, owedCount: 1, owedTotalDong: 500_000 });
  });
});

describe('formatOwedDay', () => {
  it('includes the year, unlike formatDeadline', () => {
    expect(formatOwedDay(new Date('2026-08-18T00:00:00Z'))).toBe('Aug 18, 2026');
  });

  it('distinguishes two rows more than a year apart that formatDeadline would render identically', () => {
    const thisYear = formatOwedDay(new Date('2026-08-18T00:00:00Z'));
    const lastYear = formatOwedDay(new Date('2025-08-18T00:00:00Z'));
    expect(thisYear).not.toBe(lastYear);
  });
});

describe('collectionMessage', () => {
  it('reuses formatDong/formatOwedDay — the exact money formatting used everywhere else, plus the year', () => {
    // Verbatim from epic-4-context.md, with the planning doc's own literal comma-grouped
    // "500,000" replaced by formatDong's dot-grouped "500.000₫" (confirmed with the human),
    // and the day carrying its year — an owed Penalty persists indefinitely (this story's
    // own "never written off automatically"), so a bare "Aug 18" would be ambiguous for a
    // debt sitting unpaid more than a year.
    expect(collectionMessage(500_000, new Date('2026-08-18T00:00:00Z'))).toBe(
      "todoapp says you owe 500.000₫ for Aug 18, 2026. I'm just the one collecting it. When are you free?",
    );
  });

  it('attributes the demand to the app, never the referee', () => {
    const message = collectionMessage(500_000, new Date('2026-08-18T00:00:00Z'));
    expect(message).toMatch(/^todoapp says you owe/);
    expect(message).toContain("I'm just the one collecting it.");
  });

  it('names every amount distinctly — a different amount reads a different message', () => {
    const a = collectionMessage(500_000, new Date('2026-08-18T00:00:00Z'));
    const b = collectionMessage(1_000_000, new Date('2026-08-18T00:00:00Z'));
    expect(a).not.toBe(b);
  });
});

describe('daysSinceQuiet (Story 5.3)', () => {
  it('counts inclusively from asked_day (yesterday), matching the migration’s own arithmetic exactly', () => {
    // 20260826100000_the_friend_is_told_i_have_disappeared.sql escalates at exactly
    // asked_day - started_day >= 3, where asked_day is *yesterday* in the fixed zone
    // (enqueue_gate_reminders()'s own local_now::date - 1) — never today. "now" here is
    // 10:00 on the 23rd, so asked_day is the 22nd; started_day the 19th is 3 days before
    // that, i.e. day 4 inclusive — the exact figure the SQL formula would also produce for
    // the same instant.
    expect(daysSinceQuiet('2026-08-19', new Date('2026-08-23T10:00:00+07:00'))).toBe(4);
  });

  it('reads 1 when started_day is asked_day itself — never 0', () => {
    expect(daysSinceQuiet('2026-08-22', new Date('2026-08-23T10:00:00+07:00'))).toBe(1);
  });

  it('is computed in Asia/Ho_Chi_Minh, not a naive UTC day', () => {
    // 20:00 UTC on the 22nd is already 03:00 on the 23rd in Ho Chi Minh City (UTC+7), so
    // asked_day (yesterday, zone-correct) is the 22nd — the same asked_day the first test
    // above reaches from a different instant, and the same answer (4) it must produce here
    // too. A naive UTC-based "yesterday" would instead read the 22nd's own UTC calendar day
    // minus one (the 21st), undercounting by one.
    expect(daysSinceQuiet('2026-08-19', new Date('2026-08-22T20:00:00Z'))).toBe(4);
  });
});

describe('REFEREE_HOME_COPY.goneQuiet (Story 5.3, FR-18)', () => {
  it('states the real day count, no amount, no missed commitment', () => {
    expect(REFEREE_HOME_COPY.goneQuiet(4)).toBe(
      "He hasn't opened this in 4 days. Nothing needs deciding — but he'd probably rather " +
        'hear from you than from the app.',
    );
  });

  it('names a different count distinctly — never a hardcoded "four"', () => {
    expect(REFEREE_HOME_COPY.goneQuiet(4)).not.toBe(REFEREE_HOME_COPY.goneQuiet(9));
    expect(REFEREE_HOME_COPY.goneQuiet(9)).toContain('9 days');
  });

  it('asks him for no action — no verb of its own beyond hearing from him', () => {
    const message = REFEREE_HOME_COPY.goneQuiet(4);
    expect(message).not.toMatch(/₫/);
    expect(message).not.toMatch(/mark|collect|rule|approve|reject/i);
  });
});

/**
 * Story 6.7 — the referee's own half.
 *
 * `objectionIsOffered` is a mirror, never a judge: `object_to_day()` checks the role, the window,
 * a day corrected since he read it, an outcome that is not held and a penalty already collected,
 * each in its own words. What is asserted here is that the mirror is narrower than the server on
 * purpose (it never reasons about a collected penalty, which is terminal and which this feature
 * never reads) and that the copy carries no list, no count and no badge — the property the whole
 * design rests on.
 */
const heldRow: RefereeDayRow = {
  settlementId: 's1',
  commitmentId: 'c1',
  commitmentName: 'Pill',
  outcome: 'held',
  objectionDeadline: '2026-09-05T03:00:00Z',
  alreadyObjected: false,
};

describe('objectionIsOffered (Story 6.7)', () => {
  it('offers the control on a day that held, inside the window, nobody has objected to', () => {
    expect(objectionIsOffered(heldRow, new Date('2026-09-04T00:00:00Z'))).toBe(true);
  });

  it('withdraws it once the window has closed, to the instant', () => {
    // Half-open, matching objection_deadline()'s own `now() >= deadline` comparison: the last
    // instant inside is offered, the deadline itself is not.
    expect(objectionIsOffered(heldRow, new Date('2026-09-05T02:59:59Z'))).toBe(true);
    expect(objectionIsOffered(heldRow, new Date('2026-09-05T03:00:00Z'))).toBe(false);
  });

  it('withdraws it once the day has been objected to — one objection per day', () => {
    expect(
      objectionIsOffered({ ...heldRow, alreadyObjected: true }, new Date('2026-09-04T00:00:00Z')),
    ).toBe(false);
  });

  it('never offers it against a day that did not hold — there is nothing to overturn', () => {
    for (const outcome of ['missed', 'unanswered'] as const) {
      expect(objectionIsOffered({ ...heldRow, outcome }, new Date('2026-09-04T00:00:00Z'))).toBe(
        false,
      );
    }
  });
});

describe('formatWindowClose', () => {
  it('names the hour as well as the day, in the fixed zone the product uses', () => {
    // 03:00 UTC is 10:00 in Ho Chi Minh City. A window that closes at a particular hour needs
    // the hour, or "until Sep 5" is ambiguous by a day in exactly the direction that matters.
    expect(formatWindowClose('2026-09-05T03:00:00Z')).toBe('Sep 5, 10:00');
  });
});

describe('REFEREE_DAY_COPY (Story 6.7)', () => {
  it('says the referee is not being queued, in the copy itself', () => {
    expect(REFEREE_DAY_COPY.intro).toMatch(/nothing is waiting/i);
    expect(REFEREE_DAY_COPY.intro).toMatch(/a day nobody objects to holds/i);
  });

  it('carries no count and no badge anywhere', () => {
    // A page of the author's days to work through is a queue in everything but name, and copy
    // that says "3 days pending" is that page whether or not one is rendered. The intro's own
    // "nothing is queued for you" is the denial, not the thing -- so what is banned here is a
    // number, and any word that asserts something is waiting on him.
    //
    // Only the fixed sentences: the two functions here fill in a commitment's own outcome and
    // the instant one window shuts, both of which are facts about a day he already named rather
    // than a tally of days he has not.
    for (const value of Object.values(REFEREE_DAY_COPY)) {
      if (typeof value !== 'string') continue;
      expect(value).not.toMatch(/[0-9]/);
      expect(value).not.toMatch(/(pending|awaiting|outstanding|unreviewed)/i);
    }
  });

  it('says an objection is final before it is made, and that the remedy is his own', () => {
    expect(REFEREE_DAY_COPY.finalWarning).toMatch(/final/i);
    expect(REFEREE_DAY_COPY.finalWarning).toMatch(/grace day/i);
  });

  it('tells him the author was told in his own words, not the app copy', () => {
    expect(REFEREE_DAY_COPY.objected).toMatch(/in your words/i);
  });
});

describe('REFEREE_HOME_COPY.lookUpDay (Story 6.7)', () => {
  it('is a door and never a count — the home surface gains no list', () => {
    expect(REFEREE_HOME_COPY.lookUpDay).toBe('Look up a day');
    expect(REFEREE_HOME_COPY.lookUpDay).not.toMatch(/[0-9]/);
  });
});

describe('REFEREE_DAY_COPY does not promise a charge that often is not made', () => {
  // object_to_day() carries an already-owed penalty forward rather than minting a second
  // (FR-13), so an objection on a day that had already failed costs exactly what it cost
  // before. objection_body() -- the sentence the author receives -- distinguishes the two
  // cases carefully; copy on the referee's side that said "he is charged for it" would tell
  // him he had just taken 500.000 dong off somebody on the days he had not.
  it('never claims money changed hands, on either sentence', () => {
    for (const text of [REFEREE_DAY_COPY.finalWarning, REFEREE_DAY_COPY.objected]) {
      expect(text).not.toMatch(/charged|costs what|now costs|500/i);
    }
  });

  it('still says what is true in both cases: a failed day, answerable only by a Grace Day', () => {
    expect(REFEREE_DAY_COPY.finalWarning).toMatch(/failed day/i);
    expect(REFEREE_DAY_COPY.finalWarning).toMatch(/grace day/i);
    expect(REFEREE_DAY_COPY.objected).toMatch(/failed day/i);
  });
});

describe('OBJECTION_REASON_MAX', () => {
  it('mirrors the bound objection_reason_is_said enforces', () => {
    expect(OBJECTION_REASON_MAX).toBe(2000);
  });
});
