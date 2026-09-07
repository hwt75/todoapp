// Removes evidence objects that no `evidence` row points at.
//
// Attaching a photo is two writes — the object into Storage, then the row that gives it
// meaning — and the second can be refused after the first has succeeded. The object then
// exists, proves nothing, and is reachable by nobody.
//
// It performs effects and decides nothing. `orphaned_evidence_objects()` decides, under two
// guards it owns: nothing points at the object, and it is older than the grace period. If a
// question about *which* objects should go ever needs answering, it belongs in that function
// (AD-2, AD-3).
//
// The deletion goes through the Storage API rather than through a `delete from storage.objects`,
// which is the whole reason this file exists rather than a `security definer` function: removing
// the row leaves the stored bytes behind, which is a worse orphan than the one being fixed, and is
// exactly what `storage.protect_delete()` refuses in order to prevent.

import { createClient } from 'npm:@supabase/supabase-js@2';

const BUCKET = 'appeal-evidence';

/** One pass. A backlog waits for the next hour rather than becoming one unbounded request. */
const BATCH = 100;

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const db = createClient(url, serviceKey, { auth: { persistSession: false } });

Deno.serve(async () => {
  const { data, error } = await db.rpc('orphaned_evidence_objects', { p_batch: BATCH });
  if (error) return json({ ok: false, error: error.message }, 500);

  const names = (data ?? []) as string[];
  if (names.length === 0) return json({ ok: true, named: 0, removed: 0 });

  const { data: removed, error: removeError } = await db.storage.from(BUCKET).remove(names);

  // Loudly, not quietly. Nothing here retries or marks anything: the next pass asks the same
  // question of the same database and gets the same answer, so a failure costs an hour and
  // nothing else. Swallowing it would cost the only signal that the sweep has stopped working.
  if (removeError) {
    return json({ ok: false, named: names.length, error: removeError.message }, 500);
  }

  // `remove` reports what it actually deleted, which is not always what was asked for — an
  // object can go between the database naming it and this call reaching it. Reported as its own
  // number rather than assumed equal to `named`, so a persistent gap is visible.
  return json({ ok: true, named: names.length, removed: (removed ?? []).length });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
