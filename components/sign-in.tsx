'use client';

import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import type { AppRole } from '@/lib/roles';

type Stage =
  | { kind: 'loading' }
  | { kind: 'signed-out' }
  | { kind: 'signed-in'; email: string; role: AppRole | null }
  | { kind: 'failed'; reason: string };

/**
 * Email and password sign-in, and the account's role once signed in.
 *
 * Password rather than a magic link or an emailed code, and the reason is a platform
 * constraint rather than a preference. On iOS a link tapped in Mail opens Safari, not the
 * installed home-screen app — so a magic link signs you into the browser and leaves the
 * one surface that can receive push still signed out. An emailed code would avoid that,
 * but Supabase will not let the email template be edited without custom SMTP, so the code
 * never appears in the message. A password is typed where it is needed and needs no email
 * at all.
 *
 * That is only acceptable because email confirmation is off, which is a decision recorded
 * in `spec-2-1-sign-in-as-the-doer.md` rather than a default that drifted.
 *
 * The role shown here is read from the profile table through RLS, and is display only.
 * Every access decision is made by a policy in `supabase/migrations` (AD-7).
 */
export function SignIn() {
  const [stage, setStage] = useState<Stage>({ kind: 'loading' });
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');

  useEffect(() => {
    // The restore runs inside the effect rather than calling a function declared below
    // it: the React Compiler rejects reading a binding before its declaration, and it is
    // right to — the effect would capture whatever that name meant at mount.
    let cancelled = false;

    async function restore() {
      const supabase = createClient();
      const { data, error } = await supabase.auth.getUser();
      if (cancelled) return;

      if (error || !data.user) {
        setStage({ kind: 'signed-out' });
        return;
      }

      const { data: profile } = await supabase.from('profile').select('role').maybeSingle();
      if (cancelled) return;

      setStage({
        kind: 'signed-in',
        email: data.user.email ?? '(no email)',
        role: (profile?.role as AppRole | undefined) ?? null,
      });
    }

    void restore();
    return () => {
      cancelled = true;
    };
  }, []);

  async function readRole(fallbackEmail: string) {
    const supabase = createClient();
    // Through RLS: the policy returns this account's row and no other. Asking for
    // someone else's id yields zero rows rather than an error.
    const { data } = await supabase.from('profile').select('role').maybeSingle();
    setStage({
      kind: 'signed-in',
      email: fallbackEmail,
      role: (data?.role as AppRole | undefined) ?? null,
    });
  }

  async function submit(mode: 'sign-in' | 'create') {
    setStage({ kind: 'loading' });
    const supabase = createClient();

    const { data, error } =
      mode === 'create'
        ? await supabase.auth.signUp({ email, password })
        : await supabase.auth.signInWithPassword({ email, password });

    if (error) {
      // Verbatim. The exact message separates a wrong password from an unconfirmed
      // account from a project whose signups are disabled, and a friendly summary
      // would flatten three very different problems into one.
      setStage({ kind: 'failed', reason: error.message });
      return;
    }

    if (!data.user) {
      setStage({ kind: 'failed', reason: 'No user returned, and no error was raised.' });
      return;
    }

    if (!data.session) {
      // Happens when email confirmation is still on: the account exists but has no
      // session until a link is clicked — which on iOS lands in Safari, not here.
      setStage({
        kind: 'failed',
        reason:
          'Account created, but no session was issued — email confirmation is still on. Turn it off in Authentication → Sign In / Providers → Email.',
      });
      return;
    }

    setPassword('');
    await readRole(data.user.email ?? email);
  }

  async function signOut() {
    await createClient().auth.signOut();
    setPassword('');
    setStage({ kind: 'signed-out' });
  }

  const canSubmit = email.includes('@') && password.length >= 6;

  return (
    <section>
      <h2>Account</h2>

      {stage.kind === 'loading' && <p>Working…</p>}

      {(stage.kind === 'signed-out' || stage.kind === 'failed') && (
        <>
          <p>Signing in creates the account everything you record afterwards belongs to.</p>

          <input
            type="email"
            inputMode="email"
            autoComplete="email"
            placeholder="you@example.com"
            value={email}
            onChange={(event) => setEmail(event.target.value.trim())}
          />
          <input
            type="password"
            autoComplete="current-password"
            placeholder="Password, at least 6 characters"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />

          <button type="button" onClick={() => submit('sign-in')} disabled={!canSubmit}>
            Sign in
          </button>
          <button type="button" onClick={() => submit('create')} disabled={!canSubmit}>
            Create account
          </button>
        </>
      )}

      {stage.kind === 'failed' && (
        <p>
          <strong>Failed.</strong> {stage.reason}
        </p>
      )}

      {stage.kind === 'signed-in' && (
        <>
          <p>
            Signed in as {stage.email} — role <strong>{stage.role ?? 'not readable'}</strong>.
          </p>
          {stage.role === null && (
            <p>
              The profile row was not readable. Either the trigger that creates it did not run, or a
              policy is denying the read — both are worth knowing before anything is built on this.
            </p>
          )}
          <button type="button" onClick={signOut}>
            Sign out
          </button>
        </>
      )}
    </section>
  );
}
