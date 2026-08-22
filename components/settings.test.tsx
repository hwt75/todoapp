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
let profileResult: unknown = { data: { morning_hour: 7 }, error: null };
// What the write comes back with. Set per test; the default is a clean save.
let updateResult: { error: { message: string } | null } = { error: null };

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    from: () => ({
      select: () => ({ maybeSingle: () => Promise.resolve(profileResult) }),
      update: (payload: unknown) => {
        update(payload);
        return { eq: () => Promise.resolve(updateResult) };
      },
      upsert: (payload: unknown, options: unknown) => {
        upsert(payload, options);
        return Promise.resolve({ error: null });
      },
    }),
  }),
}));

const subscribe = vi.fn();

beforeEach(() => {
  update.mockReset();
  updateResult = { error: null };
  upsert.mockReset();
  profileResult = { data: { morning_hour: 7 }, error: null };

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

  it('leaves out the rows this epic cannot fill, rather than greying them out', async () => {
    render(<Settings ownerId="u1" installState="installed" onClose={vi.fn()} />);
    await screen.findByLabelText('Morning hour');

    // There is no referee and no grace day can be produced. A disabled row would be a promise
    // with a date the author cannot see.
    expect(screen.queryByText(/[Rr]eferee/)).not.toBeInTheDocument();
    expect(screen.queryByText(/[Gg]race/)).not.toBeInTheDocument();
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
