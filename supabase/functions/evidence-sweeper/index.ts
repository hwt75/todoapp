// Removes evidence objects: the ones no `evidence` row points at, and the ones whose row has
// outlived the retention period.
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

/** One pass, per sweep. A backlog waits for the next hour rather than becoming one unbounded
 *  request. Each sweep gets its own budget: a large orphan backlog must not starve retention,
 *  or the thing that actually costs storage would never run. */
const BATCH = 100;

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const db = createClient(url, serviceKey, { auth: { persistSession: false } });

Deno.serve(async () => {
  // Orphans first, then retention. The order is not arbitrary: an orphan has no row, so the
  // retention pass cannot see it, and sweeping orphans first keeps the two from ever naming the
  // same object in one run.
  const orphans = await sweepOrphans();
  if (!orphans.ok) return json(orphans, 500);

  const expired = await sweepExpired();
  if (!expired.ok) return json({ orphans, expired }, 500);

  return json({ ok: true, orphans, expired });
});

/** Objects a two-part write left behind. Unchanged: nothing points at them, so there is nothing
 *  to write back once they are gone. */
async function sweepOrphans() {
  const { data, error } = await db.rpc('orphaned_evidence_objects', { p_batch: BATCH });
  if (error) return { ok: false, error: error.message };

  const names = (data ?? []) as string[];
  if (names.length === 0) return { ok: true, named: 0, removed: 0 };

  const { data: removed, error: removeError } = await db.storage.from(BUCKET).remove(names);

  // Loudly, not quietly. Nothing here retries or marks anything: the next pass asks the same
  // question of the same database and gets the same answer, so a failure costs an hour and
  // nothing else. Swallowing it would cost the only signal that the sweep has stopped working.
  if (removeError) {
    return { ok: false, named: names.length, error: removeError.message };
  }

  // `remove` reports what it actually deleted, which is not always what was asked for — an
  // object can go between the database naming it and this call reaching it. Reported as its own
  // number rather than assumed equal to `named`, so a persistent gap is visible.
  return { ok: true, named: names.length, removed: (removed ?? []).length };
}

/** Photos past the retention period. The bytes go; the row stays and is stamped.
 *
 *  The row is not deleted, and that is the whole design rather than a shortcut:
 *  `commitments_owing()` and `weekly_held_count()` read whether an evidence row exists to decide
 *  whether a claimed day held, and `apply_grace_days()` re-reads the former when correcting an old
 *  day. Deleting rows would turn held days into slipped days and mint penalties nobody earned.
 *  See the migration header and the comment on `evidence.swept_at`. */
async function sweepExpired() {
  const { data, error } = await db.rpc('expired_evidence_objects', { p_batch: BATCH });
  if (error) return { ok: false, error: error.message };

  const rows = (data ?? []) as { evidence_id: string; storage_path: string }[];
  if (rows.length === 0) return { ok: true, named: 0, removed: 0, stamped: 0 };

  const { data: removed, error: removeError } = await db.storage
    .from(BUCKET)
    .remove(rows.map((row) => row.storage_path));

  if (removeError) {
    return { ok: false, named: rows.length, error: removeError.message };
  }

  // Stamp exactly what Storage said it removed, never everything that was named. A row stamped
  // without its bytes gone is a photo the product believes it deleted and is still paying to
  // store — and nothing would ever name it again.
  const gone = new Set((removed ?? []).map((object) => object.name));
  const ids = rows.filter((row) => gone.has(row.storage_path)).map((row) => row.evidence_id);

  if (ids.length === 0) return { ok: true, named: rows.length, removed: 0, stamped: 0 };

  const { data: stamped, error: stampError } = await db.rpc('mark_evidence_swept', { p_ids: ids });

  // The bytes are already gone at this point, so this is not recoverable by retrying the removal
  // — the next pass will simply name the same rows and find nothing to delete. Reported rather
  // than swallowed, because a stamp that never lands is a sweep that never converges.
  if (stampError) {
    return { ok: false, named: rows.length, removed: ids.length, error: stampError.message };
  }

  return { ok: true, named: rows.length, removed: ids.length, stamped: stamped ?? 0 };
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
