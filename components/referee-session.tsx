'use client';

import { useEffect, useState } from 'react';
import { usePathname, useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { REFEREE_HOME_COPY } from '@/lib/referee';

/**
 * Who is signed in, and the way out — the right-hand half of the referee's brand bar.
 *
 * It lives in the bar rather than at the foot of his home screen, which is where Sign out
 * used to be. Two reasons. The referee reaches this surface from a link in a message, in a
 * browser tab beside his own work: he needs to be told which account he is looking at
 * before he rules on anything, and "whose session is this" is a question about the window,
 * not about the screen inside it. And Sign out was previously reachable from exactly one of
 * his four screens — from the appeal he had been sent to rule on, there was no way out at
 * all without navigating back first.
 *
 * It renders nothing at all when signed out, which is what leaves the sign-in and
 * accept-invite screens showing the wordmark alone, as the design draws them. The bar
 * itself stays, because it is what says whose app this is to somebody who has never seen it.
 *
 * The identity shown is the account's email. The design writes a first name — *Nam* — but
 * `profile` carries no name column and this is a stylesheet's worth of work, not a schema
 * change: the email is the identity this product actually knows, and showing a real one
 * beats showing a placeholder that is right about nobody.
 *
 * Re-read on every route change rather than subscribed to. Both ways into a session
 * (`referee-login`, `referee-signup`) end in a `router.replace`, and signing out below does
 * the same, so every real transition moves the path and re-runs this. What it does not
 * catch is a session ending with no navigation — a token revoked in another tab — where the
 * bar would name a stale account until the next click. That is a cosmetic lag on a screen
 * whose every read is already scoped by RLS: nothing this component says grants access to
 * anything, and the first request made under a dead session fails on the server.
 */
export function RefereeSession() {
  const router = useRouter();
  const pathname = usePathname();
  const [email, setEmail] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    createClient()
      .auth.getUser()
      .then(({ data, error }) => {
        // An error and a missing user are the same answer here: nobody to name. Failing
        // toward "signed out" hides a control that would not have worked anyway, where
        // failing the other way would put someone else's email in the bar.
        if (!cancelled) setEmail(error ? null : (data.user?.email ?? null));
      });

    return () => {
      cancelled = true;
    };
  }, [pathname]);

  async function signOut() {
    await createClient().auth.signOut();
    // Clears the name before the route resolves. Without it the bar keeps naming the account
    // for as long as the navigation takes, which is the one moment it is certainly wrong.
    setEmail(null);
    router.replace('/referee/login');
  }

  if (!email) return null;

  return (
    <div className="brandbar-session">
      <span className="brandbar-account">{email}</span>
      {/* The separator the design draws between the two. Decorative: the account is a name
          and Sign out is a control, and a screen reader gains nothing from a middle dot
          announced between them. */}
      <span aria-hidden="true">·</span>
      <button type="button" className="quiet" onClick={() => void signOut()}>
        {REFEREE_HOME_COPY.signOut}
      </button>
    </div>
  );
}
