// Mints one invitation to become the referee (the invite half of Story 4.5's account
// creation). The account itself is created later, by `accept-referee-invite`, with a
// password the referee chooses and the doer never sees.
//
// This function is `pair-referee` with the account creation removed and a token put in its
// place, and every one of that function's guards is repeated here rather than shared:
// caller is authenticated, caller is a `doer`, caller is the *live* doer, the address is not
// the caller's own, and no referee exists yet. They are repeated deliberately. Two doors
// into the same unrepeatable slot is exactly the shape where a factored-out helper drifts on
// one side and nobody notices, and the cost of the duplication is a few lines that a reader
// of either file can check without opening the other.
//
// `is_live_doer` in particular is not negotiable. `20260824160000`'s header sets out what it
// buys: the referee reads every appeal, every piece of evidence, every settlement and every
// penalty with no owner scoping at all, and that is safe only because the one referee that
// can exist was authorised by the real account rather than by one of the unlimited
// self-registered doers `sign-in.tsx`'s open signup produces. Letting an invitation skip
// that check would hand the slot -- and that read access -- to whoever called this first.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Long enough that a stale link in a chat thread is not a standing key to the referee slot,
// long enough that an invitation sent on a Friday still works on a Monday. The doer can mint
// a replacement at any time, which revokes this one, so a short window costs a click rather
// than a locked door.
const INVITE_TTL_HOURS = 72;

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

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return json({ error: 'Sign in as the doer before inviting a referee.' }, 403);
  }

  // The caller's own JWT, through the publishable key -- never the admin client. The same
  // `profile: read own` policy that constrains every other read constrains this one.
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: callerProfile, error: callerError } = await caller
    .from('profile')
    .select('id,role,is_live_doer')
    .maybeSingle();

  if (callerError) {
    return json({ error: callerError.message }, 500);
  }

  const profile = callerProfile as
    | { id?: string; role?: string; is_live_doer?: boolean }
    | null;

  if (profile?.role !== 'doer' || !profile.is_live_doer || !profile.id) {
    return json({ error: 'Only the live doer account may invite a referee.' }, 403);
  }

  const { data: callerUser, error: callerUserError } = await caller.auth.getUser();

  if (callerUserError) {
    return json({ error: callerUserError.message }, 500);
  }

  if (callerUser.user?.email?.toLowerCase() === email.toLowerCase()) {
    return json({ error: 'The referee must be a different account than your own.' }, 400);
  }

  // The cheap common-case check, exactly as `pair-referee` frames its own: worth a round
  // trip to refuse an ordinary second attempt before minting anything, while
  // `profile_single_referee` remains the actual guarantee at acceptance time.
  const { data: existingReferee, error: existingError } = await admin
    .from('profile')
    .select('id')
    .eq('role', 'referee')
    .maybeSingle();

  if (existingError) {
    return json({ error: existingError.message }, 500);
  }

  if (existingReferee) {
    return json({ error: 'A referee is already paired. There is no re-pairing yet.' }, 409);
  }

  const token = generateToken();
  const expiresAt = new Date(Date.now() + INVITE_TTL_HOURS * 60 * 60 * 1000).toISOString();

  // Supersede whatever was outstanding, then insert. Not one transaction -- the JS client
  // has no transaction -- which is why `referee_invite_single_outstanding` exists: if a
  // concurrent mint wins the gap between these two statements, this insert is refused by the
  // index rather than producing a second live link.
  const { error: revokeError } = await admin
    .from('referee_invite')
    .update({ revoked_at: new Date().toISOString() })
    .is('accepted_at', null)
    .is('revoked_at', null);

  if (revokeError) {
    return json({ error: revokeError.message }, 500);
  }

  const { error: insertError } = await admin.from('referee_invite').insert({
    email,
    token_hash: await sha256Hex(token),
    created_by: profile.id,
    expires_at: expiresAt,
  });

  if (insertError) {
    if (insertError.code === '23505') {
      return json(
        { error: 'Another invitation was created at the same moment. Try again.' },
        409,
      );
    }
    return json({ error: insertError.message }, 500);
  }

  // The only time the token exists in the clear. Nothing stores it, nothing emails it --
  // the doer relays the link, the same Never boundary `pair-referee`'s password already has.
  return json({ email, token, expiresAt }, 200);
});

function generateToken(): string {
  // 32 random bytes -> 43 base64url characters. Wider than the 18 bytes `pair-referee`
  // generates for a password, because this one travels in a URL rather than being typed:
  // there is no length cost to a human, and a bearer token that opens the referee slot
  // should not be the shorter of the two secrets in this system.
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
