// Spends an invitation: creates the referee's account with a password the referee chooses,
// and that the doer never sees. The second half of the invite flow `invite-referee` starts.
//
// **This is the only function in this codebase that answers without a session**, so what it
// is willing to do on an anonymous caller's word is the whole of its security surface. It is
// exactly two things: read one row by the SHA-256 of a 256-bit token, and -- if that row is
// outstanding and unexpired -- create one account at the address *that row* names. Nothing
// in the request body reaches the created account except the password. In particular the
// email does not: an acceptance that could name its own address would let whoever forwarded
// the link become the referee under an address the doer never approved, which is the entire
// point of storing the address at mint time (20260828120000).
//
// Authorisation for a referee existing at all was decided at mint time, by the live doer,
// and is not re-derived here -- there is no session to derive it from. This function's job
// is to prove that whoever is calling holds a secret only that doer was ever given.
//
// Distinguishing "expired" from "already used" from "no such invitation" leaks nothing worth
// having: the token space is 2^256, so an attacker who can tell those apart still has
// nothing to enumerate, while a referee holding a link that quietly stopped working has a
// real problem the doer cannot diagnose from a single generic refusal.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Eight rather than the six `sign-in.tsx` asks of the doer. Not a style preference: the doer
// can reset his own password by signing up again with a fresh address if it comes to it,
// while the referee's account is the single unrepeatable one in the system, and it authorises
// rulings that move money. The floor is stated in `lib/referee-invite.ts` too, and the client
// checks it before spending a round trip -- but this is the copy that decides.
const MIN_PASSWORD_LENGTH = 8;

const url = Deno.env.get('SUPABASE_URL')!;
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

  const fields = (body ?? {}) as { token?: unknown; password?: unknown };

  if (typeof fields.token !== 'string' || fields.token.length === 0) {
    return json({ error: 'This link is missing its invitation code.' }, 400);
  }

  if (typeof fields.password !== 'string' || fields.password.length < MIN_PASSWORD_LENGTH) {
    return json(
      { error: `Choose a password of at least ${MIN_PASSWORD_LENGTH} characters.` },
      400,
    );
  }

  const { data: invite, error: lookupError } = await admin
    .from('referee_invite')
    .select('id,email,accepted_at,revoked_at,expires_at')
    .eq('token_hash', await sha256Hex(fields.token))
    .maybeSingle();

  if (lookupError) {
    return json({ error: lookupError.message }, 500);
  }

  if (!invite) {
    return json({ error: 'This invitation is not valid.' }, 404);
  }

  const row = invite as {
    id: string;
    email: string;
    accepted_at: string | null;
    revoked_at: string | null;
    expires_at: string;
  };

  if (row.accepted_at) {
    return json({ error: 'This invitation has already been used.' }, 409);
  }

  // Revoked and expired are separate sentences because they have separate fixes: a revoked
  // link means the doer minted a replacement and the referee should look for a newer message,
  // an expired one means nobody did anything wrong and the doer needs to mint again.
  if (row.revoked_at) {
    return json({ error: 'This invitation was replaced by a newer one.' }, 409);
  }

  if (Date.parse(row.expires_at) <= Date.now()) {
    return json({ error: 'This invitation has expired. Ask for a new link.' }, 410);
  }

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email: row.email,
    password: fields.password,
    email_confirm: true,
  });

  if (createError || !created.user) {
    return json({ error: createError?.message ?? 'The account could not be created.' }, 500);
  }

  // `pair-referee`'s own two-write shape, for its own reason: `on_auth_user_created` lands
  // every account as `doer` unconditionally, and only a service-role update promotes it. A
  // role read from user metadata would be a role the account could have written itself.
  const { error: promoteError } = await admin
    .from('profile')
    .update({ role: 'referee' })
    .eq('id', created.user.id);

  if (promoteError) {
    await admin.auth.admin.deleteUser(created.user.id);

    if (promoteError.code === '23505') {
      return json({ error: 'A referee is already paired. There is no re-pairing yet.' }, 409);
    }
    return json({ error: promoteError.message }, 500);
  }

  // Last, and deliberately not first. If this update fails the account already exists and
  // works -- the referee can sign in, which is what they came for -- and the invitation is
  // left outstanding rather than the reverse. A second attempt on the same link then fails at
  // the promote step against `profile_single_referee`, which is a refusal, not a second
  // referee. Marking the invitation spent before creating the account would invert that: a
  // failure after the mark would burn the only link and leave no account behind it.
  const { error: spendError } = await admin
    .from('referee_invite')
    .update({ accepted_at: new Date().toISOString(), accepted_by: created.user.id })
    .eq('id', row.id);

  if (spendError) {
    return json({ email: row.email, warning: spendError.message }, 200);
  }

  return json({ email: row.email }, 200);
});

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
