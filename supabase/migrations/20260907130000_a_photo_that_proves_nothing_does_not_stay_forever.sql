-- A photo that proves nothing does not stay forever.
--
-- Attaching a photo is two writes: the object into Storage, then the `evidence` row that gives it
-- meaning. The second can fail after the first has succeeded, and every refusal
-- `evidence_derive_owner()` raises happens at exactly that point -- a capture date that does not
-- match the day, a day that has already ended (AD-1), a parent the caller does not own. The object
-- then exists, proves nothing, is reachable by nobody, and until now nothing in the product could
-- remove it. Two entries in deferred-work.md have recorded that since Story 6.8, both waiting on a
-- mechanism that did not exist.
--
-- **The database names orphans; it never deletes them.** That split is not ceremony. Deleting a
-- `storage.objects` row removes the metadata and leaves the stored bytes behind -- a worse orphan
-- than the one being fixed, and precisely what `storage.protect_delete()` exists to prevent. The
-- Storage API is the only path that removes both, so the deletion belongs to a worker that can
-- speak it. This is the same division AD-2 and AD-3 already draw: the database decides, the worker
-- performs.


-- ---------------------------------------------------------------------------------
-- What counts as an orphan.
-- ---------------------------------------------------------------------------------

/* Two independent guards, and neither may stand in for the other.

   **Nothing points at it.** `evidence.storage_path` is `not null unique` and holds exactly the
   object's `name` (20260824130000:253), so this is an equality, not a pattern match.

   **It is older than the grace period.** An object with no `evidence` row is not necessarily
   abandoned -- it may be a write whose second half has not happened yet -- and the only thing
   separating the two cases is time. An hour is far longer than any upload and short enough that
   orphans do not accumulate. Deliberately not zero, which would delete photos out from under live
   uploads, and deliberately not a day, which would make the sweep theatre.

   Bounded, because a backlog must not become one statement that runs for as long as it takes. The
   rest wait for the next hour; nothing about an orphan is urgent. */
create function public.orphaned_evidence_objects(
  p_grace interval default interval '1 hour',
  p_batch integer default 100
)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name
    from storage.objects o
   where o.bucket_id = 'appeal-evidence'
     and o.created_at < now() - p_grace
     and not exists (
       select 1
         from public.evidence e
        where e.storage_path = o.name
     )
   order by o.created_at
   limit greatest(p_batch, 0);
$$;

comment on function public.orphaned_evidence_objects(interval, integer) is
  'The objects in appeal-evidence that no evidence row points at and that are older than p_grace --
  the ones a two-part write left behind when its second half was refused. Names them only; the
  deletion belongs to the evidence-sweeper Edge Function, because the Storage API is the only path
  that removes the stored bytes as well as the row. Oldest first, capped at p_batch. Revoked from
  every client role: the answer is a list of storage paths, and the only caller that needs it is the
  worker.';

revoke execute on function public.orphaned_evidence_objects(interval, integer)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------------
-- The sweeper's own schedule.
-- ---------------------------------------------------------------------------------

/* The same waker shape every worker here uses, and for the same reasons: the authorization comes
   from Vault so a service key never lands in a migration, and a missing secret raises rather than
   returning quietly, because a cron job that silently does nothing looks exactly like a working
   system (AD-3).

   It reuses `outbox_worker_key`, as `wake_email_worker()` does (20260826100000:411) -- the key
   authorizes invoking a function, not one particular function, and inventing a second secret would
   add a setup step that buys nothing. */
create function public.wake_evidence_sweeper()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  auth_key text;
  project_url text;
begin
  select decrypted_secret into auth_key
    from vault.decrypted_secrets
   where name = 'outbox_worker_key';

  select decrypted_secret into project_url
    from vault.decrypted_secrets
   where name = 'project_url';

  if auth_key is null or project_url is null then
    raise exception
      'Vault is missing `outbox_worker_key` or `project_url`. Orphaned evidence objects have no '
      'sweeper, which looks exactly like a working system. See README, Database and sign-in.';
  end if;

  perform net.http_post(
    url     := project_url || '/functions/v1/evidence-sweeper',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || auth_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000
  );
end;
$$;

revoke execute on function public.wake_evidence_sweeper() from public, anon, authenticated;

-- Hourly, at `:17`. Nothing about an orphan is urgent -- it is invisible to the author and costs
-- storage, not money -- and the minute is chosen only to sit clear of the other jobs in the hour:
-- `:05` gate-reminders, `:50` due-time reminders, `:55` the email worker.
select cron.schedule(
  'evidence-sweeper',
  '17 * * * *',
  $$select public.wake_evidence_sweeper()$$
);
