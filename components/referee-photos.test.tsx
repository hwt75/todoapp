import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RefereePhotos } from './referee-photos';

/**
 * Deferred from Story 8.4's review: a photo that signed and then failed to load — its object gone,
 * or its signed URL expired while the screen stayed open — rendered as a broken frame on every
 * referee photo surface, uncounted by the "could not be opened" line. One component, so the three
 * surfaces cannot go on disagreeing about it.
 */

const signCalls: string[] = [];
let resigned: Record<string, string | null> = {};

vi.mock('@/lib/supabase/client', () => ({
  createClient: () => ({
    storage: {
      from: () => ({
        createSignedUrl: async (path: string) => {
          signCalls.push(path);
          const url = resigned[path];
          return url
            ? { data: { signedUrl: url }, error: null }
            : { data: null, error: { message: 'gone' } };
        },
      }),
    },
  }),
}));

const failed = (n: number) => `${n} could not be opened.`;
const alt = (i: number, total: number) => `Proof ${i} of ${total}`;

beforeEach(() => {
  signCalls.length = 0;
  resigned = {};
});

describe('RefereePhotos', () => {
  it('shows every signed photo and counts the ones that would not sign', () => {
    render(
      <RefereePhotos
        photos={[{ path: 'd/a.jpg', url: 'https://signed/a' }]}
        unsigned={1}
        alt={alt}
        failed={failed}
      />,
    );

    expect(screen.getByRole('img')).toHaveAttribute('src', 'https://signed/a');
    expect(screen.getByRole('status')).toHaveTextContent('1 could not be opened.');
  });

  it('signs a photo again once when it fails to load, which is what an expired URL looks like', async () => {
    resigned['d/a.jpg'] = 'https://signed/a-again';
    render(
      <RefereePhotos
        photos={[{ path: 'd/a.jpg', url: 'https://signed/a' }]}
        unsigned={0}
        alt={alt}
        failed={failed}
      />,
    );

    fireEvent.error(screen.getByRole('img'));

    await waitFor(() =>
      expect(screen.getByRole('img')).toHaveAttribute('src', 'https://signed/a-again'),
    );
    expect(signCalls).toEqual(['d/a.jpg']);
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });

  it('counts a photo that still will not load after signing again, and stops showing a broken frame', async () => {
    resigned['d/a.jpg'] = 'https://signed/a-again';
    render(
      <RefereePhotos
        photos={[
          { path: 'd/a.jpg', url: 'https://signed/a' },
          { path: 'd/b.jpg', url: 'https://signed/b' },
        ]}
        unsigned={0}
        alt={alt}
        failed={failed}
      />,
    );

    fireEvent.error(screen.getByAltText('Proof 1 of 2'));
    await waitFor(() =>
      expect(screen.getByAltText('Proof 1 of 2')).toHaveAttribute('src', 'https://signed/a-again'),
    );
    fireEvent.error(screen.getByAltText('Proof 1 of 2'));

    expect(await screen.findByRole('status')).toHaveTextContent('1 could not be opened.');
    expect(screen.getAllByRole('img')).toHaveLength(1);
    expect(signCalls).toEqual(['d/a.jpg']);
  });

  it('counts a photo whose object is gone, when signing again is refused', async () => {
    render(
      <RefereePhotos
        photos={[{ path: 'd/a.jpg', url: 'https://signed/a' }]}
        unsigned={0}
        alt={alt}
        failed={failed}
      />,
    );

    fireEvent.error(screen.getByRole('img'));

    expect(await screen.findByRole('status')).toHaveTextContent('1 could not be opened.');
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  it('signs again after a later expiry too, once each time a fresh URL has loaded', async () => {
    resigned['d/a.jpg'] = 'https://signed/a-2';
    render(
      <RefereePhotos
        photos={[{ path: 'd/a.jpg', url: 'https://signed/a' }]}
        unsigned={0}
        alt={alt}
        failed={failed}
      />,
    );

    fireEvent.error(screen.getByRole('img'));
    await waitFor(() =>
      expect(screen.getByRole('img')).toHaveAttribute('src', 'https://signed/a-2'),
    );
    fireEvent.load(screen.getByRole('img'));

    resigned['d/a.jpg'] = 'https://signed/a-3';
    fireEvent.error(screen.getByRole('img'));
    await waitFor(() =>
      expect(screen.getByRole('img')).toHaveAttribute('src', 'https://signed/a-3'),
    );
    expect(signCalls).toEqual(['d/a.jpg', 'd/a.jpg']);
  });
});
