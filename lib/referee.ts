/**
 * The Referee: his own account, his own way in, and the two numbers his home surface may
 * say (Story 4.5, FR-19).
 *
 * The server is the sole judge (AD-1). Every eligibility rule around pairing — that the
 * caller is a live doer, that no second referee exists — lives in `pair-referee`'s own Edge
 * Function, mirroring the split `lib/appeal.ts` already draws: this module carries only
 * what the client actually owns, the shape of what it sends, and the copy.
 */

import type { CommitmentOutcome } from './chain';
import type { PenaltyState } from './ledger';
import { formatDong } from './money';
import { ZONE, dayInQuestion } from './declaration';

/** What Settings sends to the `pair-referee` Edge Function. Nothing else — the function
 *  derives everything about eligibility itself, never trusting a client-sent role or flag. */
export interface PairReferee {
  email: string;
}

/** The loosest check worth running before spending a round trip — the server is the real
 *  authority on whether an address is usable at all (mirrors `sign-in.tsx`'s own `canSubmit`). */
export function isPairableEmail(email: string): boolean {
  return email.includes('@');
}

/** What the Edge Function returns on success: an account and a password shown exactly once. */
export interface PairedReferee {
  email: string;
  password: string;
}

function hasStringField<K extends string>(value: unknown, key: K): value is Record<K, string> {
  return (
    typeof value === 'object' &&
    value !== null &&
    key in value &&
    typeof (value as Record<string, unknown>)[key] === 'string'
  );
}

/** `hasStringField`, plus refusing an empty string — a field present but blank is not a
 *  usable value, and treating it as one is how `{email: '', password: ''}` would have been
 *  rendered as a real, successful pairing. Only used by `isPairedReferee` below: the error
 *  path's own `{error: string}` body has no equivalent "empty means absent" reading — an
 *  empty error message is still a message the server chose to send. */
function hasNonEmptyStringField<K extends string>(
  value: unknown,
  key: K,
): value is Record<K, string> {
  return hasStringField(value, key) && value[key].length > 0;
}

/** Whether an Edge Function response body is the success shape, narrowed rather than cast.
 *  Requires both fields to be non-empty — a blank email or password is not a real pairing,
 *  and falls through to `REFEREE_PAIRING_COPY.noPassword` the same as a missing field would. */
export function isPairedReferee(data: unknown): data is PairedReferee {
  return hasNonEmptyStringField(data, 'email') && hasNonEmptyStringField(data, 'password');
}

/**
 * What one call to `supabase.functions.invoke('pair-referee', ...)` failed with, as a
 * sentence rather than a thrown class name.
 *
 * `functions.invoke` never rejects on a non-2xx response — it resolves with `error` set,
 * and the response body (the function's own `{ error: string }`) is reachable only through
 * `error.context`, a `Response` the caller has to read itself. Reading a `Response` body is
 * the one place this needs to be async; everything else in this module is pure.
 */
export async function refereeFunctionErrorMessage(
  error: { message?: string; context?: unknown } | null,
): Promise<string> {
  const fallback = error?.message ?? REFEREE_PAIRING_COPY.unreachable;
  const context = error?.context;

  if (!context || typeof (context as { json?: unknown }).json !== 'function') {
    return fallback;
  }

  try {
    const body: unknown = await (context as { json: () => Promise<unknown> }).json();
    if (hasStringField(body, 'error')) return body.error;
    return fallback;
  } catch {
    // The body was not JSON, or was already consumed. The generic message stands in.
    return fallback;
  }
}

/** Every string the Settings pairing row says. Kept here for the reason `APPEAL_COPY` gives:
 *  copy rules, testable independent of a component. */
export const REFEREE_PAIRING_COPY = {
  rowName: 'Referee',
  consequence:
    'The person who rules on a contested miss and collects what you owe. Paired once — ' +
    'there is no unpair or re-pair yet.',
  emailPlaceholder: 'referee@example.com',
  pair: 'Pair referee',
  pairing: 'Pairing…',
  failed: 'Not paired.',
  unreachable: 'The server could not be reached.',
  noPassword: 'The server did not return a password.',
  shownOnce:
    'Shown once. Relay it however you choose — text, call, in person. It is never emailed.',
  passwordLabel: 'One-time password:',
  paired: (email: string) => `Paired as ${email}.`,
} as const;

/** Every string the Referee's own login screen says (`components/referee-login.tsx`). No
 *  "Create account" path here — pairing is the only way a Referee account is ever made
 *  (Never boundary), so this screen offers sign-in and nothing else. */
export const REFEREE_LOGIN_COPY = {
  title: 'Referee sign-in',
  submit: 'Sign in',
  submitting: 'Signing in…',
  failed: 'Failed.',
  noSession:
    'Account found, but no session was issued. Ask the doer to re-pair if this keeps happening.',
} as const;

/** One row of `penalty_current`, the only shape `components/referee-home.tsx` reads.
 *  `state` is `lib/ledger.ts`'s own `PenaltyState`, not a redefined copy — a future state
 *  that type gains (`collected`, 4.7; `waived`, 5.1) becomes a compile error in the switch
 *  below rather than a row that silently counts toward neither total. */
export interface RefereePenaltyRow {
  state: PenaltyState;
  amountDong: number;
}

export interface RefereeSummary {
  pendingAppeals: number;
  owedCount: number;
  owedTotalDong: number;
}

/**
 * The two counts FR-19's home surface may show, and nothing else.
 *
 * `held` is exactly "pending appeal": `appeal_hold_penalty()` (Story 4.4) is the only writer
 * that ever moves a penalty to `held`, and it does so in the same transaction as the appeal
 * row, so counting held penalties counts open appeals without a second query joining
 * `appeal` at all. `dropped` (a timed-out appeal, resolved in the author's favour) is read
 * but deliberately excluded from both counts — it is neither pending nor owed.
 *
 * The `switch` is exhaustive on `PenaltyState` on purpose: a state this function does not
 * yet know what to do with fails the build rather than silently vanishing from both counts,
 * understating what the referee is shown.
 */
export function summarizeReferee(rows: readonly RefereePenaltyRow[]): RefereeSummary {
  let pendingAppeals = 0;
  let owedCount = 0;
  let owedTotalDong = 0;

  for (const row of rows) {
    switch (row.state) {
      case 'held':
        pendingAppeals++;
        break;
      case 'owed':
        owedCount++;
        owedTotalDong += row.amountDong;
        break;
      case 'dropped':
        break;
      // Story 4.6: a penalty the referee's own "He did it" ruling voided. Excluded from
      // both counts for the same reason `dropped` is — resolved, and not owed — though in
      // practice this state never actually reaches `penalty_current` (the read this
      // function's only caller passes through): a voided penalty belongs to a settlement
      // the ruling's own correction superseded, and penalty_current follows the chain
      // (20260825090000). The case exists so this exhaustive switch still compiles now
      // that PenaltyState carries it, and so a state that did somehow arrive here would
      // read as resolved rather than crash the home screen.
      case 'voided':
        break;
      // Story 4.7: mark_penalty_collected()'s own owed -> collected transition. Excluded
      // from both counts for the same reason `dropped`/`voided` are — resolved, and the
      // debt has changed hands, not owed any longer.
      case 'collected':
        break;
      // Story 5.1: the author's own Grace Day, folded in by apply_grace_days(). Excluded
      // from both counts for the same reason `dropped`/`voided`/`collected` are — resolved,
      // and never owed any longer. Unlike `voided`, a waived penalty is NOT structurally
      // unreachable here: apply_grace_days() gives the corrective settlement its own fresh
      // penalty row, already waived, specifically so penalty_current actually carries it
      // (20260825110000) — so this case is reachable in practice, even though the referee
      // never sees a waived Penalty as owed.
      case 'waived':
        break;
      default: {
        const exhaustive: never = row.state;
        throw new Error(`summarizeReferee: unhandled penalty state ${String(exhaustive)}`);
      }
    }
  }

  return { pendingAppeals, owedCount, owedTotalDong };
}

/** Every string `components/referee-home.tsx` says. Scoped to what `appeal`/`penalty_current`
 *  already answer (Boundaries): no live commitment count, no email-channel promise — neither
 *  exists yet for anyone, referee or author. */
export const REFEREE_HOME_COPY = {
  title: 'Referee',
  loading: 'Working…',
  failed: 'Failed.',
  signOut: 'Sign out',
  empty: 'Nothing for you right now. 0 appeals pending, 0 penalties owed.',
  pendingAppeals: (count: number): string => `${count} appeal${count === 1 ? '' : 's'} pending.`,
  owedPenalties: (count: number, totalLabel: string): string =>
    `${count} penalt${count === 1 ? 'y' : 'ies'} owed, ${totalLabel} total.`,
  appealsHeading: 'Pending appeals',
  openAppeal: 'Open',
  /** Story 6.7. A door, not a queue item: it names no day, carries no count and states no
   *  number of anything, because the moment this screen could say "3 days you might question"
   *  it would be the list this story exists not to build. */
  lookUpDay: 'Look up a day',
  /**
   * Story 5.3, FR-18 — verbatim from `epic-5-context.md`'s UX & Interaction Patterns and
   * `EXPERIENCE.md:128` (Referee escalation), with `${days}` filling the day count where
   * that copy's own worked example names a fixed "four", and `He` standing in for the
   * `[Author]` placeholder those planning docs use — the same pronoun
   * `REFEREE_APPEAL_DETAIL_COPY` already uses for the doer throughout ("He did it", "He has
   * been notified") rather than a name this schema never stores. States only the day count
   * (Always boundary): no amount, no missed commitment, no action asked of him — the only
   * message that asks the referee to act as a person rather than process a queue.
   */
  goneQuiet: (days: number): string =>
    `He hasn't opened this in ${days} days. Nothing needs deciding — but he'd probably ` +
    `rather hear from you than from the app.`,
} as const;

/**
 * How many days a Silence episode has run, from its own `started_day` up to the migration's
 * own `asked_day` — inclusive of both ends, matching `asked_day - started_day + 1`
 * (`20260826100000_the_friend_is_told_i_have_disappeared.sql`). `asked_day` is *yesterday*
 * in the product's fixed zone, not today: `dayInQuestion()` (`lib/declaration.ts`) is the
 * same "agrees with the database trigger" derivation `enqueue_gate_reminders()` uses for its
 * own `local_now::date - 1`. Using today's own calendar day here instead would read one day
 * higher than the number the email actually named, for every hour of the day the escalation
 * fires. `now` is a parameter, never read from the system clock directly, so this is
 * exercised the same deterministic way every other date rule in this file is
 * (`formatOwedDay`, `collectionMessage`).
 */
export function daysSinceQuiet(startedDay: string, now: Date): number {
  const [sy, sm, sd] = startedDay.split('-').map(Number);
  const askedDay = dayInQuestion(now);
  const [ay, am, ad] = askedDay.split('-').map(Number);

  const startedUtc = Date.UTC(sy, sm - 1, sd);
  const askedUtc = Date.UTC(ay, am - 1, ad);

  return Math.round((askedUtc - startedUtc) / 86_400_000) + 1;
}

/**
 * One row of `components/referee-home.tsx`'s own pending-appeals list (Story 4.6) — day and
 * commitment name, the two facts the list itself shows, and the id the detail link needs.
 * `commitmentName` is always present in practice (the referee's own full-row `commitment`
 * read, Story 4.5) — typed as possibly missing only because a PostgREST embed resolves to
 * `null` when a joined row cannot be read, so a component reading it has one place to decide
 * what an absent name renders as rather than every caller inventing its own fallback.
 */
export interface PendingAppealRow {
  id: string;
  forDay: string;
  commitmentName: string | null;
}

/**
 * One row of `components/referee-home.tsx`'s own "Owed penalties" list (Story 4.7, FR-21) —
 * amount, day and every commitment `referee_missed_commitments()` (a `security definer`
 * function, scoped to `outcome = 'missed'` and `kind = 'day'` — never a new RLS policy on
 * `settlement_commitment` itself, which is also `chain_current`'s own base table) names for
 * the Penalty's own settlement, joined rather than picking one — a day's settlement can
 * cover more than one missed commitment even though `penalty` itself is 1:1 with
 * `settlement` (Story 4.6's own established fact). Every owed Penalty appears here
 * regardless of kind — a week-kind one (Week Close, 3.4) has to be just as collectible as a
 * day-kind one, or it sits owed forever with no control that can ever discharge it — but
 * `missedCommitments` is empty for one, since Week Close freezes no per-commitment outcome
 * to name; the component falls back to a generic label rather than fabricating a commitment
 * list. Oldest first (`created_at` ascending) is the list's own sort, not a field carried
 * here.
 */
export interface OwedPenaltyRow {
  id: string;
  forDay: string;
  amountDong: number;
  missedCommitments: string[];
}

/**
 * What `components/referee-appeal-detail.tsx` reads for one appeal: the machine's call, the
 * amount and day it names, the ruling's own current outcome, and the deadline the timeout
 * note names. `penaltyState` is derived through `settlement_current`/`penalty_current` —
 * never the base penalty table directly (this codebase's one-door-per-table rule,
 * `lib/chain.test.ts`) — by checking whether the appeal's own settlement has since been
 * superseded by the ruling's own correction (`20260825090000_the_referee_rules.sql`): a won
 * appeal's original Penalty belongs to that superseded row and drops out of `penalty_current`
 * entirely, so "the settlement moved" is the first signal read, not a state value on a row
 * that view can no longer see.
 *
 * **That signal alone is no longer sufficient (Story 5.1).** A later Grace Day can *also*
 * supersede the same settlement, unrelated to this appeal's own ruling — and only ever on
 * top of a *rejected* appeal (`grace_day_validate()`'s own Never boundary excludes a `held`
 * Penalty, so a Grace Day can never land on one still under appeal). `apply_grace_days()`
 * always gives its own correction a fresh penalty row already `waived`
 * (`20260825110000`) — unlike an approval correction's own penalty, which is `owed` or
 * absent entirely, never `waived` — so once the settlement is found to have moved, reading
 * the *current* settlement's own penalty state is what actually tells the two causes apart:
 * `'waived'` means a Grace Day did this, not the ruling, and `penaltyState` reads `'waived'`
 * to say so; anything else (or no row at all) means the ruling itself approved it, and
 * `penaltyState` reads `'voided'` exactly as before.
 */
export interface RefereeAppealDetail {
  id: string;
  forDay: string;
  commitmentName: string | null;
  amountDong: number;
  penaltyState: PenaltyState;
  deadline: string;
}

/** One piece of evidence, resolved to a URL the referee's own browser can actually load —
 *  the bucket is private, so the row `evidence` carries is a storage path, never a
 *  URL by itself. */
export interface RefereeEvidenceItem {
  id: string;
  url: string;
}

/** The rejection sentence, named once — `REFEREE_APPEAL_DETAIL_COPY.gracedAfterRejection`
 *  below composes from this rather than repeating its literal text, so the two can never
 *  drift out of sync if the wording ever changes. */
const REJECTED_SENTENCE = 'Converted to owed. He has been notified.';

/**
 * Every string `components/referee-appeal-detail.tsx` says (Story 4.6, FR-20).
 *
 * Kept here for the reason every other `*_COPY` object in this codebase gives: copy rules,
 * testable independent of a component.
 */
export const REFEREE_APPEAL_DETAIL_COPY = {
  loading: 'Working…',
  failed: 'Failed.',
  notFound: 'No such appeal, or it is no longer yours to read.',
  back: 'Back to appeals',

  /** The machine's own call, stated the same way `lib/appeal.ts`'s own `APPEAL_COPY.claim`
   *  is to the author — which commitment, which day, that the linked check reported it
   *  missed. Never a fabricated observed/required figure (UX-DR25's own quantified example
   *  — "Location saw you for 4 minutes. It needed 30." — does not apply: `account_elsewhere`,
   *  the only Auto-check kind that exists, has no such numbers to show). */
  machineCall: (commitmentName: string | null, forDay: string): string =>
    `${commitmentName ?? 'A commitment'}, ${forDay}. Account elsewhere reported a miss.`,

  evidenceHeading: 'Evidence',
  noEvidence: 'No evidence attached.',
  /** Distinguishes one attachment from another for a screen-reader user — identical alt
   *  text on every image reads as one image repeated, not several. 1-indexed to match how
   *  the count itself is said out loud ("photo 1 of 3"), never a 0-indexed position. */
  evidenceAlt: (position: number, total: number): string =>
    `Evidence photo ${position} of ${total} the doer submitted with this appeal.`,
  /** Signing can fail per item (a stale/expired path, a transient storage error) without
   *  failing the whole screen — surfaced as a count rather than silently shrinking the
   *  list, which would be indistinguishable from nothing ever having been attached. */
  evidenceLoadFailed: (count: number): string =>
    `${count} evidence item${count === 1 ? '' : 's'} could not be loaded.`,

  /** Written for the referee's own benefit (epic-4-context.md, UX & Interaction Patterns):
   *  he is not a bottleneck, and the deadline already decides this without him. */
  timeoutNote: (deadline: string): string =>
    `Ignore this and it's dropped in his favor on ${deadline}.`,

  /** UX-DR24: plain language, never "approve"/"reject". */
  approve: 'He did it',
  reject: "He didn't",
  ruling: 'Ruling…',

  approved: 'Voided. He has been notified.',
  rejected: REJECTED_SENTENCE,

  /** The rare landing here after the buttons stopped rendering: the deadline (or a second
   *  ruling call) already resolved this one in the author's favour before this one reached
   *  it — FR-15's own promise, not a failure of this screen. */
  timedOut:
    'This one is no longer open — it timed out and dropped in his favor before you got to it.',

  /** Story 4.7: this appeal's own Penalty was rejected ("He didn't"), then later marked
   *  Collected from the "Owed penalties" list — reachable by revisiting this screen
   *  afterward (a bookmark, browser back, or simply opening it again). Without this branch
   *  `penaltyState === 'collected'` matched none of the others above and the outcome area
   *  silently went blank. */
  collected: 'Collected. The referee marked this debt paid.',

  /** Story 5.1: this appeal was rejected ("He didn't") — the ruling itself never changed —
   *  and the day was *separately* forgiven afterward by the doer's own Grace Day, which can
   *  only ever reach an `owed` Penalty (never a `held` one an appeal could still be open
   *  against). Distinct from `approved` on purpose: the referee never ruled this one in the
   *  doer's favour, and never received the "He did it" notification `approved` implies — the
   *  Grace Day sends none at all (this story's own Never boundary). */
  gracedAfterRejection: `${REJECTED_SENTENCE} The day was later forgiven by a Grace Day, unrelated to this appeal.`,
} as const;

/**
 * A day an owed Penalty stems from, with its year — unlike `lib/appeal.ts`'s own
 * `formatDeadline` (`"Aug 18"`), which deliberately omits the year because an Appeal's own
 * deadline is always a few days out and the year is never in question. An owed Penalty is
 * the opposite case by design (this story's own Never boundary: "never written off
 * automatically" — a debt persists indefinitely), so two rows more than a year apart must
 * not render identically, and the collection message must not name an ambiguous date for a
 * debt that has sat unpaid a long time. A dedicated formatter rather than adding an option to
 * `formatDeadline` itself, so its own other callers (the Appeal deadline note, the pending
 * appeals list) are untouched.
 */
export function formatOwedDay(day: Date): string {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: ZONE,
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  }).format(day);
}

/**
 * The collection message (Story 4.7, FR-21) — verbatim from `epic-4-context.md`'s UX &
 * Interaction Patterns, with `formatDong`/`formatOwedDay` filling in the amount and day
 * rather than the planning doc's own literal comma-grouped figure (confirmed with the human
 * before drafting — the story's own Ask First is "None" for exactly this reason). Attributes
 * the demand to the app, never the referee ("I'm just the one collecting it"), and is placed
 * on the clipboard unchanged — no compose field, no editable message (Never boundary).
 */
export function collectionMessage(amountDong: number, forDay: Date): string {
  return (
    `todoapp says you owe ${formatDong(amountDong)} for ${formatOwedDay(forDay)}. ` +
    `I'm just the one collecting it. When are you free?`
  );
}

/**
 * Every string `components/referee-home.tsx`'s own "Owed penalties" list says (Story 4.7).
 * Kept here for the reason every other `*_COPY` object in this codebase gives: copy rules,
 * testable independent of a component.
 */
export const OWED_PENALTIES_COPY = {
  heading: 'Owed penalties',

  copy: 'Copy message',
  copied: 'Copied.',
  /** The first clipboard use in this codebase — an unsupported browser, a denied
   *  permission, or an insecure context all reject the same way. Surfaced as a status
   *  message, never silently, matching the failure-surfacing bar Story 4.6 set for evidence
   *  loading (`REFEREE_APPEAL_DETAIL_COPY.evidenceLoadFailed`). */
  copyFailed: 'Could not copy the message.',

  markCollected: 'Mark Collected',
  marking: 'Marking…',
  markFailed: 'Failed.',
} as const;

/**
 * One row of `referee_day_lookup()` (Story 6.7) — one commitment on one settled day the referee
 * named himself, what that day recorded for it, when the 48-hour objection window closes, and
 * whether the day has already been objected to.
 *
 * The function returns facts rather than an `objectable` verdict on purpose: `object_to_day()` is
 * the sole judge (AD-1) and refuses each case in its own words. `objectionIsOffered` below mirrors
 * those facts only to decide whether the control renders at all, exactly as `lib/ledger.ts`'s own
 * `graceable` mirrors `grace_day_validate()`.
 */
export interface RefereeDayRow {
  settlementId: string;
  commitmentId: string;
  commitmentName: string;
  outcome: CommitmentOutcome;
  /** ISO instant. `objection_deadline()`'s own value, computed server-side from the settlement's
   *  `settled_at` — never re-derived here, so the screen and the function cannot disagree about
   *  when the window shuts. */
  objectionDeadline: string;
  alreadyObjected: boolean;
}

/**
 * Whether this row may still be objected to — the three conditions `object_to_day()` checks that
 * a client can honestly see: the day recorded `held` for this commitment, nobody has objected to
 * the day yet, and the window is still open.
 *
 * Deliberately NOT a full mirror. It does not know whether the day's penalty has been collected,
 * and it must not try to: a `collected` penalty is terminal and this feature never reads one. That
 * case comes back as the server's own refusal, shown verbatim, the same way
 * `components/referee-appeal-detail.tsx` shows a lost race rather than pre-computing it.
 *
 * `now` is a parameter, never the system clock, so the window boundary is exercised
 * deterministically the way every other date rule in this file is.
 */
export function objectionIsOffered(row: RefereeDayRow, now: Date): boolean {
  return (
    row.outcome === 'held' &&
    !row.alreadyObjected &&
    new Date(row.objectionDeadline).getTime() > now.getTime()
  );
}

/**
 * Every string `components/referee-day-lookup.tsx` says (Story 6.7, the referee's half).
 *
 * **There is no list here, and none of this copy implies one.** No count, no badge, no "days
 * awaiting you", no empty state that reads as a queue drained. He arrives at a day by typing its
 * date, because he already has a reason to — he was there, or the author told him. A page of the
 * author's days to work through is a queue in everything but name, and the whole design rests on
 * his never being sent one.
 */
export const REFEREE_DAY_COPY = {
  title: 'Look up a day',
  back: 'Back',
  /** States the pull, so the absence of a list reads as the design it is rather than as a screen
   *  that failed to load something. */
  intro:
    'Type the date of a day you have a reason to question. Nothing is queued for you and ' +
    'nothing is waiting — a day nobody objects to holds.',
  dateLabel: 'Date',
  look: 'Look up',
  looking: 'Working…',
  failed: 'Failed.',
  /** Not "no days found" — that phrasing implies there is a set of days to be found in. */
  nothing: 'Nothing has been settled for that date.',
  outcome: (outcome: CommitmentOutcome): string =>
    outcome === 'held' ? 'Held' : outcome === 'missed' ? 'Missed' : 'Unanswered',
  /** The window, in his own terms. He is never asked to act before it closes; it simply says
   *  when the day stops being his to question. */
  window: (deadline: string): string => `You can object until ${formatWindowClose(deadline)}.`,
  windowClosed: 'The window on this day has closed. It stands.',
  alreadyObjected: 'You have already objected to this day.',
  notHeld: 'This day did not hold anyway. There is nothing to object to.',
  reasonLabel: 'Why does that day not hold?',
  reasonPlaceholder: 'I was with him all morning. He never took it.',
  object: 'Object to this day',
  objecting: 'Objecting…',
  /**
   * Final when he makes it, and said so plainly: there is no ruling step after this, and the
   * author's recourse is his own Grace Day, not a reply to the referee.
   *
   * **Neither sentence claims a new charge**, because often there is not one. `object_to_day()`
   * carries an already-owed penalty forward rather than minting a second (FR-13), so a day that
   * had already failed costs exactly what it cost before — and `objection_body()`, the sentence
   * the *author* receives, is careful to distinguish the two. Copy on this side that said "he is
   * charged for it" would tell the referee he had just taken 500.000₫ off somebody on the days he
   * had not. What is true in both cases is that the day becomes a failed day whose penalty stands
   * against him, and that a Grace Day is the only thing that answers it.
   */
  objected: 'Objected. That day is now a failed day, and he has been told, in your words.',
  finalWarning:
    'This is final. That day becomes a failed day and its penalty stands against him — his ' +
    'only remedy is a Grace Day of his own.',
} as const;

/** The bound `objection_reason_is_said` enforces, mirrored client-side so the `<textarea>` can
 *  stop him at the limit rather than let the server refuse a sentence he has already written.
 *  `object_to_day()` refuses an over-long reason in words of its own regardless — this is the
 *  courtesy, that is the guarantee. */
export const OBJECTION_REASON_MAX = 2000;

/** The objection window's own closing instant, as a sentence a person reads — date and clock
 *  time, in the product's fixed zone (AD-6). `formatOwedDay` above states a day and never a time;
 *  a window that closes at a particular hour needs the hour, or "until Sep 3" is ambiguous by
 *  twenty-four hours in exactly the direction that matters. */
export function formatWindowClose(deadline: string): string {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: ZONE,
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(deadline));
}
