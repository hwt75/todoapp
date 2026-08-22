import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PushProbe } from './push-probe';

/**
 * Story 1.2's diagnostic apparatus — and, until a Settings surface exists, the **only** route by
 * which this product ever asks for notification permission.
 *
 * That is why it is tested rather than left as scaffolding. Every rule here exists because a retry
 * costs the author a reboot or an idle hour, so each dead end has to name itself instead of
 * hanging or surfacing a cryptic DOMException:
 *
 *   - subscribing from a browser tab is refused before the prompt, because on iOS such a
 *     subscription silently receives nothing and diagnosing that from the symptoms costs hours;
 *   - a missing VAPID key is caught before the prompt too — iOS does not offer permission twice,
 *     and spending it on a misconfigured build wastes the one chance;
 *   - a failure is repeated verbatim, because the exact failure *is* the finding.
 */

// The key is read at module scope, the way Next inlines it at build time, so it has to be set
// before the import is evaluated — `vi.hoisted` is the only place early enough.
vi.hoisted(() => {
  process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY = 'a-public-key';
});

const upsert = vi.fn();

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({ from: () => ({ upsert }) }),
}));

const subscription = {
  toJSON: () => ({
    endpoint: 'https://web.push.apple.com/abc',
    keys: { p256dh: 'p', auth: 'a' },
  }),
};

beforeEach(() => {
  upsert.mockReset();
  upsert.mockResolvedValue({ error: null });

  vi.stubGlobal('Notification', { requestPermission: vi.fn().mockResolvedValue('granted') });
  vi.stubGlobal('navigator', {
    ...navigator,
    serviceWorker: {
      ready: Promise.resolve({
        pushManager: { subscribe: vi.fn().mockResolvedValue(subscription) },
      }),
    },
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY = 'a-public-key';
});

describe('the push probe', () => {
  it('refuses a browser tab before spending the permission prompt', async () => {
    render(<PushProbe installState="browser" ownerId="u1" />);

    await userEvent.click(screen.getByRole('button', { name: 'Subscribe this device' }));

    // iOS delivers push only to an installed app, and a subscription made in a tab fails
    // silently — the worst shape a failure can take in a story whose whole purpose is an
    // unambiguous yes or no.
    expect(await screen.findByText(/Not launched from the home screen/)).toBeInTheDocument();
    expect(Notification.requestPermission).not.toHaveBeenCalled();
  });

  it('names a missing build key rather than letting the browser be cryptic about it', async () => {
    // Re-imported with the key unset, because the component reads it once at module scope —
    // which is the whole reason the failure it describes is possible.
    process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY = '';
    vi.resetModules();
    const { PushProbe: Unconfigured } = await import('./push-probe');

    render(<Unconfigured installState="installed" ownerId="u1" />);

    await userEvent.click(screen.getByRole('button', { name: 'Subscribe this device' }));

    // And it says the thing that is easy to get wrong: the key is inlined at build time,
    // so setting it without redeploying changes nothing.
    expect(await screen.findByText(/inlined at build time/)).toBeInTheDocument();
    expect(Notification.requestPermission).not.toHaveBeenCalled();
  });

  it('says which permission answer it got, rather than only that it failed', async () => {
    vi.stubGlobal('Notification', { requestPermission: vi.fn().mockResolvedValue('denied') });
    render(<PushProbe installState="installed" ownerId="u1" />);

    await userEvent.click(screen.getByRole('button', { name: 'Subscribe this device' }));

    expect(await screen.findByText(/Notification permission: denied/)).toBeInTheDocument();
  });

  it('saves the endpoint where the worker can reach it, and revives a device marked dead', async () => {
    render(<PushProbe installState="installed" ownerId="u1" />);

    await userEvent.click(screen.getByRole('button', { name: 'Subscribe this device' }));
    await screen.findByRole('textbox');

    expect(upsert).toHaveBeenCalledOnce();
    const [row, options] = upsert.mock.calls[0];
    expect(row).toMatchObject({
      owner_id: 'u1',
      endpoint: 'https://web.push.apple.com/abc',
      p256dh: 'p',
      auth: 'a',
      // Re-subscribing a device that had been marked dead brings it back, or the author
      // fixes his phone and the outbox goes on ignoring it.
      dead_at: null,
      dead_reason: null,
    });
    expect(options).toMatchObject({ onConflict: 'endpoint' });
  });

  it('still shows the subscription when nobody is signed in', async () => {
    render(<PushProbe installState="installed" ownerId={null} />);

    await userEvent.click(screen.getByRole('button', { name: 'Subscribe this device' }));

    // The CLI fallback is the only channel that has actually been seen to deliver, and it
    // goes when the worker has been watched doing the job — not before.
    const shown = await screen.findByRole('textbox');
    expect((shown as HTMLTextAreaElement).value).toContain('web.push.apple.com');
    expect(upsert).not.toHaveBeenCalled();
  });

  it('does not claim a subscription was saved when the write was refused', async () => {
    upsert.mockResolvedValue({ error: { message: 'permission denied for table' } });
    render(<PushProbe installState="installed" ownerId="u1" />);

    await userEvent.click(screen.getByRole('button', { name: 'Subscribe this device' }));

    // "Subscribed, but not saved" — the two halves fail independently and the author needs
    // to know which one did.
    expect(await screen.findByText(/Subscribed, but not saved/)).toBeInTheDocument();
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
  });
});
