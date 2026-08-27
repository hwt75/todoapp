'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { CommitmentList } from '@/components/commitment-list';
import { MorningGate } from '@/components/morning-gate';
import { PushProbe } from '@/components/push-probe';
import { SignIn } from '@/components/sign-in';
import { SilenceIntervention } from '@/components/silence-intervention';
import { Today } from '@/components/today';
import { Ledger, type AppealTarget } from '@/components/ledger';
import { Settings } from '@/components/settings';
import { MonthlyReport } from '@/components/monthly-report';
import { ChainsDetail } from '@/components/chains-detail';
import { FocusSession } from '@/components/focus-session';
import { AppealForm } from '@/components/appeal-form';
import { readInstallSignals, resolveInstallState, type InstallState } from '@/lib/install-state';
import { useGate } from '@/lib/use-gate';
import { createClient } from '@/lib/supabase/client';
import type { AppRole } from '@/lib/roles';

export default function Home() {
  const router = useRouter();
  const [installState, setInstallState] = useState<InstallState>('unknown');
  const [ownerId, setOwnerId] = useState<string | null>(null);
  // `'unknown'` until the fetch below resolves for the current `ownerId` — distinct from
  // `null` (fetched, and it read no role/no row), so the doer shell can stay unrendered for
  // a real referee session rather than defaulting through "not a referee" while the read is
  // still in flight.
  const [role, setRole] = useState<AppRole | null | 'unknown'>('unknown');
  // Which `ownerId` `role` was last reset for — the render-time guard below compares
  // against this rather than an Effect dependency, so the reset below and the render that
  // owns the new `ownerId` land in the same commit (see the comment on that guard).
  const [roleForOwner, setRoleForOwner] = useState<string | null>(null);
  const gate = useGate(ownerId);
  // Story 5.2 (FR-16): whether this account has an active (unsatisfied) Silence episode.
  // Fetched inline, mirroring `role`'s own pattern just above rather than a dedicated hook —
  // the read is a single row check, not a piece of state anything else on this screen needs.
  const [silenceEpisode, setSilenceEpisode] = useState<{ startedDay: string } | null>(null);
  // Which `ownerId` `silenceEpisode` was last reset for — same render-time-reset shape as
  // `roleForOwner` just above, and for the identical reason: switching straight from one
  // signed-in account to another with no sign-out between must not render one more frame
  // under the *previous* account's Silence episode (2026-08-26 review finding — the original
  // cut left this state keyed only to sign-out, the exact cross-account flash `roleForOwner`
  // was written to close for `role`).
  const [silenceEpisodeForOwner, setSilenceEpisodeForOwner] = useState<string | null>(null);
  const [showLedger, setShowLedger] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  // Story 5.4 (FR-24): a new screen in the existing ternary chain below, mirroring
  // `showLedger`/`showSettings` exactly — not a new route.
  const [showMonthlyReport, setShowMonthlyReport] = useState(false);
  const [chainOf, setChainOf] = useState<{ id: string; name: string } | null>(null);
  const [focusOf, setFocusOf] = useState<{ id: string; name: string } | null>(null);
  const [appealOf, setAppealOf] = useState<AppealTarget | null>(null);

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

  // A referee session redirected away to /referee, and never the other way around — RLS
  // (AD-7) is the actual boundary, not this check. Read fresh whenever the account changes
  // rather than trusting SignIn's own internal copy, which this screen has no way to reach.
  //
  // Resets `role` to `'unknown'` the instant `ownerId` itself changes — adjusted here,
  // during render, rather than inside the Effect below, per React's own guidance for
  // resetting state when a value changes. An `ownerId` change (a fresh sign-in, or
  // switching straight from one signed-in account to another with no sign-out between)
  // must not render one more frame under the *previous* account's stale role while the new
  // read is still in flight — a reset written inside the Effect would land one commit too
  // late to guarantee that; this lands in the very same render.
  if (ownerId !== roleForOwner) {
    setRoleForOwner(ownerId);
    setRole('unknown');
  }

  // Same reset, same reason, for the Silence episode (2026-08-26 review finding): landed in
  // the same render as the `ownerId` change itself, not inside the Effect below, so a second
  // account signing in with no sign-out between never renders one more frame under the
  // previous account's episode while the new read is still in flight. No dedicated regression
  // test for this one, unlike `role`'s own: `onAccountChange` only ever fires from `SignIn`,
  // which this file never renders while either this branch or the MorningGate branch below is
  // active (both are early returns) -- so in practice `silenceEpisode` is already `null` for
  // the current account at the one moment a real switch can happen. Kept anyway, matching
  // `role`'s own defensive shape, in case a future refactor changes that mounting guarantee.
  if (ownerId !== silenceEpisodeForOwner) {
    setSilenceEpisodeForOwner(ownerId);
    setSilenceEpisode(null);
  }

  useEffect(() => {
    if (!ownerId) return;

    let cancelled = false;

    createClient()
      .from('profile')
      .select('role')
      .maybeSingle()
      .then(({ data }) => {
        if (!cancelled) setRole((data?.role as AppRole | undefined) ?? null);
      });

    return () => {
      cancelled = true;
    };
  }, [ownerId]);

  const effectiveRole = ownerId ? role : null;

  useEffect(() => {
    if (effectiveRole === 'referee') router.replace('/referee');
  }, [effectiveRole, router]);

  // Story 5.2: the one row RLS ever lets this account see is its own active episode, if any
  // (silence_episode_one_active's own partial unique index guarantees at most one). No
  // `.eq('owner_id', ...)` needed — RLS ("silence_episode: read own") already scopes this,
  // the same convention every other read on this screen already follows.
  useEffect(() => {
    // No setState for the signed-out case — mirrors `useGate`'s own identical comment: the
    // React Compiler rejects it, rightly, and the empty case is derived below instead of
    // stored.
    if (!ownerId) return;

    let cancelled = false;

    createClient()
      .from('silence_episode')
      .select('started_day')
      .is('satisfied_at', null)
      .maybeSingle()
      .then(({ data }) => {
        if (!cancelled) {
          setSilenceEpisode(data ? { startedDay: data.started_day as string } : null);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [ownerId]);

  // Nothing rendered here while the role read is in flight or the redirect above is about to
  // run — the doer's own screen must never flash in front of a referee session, even for one
  // frame. A read that errors resolves `role` to `null` the same as "no row", same as the
  // fetch above always did — RLS (AD-7), not this screen, is what actually protects a doer's
  // data either way, and failing this check closed forever on a transient read error would
  // make the app permanently unusable for the common case (the doer) to guard a UX nicety for
  // the rare one.
  if (ownerId && (role === 'unknown' || effectiveRole === 'referee')) {
    return <main />;
  }

  // Story 5.2 (FR-16): a third top-level branch, ahead of the ordinary Declaration gate below
  // — an active Silence episode replaces routine notifications (including the outstanding
  // Declaration prompt) rather than adding to them, so it must win this fork even when
  // `gate.owing.length > 0` would otherwise render MorningGate directly. The intervention's
  // own one concrete action renders that same MorningGate, unchanged, beneath its copy when
  // there is something to answer.
  // Epic 5 retrospective (2026-08-27), finding A4: when nothing is owing, the intervention
  // used to have no way out at all — no Settings/sign-out, no Ledger, nothing but the copy
  // and the Grace Days sentence, until some later day's commitment happened to become owing
  // again. `!showSettings && !showLedger` lets either escape hatch fall through to the
  // ternary chain below, exactly the way `gate.owing.length > 0` already falls through when
  // neither is requested; closing either returns here, since only answering a Declaration
  // ends the episode (`declaration_satisfies_silence()`), not merely leaving the screen.
  if (ownerId && silenceEpisode && !showSettings && !showLedger) {
    return (
      <main>
        <SilenceIntervention
          ownerId={ownerId}
          startedDay={silenceEpisode.startedDay}
          owing={gate.owing}
          now={gate.now}
          onAnswered={gate.markAnswered}
          onOpenSettings={() => setShowSettings(true)}
          onOpenLedger={() => setShowLedger(true)}
        />
      </main>
    );
  }

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
        (focusOf ? (
          <FocusSession
            ownerId={ownerId}
            commitmentId={focusOf.id}
            name={focusOf.name}
            onClose={() => setFocusOf(null)}
          />
        ) : chainOf ? (
          <ChainsDetail
            commitmentId={chainOf.id}
            name={chainOf.name}
            onClose={() => setChainOf(null)}
          />
        ) : appealOf ? (
          <AppealForm
            ownerId={ownerId}
            commitmentId={appealOf.commitmentId}
            commitmentName={appealOf.commitmentName}
            forDay={appealOf.forDay}
            amountDong={appealOf.amountDong}
            onClose={() => setAppealOf(null)}
          />
        ) : showLedger ? (
          <Ledger
            ownerId={ownerId}
            onClose={() => setShowLedger(false)}
            onOpenAppeal={setAppealOf}
          />
        ) : showMonthlyReport ? (
          <MonthlyReport onClose={() => setShowMonthlyReport(false)} />
        ) : showSettings ? (
          <Settings
            ownerId={ownerId}
            installState={installState}
            onClose={() => setShowSettings(false)}
            onOpenMonthlyReport={() => setShowMonthlyReport(true)}
          />
        ) : (
          <Today
            ownerId={ownerId}
            onOpenLedger={() => setShowLedger(true)}
            onOpenChain={(c) => setChainOf({ id: c.id, name: c.name })}
            onOpenFocus={(c) => setFocusOf({ id: c.id, name: c.name })}
            onOpenSettings={() => setShowSettings(true)}
          />
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
