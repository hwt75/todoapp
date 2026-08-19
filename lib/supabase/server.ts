import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

/**
 * The Supabase client for server components and route handlers.
 *
 * Separate from the browser client because this one carries the request's session
 * cookies. A client built for one request must never be reused for another — that is
 * how one account ends up reading another's rows, and RLS would be powerless to stop
 * it because the session it was handed is genuinely valid.
 *
 * It uses the same publishable key. There is no service-role client in this codebase
 * and there must not be: the service role bypasses every policy in `supabase/migrations`,
 * so the one place it may ever live is Supabase's own Edge Function environment.
 */
export async function createClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (!url || !key) {
    throw new Error(
      'NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY is missing from this build.',
    );
  }

  const cookieStore = await cookies();

  return createServerClient(url, key, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Thrown when called from a server component, which cannot set cookies.
          // Safe to swallow only because session refresh also happens in middleware or
          // a route handler, where the write does land. If that ever stops being true,
          // sessions will expire and not renew — and this comment is where to look.
        }
      },
    },
  });
}
