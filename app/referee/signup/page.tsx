import { Suspense } from 'react';
import { RefereeSignup } from '@/components/referee-signup';

/**
 * The invitation lands here. Wrapped in `Suspense` because `RefereeSignup` reads the token
 * with `useSearchParams`, and Next opts a route out of static rendering entirely if that read
 * is not suspended — the fallback is what keeps the shell prerenderable while the query
 * string is client-only, which it has to be: the token must never be part of anything the
 * server renders into HTML a cache could hold.
 */
export default function RefereeSignupPage() {
  return (
    <Suspense>
      <RefereeSignup />
    </Suspense>
  );
}
