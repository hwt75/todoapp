'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { REFEREE_LOGIN_COPY } from '@/lib/referee';

type Stage = { kind: 'idle' } | { kind: 'submitting' } | { kind: 'failed'; reason: string };

/**
 * The Referee's own way in — email and password, and nothing else (Story 4.5).
 *
 * `sign-in.tsx`'s `signInWithPassword` shape, reused exactly, for the same platform reason
 * that component gives at length: a magic link or emailed code signs the browser in and
 * leaves the installed home-screen app — the one surface that can receive push — signed
 * out. Its `signUp` ("Create account") path is deliberately not reused here: pairing from
 * Settings is the only way a referee account is ever made (this story's own Never
 * boundary), so this screen offers sign-in only.
 */
export function RefereeLogin() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [stage, setStage] = useState<Stage>({ kind: 'idle' });

  async function submit() {
    setStage({ kind: 'submitting' });

    const supabase = createClient();
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });

    if (error) {
      // Verbatim, for the reason `sign-in.tsx` gives: a wrong password, a refused account
      // and a misconfigured project are three different problems with three different fixes.
      setStage({ kind: 'failed', reason: error.message });
      return;
    }

    if (!data.session) {
      setStage({ kind: 'failed', reason: REFEREE_LOGIN_COPY.noSession });
      return;
    }

    router.replace('/referee');
  }

  const canSubmit = email.includes('@') && password.length >= 6;

  return (
    <main>
      <section>
        <h1>{REFEREE_LOGIN_COPY.title}</h1>

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
          placeholder="Password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
        />

        <button
          type="button"
          className="action"
          disabled={!canSubmit || stage.kind === 'submitting'}
          aria-busy={stage.kind === 'submitting'}
          onClick={() => void submit()}
        >
          {stage.kind === 'submitting' ? REFEREE_LOGIN_COPY.submitting : REFEREE_LOGIN_COPY.submit}
        </button>

        {stage.kind === 'failed' && (
          <p role="status">
            <strong>{REFEREE_LOGIN_COPY.failed}</strong> {stage.reason}
          </p>
        )}
      </section>
    </main>
  );
}
