/**
 * A session is a recorded start instant, not a running process.
 *
 * The acceptance criteria ask for a timer that survives backgrounding, a locked phone and the
 * app being killed, and that nothing pauses, flags or invalidates. The way to get all of that
 * is to run nothing at all: tapping start writes `{key, commitmentId, startedAt}` to this
 * device's storage, and the screen renders `now − startedAt` whenever it happens to be looked
 * at. A killed app, a locked phone and a five-hour background are then the same event —
 * nothing was running, so nothing stopped.
 *
 * It is also why nothing here can detect inattention. There is no `visibilitychange`, no wake
 * lock and no heartbeat, because a timer that polices is a timer he stops starting, and not
 * starting is the only real failure this story is about.
 *
 * **The cost, stated rather than hidden.** A running session lives only in this device's local
 * storage until it is stopped. Clearing that storage mid-session loses the session. The
 * alternative — a row at start, updated at stop — was rejected because it puts an update policy
 * on an insert-only schema, and because a start tapped offline could not be updated by a stop
 * tapped offline: the queue would be carrying a correction to a row that does not exist yet.
 *
 * `Storage` is injected rather than reached for, the same arrangement `lib/offline-queue.ts`
 * uses, so every rule below is exercisable without a browser.
 */

import { type QueueItem, readQueue } from './offline-queue';

/** What is written when start is tapped, and nothing else. */
export interface RunningSession {
  /** Minted at the *start* tap and reused by the stop and by every retry of it (AD-4). */
  idempotencyKey: string;
  commitmentId: string;
  /** ISO-8601. The instant he tapped start. */
  startedAt: string;
}

/** One stopped session, waiting for a network. Both instants, and the key from the start tap. */
export interface QueuedFocusSession extends QueueItem {
  ownerId: string;
  commitmentId: string;
  startedAt: string;
  stoppedAt: string;
}

/** Where the running session lives. One at a time — there is one author and one clock. */
export const RUNNING_KEY = 'todoapp.focus-session.v1';

/** Stopped sessions with nowhere to go yet. Its own queue, sharing the queue's rules. */
export const FOCUS_QUEUE_KEY = 'todoapp.focus-session-queue.v1';

/**
 * Every string this surface says, including the ones it only says when something is wrong.
 *
 * The four labels originate in `EXPERIENCE.md` — the unwatched sentence and *Stop and bank it*
 * were already specified there, and *Start the clock*, *Banked today* and the already-running
 * refusal were added to it in this story's own commit rather than invented in JSX and
 * backfilled. Copy written in a component and documented afterwards is how the two documents
 * stop being one contract.
 *
 * The failure sentences live here for the reason `lib/settings.ts` gives about its own: they
 * are copy rules, and a rule that cannot be tested is a rule that erodes. It is also what keeps
 * a raw `String(error)` — a JavaScript exception with a stack in it — off a screen the author
 * opens under reluctance.
 */
export const FOCUS_COPY = {
  start: 'Start the clock',
  stop: 'Stop and bank it',
  /** Shown on the Stop button itself while the tap is still in flight, alongside `aria-busy`. */
  stopping: 'Stopping…',
  banked: 'Banked today',
  unwatched: "Keeps running while your phone is locked. Nothing here watches what you're doing.",

  /** The tap that cannot start anything, because another commitment's clock is already going. */
  alreadyElsewhere: 'A clock is already running on another commitment. Stop that one first.',

  /** Over anything the screen could not read. The same word the rest of the app uses. */
  failed: 'Failed.',

  /** Over a session the server refused. Never "Saved" — nothing was. */
  notBanked: 'Not banked.',

  queuedOffline:
    'Saved on this device — there is no connection right now. It will go when there is one, dated when you started.',

  /**
   * Said when the day's total could not be read but a session can still be run and stopped.
   * Losing the total is an inconvenience; losing the ability to bank the work is the story.
   */
  stillRuns:
    'The clock still runs, and stopping still banks. The total will catch up when there is a connection.',

  /**
   * This screen was opened for something that cannot carry sessions at all. Every
   * `daily_hours_quota` commitment has a target by the biconditional check in
   * `20260819150000_commitment.sql`, so a missing one is never a quieter version of the screen —
   * it means the row is not what this surface is for, or could not be read as itself.
   */
  notAnHoursQuota:
    'This is not a Put hours in commitment, so no time can be banked against it. Go back to today and open it from its own row.',

  /** Storage blocked, or no crypto outside a secure context. The tap must not look ignored. */
  deviceRefused:
    'This device would not record the session. Private browsing and blocked storage both do that, and nothing can be timed until it is allowed.',

  /** When a refusal arrives carrying no message of its own. */
  serverRefused: 'The server refused this session.',
} as const;

/**
 * How the running figure is announced.
 *
 * The figure is a number that changes every second, and a bare one reads as a quantity of
 * something unnamed — the same problem `lib/settings.ts` solved by rendering `07:00` rather
 * than `7`. `components/debt-block.tsx` set the pattern for the other claimant of this type
 * role: label the element and hide the raw digits from the reader.
 */
export function elapsedLabel(seconds: number): string {
  return `Running ${formatElapsed(seconds)}.`;
}

export function readRunning(storage: Storage): RunningSession | null {
  const raw = storage.getItem(RUNNING_KEY);
  if (!raw) return null;

  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    const session = parsed as Partial<RunningSession>;
    // A record missing its start instant is not a session that started late — it is a record
    // that cannot say when, and rendering `now − undefined` would put a number on the screen
    // with nothing behind it.
    if (!session.idempotencyKey || !session.commitmentId || !session.startedAt) return null;
    return { ...session } as RunningSession;
  } catch {
    return null;
  }
}

/**
 * What a tap on start actually did. Three answers, because a tap that changes nothing must
 * never be indistinguishable from a tap that started the work.
 */
export type StartOutcome =
  /** Nothing was running. The clock is now going from this instant. */
  | { kind: 'started'; session: RunningSession }
  /** This commitment was already running. The earlier instant stands. */
  | { kind: 'already-running'; session: RunningSession }
  /** Another commitment's clock is going. Nothing was written, and the caller must say so. */
  | { kind: 'running-elsewhere'; session: RunningSession };

/**
 * Records a start, unless something is already running.
 *
 * A second tap on the *same* commitment keeps the earlier instant rather than restarting the
 * clock: the author cannot see a process to know one is going, and the work began at the first
 * tap. A tap while *another* commitment is running is refused outright and the foreign record
 * is handed back rather than returned as though it were this screen's — a screen that filtered
 * it out would leave a start control that does nothing at all, which on the one surface built
 * to make starting easy is the worst failure available.
 */
export function startSession(storage: Storage, session: RunningSession): StartOutcome {
  const existing = readRunning(storage);

  if (existing) {
    return existing.commitmentId === session.commitmentId
      ? { kind: 'already-running', session: existing }
      : { kind: 'running-elsewhere', session: existing };
  }

  storage.setItem(RUNNING_KEY, JSON.stringify(session));
  return { kind: 'started', session };
}

export function clearRunning(storage: Storage): void {
  storage.removeItem(RUNNING_KEY);
}

/**
 * How long the session has been going, in seconds.
 *
 * Two instants and a subtraction. Nothing accumulates, so nothing can be lost — a session read
 * back after the app was killed measures from the instant it was started, not from the instant
 * the screen came back.
 *
 * Never negative. A device whose clock jumps backwards mid-session would otherwise render a
 * figure counting down, and the database refuses that row anyway.
 */
export function elapsedSeconds(session: RunningSession, now: Date): number {
  const started = new Date(session.startedAt).getTime();
  return Math.max(0, Math.floor((now.getTime() - started) / 1000));
}

/**
 * A duration as `H:MM`. `0:00`, `0:50`, `10:05`.
 *
 * The product's one duration format, so the day's total, the target and the running figure all
 * read the same way. Hours are never padded and minutes always are, which is how a clock reads
 * and how `0:50 of 3:00` was specified in `EXPERIENCE.md` § KF-2.
 */
export function formatDuration(minutes: number): string {
  const whole = Math.max(0, Math.floor(minutes));
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
}

/**
 * The running figure, `H:MM:SS`.
 *
 * The one place seconds are shown, and the only reason they are: the acceptance criterion is
 * that tapping start makes the figure *run*. In `H:MM` it would read `0:00` for a full minute
 * after the tap, which on the one screen whose entire job is to make starting feel like
 * something happened would read as broken. Everywhere else — banked totals, targets — is
 * `H:MM`, because a total that ticks is a total that invites watching.
 */
export function formatElapsed(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(whole / 60);
  return `${formatDuration(minutes)}:${String(whole % 60).padStart(2, '0')}`;
}

/** The day's position against the quota: `0:50 of 3:00` (`EXPERIENCE.md` § KF-2). */
export function bankedAgainstTarget(minutes: number, targetMinutes: number): string {
  return `${formatDuration(minutes)} of ${formatDuration(targetMinutes)}`;
}

/**
 * The bar's fill, as a percentage clamped to the track it draws inside.
 *
 * `daily_minutes_target` is always positive on the one cadence that reaches this screen
 * (`commitment_daily_hours_target` in `20260819150000_commitment.sql`), so this never divides
 * by zero in practice — the zero-target guard exists so a bad read renders an empty bar rather
 * than throwing on a screen whose clock and Stop control must still work.
 *
 * Capped at 100 rather than left to overflow: banked exceeding target is a real state (spec
 * 3-2's matrix has 200 of 180) and the bar reads it as full, exactly as full as any other day
 * that met its target. The text beside it, not the bar, is what still says `3:20 of 3:00`.
 */
export function bankedPercent(minutes: number, targetMinutes: number): number {
  if (targetMinutes <= 0) return 0;
  const ratio = (Math.max(0, minutes) / targetMinutes) * 100;
  return Math.min(100, Math.max(0, ratio));
}

/**
 * What the screen may show while a stopped session is still queued.
 *
 * The database owns the day's total (AD-1) and this is the single exception, narrowly drawn: a
 * session stopped without a network has not reached `focus_day_minutes` yet, and a screen that
 * dropped it would be losing time it has already been told about, right after telling him it
 * was safely saved.
 *
 * Both halves are added **in seconds and floored once**, exactly as the view floors — adding
 * minutes to minutes would floor twice and lose up to another 59 seconds. This number is
 * displayed and never sent anywhere.
 */
export function shownMinutes(bankedSeconds: number, queuedSeconds: number): number {
  return Math.floor((Math.max(0, bankedSeconds) + Math.max(0, queuedSeconds)) / 60);
}

/**
 * Every stopped session still waiting for a network.
 *
 * The queue's own key, named once. Spelling `readQueue(storage, FOCUS_QUEUE_KEY)` at each call
 * site is how one of them eventually gets the declaration queue's key by default and starts
 * reading answers as if they were sessions.
 */
export function readStoppedSessions(storage: Storage): QueuedFocusSession[] {
  return readQueue<QueuedFocusSession>(storage, FOCUS_QUEUE_KEY);
}

/** The length of a stopped session, in seconds. Never negative, for the same reason. */
export function queuedSeconds(session: QueuedFocusSession): number {
  const started = new Date(session.startedAt).getTime();
  const stopped = new Date(session.stoppedAt).getTime();
  return Math.max(0, Math.floor((stopped - started) / 1000));
}
