'use client';

import { formatDong } from '@/lib/money';

/**
 * The debt total. The largest and most saturated thing in the product.
 *
 * It spends **one of the two `figure` roles** the whole design system allows — the other
 * belongs to Epic 3's focus timer, and nothing else may ever claim it. It is also the only
 * place colour covers an area rather than labelling a state. The author chose that
 * knowingly, against advice, and this executes it rather than softening it.
 *
 * It renders nothing when there is nothing owed. A large `0` in failed-tint is a decoration
 * that says nothing and charges him the reluctance of opening a screen with a red area on
 * it.
 */
export function DebtBlock({ totalDong, onOpen }: { totalDong: number; onOpen: () => void }) {
  if (totalDong <= 0) return null;

  return (
    <section className="debt-block">
      <button
        type="button"
        className="debt-block-tap"
        onClick={onOpen}
        // One label, so it is announced as a fact and not as three fragments.
        aria-label={`Owed since you started: ${formatDong(totalDong)}. Opens the ledger.`}
      >
        <span className="debt-block-label" aria-hidden="true">
          Owed
        </span>
        <span className="debt-block-figure" aria-hidden="true">
          {formatDong(totalDong)}
        </span>
      </button>
    </section>
  );
}
