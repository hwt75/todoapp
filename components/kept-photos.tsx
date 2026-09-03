'use client';

import { useCallback, useState } from 'react';
import { EVIDENCE_COPY, photosOn, type KeptPhoto, type KeptPhotoRead } from '@/lib/evidence';

/**
 * How a filed photo is shown, once, for the three surfaces that show one (Story 6.9).
 *
 * `lib/evidence.ts` owns the read — which rows, signed how long for, and what a failure to sign
 * is called. This owns what happens after that answer reaches a screen: which images render,
 * what a browser that cannot load one is counted as, and the two sentences either case is
 * allowed to say. Three copies of that is how three surfaces start disagreeing about whether a
 * photo the author kept is on screen or missing.
 */

/** One read, plus what this browser has since discovered about it. */
export interface KeptPhotoView {
  /** One commitment's photos for one day, minus any this browser could not load. */
  photosOn: (commitmentId: string, day: string) => KeptPhoto[];
  /**
   * How many are known to exist and are not on screen — never signed, or signed and then
   * unloadable. One number because it is one fact to the person looking at the screen.
   */
  unloadable: number;
  /** The read itself failed, with the server's own words. Null when it did not. */
  failed: string | null;
  onUnloadable: (photoId: string) => void;
}

/**
 * Folds a read together with the load failures only a browser can find.
 *
 * A signed URL is good for an hour and these screens outlive that — a Focus Session against a
 * three-hour target sits open far longer than one, and Today re-reads only at midnight or after
 * an upload. An expired URL, or one lost to a dead connection, renders as a broken frame that
 * says nothing; counted here instead, it says the same thing every other missing photo says.
 */
export function useKeptPhotos(read: KeptPhotoRead | null): KeptPhotoView {
  // The read these failures belong to is stored beside them rather than reset by an effect. A
  // new read is a new answer with new URLs — a photo that would not load a minute ago may well
  // load now — so a verdict against the previous one is simply not this one's, and saying so
  // here means there is never a render in which it still counts.
  const [failures, setFailures] = useState<{
    of: KeptPhotoRead | null;
    ids: readonly string[];
  }>({ of: null, ids: [] });

  const ids = failures.of === read ? failures.ids : [];

  const onUnloadable = useCallback(
    (photoId: string) => {
      setFailures((current) => {
        const kept = current.of === read ? current.ids : [];
        return kept.includes(photoId)
          ? { of: read, ids: kept }
          : { of: read, ids: [...kept, photoId] };
      });
    },
    [read],
  );

  return {
    photosOn: (commitmentId, day) =>
      read === null
        ? []
        : photosOn(read, commitmentId, day).filter((photo) => !ids.includes(photo.id)),
    unloadable: (read?.unsigned ?? 0) + ids.length,
    failed: read?.failed ?? null,
    onUnloadable,
  };
}

/**
 * The images themselves.
 *
 * `loading="lazy"` and `decoding="async"` because these are whatever resolution the author's
 * phone produced, and a history can hold several at once; `.kept-photo` bounds the height so one
 * of them is not the entire screen. A bare `img` rather than `next/image` for the reason
 * `components/referee-appeal-detail.tsx` gives: a signed URL into a private bucket is not an
 * asset that optimiser is set up to fetch.
 */
export function KeptPhotos({ photos, view }: { photos: KeptPhoto[]; view: KeptPhotoView }) {
  return (
    <>
      {photos.map((photo) => (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          key={photo.id}
          className="kept-photo"
          src={photo.url}
          alt={photo.alt}
          loading="lazy"
          decoding="async"
          onError={() => view.onUnloadable(photo.id)}
        />
      ))}
    </>
  );
}

/**
 * What is said about the photos that are not on screen, and nothing at all when they all are.
 *
 * Not a `role="status"` live region: nothing here follows an act of the author's, so there is no
 * moment at which a screen reader should interrupt him to say it. It is a sentence beside the
 * photos, read in document order like the rest of the block — unlike "Proof saved.", which
 * answers something he just did and stays a live region.
 */
export function KeptPhotoNote({ view }: { view: KeptPhotoView }) {
  return (
    <>
      {view.unloadable > 0 && (
        <p className="row-muted">{EVIDENCE_COPY.photosFailed(view.unloadable)}</p>
      )}
      {/* The server's own reason, not only that there was one. A refused read and a dead
          connection are different problems and only one of them is worth retrying. */}
      {view.failed !== null && (
        <p className="row-muted">
          <strong>{EVIDENCE_COPY.photosUnreadable}</strong> {view.failed}
        </p>
      )}
    </>
  );
}
