import { fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AppealForm } from './appeal-form';

/**
 * The screen `components/ledger.tsx`'s Contest control opens. The server is the sole judge
 * of eligibility (`appeal_hold_penalty()`'s trigger) — everything here is about reading back
 * whatever it decided honestly, never about re-deriving the rule client-side.
 */

let insertResponse: { data: unknown; error: unknown } = { data: null, error: null };
let rereadResponse: { data: unknown; error: unknown } = { data: null, error: null };
let evidenceInsertResponse: { data: unknown; error: unknown } = { data: null, error: null };
let uploadResponse: { data: unknown; error: unknown } = { data: null, error: null };
let lastEvidenceInsert: Record<string, unknown> | null = null;
let uuidCounter = 0;

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => {
      if (table === 'appeal') {
        return {
          insert: () => ({
            select: () => ({
              single: () => Promise.resolve(insertResponse),
            }),
          }),
          select: () => {
            const query = {
              eq: () => query,
              maybeSingle: () => Promise.resolve(rereadResponse),
            };
            return query;
          },
        };
      }
      if (table === 'evidence') {
        return {
          insert: (row: Record<string, unknown>) => {
            lastEvidenceInsert = row;
            return Promise.resolve(evidenceInsertResponse);
          },
        };
      }
      throw new Error(`appeal-form.test.tsx: unexpected table ${table}`);
    },
    storage: {
      from: () => ({
        upload: () => Promise.resolve(uploadResponse),
      }),
    },
  }),
}));

beforeEach(() => {
  insertResponse = { data: null, error: null };
  rereadResponse = { data: null, error: null };
  evidenceInsertResponse = { data: null, error: null };
  uploadResponse = { data: null, error: null };
  lastEvidenceInsert = null;
  uuidCounter = 0;
  vi.stubGlobal('crypto', { randomUUID: () => `uuid-${++uuidCounter}` });
});

afterEach(() => {
  // Restores jsdom's real `crypto` for every test file that runs after this one in the
  // same worker — `vi.stubGlobal` mutates `globalThis` directly and outlives this file's
  // own tests unless undone.
  vi.unstubAllGlobals();
});

function renderForm(onClose = vi.fn()) {
  return render(
    <AppealForm
      ownerId="owner-1"
      commitmentId="commitment-1"
      commitmentName="TryHackMe"
      forDay="2026-08-18"
      amountDong={500_000}
      onClose={onClose}
    />,
  );
}

describe('the claim', () => {
  it('is generic and honest, never a fabricated observed/required figure', () => {
    renderForm();
    // UX-DR25's own measured-quantity example ("Location saw you for 4 minutes. It needed
    // 30.") does not apply here: account_elsewhere has no such numbers to show.
    expect(screen.getByText('Account elsewhere reported a miss.')).toBeInTheDocument();
    expect(screen.queryByText(/It needed/)).not.toBeInTheDocument();
  });

  it('names the day and the amount before anything is tapped', () => {
    renderForm();
    expect(screen.getByText(/2026-08-18/)).toBeInTheDocument();
    expect(screen.getByText(/500\.000₫/)).toBeInTheDocument();
  });
});

describe('submitting an eligible appeal', () => {
  it('shows the hold-state sentence with the real amount and the real deadline', async () => {
    insertResponse = {
      data: { id: 'appeal-1', deadline: '2026-08-20T00:00:00+07:00' },
      error: null,
    };

    renderForm();
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));

    const status = await screen.findByRole('status');
    expect(status).toHaveTextContent('500.000₫ is on hold, not charged.');
    expect(status).toHaveTextContent('Aug 20');
    expect(status).toHaveTextContent("if he doesn't get to it, it's dropped.");
  });

  it('removes the Contest button once the appeal is held — nothing to submit twice', async () => {
    insertResponse = {
      data: { id: 'appeal-1', deadline: '2026-08-20T00:00:00+07:00' },
      error: null,
    };

    renderForm();
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));

    await screen.findByRole('status');
    expect(screen.queryByRole('button', { name: 'Contest this' })).not.toBeInTheDocument();
  });

  it('offers the evidence input only once the appeal is held', async () => {
    renderForm();
    expect(screen.queryByLabelText('Evidence')).not.toBeInTheDocument();

    insertResponse = {
      data: { id: 'appeal-1', deadline: '2026-08-20T00:00:00+07:00' },
      error: null,
    };
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));

    expect(await screen.findByLabelText('Evidence')).toBeInTheDocument();
  });
});

describe('a refusal the trigger actually raised', () => {
  it('shows the server’s own message and offers to try again', async () => {
    insertResponse = {
      data: null,
      error: { code: 'P0001', message: 'Only a machine-filed miss can be appealed.' },
    };

    renderForm();
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));

    expect(
      await screen.findByText(/Only a machine-filed miss can be appealed\./),
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Contest this' })).toBeInTheDocument();
  });
});

describe('a 23505 on the per-day uniqueness', () => {
  it('reports "already appealed" when the winning row is not this attempt’s own', async () => {
    insertResponse = { data: null, error: { code: '23505', message: 'duplicate key value' } };
    rereadResponse = {
      data: {
        id: 'appeal-earlier',
        idempotency_key: 'someone-elses-key',
        deadline: '2026-08-20T00:00:00+07:00',
      },
      error: null,
    };

    renderForm();
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));

    expect(await screen.findByText(/already been appealed/)).toBeInTheDocument();
  });

  it('reports the hold as succeeded when the winning row is this attempt’s own retry', async () => {
    // The component mints its idempotency key on the first tap (stubbed to `uuid-1` here)
    // and reuses it on every retry — so a row that comes back carrying that same key is
    // this attempt's own earlier success arriving late, not a real conflict.
    insertResponse = { data: null, error: { code: '23505', message: 'duplicate key value' } };
    rereadResponse = {
      data: { id: 'appeal-1', idempotency_key: 'uuid-1', deadline: '2026-08-20T00:00:00+07:00' },
      error: null,
    };

    renderForm();
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));

    const status = await screen.findByRole('status');
    expect(status).toHaveTextContent('is on hold, not charged.');
  });
});

describe('a network that never reached a decision', () => {
  it('says the generic refusal and keeps the button offered', async () => {
    insertResponse = { data: null, error: { message: 'fetch failed' } };

    renderForm();
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));

    expect(await screen.findByText(/fetch failed/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Contest this' })).toBeInTheDocument();
  });
});

describe('evidence, optional and never blocking', () => {
  async function heldForm() {
    insertResponse = {
      data: { id: 'appeal-1', deadline: '2026-08-20T00:00:00+07:00' },
      error: null,
    };
    renderForm();
    fireEvent.click(screen.getByRole('button', { name: 'Contest this' }));
    await screen.findByLabelText('Evidence');
  }

  // `forDay` is always `2026-08-18` (see `renderForm`). Noon Asia/Ho_Chi_Minh keeps this
  // comfortably inside that calendar date regardless of the machine running the test.
  function fileDatedOn(isoDate: string) {
    return new File(['data'], 'photo.jpg', {
      type: 'image/jpeg',
      lastModified: new Date(`${isoDate}T12:00:00+07:00`).getTime(),
    });
  }

  it('says it is optional and never required to submit', async () => {
    await heldForm();
    expect(screen.getByText(/Optional, and never required to submit/)).toBeInTheDocument();
  });

  it('confirms once uploaded and inserted, with the day it read off the file', async () => {
    await heldForm();

    fireEvent.change(screen.getByLabelText('Evidence'), {
      target: { files: [fileDatedOn('2026-08-18')] },
    });

    expect(await screen.findByText('Evidence attached.')).toBeInTheDocument();
    expect(lastEvidenceInsert).toMatchObject({ captured_on: '2026-08-18' });
  });

  it('says the appeal still stands when the upload itself fails', async () => {
    await heldForm();
    uploadResponse = { data: null, error: { message: 'storage refused' } };

    fireEvent.change(screen.getByLabelText('Evidence'), {
      target: { files: [fileDatedOn('2026-08-18')] },
    });

    expect(await screen.findByText(/The appeal itself still stands/)).toBeInTheDocument();
  });

  it('says the appeal still stands when the metadata insert fails after a good upload', async () => {
    await heldForm();
    evidenceInsertResponse = { data: null, error: { message: 'insert refused' } };

    fireEvent.change(screen.getByLabelText('Evidence'), {
      target: { files: [fileDatedOn('2026-08-18')] },
    });

    expect(await screen.findByText(/The appeal itself still stands/)).toBeInTheDocument();
  });

  it('refuses a file dated a different day, before any upload starts (FR-14)', async () => {
    await heldForm();

    fireEvent.change(screen.getByLabelText('Evidence'), {
      target: { files: [fileDatedOn('2026-08-17')] },
    });

    expect(await screen.findByText(/isn’t dated the day being appealed/)).toBeInTheDocument();
    expect(lastEvidenceInsert).toBeNull();
  });
});

describe('closing', () => {
  it('calls onClose and never submits anything on its own', () => {
    const onClose = vi.fn();
    renderForm(onClose);
    fireEvent.click(screen.getByRole('button', { name: 'Back to the ledger' }));
    expect(onClose).toHaveBeenCalledOnce();
  });
});
