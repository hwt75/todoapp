-- AD-3: everything outbound goes through the transactional outbox.
--
-- Settlement never calls out. It inserts here in the same transaction as the verdict, so
-- a pass that rolls back takes the notification with it — there is never a penalty with
-- no notification, nor a notification for a penalty that did not survive.
--
-- The worker that drains this is an Edge Function, because Postgres should not be signing
-- VAPID payloads or parsing a push service's JSON. The outbox is the seam between "must be
-- transactional" and "must speak HTTP".

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------------
-- Where a device's push endpoint lives now.
--
-- Story 1.2 kept this in a gitignored file so a human could paste it into a CLI. That was
-- the proof's apparatus; this is the product.
-- ---------------------------------------------------------------------------------

create table public.push_subscription (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profile (id) on delete cascade,

  -- The push service's URL for this device. Unique because re-subscribing the same device
  -- returns the same endpoint, and two rows would mean two notifications.
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,

  -- Set when the push service says the endpoint is gone (404/410). A dead endpoint retried
  -- forever is a queue that never drains.
  dead_at timestamptz,
  dead_reason text,

  created_at timestamptz not null default now(),
  last_sent_at timestamptz
);

comment on table public.push_subscription is
  'One row per device that has granted notification permission. Endpoint is the push service URL.';

create index push_subscription_live_idx
  on public.push_subscription (owner_id)
  where dead_at is null;

alter table public.push_subscription enable row level security;

create policy "push_subscription: read own"
  on public.push_subscription for select to authenticated
  using ((select auth.uid()) = owner_id);

create policy "push_subscription: register own"
  on public.push_subscription for insert to authenticated
  with check ((select auth.uid()) = owner_id and public.role_from_table() is not null);

create policy "push_subscription: update own"
  on public.push_subscription for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id and public.role_from_table() is not null);

create policy "push_subscription: forget own"
  on public.push_subscription for delete to authenticated
  using ((select auth.uid()) = owner_id);


-- ---------------------------------------------------------------------------------
-- The outbox itself.
-- ---------------------------------------------------------------------------------

create type public.outbox_status as enum ('pending', 'sent', 'dead', 'failed');

create table public.outbox (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profile (id) on delete cascade,

  -- AD-3: every effect carries a dedupe key and must be safe to execute twice.
  -- At-least-once is the guarantee. Exactly-once is not on offer, and pretending
  -- otherwise is how duplicates become silent.
  dedupe_key text not null unique,

  payload jsonb not null,

  status public.outbox_status not null default 'pending',
  attempts integer not null default 0,

  -- A queue that drops its failures is a queue with no evidence.
  last_error text,

  -- Visibility timeout. A claimed row is pushed into the future so a second tick cannot
  -- take it, and a worker that dies mid-send releases it again without anyone intervening.
  not_before timestamptz not null default now(),

  claimed_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),

  constraint outbox_payload_has_body
    check (payload ? 'title' and payload ? 'body'),

  -- Story 1.2 found a push arriving minutes late, after the phone rejoined Wi-Fi. So a
  -- body must carry its own timestamp and never say "now": by the time it is read, "now"
  -- may be a different day.
  constraint outbox_payload_is_self_dating
    check (payload ? 'sent_at')
);

comment on table public.outbox is
  'Effects to perform, written by settlement in its own transaction and drained by the worker. No client may read or write this table.';

create index outbox_claimable_idx
  on public.outbox (not_before)
  where status = 'pending';

alter table public.outbox enable row level security;

-- An explicit deny rather than an absent policy. RLS with no policy already denies, but
-- silence reads as an oversight and this reads as a decision. The grants below are what
-- actually keeps the table out of the API; this is the second lock.
create policy "outbox: no client may touch this"
  on public.outbox for all to authenticated, anon
  using (false)
  with check (false);

revoke all on table public.outbox from anon, authenticated;


-- ---------------------------------------------------------------------------------
-- Enqueue and claim.
-- ---------------------------------------------------------------------------------

/* Called by settlement, inside settlement's own transaction. Returns null when the dedupe
   key has already been seen, which is the point: an effect enqueued twice happens once. */
create function public.outbox_enqueue(
  p_owner uuid,
  p_dedupe_key text,
  p_payload jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
begin
  insert into public.outbox (owner_id, dedupe_key, payload)
  values (p_owner, p_dedupe_key, p_payload)
  on conflict (dedupe_key) do nothing
  returning id into new_id;

  return new_id;
end;
$$;

/* Takes a batch and makes it invisible to any other tick for a minute.

   `for update skip locked` plus a visibility timeout in one statement, never a read
   followed by a write: two ticks overlapping is a normal condition on a schedule, and a
   read-then-write claim sends the same notification twice on the day the first tick runs
   slow. */
create function public.outbox_claim(p_batch integer default 10)
returns setof public.outbox
language sql
volatile
security definer
set search_path = ''
as $$
  update public.outbox o
     set attempts = o.attempts + 1,
         claimed_at = now(),
         not_before = now() + interval '1 minute'
   where o.id in (
     select c.id
       from public.outbox c
      where c.status = 'pending'
        and c.not_before <= now()
      order by c.created_at
      for update skip locked
      limit p_batch
   )
  returning o.*;
$$;

revoke execute on function public.outbox_enqueue(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.outbox_claim(integer) from public, anon, authenticated;
