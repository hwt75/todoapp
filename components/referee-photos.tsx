'use client';

import { useState } from 'react';
import { EVIDENCE_BUCKET, EVIDENCE_URL_TTL_SECONDS } from '@/lib/evidence';
import { createClient } from '@/lib/supabase/client';

/**
 * The photographs a referee is shown, for the three screens that show them: what is waiting for
 * him today, the day lookup, and an appeal (deferred from Story 8.4's review).
 *
 * Story 6.9's rule is that a photo is reported, never dropped: he must not be shown three and told
 * nothing about the fourth on a screen where he is deciding whether a day held. Each screen
 * enforced that only at signing time, so a photo that signed and then would not load — its object
 * gone, or its URL expired while he read — became a broken frame nothing counted. Fixing three
 * screens separately is how they came to differ, so this is one component.
 *
 * Signing stays with the screens, which sign a whole day in one call. This owns what happens after:
 * an image that fails to load is signed again, once, which is what an expired URL needs, and one
 * that still fails, or cannot be signed at all, joins the count.
 */

export interface SignedPhoto {
  /** The storage path, which is what can be signed again. */
  path: string;
  url: string;
}

interface PhotoState {
  /** The photos this state is about. A new set from the screen starts fresh: a photo that would
   *  not load from an earlier read may well load from this one. */
  of: string;
  /** Fresh URLs, by path, for photos signed again here. */
  urls: Readonly<Record<string, string>>;
  /** Paths signed again since they last loaded. A second failure before a load means the problem
   *  is not the URL's age. */
  retried: readonly string[];
  /** Paths given up on, which are counted rather than drawn. */
  broken: readonly string[];
}

async function signAgain(path: string): Promise<string | null> {
  const { data, error } = await createClient()
    .storage.from(EVIDENCE_BUCKET)
    .createSignedUrl(path, EVIDENCE_URL_TTL_SECONDS);
  return error || !data?.signedUrl ? null : data.signedUrl;
}

export function RefereePhotos({
  photos,
  unsigned,
  alt,
  failed,
  className = 'kept-photo',
}: {
  photos: SignedPhoto[];
  /** How many could not be signed in the first place. Counted with the ones that fail here, as
   *  one number, because to the referee they are one fact. */
  unsigned: number;
  /** Alt text by 1-indexed position among the photos actually on screen. */
  alt: (position: number, total: number) => string;
  /** The sentence for how many could not be opened. Each screen keeps its own wording. */
  failed: (count: number) => string;
  className?: string;
}) {
  const of = photos.map((photo) => photo.path).join('|');
  const [state, setState] = useState<PhotoState>({ of, urls: {}, retried: [], broken: [] });
  const current: PhotoState = state.of === of ? state : { of, urls: {}, retried: [], broken: [] };

  function update(change: (s: PhotoState) => PhotoState) {
    setState((s) => change(s.of === of ? s : { of, urls: {}, retried: [], broken: [] }));
  }

  async function onError(path: string) {
    if (current.retried.includes(path)) {
      update((s) => ({ ...s, broken: s.broken.includes(path) ? s.broken : [...s.broken, path] }));
      return;
    }

    update((s) => ({ ...s, retried: [...s.retried, path] }));
    const url = await signAgain(path);

    update((s) =>
      url
        ? { ...s, urls: { ...s.urls, [path]: url } }
        : { ...s, broken: s.broken.includes(path) ? s.broken : [...s.broken, path] },
    );
  }

  function onLoad(path: string) {
    // A load proves the URL is good, so a later failure is a later expiry and earns its own
    // signing again rather than counting as the second failure of this one.
    if (current.retried.includes(path)) {
      update((s) => ({ ...s, retried: s.retried.filter((p) => p !== path) }));
    }
  }

  const shown = photos.filter((photo) => !current.broken.includes(photo.path));
  const unopenable = unsigned + current.broken.length;

  return (
    <>
      {shown.map((photo, index) => (
        // A signed URL into a private bucket, not an asset next/image's optimiser is set up to
        // fetch. `lazy` so photographs further down do not compete with the first one.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          key={photo.path}
          className={className || undefined}
          src={current.urls[photo.path] ?? photo.url}
          loading="lazy"
          decoding="async"
          alt={alt(index + 1, shown.length)}
          onError={() => void onError(photo.path)}
          onLoad={() => onLoad(photo.path)}
        />
      ))}
      {unopenable > 0 && <p role="status">{failed(unopenable)}</p>}
    </>
  );
}
