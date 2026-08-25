// Creates the Referee's account (Story 4.5, FR-19). The one place in this codebase a
// service-role client may live — `lib/supabase/server.ts`'s own header comment is explicit
// that there is no service-role client anywhere else, ever. Creating another account's
// `auth.users` row has no RLS-gated path; it is inherently a service-role operation, so it
// has to happen here, invoked directly by the doer's browser via
// `supabase.functions.invoke()` while his own session is live and can authenticate the call
// itself (unlike `outbox-worker`, which exists for a cron job with no session to carry).
//
// Two writes, deliberately. `auth.admin.createUser()` lands the account through the same
// `on_auth_user_created` trigger every account goes through — `role = 'doer'`,
// unconditionally (20260819120000_account_and_roles.sql). Only a second, separate,
// service-role-only update promotes it to `referee`. Trusting `user_metadata` for the role
// instead would let any self-service `signUp()` write `app_role: 'referee'` into its own
// metadata and promote itself — exactly the class of forgery Story 4.4 closed for
// `declaration.filed_by`.
//
// The caller's own doer-ness is read through a plain publishable-key client carrying the
// caller's own forwarded JWT — never the admin client — so this check is bound by the same
// `profile: read own` RLS policy as everything else, not by a privileged shortcut. Refusing
// a non-doer caller (403) happens before anything is created.
//
// `profile_single_referee` (the story's own migration) is the actual guarantee against two
// concurrent pairing attempts both creating a referee — this function's own "does one
// already exist" read is the cheap, common-case check that keeps an ordinary re-pairing
// attempt from creating and discarding an `auth.users` row every time.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const url = Deno.env.get('SUPABASE_URL')!;
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return json({ error: 'POST only.' }, 405);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Malformed request body.' }, 400);
  }

  const email =
    typeof body === 'object' && body !== null && 'email' in body
      ? (body as { email: unknown }).email
      : undefined;

  if (typeof email !== 'string' || !email.includes('@')) {
    return json({ error: 'A valid email address is required.' }, 400);
  }

  // The caller's own doer-ness, read live through the caller's own forwarded JWT — never
  // the admin client, and never a token claim (this codebase has no `role_from_table()`
  // equivalent to lean on here; the RLS policy this query runs under is the same guarantee).
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return json({ error: 'Sign in as the doer before pairing a referee.' }, 403);
  }

  const caller = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: callerProfile, error: callerError } = await caller
    .from('profile')
    .select('role,is_live_doer')
    .maybeSingle();

  if (callerError) {
    return json({ error: callerError.message }, 500);
  }

  const profile = callerProfile as { role?: string; is_live_doer?: boolean } | null;

  // Not merely `role = 'doer'`: `sign-in.tsx`'s own signup is open to anyone, so any visitor
  // can self-register a `doer` profile with no cap. `is_live_doer` is never client-writable
  // (only `morning_hour` is granted to `authenticated` — 20260819201000) and defaults false,
  // exactly the AD-16 flag every settlement function already uses to tell the real account
  // from an incidental one. Without this check, a self-registered stranger could call this
  // function first and permanently claim the one referee slot `profile_single_referee`
  // allows (this story builds no unpair/re-pair path) — locking the real doer out and
  // handing that stranger's referee account read access to the real doer's own appeals,
  // evidence, penalties, settlements and commitments.
  if (profile?.role !== 'doer' || !profile.is_live_doer) {
    return json({ error: 'Only the live doer account may pair a referee.' }, 403);
  }

  const { data: existingReferee, error: existingError } = await admin
    .from('profile')
    .select('id')
    .eq('role', 'referee')
    .maybeSingle();

  if (existingError) {
    return json({ error: existingError.message }, 500);
  }

  if (existingReferee) {
    return json(
      { error: 'A referee is already paired. There is no re-pairing yet.' },
      409,
    );
  }

  const password = generatePassword();

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });

  if (createError || !created.user) {
    return json({ error: createError?.message ?? 'The account could not be created.' }, 500);
  }

  // Loses cleanly if `profile_single_referee` refuses this update because a concurrent
  // pairing attempt won the race between the read above and here — the auth user this
  // attempt just created is deleted rather than left as a dangling, unreachable doer row.
  const { error: promoteError } = await admin
    .from('profile')
    .update({ role: 'referee' })
    .eq('id', created.user.id);

  if (promoteError) {
    await admin.auth.admin.deleteUser(created.user.id);

    if (promoteError.code === '23505') {
      return json(
        { error: 'A referee is already paired. There is no re-pairing yet.' },
        409,
      );
    }
    return json({ error: promoteError.message }, 500);
  }

  return json({ email, password }, 200);
});

function generatePassword(): string {
  // 18 random bytes -> 24 base64 characters with no padding (18 is divisible by 3). Long
  // enough to be a real password, short enough to relay by text, call or in person, per this
  // story's own Never boundary — no email delivery, ever, of anything. Read off a screen
  // once and typed once, not memorised, so there is no reason to avoid look-alike characters
  // the way a human-chosen password scheme might.
  const bytes = new Uint8Array(18);
  crypto.getRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  // Mapped to `-`/`_` — base64url's own substitution, and genuinely outside the standard
  // base64 alphabet unlike a stray letter or digit would be. `btoa` already emits every
  // letter A-Za-z and digit 0-9 as ordinary output; replacing `+`/`/` into any character
  // from that same set (as an earlier version of this function did with `x`/`z`) would have
  // doubled that character's frequency versus every other one, reproducing the exact skew
  // this substitution exists to avoid.
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_');
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
