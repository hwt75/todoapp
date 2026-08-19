'use client';

import { useEffect, useState } from 'react';
import { PushProbe } from '@/components/push-probe';
import { SignIn } from '@/components/sign-in';
import { readInstallSignals, resolveInstallState, type InstallState } from '@/lib/install-state';

export default function Home() {
  const [installState, setInstallState] = useState<InstallState>('unknown');

  useEffect(() => {
    try {
      // The lint rule below is right, and the proper fix is useSyncExternalStore,
      // which would also re-check on display-mode change and bfcache restore.
      // Deliberately not done yet: this value gates whether the push probe will
      // subscribe at all, and rewriting it days before a one-shot device test
      // would risk breaking that test in a way that looks like an iOS failure.
      // Recorded in deferred-work.md; do it once the channel is proven.
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setInstallState(resolveInstallState(readInstallSignals()));
    } catch {
      // Fail toward showing the instruction. Being told to install when already
      // installed is a small annoyance; never being told is the whole product.
      setInstallState('browser');
    }
  }, []);

  return (
    <main>
      <h1>todoapp</h1>

      {/* Server-rendered so it survives a JavaScript failure. Hidden before
          hydration on an installed launch by the display-mode rule in the layout;
          the JS check below then covers legacy iOS, which reports standalone only
          through navigator.standalone. */}
      {installState !== 'installed' && (
        <section data-install-hint>
          <h2>Add this to your home screen</h2>
          <p>
            On iOS, notifications are only delivered to a web app that has been added to the home
            screen — and without notifications there is no product, because every part of this one
            reaches you by notification or not at all.
          </p>
          <p>Share button, then &ldquo;Add to Home Screen&rdquo;, then open it from its icon.</p>
        </section>
      )}

      {installState === 'installed' && <p>Launched from the home screen.</p>}

      <SignIn />

      <PushProbe installState={installState} />
    </main>
  );
}
