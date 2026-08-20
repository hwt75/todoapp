-- The payload rule, moved to where it can actually stop something.
--
-- Story 1.2 paid for this rule: a push arrived minutes late, after the phone rejoined
-- Wi-Fi. Late, not lost — the good outcome — but it means a notification is read at a time
-- the sender cannot know. So a body must never describe the present, and must carry enough
-- of its own timestamp that a copy sitting on the lock screen can be told from a new one.
--
-- The rule was written in `lib/outbox.ts` (`payloadProblems`, `bodyIsSelfDating`) and
-- **nothing has ever called it**. Bodies are built in SQL — `enqueue_gate_reminders` and
-- `settle_day` — and the only guard the database had was `payload ? 'sent_at'`, which
-- checks that a key exists and says nothing about what the sentence claims. Epic 2's
-- retrospective found the whole rule sitting in TypeScript that no production path reaches
-- (A7/T3). A rule that cannot refuse anything is a comment.
--
-- So it moves here. This is the only place in the system where a body can be rejected
-- before it is queued.

create function public.push_body_is_sendable(p_body text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_body is not null
     and btrim(p_body) <> ''
     -- Never the present. Small and blunt on purpose: it cannot catch every way of writing
     -- a claim that expires, but it catches the ones people reach for first.
     and p_body !~* '(right now|just now|currently|at the moment)'
     -- Self-dating, in whatever unit the message is about. A clock time for a message about
     -- a moment ("as of 07:30"); a named day for one about a day ("Four of five on
     -- Tuesday") — a summary in the coach register cannot state a clock time without
     -- sounding like a machine, and that voice is load-bearing.
     and (p_body ~ '[0-9]{1,2}:[0-9]{2}'
          or p_body ~ '(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)');
$$;

comment on function public.push_body_is_sendable(text) is
  'Whether a notification body may be queued: it says something, it does not describe the '
  'present, and it dates itself. Mirrored for reading in lib/outbox.ts, which is not '
  'production code — this function is the rule.';

-- `not valid`, deliberately. It applies to every row queued from now on, which is the whole
-- point; it does not re-judge what has already been sent. Rows already delivered are
-- history, and a migration that fails on the author's own outbox because of a sentence sent
-- in August would teach exactly the wrong lesson about adding a guard late.
alter table public.outbox
  add constraint outbox_body_is_sendable
  check (public.push_body_is_sendable(payload ->> 'body')) not valid;
