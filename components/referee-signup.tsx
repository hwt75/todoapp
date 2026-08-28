'use client';

import { useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { refereeFunctionErrorMessage } from '@/lib/referee';
import { REFEREE_SIGNUP_COPY, canAcceptInvite, isAcceptedInvite } from '@/lib/referee-invite';

type Stage =
  | { kind: 'idle' }
  | { kind: 'submitting' }
  | { kind: 'failed'; reason: string }
  | { kind: 'no-session'; email: string };

/**
 * Where an invitation is spent: the referee chooses a password, and the account is created.
 *
 * This is the "Create account" path `referee-login.tsx` deliberately refuses to offer, and it
 * is offered here only because it is not self-service. The screen is useless without a token
 * the live doer minted (`invite-referee`), and the token names no address — the account is
 * created at whatever address the invitation row carries, so a visitor who reaches this page
 * without a link, or with someone else's, cannot make themselves the referee under an
 * address of their choosing. Story 4.5's Never boundary is intact: no account exists that the
 * doer did not authorise.
 *
 * **The email is never shown before the server answers.** It could have been passed in the
 * link and rendered as reassurance — "you are becoming ref@example.com" — but a query
 * parameter is written by whoever sends the link, so that reassurance would be exactly as
 * trustworthy as the sender, and this screen's whole job is to be safe in the hands of
 * someone the doer did not choose.
 *
 * Signing in immediately afterwards, rather than sending the referee to `/referee/login` to
 * type the password they typed ten seconds ago, is the same platform reasoning
 * `sign-in.tsx` records at length: a session that is not established here is one the
 * home-screen app does not have.
 */
export function RefereeSignup() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const token = searchParams.get('token') ?? '';

  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [stage, setStage] = useState<Stage>({ kind: 'idle' });

  async function submit() {
    setStage({ kind: 'submitting' });

    const supabase = createClient();
    const { data, error } = await supabase.functions.invoke('accept-referee-invite', {
      body: { token, password },
    });

    if (error) {
      // Verbatim from the function's own `{error}` body, for the reason `referee-login.tsx`
      // gives: "expired", "already used" and "replaced by a newer one" have three different
      // answers, and only one of them is "ask for another link".
      setStage({ kind: 'failed', reason: await refereeFunctionErrorMessage(error) });
      return;
    }

    if (!isAcceptedInvite(data)) {
      setStage({ kind: 'failed', reason: 'The server did not say which account was created.' });
      return;
    }

    const email = data.email;

    // The account exists from here on, whatever happens next. Every path below therefore
    // reports something the referee can act on rather than offering the button again — a
    // second submit would spend a token that is already spent and fail with a message about
    // an invitation, which is not the problem they have.
    const { data: session, error: signInError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (signInError) {
      setStage({ kind: 'failed', reason: signInError.message });
      return;
    }

    if (!session.session) {
      setStage({ kind: 'no-session', email });
      return;
    }

    setPassword('');
    setConfirmation('');
    router.replace('/referee');
  }

  const mismatched = confirmation.length > 0 && password !== confirmation;
  const canSubmit = token.length > 0 && canAcceptInvite(password, confirmation);

  return (
    <main>
      <section className="screen">
        <header className="screen-head">
          <h1>{REFEREE_SIGNUP_COPY.title}</h1>
        </header>

        <div className="card card-pad stack">
          {token.length === 0 ? (
            // Stated instead of rendering a form that cannot work. A disabled button with no
            // explanation reads as a bug in the page rather than a missing link.
            <p role="status">{REFEREE_SIGNUP_COPY.missingToken}</p>
          ) : (
            <>
              <p>{REFEREE_SIGNUP_COPY.intro}</p>

              <div>
                <input
                  type="password"
                  autoComplete="new-password"
                  placeholder={REFEREE_SIGNUP_COPY.passwordPlaceholder}
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                />
                <input
                  type="password"
                  autoComplete="new-password"
                  placeholder={REFEREE_SIGNUP_COPY.confirmationPlaceholder}
                  value={confirmation}
                  onChange={(event) => setConfirmation(event.target.value)}
                />
              </div>

              {/* Said as soon as the two fields disagree, not on submit. The invitation is
                  spent by a successful submit, so a typo caught afterwards is not recoverable
                  by trying again. */}
              {mismatched && <p role="status">{REFEREE_SIGNUP_COPY.mismatch}</p>}

              <div className="actions">
                <button
                  type="button"
                  className="action"
                  disabled={!canSubmit || stage.kind === 'submitting'}
                  aria-busy={stage.kind === 'submitting'}
                  onClick={() => void submit()}
                >
                  {stage.kind === 'submitting'
                    ? REFEREE_SIGNUP_COPY.submitting
                    : REFEREE_SIGNUP_COPY.submit}
                </button>
              </div>
            </>
          )}

          {stage.kind === 'failed' && (
            <p role="status">
              <strong>{REFEREE_SIGNUP_COPY.failed}</strong> {stage.reason}
            </p>
          )}

          {stage.kind === 'no-session' && (
            <p role="status">{REFEREE_SIGNUP_COPY.noSession(stage.email)}</p>
          )}
        </div>
      </section>
    </main>
  );
}
