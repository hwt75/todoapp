import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { refusalBeforePrompting, subscribeThisDevice } from './push-subscribe';

/**
 * The order of the checks, which is the whole substance of this module.
 *
 * iOS prompts for notification permission exactly once. Every check that could make a subscription
 * useless has to run *before* the prompt, or the single chance is spent on a build that could
 * never have delivered anything — and in Story 1.2 each retry cost the author a reboot or an idle
 * hour.
 */

const subscribe = vi.fn();

beforeEach(() => {
  subscribe.mockReset();
  subscribe.mockResolvedValue({
    toJSON: () => ({
      endpoint: 'https://web.push.apple.com/abc',
      keys: { p256dh: 'p', auth: 'a' },
    }),
  });

  vi.stubGlobal('Notification', { requestPermission: vi.fn().mockResolvedValue('granted') });
  vi.stubGlobal('navigator', {
    ...globalThis.navigator,
    serviceWorker: { ready: Promise.resolve({ pushManager: { subscribe } }) },
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('what is refused before the prompt is spent', () => {
  it('refuses a browser tab, whatever else is configured', () => {
    expect(refusalBeforePrompting('browser', 'a-key')).toMatch(/home screen/);
    expect(refusalBeforePrompting('unknown', 'a-key')).toMatch(/home screen/);
  });

  it('refuses a build with no VAPID key, and says why setting it is not enough', () => {
    // The key is inlined at build time, so an unset deploy variable is the likeliest way to
    // meet the browser's cryptic error — and setting it without redeploying changes nothing.
    expect(refusalBeforePrompting('installed', undefined)).toMatch(/inlined at build time/);
    expect(refusalBeforePrompting('installed', '')).toMatch(/inlined at build time/);
  });

  it('says nothing at all when the device could actually receive a push', () => {
    expect(refusalBeforePrompting('installed', 'a-key')).toBeNull();
  });

  it('answers the question without prompting, so a caller can ask before offering a control', () => {
    refusalBeforePrompting('browser', undefined);
    expect(Notification.requestPermission).not.toHaveBeenCalled();
  });
});

describe('subscribing this device', () => {
  it('never prompts when the answer would be useless', async () => {
    const result = await subscribeThisDevice('browser', 'a-key');

    expect(result).toMatchObject({ kind: 'refused' });
    expect(Notification.requestPermission).not.toHaveBeenCalled();
    expect(subscribe).not.toHaveBeenCalled();
  });

  it('says which answer the browser gave, rather than only that it failed', async () => {
    vi.stubGlobal('Notification', { requestPermission: vi.fn().mockResolvedValue('denied') });

    const result = await subscribeThisDevice('installed', 'a-key');

    // `denied` and `default` need different things done about them, and only one of them can
    // still be changed from inside the app.
    expect(result).toMatchObject({ kind: 'refused', reason: 'Notification permission: denied' });
  });

  it('hands the subscription to whoever asked, and says whether it was stored', async () => {
    const save = vi.fn().mockResolvedValue({ error: null });

    const result = await subscribeThisDevice('installed', 'a-key', save);

    expect(result).toMatchObject({ kind: 'subscribed', savedToDatabase: true });
    expect(save).toHaveBeenCalledOnce();
    expect(save.mock.calls[0][0]).toMatchObject({ endpoint: 'https://web.push.apple.com/abc' });
    expect(subscribe).toHaveBeenCalledWith({
      userVisibleOnly: true,
      applicationServerKey: 'a-key',
    });
  });

  it('subscribes without storing anything when nobody is signed in', async () => {
    const result = await subscribeThisDevice('installed', 'a-key');

    expect(result).toMatchObject({ kind: 'subscribed', savedToDatabase: false });
  });

  it('does not report a subscription as saved when the write was refused', async () => {
    const save = vi.fn().mockResolvedValue({ error: { message: 'permission denied for table' } });

    const result = await subscribeThisDevice('installed', 'a-key', save);

    // A subscription that exists but was not stored is invisible to the worker, and the two
    // halves fail independently.
    expect(result).toMatchObject({ kind: 'refused' });
    expect((result as { reason: string }).reason).toMatch(/Subscribed, but not saved/);
  });

  it('repeats a thrown failure verbatim, because the exact failure is the finding', async () => {
    subscribe.mockRejectedValue(new Error('AbortError: Registration failed - push service error'));

    const result = await subscribeThisDevice('installed', 'a-key');

    expect((result as { reason: string }).reason).toMatch(/push service error/);
  });

  it('gives up on a service worker that is never coming, and names that as the cause', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('navigator', {
      ...globalThis.navigator,
      // Never settles — exactly what a non-production build does, where Serwist is disabled.
      serviceWorker: { ready: new Promise(() => {}) },
    });

    const pending = subscribeThisDevice('installed', 'a-key');
    await vi.advanceTimersByTimeAsync(10_000);
    const result = await pending;

    expect((result as { reason: string }).reason).toMatch(/No service worker registered after 10s/);
    vi.useRealTimers();
  });
});
