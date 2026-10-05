import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { KeptPhotos, type KeptPhotoView } from './kept-photos';
import { EVIDENCE_COPY, type KeptPhoto } from '@/lib/evidence';

/**
 * Epic 6 retrospective item 46. After a reload the only sign a photo was kept used to be the
 * image itself plus an alt attribute that a sighted reader never sees. The count is the textual
 * signal: said once beside the photos, in words, on every surface that shows them.
 */

function photo(id: string, position: number, total: number): KeptPhoto {
  return {
    id,
    commitmentId: 'c1',
    day: '2026-10-05',
    url: `https://signed/${id}`,
    alt: EVIDENCE_COPY.photoAlt(position, total),
  };
}

function view(): KeptPhotoView {
  return {
    photosOn: () => [],
    unloadable: 0,
    cleared: 0,
    failed: null,
    onUnloadable: vi.fn(),
  };
}

describe('a kept photo says so in words', () => {
  it('names one photo kept, beside the image', () => {
    render(<KeptPhotos photos={[photo('p1', 1, 1)]} view={view()} />);

    expect(screen.getByText(EVIDENCE_COPY.photosKept(1))).toBeInTheDocument();
    expect(screen.getByRole('img')).toHaveAttribute('alt', EVIDENCE_COPY.photoAlt(1, 1));
  });

  it('counts several, once, rather than once per photo', () => {
    render(<KeptPhotos photos={[photo('p1', 1, 2), photo('p2', 2, 2)]} view={view()} />);

    expect(screen.getAllByText(EVIDENCE_COPY.photosKept(2))).toHaveLength(1);
  });

  it('says nothing for a day with no photo — a day that never needed one is not missing one', () => {
    const { container } = render(<KeptPhotos photos={[]} view={view()} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('still reports a photo that will not load to the view, as before', () => {
    const v = view();
    render(<KeptPhotos photos={[photo('p1', 1, 1)]} view={v} />);
    fireEvent.error(screen.getByRole('img'));
    expect(v.onUnloadable).toHaveBeenCalledWith('p1');
  });
});

describe('EVIDENCE_COPY.photosKept', () => {
  it('reads as a count in words, singular and plural', () => {
    expect(EVIDENCE_COPY.photosKept(1)).toBe('1 photo kept for this day.');
    expect(EVIDENCE_COPY.photosKept(3)).toBe('3 photos kept for this day.');
  });
});
