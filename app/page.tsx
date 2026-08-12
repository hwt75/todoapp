'use client';

import { useEffect, useState } from 'react';
import { readInstallSignals, resolveInstallState, type InstallState } from '@/lib/install-state';

export default function Home() {
  const [installState, setInstallState] = useState<InstallState>('unknown');

  useEffect(() => {
    try {
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

      {installState === 'installed' && (
        <p>Launched from the home screen. Notifications are not set up yet.</p>
      )}
    </main>
  );
}
