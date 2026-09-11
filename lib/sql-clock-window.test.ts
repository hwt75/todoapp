import { readFileSync, readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

// CI skips a `supabase/tests/` file whose declared clock window has closed, so that a change
// touching no SQL does not go red for nothing but the hour it was pushed (`.github/workflows/ci.yml`,
// the `Run every file under supabase/tests/` step). The declaration is a comment, and a comment
// cannot fail — which is the whole risk: widen the `raise` inside the file and forget the marker,
// and CI skips hours the file would have run, quietly buying back coverage nobody asked it to
// spend. These tests are what makes that drift loud.

const TESTS_DIR = 'supabase/tests';

/** `-- ci-clock-window: 7-20 Asia/Ho_Chi_Minh` — the same line `ci.yml`'s `sed` reads, and the
 *  reason this expression is duplicated rather than shared: the point is to fail if they differ,
 *  and a shared constant could not. */
const MARKER = /^-- ci-clock-window: (\d{1,2})-(\d{1,2}) (\S+)$/m;

/** The guard the file actually enforces: `if v_hour < 7 or v_hour > 20 then`. */
const GUARD = /if\s+v_hour\s*<\s*(\d{1,2})\s+or\s+v_hour\s*>\s*(\d{1,2})\s+then/;

/** The timezone that guard reads the hour in: `now() at time zone 'Asia/Ho_Chi_Minh'`. */
const GUARD_TZ = /extract\(hour from now\(\) at time zone '([^']+)'\)/;

const sqlFiles = readdirSync(TESTS_DIR)
  .filter((name) => name.endsWith('.sql'))
  .map((name) => ({
    name,
    path: `${TESTS_DIR}/${name}`,
    sql: readFileSync(`${TESTS_DIR}/${name}`, 'utf8'),
  }));

describe('the clock windows CI skips on', () => {
  it('finds at least one file to check, so a rename cannot make this suite vacuously green', () => {
    expect(sqlFiles.length).toBeGreaterThan(0);
    expect(sqlFiles.some((f) => MARKER.test(f.sql))).toBe(true);
  });

  it.each(sqlFiles.filter((f) => MARKER.test(f.sql)))(
    '$name declares the window its own guard enforces',
    ({ path, sql }) => {
      const marker = MARKER.exec(sql);
      const guard = GUARD.exec(sql);
      expect(
        guard,
        `${path} carries a ci-clock-window marker but no \`if v_hour < X or v_hour > Y then\` ` +
          'guard to match it against. Either the guard moved and the marker is now a claim ' +
          'nothing backs, or the marker belongs on a different file.',
      ).not.toBeNull();

      const [, from, to] = marker!;
      const [, guardFrom, guardTo] = guard!;
      expect(
        [from, to],
        `${path}'s marker says ${from}:00-${to}:59 and its guard says ${guardFrom}:00-${guardTo}:59. ` +
          'CI reads the marker and the database reads the guard, so a gap between them is either ' +
          'hours of coverage skipped for no reason or a red job the skip was meant to prevent.',
      ).toEqual([guardFrom, guardTo]);
    },
  );

  it.each(sqlFiles.filter((f) => MARKER.test(f.sql)))(
    '$name declares the timezone its own guard reads the hour in',
    ({ path, sql }) => {
      const [, , , markerTz] = MARKER.exec(sql)!;
      const guardTz = GUARD_TZ.exec(sql);
      expect(
        guardTz,
        `${path} declares a timezone CI will resolve the hour in, but the file itself never ` +
          'names one — so nothing says the two agree.',
      ).not.toBeNull();
      expect(
        markerTz,
        `${path}'s marker resolves the hour in ${markerTz} and its guard in ${guardTz?.[1]}. ` +
          'Seven hours apart, that is most of the window.',
      ).toBe(guardTz![1]);
    },
  );

  it('leaves no clock-bound file undeclared — a guard with no marker is a red job at 21:00', () => {
    const undeclared = sqlFiles
      .filter((f) => GUARD.test(f.sql) && !MARKER.test(f.sql))
      .map((f) => f.path);
    expect(
      undeclared,
      'These files refuse to run outside an hour range but do not say so in the form CI reads, ' +
        'so every push outside it fails on them. Add `-- ci-clock-window: <from>-<to> <tz>` to ' +
        'each, matching its own guard.',
    ).toEqual([]);
  });
});
