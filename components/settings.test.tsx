import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Settings } from './settings';

/**
 * The surface Story 2.4 declared and Epic 2 never built.
 *
 * What is asserted here is the pair of rules that make it honest rather than merely present: a
 * permission the app cannot revoke is **stated, never toggled**, and a row this epic cannot fill
 * is **absent, never disabled**. Both are ways a screen starts lying quietly — the first by
 * offering a control that does nothing, the second by promising something with no date.
 *
 * The hour is the one thing here the app owns, so the assertions on it are about not claiming a
 * save that did not happen.
 */

vi.hoisted(() => {
  process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY = 'a-public-key';
});

const update = vi.fn();
const upsert = vi.fn();
const invoke = vi.fn();
let profileResult: unknown = { data: { morning_hour: 7 }, error: null };
// What the write comes back with. Set per test; the default is a clean save.
let updateResult: { error: { message: string } | null } = { error: null };
// What `pair-referee` comes back with. Set per test; the default is never exercised
// unless a test actually pairs.
let invokeResult: unknown = { data: null, error: null };
// What `grace_allowance_remaining` comes back with (Story 5.1). Set per test; the default
// leaves plenty of room so no test is coupled to the exact allowance unless it says so.
let graceResult: unknown = { data: { remaining: 2 }, error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: (table: string) => ({
      select: () => ({
        maybeSingle: () =>
          Promise.resolve(table === 'grace_allowance_remaining' ? graceResult : profileResult),
      }),
      update: (payload: unknown) => {
        update(payload);
        return { eq: () => Promise.resolve(updateResult) };
      },
      upsert: (payload: unknown, options: unknown) => {
        upsert(payload, options);
        return Promise.resolve({ error: null });
      },
    }),
    functions: {
      invoke: (name: string, options: unknown) => {
        invoke(name, options);
        return Promise.resolve(invokeResult);
      },
    },
  }),
}));

const subscribe = vi.fn();

beforeEach(() => {
  update.mockReset();
  updateResult = { error: null };
  upsert.mockReset();
  invoke.mockReset();
  invokeResult = { data: null, error: null };
  profileResult = { data: { morning_hour: 7 }, error: null };
  graceResult = { data: { remaining: 2 }, error: null };

  subscribe.mockResolvedValue({
    toJSON: () => ({
      endpoint: 'https://web.push.apple.com/abc',
      keys: { p256dh: 'p', auth: 'a' },
    }),
  });
  vi.stubGlobal('Notification', {
    permission: 'default',
    requestPermission: vi.fn().mockResolvedValue('granted'),
  });
  vi.stubGlobal('navigator', {
    ...globalThis.navigator,
    serviceWorker: { ready: Promise.resolve({ pushManager: { subscribe } }) },
  });
});

describe('the settings surface', () => {
  it('shows the hour the question actually arrives at', async () => {
    profileResult = { data: { morning_hour: 9 }, error: null };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);

    expect(await screen.findByLabelText('Morning hour')).toHaveValue('9');
    expect(screen.getByRole('group', { name: 'Morning hour, 09:00' })).toBeInTheDocument();
  });

  it('writes the hour to the account, through the column grant that already exists', async () => {
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    await userEvent.selectOptions(screen.getByLabelText('Morning hour'), '6');

    // The column and nothing else. Sending `role` in the same statement is the escalation
    // `20260819201000` closed, and the grant is what keeps this write narrow.
    expect(update).toHaveBeenCalledWith({ morning_hour: 6 });
  });

  it('does not claim a refused write saved, but keeps the hour he typed', async () => {
    updateResult = { error: { message: 'new row violates check constraint' } };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    await userEvent.selectOptions(screen.getByLabelText('Morning hour'), '6');

    // Nothing was written, so "Not saved." must say so — but the field shows what he chose,
    // not what reverting it would silently claim was still true.
    expect(await screen.findByText(/Not saved\./)).toBeInTheDocument();
    expect(screen.getByLabelText('Morning hour')).toHaveValue('6');
  });

  it('says what failed rather than guessing a second fallback hour', async () => {
    // Zero rows, no error — `maybeSingle()`'s honest shape for a missing profile row. The
    // frozen boundary forbids a second `?? 7` here, so this must read as a failure, not a guess.
    profileResult = { data: null, error: null };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);

    expect(await screen.findByText(/No profile found/)).toBeInTheDocument();
    expect(screen.queryByLabelText('Morning hour')).not.toBeInTheDocument();
  });

  it('offers a control for permission only while one could still change the answer', async () => {
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    expect(screen.getByRole('button', { name: 'Turn on notifications' })).toBeInTheDocument();
  });

  it('states a granted or denied permission instead of offering a button that would lie', async () => {
    vi.stubGlobal('Notification', { permission: 'denied', requestPermission: vi.fn() });
    const { unmount } = render(
      <Settings ownerId="u1" installState="installed" onClose={vi.fn()} />,
    );
    await screen.findByLabelText('Morning hour');

    // iOS will not ask again from inside the app, so a button here is a lie with a tap target.
    // The row says where the real switch is instead.
    expect(screen.queryByRole('button', { name: 'Turn on notifications' })).not.toBeInTheDocument();
    expect(screen.getByText(/Settings → Notifications/)).toBeInTheDocument();
    unmount();

    vi.stubGlobal('Notification', { permission: 'granted', requestPermission: vi.fn() });
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    expect(screen.queryByRole('button', { name: 'Turn on notifications' })).not.toBeInTheDocument();
  });

  it('never offers to install or uninstall the app', async () => {
    render(<Settings ownerId="u1" installState="browser" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    const home = screen.getByRole('group', { name: /Home screen/ });
    expect(home.querySelector('button')).toBeNull();
    // It says what to do instead, in the words iOS uses for it.
    expect(screen.getByText(/Add to Home Screen/)).toBeInTheDocument();
  });

  it('does not offer notification permission from a browser tab either — the install row leads', async () => {
    // Permission defaults to `'default'` (from `beforeEach`), which is actionable on its own —
    // this is the case the install row must still override, per the frozen I/O matrix row
    // "Launched in a browser tab → permission is not offered at all".
    render(<Settings ownerId="u1" installState="browser" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    expect(screen.queryByRole('button', { name: 'Turn on notifications' })).not.toBeInTheDocument();
  });

  it('shows the Grace Days remaining count, read-only (Story 5.1)', async () => {
    graceResult = { data: { remaining: 1 }, error: null };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    const row = await screen.findByRole('group', { name: 'Grace Days' });
    expect(row).toHaveTextContent('1 Grace Day remaining this month.');
    // Read-only: nothing here can be clicked to spend one — that control lives on the Day
    // summary and a Ledger row instead.
    expect(row.querySelector('button')).toBeNull();
  });

  it('says none remain rather than a bare 0', async () => {
    graceResult = { data: { remaining: 0 }, error: null };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    expect(await screen.findByText('No Grace Days remaining this month.')).toBeInTheDocument();
  });

  it('does not claim a count it has not read yet, and does not block the rest of the screen on it', async () => {
    // Never resolves during this test — this is the genuine "still loading" case, which must
    // stay distinguishable from the "failed" case below rather than the two sharing one
    // ambiguous null.
    graceResult = new Promise(() => {});
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);

    // The morning hour still loads and is still usable — a slow Grace Days read is one
    // independent fact among several on this screen, not a precondition for the rest.
    expect(await screen.findByLabelText('Morning hour')).toBeInTheDocument();
    expect(screen.getByRole('group', { name: 'Grace Days' })).toHaveTextContent('Working…');
  });

  it('surfaces a failed Grace Days read rather than leaving the row stuck on "Working…" forever', async () => {
    // An earlier version destructured only `data` from this read, silently swallowing
    // `error` entirely — a real failure was indistinguishable from "still loading".
    graceResult = { data: null, error: { message: 'permission denied' } };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    const row = await screen.findByRole('group', { name: 'Grace Days' });
    expect(row).toHaveTextContent('Failed.');
    expect(row).toHaveTextContent('permission denied');
    expect(row).not.toHaveTextContent('Working…');
    // The morning hour is still usable — this row's own failure does not block the rest.
    expect(screen.getByLabelText('Morning hour')).toBeInTheDocument();
  });

  it('surfaces a missing row the same way as an explicit error, never as 0 remaining', async () => {
    // A real doer session always has exactly one row here (`grace_allowance_remaining`'s
    // own `where role = 'doer'`) — no row without an error is itself a failure, not a
    // silent "treat it as 0 remaining".
    graceResult = { data: null, error: null };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    const row = await screen.findByRole('group', { name: 'Grace Days' });
    expect(row).toHaveTextContent('Failed.');
    expect(row).not.toHaveTextContent('No Grace Days remaining this month.');
  });

  it('surfaces a genuine promise rejection, not only a resolved {error} pair', async () => {
    graceResult = Promise.reject(new Error('network down'));
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    const row = await screen.findByRole('group', { name: 'Grace Days' });
    expect(row).toHaveTextContent('Failed.');
    expect(row).toHaveTextContent('network down');
  });

  it('fills the referee row: pairs from an email, shows the one-time password once', async () => {
    invokeResult = { data: { email: 'ref@example.com', password: 'p4ssw0rd12345' }, error: null };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    expect(screen.getByRole('button', { name: 'Pair referee' })).toBeDisabled();

    await userEvent.type(screen.getByPlaceholderText('referee@example.com'), 'ref@example.com');
    expect(screen.getByRole('button', { name: 'Pair referee' })).toBeEnabled();

    await userEvent.click(screen.getByRole('button', { name: 'Pair referee' }));

    expect(invoke).toHaveBeenCalledWith('pair-referee', {
      body: { email: 'ref@example.com' },
    });
    expect(await screen.findByText('Paired as ref@example.com.')).toBeInTheDocument();
    expect(screen.getByText('p4ssw0rd12345')).toBeInTheDocument();
    expect(screen.getByText(/never emailed/)).toBeInTheDocument();
    // The form itself is gone once paired — nothing left to submit a second time.
    expect(screen.queryByPlaceholderText('referee@example.com')).not.toBeInTheDocument();
  });

  it('shows the server refusal verbatim rather than a generic failure, and creates nothing', async () => {
    invokeResult = {
      data: null,
      error: { message: 'A referee is already paired. There is no re-pairing yet.' },
    };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    await userEvent.type(screen.getByPlaceholderText('referee@example.com'), 'ref2@example.com');
    await userEvent.click(screen.getByRole('button', { name: 'Pair referee' }));

    expect(
      await screen.findByText('A referee is already paired. There is no re-pairing yet.'),
    ).toBeInTheDocument();
    // Refused, so the form is still here for another attempt — not swapped for a success state.
    expect(screen.getByPlaceholderText('referee@example.com')).toBeInTheDocument();
  });

  it('subscribes this device when permission is granted from here', async () => {
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    await userEvent.click(screen.getByRole('button', { name: 'Turn on notifications' }));

    // The probe stops being the only route to a subscription — that is the whole reason this
    // row exists (spec 3.0, D3).
    expect(upsert).toHaveBeenCalledOnce();
    expect(upsert.mock.calls[0][0]).toMatchObject({
      owner_id: 'u1',
      endpoint: 'https://web.push.apple.com/abc',
      dead_at: null,
    });
  });

  it('says which answer the browser gave when the prompt is refused', async () => {
    vi.stubGlobal('Notification', {
      permission: 'default',
      requestPermission: vi.fn().mockResolvedValue('denied'),
    });
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    await userEvent.click(screen.getByRole('button', { name: 'Turn on notifications' }));

    expect(await screen.findByText(/Notification permission: denied/)).toBeInTheDocument();
  });

  it('says what failed rather than showing a default hour it never read', async () => {
    profileResult = { data: null, error: { message: 'permission denied' } };
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);

    expect(await screen.findByText(/permission denied/)).toBeInTheDocument();
    expect(screen.queryByLabelText('Morning hour')).not.toBeInTheDocument();
  });

  it('goes back to today', async () => {
    const onClose = vi.fn();
    render(<Settings ownerId="u1" installState="installed" onClose={onClose} />);

    await userEvent.click(screen.getByRole('button', { name: 'Back to today' }));
    expect(onClose).toHaveBeenCalledOnce();
  });
});
