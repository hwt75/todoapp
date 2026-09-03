import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { CommitmentList } from './commitment-list';

/**
 * The surface for changing commitments, and the three writes underneath it.
 *
 * All three are decisions rather than plumbing, and none was checked by anything until now.
 *
 * **A create is an upsert that ignores a duplicate**, never an insert that raises one. AD-4 wants
 * a retried save to land once; a unique violation would land once and then tell the author his
 * save failed after it had already succeeded — the worse of the two lies on a screen about
 * commitments he is held to.
 *
 * **A delete is an archive.** Every declaration, failed day and penalty still points at the row.
 *
 * **Nothing filters by owner.** RLS decides what this account can see, and putting that decision
 * in the client is what AD-7 forbids — a filter here would look identical while being worth
 * nothing.
 */

const calls: { table: string; op: string; payload?: unknown; options?: unknown }[] = [];
/** The column string every read asked for — see `today.test.tsx`'s own note on why. */
const selected: string[] = [];
let listResult: unknown = { data: [], error: null };
let writeResult: unknown = { error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      const query = {
        select: (columns?: string) => {
          if (typeof columns === 'string') selected.push(columns);
          return query;
        },
        is: () => query,
        order: () => Promise.resolve(listResult),
        upsert: (payload: unknown, options: unknown) => {
          calls.push({ table, op: 'upsert', payload, options });
          return Promise.resolve(writeResult);
        },
        update: (payload: unknown) => {
          calls.push({ table, op: 'update', payload });
          return { eq: () => Promise.resolve(writeResult) };
        },
      };
      return query;
    },
  }),
}));

const gym = {
  id: 'c1',
  name: 'Gym',
  kind: 'do',
  cadence: 'weekly_quota',
  carries_penalty: true,
  weekly_target: 3,
  week_start_day: 1,
  daily_minutes_target: null,
  auto_check_kind: null,
  auto_check_account_ref: null,
  auto_check_last_checked_at: null,
  due_time: null,
  late_window_minutes: null,
  requires_photo: false,
};

beforeEach(() => {
  calls.length = 0;
  selected.length = 0;
  listResult = { data: [gym], error: null };
  writeResult = { error: null };
});

describe('the commitment list', () => {
  it('creates through an upsert that ignores a repeat rather than failing on it', async () => {
    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'New commitment' }));

    await userEvent.type(screen.getByLabelText('Name'), 'Reading');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    const write = calls.find((c) => c.op === 'upsert');
    expect(write?.table).toBe('commitment');
    expect(write?.options).toMatchObject({
      onConflict: 'idempotency_key',
      ignoreDuplicates: true,
    });
    // The key is generated at the moment of the action, so a retry of this same save
    // reuses it and cannot produce a second commitment (AD-4).
    expect(write?.payload).toMatchObject({ owner_id: 'u1', name: 'Reading' });
    expect((write?.payload as { idempotency_key: string }).idempotency_key).toBeTruthy();
  });

  it('never sends an owner or a key on an edit', async () => {
    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    const write = calls.find((c) => c.op === 'update');
    // Re-sending an owner would be a client deciding whose row this is, and re-sending a
    // key would collide with the create that already used it.
    expect(write?.payload).toMatchObject({ owner_id: undefined, idempotency_key: undefined });
  });

  it('deletes by archiving, and keeps the row', async () => {
    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));
    await userEvent.click(screen.getByRole('button', { name: 'Yes, delete it' }));

    const write = calls.find((c) => c.op === 'update');
    expect(Object.keys(write?.payload as object)).toEqual(['archived_at']);
    expect(calls.some((c) => c.op === 'delete')).toBe(false);
  });

  it('leaves the access decision to the database', async () => {
    render(<CommitmentList ownerId="u1" />);

    // A row that is not this account's is invisible rather than refused. Nothing here
    // narrows the read to an owner: filtering in the client would look the same on screen
    // and protect nothing (AD-7).
    expect(await screen.findByText('Gym')).toBeInTheDocument();
    expect(calls.some((c) => c.op === 'filter-by-owner')).toBe(false);
  });

  it('carries an existing commitment into the form rather than asking for it again', async () => {
    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));

    expect(screen.getByRole('heading', { name: 'Edit commitment' })).toBeInTheDocument();
    expect(screen.getByLabelText('Name')).toHaveValue('Gym');
    expect(screen.getByLabelText('Times a week')).toHaveValue(3);
    expect(screen.getByLabelText(/Missing this costs money/)).toBeChecked();
    // Not linked: the checkbox reads unchecked, not "checked because the field is missing".
    expect(screen.getByLabelText('Account elsewhere')).not.toBeChecked();
  });

  it('carries a linked Auto-check into the form, ref and last-read time included', async () => {
    listResult = {
      data: [
        {
          ...gym,
          auto_check_kind: 'account_elsewhere',
          auto_check_account_ref: 'my-handle',
          auto_check_last_checked_at: '2026-08-23T00:00:00Z',
        },
      ],
      error: null,
    };
    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));

    expect(screen.getByLabelText('Account elsewhere')).toBeChecked();
    expect(screen.getByLabelText('Account')).toHaveValue('my-handle');
    expect(screen.getByText(/Last read/)).toBeInTheDocument();
  });

  it('carries a time into the form as HH:MM, not as the HH:MM:SS the database sends', async () => {
    listResult = {
      data: [{ ...gym, due_time: '20:00:00', late_window_minutes: 30 }],
      error: null,
    };
    render(<CommitmentList ownerId="u1" />);

    // The line says it before anything is opened.
    expect(await screen.findByText(/20:00 \+30m/)).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Edit' }));

    // `<input type="time">` renders and produces HH:MM. Handing it the seconds Postgres sends
    // would make an edit that never touched the field send back something different.
    expect(screen.getByLabelText('Time of day')).toHaveValue('20:00');
    expect(screen.getByLabelText('Late window, in minutes')).toHaveValue(30);
  });

  it('says a linked commitment has not been read yet, before any pass has run', async () => {
    listResult = {
      data: [
        {
          ...gym,
          auto_check_kind: 'account_elsewhere',
          auto_check_account_ref: 'my-handle',
          auto_check_last_checked_at: null,
        },
      ],
      error: null,
    };
    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));

    // A freshly linked commitment must not claim a read that never happened.
    expect(screen.getByText('Not read yet.')).toBeInTheDocument();
    expect(screen.queryByText(/Last read/)).not.toBeInTheDocument();
  });

  it('says what failed instead of showing an empty list', async () => {
    listResult = { data: null, error: { message: 'permission denied' } };
    render(<CommitmentList ownerId="u1" />);

    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
  });

  it('surfaces a refused write rather than reporting a save that did not happen', async () => {
    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));

    writeResult = { error: { message: 'new row violates row-level security policy' } };
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText(/row-level security/)).toBeInTheDocument();
  });
});

/**
 * Story 6.8 — the flag survives the round trip, which is the only thing `toDraft` is for.
 *
 * The column is `not null default false`, so nothing here can fail loudly: a `toDraft` that
 * dropped it would render an unchecked box, an untouched save would send `false`, and the author
 * would find out by opening Today the next day and finding the control gone.
 */
describe('a commitment that already keeps a photo', () => {
  it('asks for the column, renders it checked, and sends it back untouched', async () => {
    listResult = { data: [{ ...gym, requires_photo: true }], error: null };

    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));

    // The read has to ask for it, or the checkbox below is drawn from a field the server never
    // sent and reads `false` for a commitment that really does keep a photo.
    expect(selected.some((columns) => columns.includes('requires_photo'))).toBe(true);
    expect(screen.getByLabelText('Keep a photo against this')).toBeChecked();

    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    const update = calls.find((c) => c.op === 'update');
    expect(update?.payload).toMatchObject({ requires_photo: true });
  });

  it('turns it off when the author actually unchecks it', async () => {
    listResult = { data: [{ ...gym, requires_photo: true }], error: null };

    render(<CommitmentList ownerId="u1" />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit' }));
    await userEvent.click(screen.getByLabelText('Keep a photo against this'));
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    const update = calls.find((c) => c.op === 'update');
    expect(update?.payload).toMatchObject({ requires_photo: false });
  });
});
