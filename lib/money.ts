/**
 * Money, as integers of đồng and nothing else.
 *
 * The product's whole relationship with money is recording that one person owes another
 * and that it was later paid (NFR5). There is no payment integration, no stored
 * instrument, no balance it can move, and no code path that transfers value. This module
 * formats a number; it is not the beginning of a payments layer and must not become one.
 */

/** One Failed Day. Mirrors `public.penalty_amount_dong()`, and the test asserts they agree. */
export const PENALTY_DONG = 500_000;

/**
 * Whether a value may be stored as an amount.
 *
 * Floats are refused rather than rounded. A rounding error in a number that only grows is
 * a number that eventually disagrees with itself, and this one is a claim against a real
 * person — the difference has to be a bug, not a discrepancy someone explains away.
 */
export function isStorableAmount(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

/**
 * How an amount reads.
 *
 * Grouped with the separator Vietnamese uses and suffixed `₫`, because the figure is the
 * largest thing on the screen and a bare `2500000` is a number the eye has to count.
 */
export function formatDong(amountDong: number): string {
  if (!isStorableAmount(amountDong)) {
    throw new Error(`Not a storable amount of đồng: ${String(amountDong)}`);
  }
  return `${amountDong.toLocaleString('vi-VN')}₫`;
}

/**
 * The total owed since first use.
 *
 * Cumulative and never reset by a period boundary — a debt that resets each month is a
 * debt the product has quietly forgiven, and forgiveness here has exactly two forms, both
 * of which are recorded acts: a Grace Day and a won Appeal.
 */
export function totalOwed(amounts: readonly number[]): number {
  return amounts.reduce((sum, amount) => {
    if (!isStorableAmount(amount)) {
      throw new Error(`Not a storable amount of đồng: ${String(amount)}`);
    }
    return sum + amount;
  }, 0);
}
