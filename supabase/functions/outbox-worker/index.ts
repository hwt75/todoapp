// Drains the outbox and sends Web Push. The only thing in this system that holds the
// VAPID private key, and the only thing that speaks to a push service.
//
// It performs effects and decides nothing. Settlement decides; this delivers. If a
// question about what *should* happen ever needs answering in here, it belongs in a
// settlement function instead (AD-2, AD-3).
//
// Two rules come from Story 1.2's findings rather than from theory:
//   - A 2xx from the push service means accepted, not delivered. Rows are marked `sent`.
//   - A push can arrive minutes late, so every payload carries its own `sent_at` and the
//     database refuses one that does not.

import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

const MAX_ATTEMPTS = 5;
const BATCH = 10;

/** 404 and 410 mean the endpoint is gone. Retrying one forever is a queue that never drains. */
const GONE = new Set([404, 410]);

interface OutboxRow {
  id: string;
  owner_id: string;
  payload: { title: string; body: string; sent_at: string };
  attempts: number;
}

interface SubscriptionRow {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
}

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const vapidPublic = Deno.env.get('VAPID_PUBLIC_KEY');
const vapidPrivate = Deno.env.get('VAPID_PRIVATE_KEY');
const vapidSubject = Deno.env.get('VAPID_SUBJECT');

const db = createClient(url, serviceKey, { auth: { persistSession: false } });

Deno.serve(async () => {
  if (!vapidPublic || !vapidPrivate || !vapidSubject) {
    // Fail loudly rather than draining the queue into nothing. A worker that marks rows
    // sent without a key is worse than a worker that does not run.
    return json(
      { ok: false, error: 'VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY or VAPID_SUBJECT is unset' },
      500,
    );
  }
  webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);

  const { data: claimed, error } = await db.rpc('outbox_claim', { p_batch: BATCH });
  if (error) return json({ ok: false, error: error.message }, 500);

  const rows = (claimed ?? []) as OutboxRow[];
  const result = { claimed: rows.length, sent: 0, dead: 0, failed: 0, retrying: 0 };

  for (const row of rows) {
    const { data: subs } = await db
      .from('push_subscription')
      .select('id,endpoint,p256dh,auth')
      .eq('owner_id', row.owner_id)
      .is('dead_at', null);

    const live = (subs ?? []) as SubscriptionRow[];

    if (live.length === 0) {
      // Undeliverable is a finding, not a success. Marking it sent would hide a channel
      // that has quietly stopped existing.
      await mark(row.id, 'dead', 'no live subscription for this account');
      result.dead++;
      continue;
    }

    let anyAccepted = false;
    let lastError = '';

    for (const sub of live) {
      try {
        await webpush.sendNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
          JSON.stringify(row.payload),
        );
        anyAccepted = true;
        await db
          .from('push_subscription')
          .update({ last_sent_at: new Date().toISOString() })
          .eq('id', sub.id);
      } catch (e) {
        const status = (e as { statusCode?: number }).statusCode;
        lastError = `${status ?? 'no status'}: ${(e as Error).message}`;

        if (status !== undefined && GONE.has(status)) {
          await db
            .from('push_subscription')
            .update({ dead_at: new Date().toISOString(), dead_reason: lastError })
            .eq('id', sub.id);
        }
      }
    }

    if (anyAccepted) {
      await mark(row.id, 'sent', null);
      result.sent++;
    } else if (row.attempts >= MAX_ATTEMPTS) {
      // Past the ceiling this is a failure with a reason, not an infinite loop.
      await mark(row.id, 'failed', lastError);
      result.failed++;
    } else {
      // Left pending. The visibility timeout set by outbox_claim releases it for a later
      // tick without anyone intervening.
      await db.from('outbox').update({ last_error: lastError }).eq('id', row.id);
      result.retrying++;
    }
  }

  return json({ ok: true, ...result });
});

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
