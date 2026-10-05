import { readFileSync, readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

// `supabase/tests/README.md`'s "What is here" table is the only index of what the SQL suite
// proves, and it drifted one story at a time until it described 26 of 46 files (deferred from
// Story 8.1's review). A half-index reads as a complete one. This keeps it complete: a new file
// without a row fails here, and so does a row for a file that no longer exists.

const TESTS_DIR = 'supabase/tests';
const readme = readFileSync(`${TESTS_DIR}/README.md`, 'utf8');
const files = readdirSync(TESTS_DIR).filter((name) => name.endsWith('.sql'));
const rows = [...readme.matchAll(/^\| `([^`]+\.sql)` +\|/gm)].map((match) => match[1]);

describe('the SQL suite index', () => {
  it('has a row for every file under supabase/tests/', () => {
    expect(files.filter((name) => !rows.includes(name))).toEqual([]);
  });

  it('has no row for a file that is not there', () => {
    expect(rows.filter((name) => !files.includes(name))).toEqual([]);
  });
});
