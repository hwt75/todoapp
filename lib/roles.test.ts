import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { ROLE_HELPERS } from './roles';

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGRATIONS_DIR = join(PROJECT_ROOT, 'supabase', 'migrations');

interface Migration {
  file: string;
  sql: string;
}

const migrations: Migration[] = readdirSync(MIGRATIONS_DIR)
  .filter((file) => file.endsWith('.sql'))
  .sort()
  .map((file) => ({ file, sql: readFileSync(join(MIGRATIONS_DIR, file), 'utf8') }));

/** SQL with `--` line comments removed, so prose about a rule never trips a check for it. */
function stripComments(sql: string): string {
  return sql
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');
}

/** Balanced-paren extraction of every `with check (...)` body in a migration. */
function withCheckClauses(sql: string): string[] {
  const bodies: string[] = [];
  const source = stripComments(sql);

  for (const match of source.matchAll(/with\s+check\s*\(/gi)) {
    let depth = 1;
    let index = match.index! + match[0].length;
    const start = index;

    while (index < source.length && depth > 0) {
      if (source[index] === '(') depth++;
      else if (source[index] === ')') depth--;
      index++;
    }

    bodies.push(source.slice(start, index - 1));
  }

  return bodies;
}

describe('migrations exist to be checked', () => {
  it('finds migration files', () => {
    // Without this the guards below would pass vacuously on an empty directory.
    expect(migrations.length).toBeGreaterThan(0);
  });
});

describe('the write path never trusts the token', () => {
  // This is the guard that makes the hybrid role resolution affordable. `using` filters
  // rows that already exist, so a stale role there costs a read, bounded by the token's
  // lifetime. `with check` decides whether a row may come into existence — a stale role
  // there writes something that should never have been written, and no refresh undoes it.
  it.each(migrations.map((m) => [m.file, m] as const))(
    '%s has no `with check` reading the role from the JWT',
    (_file, migration) => {
      for (const clause of withCheckClauses(migration.sql)) {
        expect(
          clause,
          `${migration.file}: a \`with check\` clause calls ${ROLE_HELPERS.read}(). ` +
            `Write paths must use ${ROLE_HELPERS.write}(), which is always current.`,
        ).not.toMatch(new RegExp(ROLE_HELPERS.read, 'i'));
      }
    },
  );

  it('recognises a violation when it sees one', () => {
    // The guard above passes today because nothing violates it yet. That is exactly when
    // a guard silently stops working, so the extractor is checked against a known-bad
    // policy rather than trusted.
    const bad = `create policy "x" on public.t for insert to authenticated
                   with check ( public.${ROLE_HELPERS.read}() = 'referee' );`;
    const clauses = withCheckClauses(bad);
    expect(clauses).toHaveLength(1);
    expect(clauses[0]).toMatch(new RegExp(ROLE_HELPERS.read));
  });

  it('does not mistake a comment for a policy', () => {
    const commented = `-- with check ( public.${ROLE_HELPERS.read}() = 'referee' )\nselect 1;`;
    expect(withCheckClauses(commented)).toHaveLength(0);
  });
});

describe('every table carries row-level security', () => {
  // AD-7: authorization lives in RLS. A table that ships without it has been readable by
  // anyone holding the publishable key for as long as that deploy lasted.
  const allSql = migrations.map((m) => stripComments(m.sql)).join('\n');
  const created = [...allSql.matchAll(/create\s+table\s+(?:if\s+not\s+exists\s+)?public\.(\w+)/gi)]
    .map((m) => m[1])
    .filter((name, index, all) => all.indexOf(name) === index);

  it('finds the tables to check', () => {
    expect(created.length).toBeGreaterThan(0);
  });

  it.each(created.map((name) => [name]))('public.%s has RLS enabled', (table) => {
    const pattern = new RegExp(
      `alter\\s+table\\s+public\\.${table}\\s+enable\\s+row\\s+level\\s+security`,
      'i',
    );
    expect(allSql, `public.${table} was created without enabling RLS`).toMatch(pattern);
  });

  it.each(created.map((name) => [name]))('public.%s has at least one policy', (table) => {
    const pattern = new RegExp(`create\\s+policy[^;]*?\\son\\s+public\\.${table}\\b`, 'is');
    expect(
      allSql,
      `public.${table} has RLS enabled but no policy — that denies everything`,
    ).toMatch(pattern);
  });
});

describe('no policy is left open', () => {
  // `using (true)` for a client role grants every row to everyone holding the publishable
  // key. It is legitimate only for internal roles such as the auth admin the token hook
  // runs as, which cannot be reached from a browser.
  const CLIENT_ROLES = ['authenticated', 'anon', 'public'];

  it.each(migrations.map((m) => [m.file, m] as const))(
    '%s grants no client role a `using (true)` policy',
    (_file, migration) => {
      const source = stripComments(migration.sql);
      for (const policy of source.matchAll(/create\s+policy[\s\S]*?;/gi)) {
        const text = policy[0];
        if (!/using\s*\(\s*true\s*\)/i.test(text)) continue;

        const to = /\sto\s+([\w\s,]+?)(?:\s+using|\s+with|\s*\()/i.exec(text)?.[1] ?? '';
        const targets = to.split(',').map((role) => role.trim().toLowerCase());

        for (const role of targets) {
          expect(
            CLIENT_ROLES,
            `${migration.file}: policy grants \`using (true)\` to \`${role}\`, which is ` +
              `every row to anyone holding the publishable key`,
          ).not.toContain(role);
        }
      }
    },
  );
});

describe('functions cannot be hijacked through search_path', () => {
  // A SECURITY DEFINER function that resolves names through a caller-controlled
  // search_path is a privilege escalation. Supabase's own advisor flags it, but the
  // advisor only runs against a live project — this runs on every commit.
  it.each(migrations.map((m) => [m.file, m] as const))(
    '%s pins search_path on every function it defines',
    (_file, migration) => {
      const source = stripComments(migration.sql);
      for (const fn of source.matchAll(
        /create\s+(?:or\s+replace\s+)?function\s+public\.(\w+)[\s\S]*?\$\$/gi,
      )) {
        expect(fn[0], `${migration.file}: public.${fn[1]}() does not set search_path`).toMatch(
          /set\s+search_path\s*=/i,
        );
      }
    },
  );
});
