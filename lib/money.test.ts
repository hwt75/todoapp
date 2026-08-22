import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { PENALTY_DONG, formatDong, isStorableAmount, totalOwed } from './money';

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGRATIONS = join(PROJECT_ROOT, 'supabase', 'migrations');

const allSql = readdirSync(MIGRATIONS)
  .filter((f) => f.endsWith('.sql'))
  .map((f) => readFileSync(join(MIGRATIONS, f), 'utf8'))
  .join('\n');

describe('the amount', () => {
  it('is 500,000 đồng', () => {
    expect(PENALTY_DONG).toBe(500000);
  });

  it('agrees with the database', () => {
    // Two copies of a number that decides what someone owes. The test is what keeps them
    // from drifting, since nothing else would notice.
    expect(allSql).toMatch(/select\s+500000::bigint/i);
  });

  it('is stored as a bigint, not a float', () => {
    expect(allSql).toMatch(/amount_dong\s+bigint\s+not null/i);
    expect(allSql).not.toMatch(/amount_dong\s+(real|double|numeric|decimal|float)/i);
  });
});

describe('what may be stored as an amount', () => {
  it.each([[0], [1], [500000], [12_500_000]])('%i is storable', (value) => {
    expect(isStorableAmount(value)).toBe(true);
  });

  it.each([
    ['a float', 500000.5],
    ['a negative', -500000],
    ['NaN', Number.NaN],
    ['Infinity', Number.POSITIVE_INFINITY],
    ['a number past safe integers', Number.MAX_SAFE_INTEGER + 2],
    ['a string', '500000'],
    ['null', null],
    ['undefined', undefined],
  ])('%s is not', (_label, value) => {
    expect(isStorableAmount(value)).toBe(false);
  });

  it('refuses a float rather than rounding it', () => {
    // Rounding here would make the ledger disagree with itself by an amount nobody can
    // trace, in a number that is a claim against a real person.
    expect(() => formatDong(500000.5)).toThrow();
  });
});

describe('how an amount reads', () => {
  it('groups the digits and names the currency', () => {
    // The figure is the largest thing on the screen. A bare 2500000 is a number the eye has
    // to count before it means anything.
    const formatted = formatDong(2_500_000);
    expect(formatted).toContain('₫');
    expect(formatted).not.toBe('2500000₫');
  });

  it('formats one penalty', () => {
    expect(formatDong(PENALTY_DONG)).toContain('₫');
  });

  it('formats zero without breaking', () => {
    expect(formatDong(0)).toContain('₫');
  });
});

describe('the total owed', () => {
  it('is zero for a clean record', () => {
    expect(totalOwed([])).toBe(0);
  });

  it('adds penalties up', () => {
    expect(totalOwed([PENALTY_DONG, PENALTY_DONG, PENALTY_DONG])).toBe(1_500_000);
  });

  it('stays an exact integer across a long run of failures', () => {
    // Two years of failed days. A float would have started disagreeing with itself well
    // before here; this must be exact.
    const twoYears = Array.from({ length: 730 }, () => PENALTY_DONG);
    expect(totalOwed(twoYears)).toBe(365_000_000);
    expect(Number.isSafeInteger(totalOwed(twoYears))).toBe(true);
  });

  it('refuses a float in the middle of a sum rather than silently absorbing it', () => {
    expect(() => totalOwed([PENALTY_DONG, 0.5])).toThrow();
  });
});

describe('the product never moves money', () => {
  // NFR5. Not a style rule: there is no integration, no stored instrument, no balance this
  // system can move, and a penalty is discharged only by the Referee marking it collected.
  const sourceDirs = ['app', 'components', 'lib', 'supabase'];
  const walk = (dir: string): string[] => {
    const full = join(PROJECT_ROOT, dir);
    return readdirSync(full, { withFileTypes: true }).flatMap((entry) => {
      if (entry.name === 'node_modules' || entry.name.startsWith('.')) return [];
      const path = join(dir, entry.name);
      // Test files are excluded, or this scan finds the very list it is scanning for.
      if (entry.isDirectory()) return walk(path);
      if (/\.test\.tsx?$/.test(entry.name)) return [];
      return /\.(ts|tsx|sql|mjs)$/.test(entry.name)
        ? [readFileSync(join(PROJECT_ROOT, path), 'utf8')]
        : [];
    });
  };
  const sources = sourceDirs.flatMap(walk);

  it('finds the sources to check', () => {
    expect(sources.length).toBeGreaterThan(20);
  });

  it.each([['stripe'], ['paypal'], ['vnpay'], ['momo'], ['payment_intent'], ['card_number']])(
    'has no %s anywhere',
    (needle) => {
      const offending = sources.filter((s) => s.toLowerCase().includes(needle));
      expect(offending).toHaveLength(0);
    },
  );
});
