// Drains the outbox's `email` channel and sends through Resend's HTTP API. The referee's
// own channel (NFR3) — mirrors `outbox-worker`'s shape (Story 2.4a) exactly: claim a batch,
// perform the effect, mark the row, retry up to the same ceiling, never decide anything
// itself. If a question about what *should* happen ever needs answering in here, it belongs
// in `enqueue_gate_reminders()` instead (AD-2, AD-3) — that function already decided this row
// should exist, and by what deadline; this delivers it.
//
// One recipient resolution deliberately does not mirror `outbox-worker`'s own
// `push_subscription` lookup by `owner_id`: that pattern finds *the same account's* devices,
// but here the row's `owner_id` (the doer, kept for FK/cascade/audit consistency with every
// other outbox row) and the actual recipient (the one `role = 'referee'` account) are
// different people. The referee's own email is resolved here, server-side, from
// `auth.users` — never trusted from the payload, and never derived from `owner_id`.
//
// At most one referee can ever exist (`profile_single_referee`,
// 20260824160000_the_referee_has_his_own_way_in.sql), so this resolves once per invocation,
// not once per row — every row this worker ever claims is addressed to the same recipient.

import { createClient } from 'npm:@supabase/supabase-js@2';

const MAX_ATTEMPTS = 5;
const BATCH = 10;

interface OutboxRow {
  id: string;
  owner_id: string;
  payload: { title: string; body: string; sent_at: string };
  attempts: number;
}

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const resendApiKey = Deno.env.get('RESEND_API_KEY');
const resendFromEmail = Deno.env.get('RESEND_FROM_EMAIL');

const db = createClient(url, serviceKey, { auth: { persistSession: false } });

Deno.serve(async () => {
  if (!resendApiKey || !resendFromEmail) {
    // Fail loudly rather than draining the queue into nothing — the same discipline
    // `outbox-worker`'s own VAPID check follows. A worker that marks rows sent without a key
    // is worse than a worker that does not run.
    return json({ ok: false, error: 'RESEND_API_KEY or RESEND_FROM_EMAIL is unset' }, 500);
  }

  const { data: claimed, error } = await db.rpc('outbox_claim', {
    p_batch: BATCH,
    p_channel: 'email',
  });
  if (error) return json({ ok: false, error: error.message }, 500);

  const rows = (claimed ?? []) as OutboxRow[];
  const result = { claimed: rows.length, sent: 0, dead: 0, failed: 0, retrying: 0 };

  const referee = await resolveRefereeEmail();

  for (const row of rows) {
    if (referee.status === 'none') {
      // Undeliverable is a finding, not a success. Marking it sent would hide a recipient
      // that has quietly stopped existing (the I/O Matrix's own "No referee paired" row).
      // This is a terminal state, not a transient one: re-reading "does a referee profile
      // with an email exist" will keep answering the same way until a referee is actually
      // paired, so retrying buys nothing a human fixing that can't.
      await mark(row.id, 'dead', 'no referee paired');
      result.dead++;
      continue;
    }

    if (referee.status === 'error') {
      // Distinct from `status === 'none'`: this is `resolveRefereeEmail()` itself failing
      // (a transient network/API error reading `profile` or calling
      // `auth.admin.getUserById`), indistinguishable from "no referee paired" only if this
      // branch did not exist. Routed through the same retry ceiling a Resend failure gets
      // below, rather than an immediate terminal `dead` — a blip resolving the recipient is
      // not evidence the recipient does not exist.
      await retryOrFail(row, referee.message, result);
      continue;
    }

    try {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${resendApiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from: resendFromEmail,
          to: [referee.email],
          // The outbox's existing title/body/sent_at contract (Story 5.3's own Always
          // boundary) — title becomes the subject, unchanged from what enqueue_gate_reminders()
          // wrote.
          subject: row.payload.title,
          text: row.payload.body,
        }),
      });

      if (res.ok) {
        await mark(row.id, 'sent', null);
        result.sent++;
        continue;
      }

      const lastError = `${res.status}: ${await res.text()}`;
      await retryOrFail(row, lastError, result);
    } catch (e) {
      await retryOrFail(row, (e as Error).message, result);
    }
  }

  return json({ ok: true, ...result });
});

/** `resolveRefereeEmail()`'s own result — a discriminated union rather than `string | null`,
 *  so "no referee is paired" (`'none'`, terminal — every claimed row this run is `dead`) and
 *  "resolving the referee's own email failed" (`'error'`, transient — every claimed row this
 *  run is retried the same way a Resend failure is) can never collapse into the same falsy
 *  value at the call site the way they would have under a bare `string | null`. */
type RefereeResolution =
  | { status: 'ok'; email: string }
  | { status: 'none' }
  | { status: 'error'; message: string };

/** The one `role = 'referee'` account's own email, read from `auth.users` — never the
 *  payload, never `owner_id`. `'none'` when no referee is paired (or the paired account has
 *  no email of its own — a state this schema never otherwise produces, since sign-in is
 *  always email/password); `'error'` when either read itself fails. */
async function resolveRefereeEmail(): Promise<RefereeResolution> {
  const { data: refereeProfile, error: profileError } = await db
    .from('profile')
    .select('id')
    .eq('role', 'referee')
    .maybeSingle();

  if (profileError) return { status: 'error', message: profileError.message };
  if (!refereeProfile) return { status: 'none' };

  const { data: refereeUser, error: userError } = await db.auth.admin.getUserById(
    (refereeProfile as { id: string }).id,
  );
  if (userError) return { status: 'error', message: userError.message };

  const email = refereeUser.user?.email;
  if (!email) return { status: 'none' };

  return { status: 'ok', email };
}

/** Past the ceiling this is a failure with a reason, not an infinite loop. Below it, the
 *  visibility timeout `outbox_claim` already set releases the row for a later tick without
 *  anyone intervening — the same shape `outbox-worker` retries a push under. */
async function retryOrFail(
  row: OutboxRow,
  lastError: string,
  result: { failed: number; retrying: number },
): Promise<void> {
  if (row.attempts >= MAX_ATTEMPTS) {
    await mark(row.id, 'failed', lastError);
    result.failed++;
  } else {
    await db.from('outbox').update({ last_error: lastError }).eq('id', row.id);
    result.retrying++;
  }
}

async function mark(id: string, status: 'sent' | 'dead' | 'failed', error: string | null) {
  await db
    .from('outbox')
    .update({
      status,
      last_error: error,
      sent_at: status === 'sent' ? new Date().toISOString() : null,
    })
    .eq('id', id);
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
