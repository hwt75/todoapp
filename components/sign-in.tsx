'use client';

import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import type { AppRole } from '@/lib/roles';

type Stage =
  | { kind: 'loading' }
  | { kind: 'signed-out' }
  | { kind: 'code-sent'; email: string }
  | { kind: 'signed-in'; email: string; role: AppRole | null }
  | { kind: 'failed'; reason: string };

/**
 * Email sign-in, and the account's role once signed in.
 *
 * A six-digit code rather than a magic link, and that is not a style preference. On iOS
 * a link tapped in Mail opens Safari, not the installed home-screen app — so a magic
 * link signs you into the browser and leaves the app, which is the only surface that can
 * receive push, still signed out. A code can be typed where it is needed.
 *
 * The role shown here is read from the profile table through RLS. It is display only:
 * every access decision is made by a policy in `supabase/migrations`, never by this
 * component (AD-7).
 */
export function SignIn() {
  const [stage, setStage] = useState<Stage>({ kind: 'loading' });
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');

  useEffect(() => {
    const supabase = createClient();

    async function load() {
      const { data, error } = await supabase.auth.getUser();
      if (error || !data.user) {
        setStage({ kind: 'signed-out' });
        return;
      }
      setStage({ kind: 'signed-in', email: data.user.email ?? '(no email)', role: null });
      await loadRole(data.user.email ?? '(no email)');
    }

    async function loadRole(userEmail: string) {
      // Through RLS: the policy returns this account's row and no other. A client that
      // asked for someone else's id would get zero rows, not an error.
      const { data } = await supabase.from('profile').select('role').maybeSingle();
      setStage({ kind: 'signed-in', email: userEmail, role: (data?.role as AppRole) ?? null });
    }

    void load();
  }, []);

  async function sendCode() {
    setStage({ kind: 'loading' });
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOtp({ email });
    if (error) {
      setStage({ kind: 'failed', reason: error.message });
      return;
    }
    setStage({ kind: 'code-sent', email });
  }

  async function verify() {
    setStage({ kind: 'loading' });
    const supabase = createClient();
    const { data, error } = await supabase.auth.verifyOtp({ email, token: code, type: 'email' });
    if (error || !data.user) {
      setStage({ kind: 'failed', reason: error?.message ?? 'No user returned' });
      return;
    }
    const { data: profile } = await supabase.from('profile').select('role').maybeSingle();
    setStage({
      kind: 'signed-in',
      email: data.user.email ?? email,
      role: (profile?.role as AppRole) ?? null,
    });
  }

  async function signOut() {
    await createClient().auth.signOut();
    setStage({ kind: 'signed-out' });
    setCode('');
  }

  return (
    <section>
      <h2>Account</h2>

      {stage.kind === 'loading' && <p>Working…</p>}

      {stage.kind === 'signed-out' && (
        <>
          <p>Signing in creates the account everything you record afterwards belongs to.</p>
          <input
            type="email"
            inputMode="email"
            autoComplete="email"
            placeholder="you@example.com"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
          />
          <button type="button" onClick={sendCode} disabled={!email.includes('@')}>
            Email me a code
          </button>
        </>
      )}

      {stage.kind === 'code-sent' && (
        <>
          <p>
            A six-digit code is on its way to {stage.email}. Type it here rather than following any
            link — a link would open Safari and leave this app signed out.
          </p>
          <input
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            placeholder="123456"
            value={code}
            onChange={(event) => setCode(event.target.value.trim())}
          />
          <button type="button" onClick={verify} disabled={code.length < 6}>
            Sign in
          </button>
        </>
      )}

      {stage.kind === 'signed-in' && (
        <>
          <p>
            Signed in as {stage.email} — role <strong>{stage.role ?? 'not readable'}</strong>.
          </p>
          {stage.role === null && (
            <p>
              The profile row was not readable. Either the trigger did not run, or a policy is
              denying it — both are worth knowing about before anything is built on this.
            </p>
          )}
          <button type="button" onClick={signOut}>
            Sign out
          </button>
        </>
      )}

      {stage.kind === 'failed' && (
        <p>
          {/* Verbatim: the exact message is the finding, and a friendly summary would hide
              which of several very different causes this was. */}
          <strong>Failed.</strong> {stage.reason}
        </p>
      )}
    </section>
  );
}
