import type { ReactNode } from 'react';
import Image from 'next/image';
import { RefereeSession } from '@/components/referee-session';

/**
 * The referee's surface gets a brand bar and the doer's does not.
 *
 * That asymmetry is deliberate and comes from the handoff: the doer installs this to a home
 * screen and opens it from an icon, so he already knows what he is looking at and a
 * wordmark on every screen would be one more thing between him and the question. The
 * referee reaches it from a link in a message, in a browser tab beside his own work, once a
 * week at most. He needs to be told whose app this is, and that is the whole job of this bar.
 *
 * It is the third and last claimant of the display face — the wordmark, the debt total, and
 * the running timer, and nothing else in the product.
 *
 * The mark is the app icon rather than a second asset: it is the same image at a size the
 * handoff draws it at, and shipping it twice would be two files that can disagree. Purely
 * decorative here — the wordmark beside it carries the name — so it takes an empty `alt`
 * and is not announced twice.
 *
 * `priority` because it is above the fold on every referee screen and there is exactly one
 * of it: letting it lazy-load would trade a request nobody saves for a mark that pops in.
 *
 * Full-bleed across the window, while everything below it stays in the 544px column. The
 * two are not in tension: the column rule is about the content being read, and this is
 * chrome above it. `.brandbar` in `app/globals.css` carries how that is done.
 *
 * The bar's right-hand half — the account and the way out — is `RefereeSession`, which is a
 * client component and renders nothing while signed out. This file stays a server component
 * so the mark and the name are in the first HTML the browser gets: the referee arrives here
 * from a link and the one thing he must be told immediately is whose app this is.
 */
export default function RefereeLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <header className="brandbar">
        <Image src="/icons/icon-180.png" alt="" width={26} height={26} priority />
        <span className="wordmark">todoapp</span>
        <RefereeSession />
      </header>
      {children}
    </>
  );
}
