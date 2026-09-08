import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereeDayLookup } from './referee-day-lookup';
import { OBJECTION_REASON_MAX } from '@/lib/referee';

/**
 * The referee looks up one day (Story 6.7).
 *
 * **What this file is really asserting is an absence.** The referee is never sent a queue: with no
 * action from him at all, every proven day settles held. So this screen must reach a day only by
 * his naming it — no list, no count, no badge, nothing rendered before he asks — and the tests
 * below check that nothing appears until he types a date and presses Look up, and that the copy
 * itself never implies a set of days waiting for him.
 *
 * **The server is the sole judge (AD-1).** `object_to_day()` refuses a closed window, a day
 * corrected since he read it, an outcome that is not held and a penalty already collected, each in
 * its own words. This screen mirrors only the three facts `referee_day_lookup()` hands back, and
 * only to decide whether the control renders; a refusal it cannot foresee is shown verbatim and
 * never reloads the row away.
 */

const getUser = vi.fn();
const rpc = vi.fn();
let profileResult: unknown = { data: { role: 'referee' }, error: null };
let settlementResult: unknown = { data: [{ id: 's1' }], error: null };
let lookupResult: unknown = { data: [], error: null };
let objectResult: unknown = { data: null, error: null };
/** Retro item 43. `createSignedUrls` reports per item, so a failure is an entry with no
 *  `signedUrl` rather than a shorter list — the shape the screen counts unopenable photos from. */
let signedUrlsResult: unknown = { data: [], error: null };
const createSignedUrls = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    auth: { getUser },
    from: (table: string) => {
      if (table === 'profile') {
        return { select: () => ({ maybeSingle: () => Promise.resolve(profileResult) }) };
      }
      // settlement_current — `.select('id').eq('kind', 'day').eq('period', day)`, where the last
      // call in the chain resolves. A thenable chain, matching the shape the component builds.
      const query: Record<string, unknown> = {};
      query.select = () => query;
      query.eq = () => query;
      query.then = (resolve: (value: unknown) => unknown) =>
        Promise.resolve(settlementResult).then(resolve);
      return query;
    },
    rpc: (name: string, ...args: unknown[]) => {
      rpc(name, ...args);
      if (name === 'referee_day_lookup') return Promise.resolve(lookupResult);
      return Promise.resolve(objectResult);
    },
    storage: {
      from: () => ({
        createSignedUrls: (paths: string[], ttl: number) => {
          createSignedUrls(paths, ttl);
          return Promise.resolve(signedUrlsResult);
        },
      }),
    },
  }),
}));

const replace = vi.fn();
const push = vi.fn();
// A single, stable object — real `useRouter()` returns a stable reference across renders, and a
// fresh one each call would re-trigger the effect's `[router]` dependency forever.
const router = { replace, push };

vi.mock('next/navigation', () => ({ useRouter: () => router }));

/** Far enough in the future that the window is open for every test that does not say otherwise. */
const OPEN = '2099-01-01T00:00:00Z';

function heldRow(overrides: Record<string, unknown> = {}) {
  return {
    commitment_id: 'c1',
    commitment_name: 'Pill',
    outcome: 'held',
    objection_deadline: OPEN,
    already_objected: false,
    evidence_paths: [],
    ...overrides,
  };
}

/** What `createSignedUrls` returns for paths that sign cleanly. */
function signed(...paths: string[]) {
  return { data: paths.map((p) => ({ path: p, signedUrl: `https://signed/${p}` })), error: null };
}

beforeEach(() => {
  getUser.mockResolvedValue({ data: { user: { id: 'ref' } }, error: null });
  profileResult = { data: { role: 'referee' }, error: null };
  settlementResult = { data: [{ id: 's1' }], error: null };
  lookupResult = { data: [], error: null };
  objectResult = { data: null, error: null };
  signedUrlsResult = { data: [], error: null };
});

afterEach(() => {
  vi.clearAllMocks();
});

async function lookUp(day = '2026-09-01') {
  const user = userEvent.setup();
  render(<RefereeDayLookup />);
  const field = await screen.findByLabelText('Date');
  // `type="date"` inputs take the ISO value directly; userEvent.type would fight the mask.
  await user.clear(field);
  await user.type(field, day);
  await user.click(screen.getByRole('button', { name: 'Look up' }));
  return user;
}

describe('the referee is never sent a queue', () => {
  it('renders nothing about any day until he names one himself', async () => {
    lookupResult = { data: [heldRow()], error: null };
    render(<RefereeDayLookup />);

    await screen.findByLabelText('Date');

    // Not one commitment, not one outcome, not one count — and crucially not the "nothing
    // settled" empty state either, which would read as a queue he has already drained.
    expect(screen.queryByText('Pill')).not.toBeInTheDocument();
    expect(screen.queryByText(/Nothing has been settled/)).not.toBeInTheDocument();
    expect(rpc).not.toHaveBeenCalled();
  });

  it('says so in the copy: nothing is queued and a day nobody objects to holds', async () => {
    render(<RefereeDayLookup />);
    const intro = await screen.findByText(/Nothing is queued for you/);
    expect(intro).toHaveTextContent('a day nobody objects to holds');
  });

  it('asks about exactly the settlement he named, one at a time', async () => {
    lookupResult = { data: [heldRow()], error: null };
    await lookUp();

    await screen.findByText('Pill');
    expect(rpc).toHaveBeenCalledWith('referee_day_lookup', { p_settlement_id: 's1' });
  });

  it('says nothing settled for a date with no day, without implying a list', async () => {
    settlementResult = { data: [], error: null };
    await lookUp();

    expect(await screen.findByText('Nothing has been settled for that date.')).toBeInTheDocument();
    expect(rpc).not.toHaveBeenCalled();
  });
});

describe('what the day recorded, and whether it can be objected to', () => {
  it('offers a reason field and the control on a day that held', async () => {
    lookupResult = { data: [heldRow()], error: null };
    await lookUp();

    expect(await screen.findByText('Pill')).toBeInTheDocument();
    expect(screen.getByLabelText('Why does that day not hold?')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Object to Pill/ })).toBeInTheDocument();
  });

  it('warns that it is final and that the remedy is the author’s own, before he presses it', async () => {
    lookupResult = { data: [heldRow()], error: null };
    await lookUp();

    const warning = await screen.findByText(/This is final/);
    expect(warning).toHaveTextContent(/Grace Day/);
  });

  it('offers nothing against a day that did not hold', async () => {
    lookupResult = { data: [heldRow({ outcome: 'missed' })], error: null };
    await lookUp();

    expect(await screen.findByText(/nothing to object to/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Object to/ })).not.toBeInTheDocument();
  });

  it('offers nothing once the window has closed, and says the day stands', async () => {
    lookupResult = {
      data: [heldRow({ objection_deadline: '2020-01-01T00:00:00Z' })],
      error: null,
    };
    await lookUp();

    expect(await screen.findByText(/window on this day has closed/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Object to/ })).not.toBeInTheDocument();
  });

  it('offers nothing on a day already objected to — one objection per day', async () => {
    lookupResult = { data: [heldRow({ already_objected: true })], error: null };
    await lookUp();

    expect(await screen.findByText(/already objected to this day/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Object to/ })).not.toBeInTheDocument();
  });

  it('will not send an objection with no reason — the server requires one either way', async () => {
    lookupResult = { data: [heldRow()], error: null };
    await lookUp();

    await screen.findByText('Pill');
    expect(screen.getByRole('button', { name: /Object to Pill/ })).toBeDisabled();
  });
});

describe('what the day was proved with (epic 6 retrospective, item 43)', () => {
  it('shows the photo the claim was proved with', async () => {
    lookupResult = { data: [heldRow({ evidence_paths: ['d1/e1.jpg'] })], error: null };
    signedUrlsResult = signed('d1/e1.jpg');
    await lookUp();

    const photo = await screen.findByAltText('The photo this day was proved with');
    expect(photo).toHaveAttribute('src', 'https://signed/d1/e1.jpg');
  });

  it('numbers them when there is more than one', async () => {
    lookupResult = {
      data: [heldRow({ evidence_paths: ['d1/a.jpg', 'd1/b.jpg'] })],
      error: null,
    };
    signedUrlsResult = signed('d1/a.jpg', 'd1/b.jpg');
    await lookUp();

    expect(await screen.findByAltText('Proof photo 1 of 2')).toBeInTheDocument();
    expect(screen.getByAltText('Proof photo 2 of 2')).toBeInTheDocument();
  });

  it('renders nothing at all for a day with no proof', async () => {
    // A day that never needed a photo must not read as a day missing one — no placeholder, no
    // empty frame, and no signing call either.
    lookupResult = { data: [heldRow()], error: null };
    await lookUp();

    expect(await screen.findByText('Pill')).toBeInTheDocument();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
    expect(createSignedUrls).not.toHaveBeenCalled();
  });

  it('signs every photo on the day in one call, never one per photo', async () => {
    // The lesson `readKeptPhotos` already learned: a ten-photo day was ten round trips.
    lookupResult = {
      data: [
        heldRow({ evidence_paths: ['d1/a.jpg'] }),
        heldRow({ commitment_id: 'c2', commitment_name: 'Gym', evidence_paths: ['d2/b.jpg'] }),
      ],
      error: null,
    };
    signedUrlsResult = signed('d1/a.jpg', 'd2/b.jpg');
    await lookUp();

    await screen.findByText('Gym');
    expect(createSignedUrls).toHaveBeenCalledTimes(1);
    expect(createSignedUrls).toHaveBeenCalledWith(['d1/a.jpg', 'd2/b.jpg'], 3600);
  });

  it('reports a photo that would not sign, and still shows the ones that did', async () => {
    lookupResult = {
      data: [heldRow({ evidence_paths: ['d1/a.jpg', 'd1/broken.jpg'] })],
      error: null,
    };
    signedUrlsResult = {
      data: [
        { path: 'd1/a.jpg', signedUrl: 'https://signed/d1/a.jpg' },
        { path: 'd1/broken.jpg', signedUrl: null, error: 'not found' },
      ],
      error: null,
    };
    await lookUp();

    expect(await screen.findByAltText('The photo this day was proved with')).toBeInTheDocument();
    expect(screen.getByText('One photo on this day could not be opened.')).toBeInTheDocument();
  });

  it('does not fail the lookup when signing fails outright', async () => {
    // The outcomes and the objection window are what he came for and are already in hand. A
    // screen that failed here would tell him nothing about a day it had already read.
    lookupResult = { data: [heldRow({ evidence_paths: ['d1/a.jpg'] })], error: null };
    signedUrlsResult = { data: null, error: { message: 'storage down' } };
    await lookUp();

    expect(await screen.findByText('Pill')).toBeInTheDocument();
    expect(screen.getByText('One photo on this day could not be opened.')).toBeInTheDocument();
    expect(screen.queryByText(/storage down/)).not.toBeInTheDocument();
  });
});

describe('objecting', () => {
  it('sends the settlement, the commitment and his own words unchanged', async () => {
    lookupResult = { data: [heldRow()], error: null };
    const user = await lookUp();

    await screen.findByText('Pill');
    await user.type(
      screen.getByLabelText('Why does that day not hold?'),
      'I was with him all morning.',
    );
    await user.click(screen.getByRole('button', { name: /Object to Pill/ }));

    await waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('object_to_day', {
        p_settlement_id: 's1',
        p_commitment_id: 'c1',
        p_reason: 'I was with him all morning.',
      }),
    );
  });

  it('stops offering the control once it has landed, and says the author was told', async () => {
    lookupResult = { data: [heldRow()], error: null };
    const user = await lookUp();

    await screen.findByText('Pill');
    await user.type(screen.getByLabelText('Why does that day not hold?'), 'He never took it.');
    await user.click(screen.getByRole('button', { name: /Object to Pill/ }));

    expect(await screen.findByText(/he has been told, in your words/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Object to/ })).not.toBeInTheDocument();
  });

  it('shows the server’s own refusal verbatim and leaves the row where it was', async () => {
    // The cases this screen deliberately cannot foresee: a penalty already collected (terminal,
    // and never read by this feature), or a day corrected between his reading it and objecting.
    lookupResult = { data: [heldRow()], error: null };
    objectResult = {
      data: null,
      error: { message: "That day's penalty has already been collected." },
    };
    const user = await lookUp();

    await screen.findByText('Pill');
    await user.type(screen.getByLabelText('Why does that day not hold?'), 'Objecting anyway.');
    await user.click(screen.getByRole('button', { name: /Object to Pill/ }));

    expect(await screen.findByText(/already been collected/)).toBeInTheDocument();
    // Still there, with its control, rather than vanishing with no explanation.
    expect(screen.getByRole('button', { name: /Object to Pill/ })).toBeInTheDocument();
  });
});

describe('who may reach this screen at all', () => {
  it('sends a signed-out visitor to the referee sign-in', async () => {
    getUser.mockResolvedValue({ data: { user: null }, error: null });
    render(<RefereeDayLookup />);

    await waitFor(() => expect(replace).toHaveBeenCalledWith('/referee/login'));
    expect(screen.queryByLabelText('Date')).not.toBeInTheDocument();
  });

  it('sends a doer session home without rendering the lookup — RLS is the real boundary', async () => {
    profileResult = { data: { role: 'doer' }, error: null };
    render(<RefereeDayLookup />);

    await waitFor(() => expect(replace).toHaveBeenCalledWith('/'));
    expect(screen.queryByLabelText('Date')).not.toBeInTheDocument();
  });
});

describe('the refusals this screen keeps human, and the ones it leaves to the server', () => {
  it('stops him writing past the bound the column enforces, rather than letting a 23514 through', async () => {
    lookupResult = { data: [heldRow()], error: null };
    await lookUp();

    await screen.findByText('Pill');
    expect(screen.getByLabelText('Why does that day not hold?')).toHaveAttribute(
      'maxlength',
      String(OBJECTION_REASON_MAX),
    );
  });

  it('announces the rows it found, not only the fact that it found none', async () => {
    // The empty branch carries role="status" already; the one case where something actually
    // came back must not be the silent one.
    lookupResult = { data: [heldRow()], error: null };
    await lookUp();

    await screen.findByText('Pill');
    expect(screen.getByRole('status')).toHaveTextContent('Pill');
  });

  it('stops offering every other commitment on a day one objection has spoken for', async () => {
    // objection_once_per_day is (subject, for_day), never per commitment: once one commitment
    // on the day is objected to, a control on any other row could only ever come back
    // "already objected to".
    lookupResult = {
      data: [heldRow(), heldRow({ commitment_id: 'c2', commitment_name: 'Gym' })],
      error: null,
    };
    const user = await lookUp();

    await screen.findByText('Gym');
    expect(screen.getByRole('button', { name: /Object to Gym/ })).toBeInTheDocument();

    // Two rows, so two textareas share the label text. The first is Pill's.
    await user.type(
      screen.getAllByLabelText('Why does that day not hold?')[0],
      'He never took it.',
    );
    await user.click(screen.getByRole('button', { name: /Object to Pill/ }));

    await screen.findByText(/he has been told, in your words/i);
    expect(screen.queryByRole('button', { name: /Object to Gym/ })).not.toBeInTheDocument();
    expect(screen.getByText(/already objected to this day/i)).toBeInTheDocument();
  });
});
