'use client';

import { useEffect, useState } from 'react';
import { CommitmentList } from '@/components/commitment-list';
import { MorningGate } from '@/components/morning-gate';
import { PushProbe } from '@/components/push-probe';
import { SignIn } from '@/components/sign-in';
import { Today } from '@/components/today';
import { Ledger } from '@/components/ledger';
import { readInstallSignals, resolveInstallState, type InstallState } from '@/lib/install-state';
import { useGate } from '@/lib/use-gate';

export default function Home() {
  const [installState, setInstallState] = useState<InstallState>('unknown');
  const [ownerId, setOwnerId] = useState<string | null>(null);
  const gate = useGate(ownerId);
  const [showLedger, setShowLedger] = useState(false);

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

  // The gate is the entire screen, and that is how it blocks. Not a focus trap, not an
  // aria-modal, not an intercepted back gesture — there is simply nothing else rendered.
  // The app still closes, the notification is still dismissable, and a screen reader's
  // rotor still moves freely, because nothing is holding it. That distinction is the
  // accessibility review's one `high` finding: blocking the app must never become locking
  // the device.
  if (ownerId && gate.owing.length > 0) {
    return (
      <main>
        <MorningGate
          ownerId={ownerId}
          owing={gate.owing}
          now={gate.now}
          onAnswered={gate.markAnswered}
        />
      </main>
    );
  }

  return (
    <main>
      {ownerId &&
        (showLedger ? (
          <Ledger onClose={() => setShowLedger(false)} />
        ) : (
          <Today onOpenLedger={() => setShowLedger(true)} />
        ))}

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

      <SignIn onAccountChange={setOwnerId} />

      {ownerId && <CommitmentList ownerId={ownerId} />}

      <PushProbe installState={installState} ownerId={ownerId} />
    </main>
  );
}
