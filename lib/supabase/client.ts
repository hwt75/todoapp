import { createBrowserClient } from '@supabase/ssr';

/**
 * The Supabase client for browser code.
 *
 * It carries the publishable key, which grants nothing on its own — every row it can
 * reach is decided by row-level security (AD-7). That is only true because RLS is on
 * from the first table, which is why the migration enabling it and the migration
 * creating the table are the same file.
 *
 * A new client per call rather than a module-level singleton: the session lives in
 * cookies the client reads at construction, and a singleton captured before sign-in
 * keeps serving the signed-out session.
 */
export function createClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  // Checked rather than assumed: these are inlined at build time, so a variable set in
  // the deploy environment after the build is not present here. The push probe learned
  // the same lesson the expensive way — the browser's own error for a missing value is
  // unrecognisable as a configuration problem.
  if (!url || !key) {
    throw new Error(
      'NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY is missing from this ' +
        'build. They are inlined at build time — set them in the deploy environment and redeploy.',
    );
  }

  return createBrowserClient(url, key);
}
