-- The outbox worker's own schedule.
--
-- AD-3 is explicit that this is separate from settlement's: "the outbox must drain even
-- when no settlement ran, or a queue with no consumer looks exactly like a working
-- system." So this job exists whether or not anything is settling, and nothing about
-- settlement may ever come to depend on it running, or vice versa.

/* Wakes the worker over HTTP.

   The authorization comes from Vault, never from this file: a service key committed to a
   migration is a service key in the repository, and the whole point of the worker holding
   its own secrets is that they never land here.

   It raises rather than returning quietly when the secret is missing. A cron job that
   silently does nothing is precisely the failure AD-3 warns about — the queue looks
   healthy, the producer keeps producing, and nobody learns until a notification that
   mattered never arrived. A failing job is at least visible in `cron.job_run_details`. */
create function public.wake_outbox_worker()
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
      'Vault is missing `outbox_worker_key` or `project_url`. The outbox has no consumer, '
      'which looks exactly like a working system. See README, Database and sign-in.';
  end if;

  perform net.http_post(
    url     := project_url || '/functions/v1/outbox-worker',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || auth_key
               ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000
  );
end;
$$;

revoke execute on function public.wake_outbox_worker() from public, anon, authenticated;

-- Every minute. The morning gate's push has to land close to the configured hour, and a
-- minute of slack is the most that can be spent before "07:30" stops meaning 07:30.
select cron.schedule(
  'outbox-worker',
  '* * * * *',
  $$select public.wake_outbox_worker()$$
);
