-- Story 2.8 — the sentence that ends the day, checked where it is actually built.
--
-- This is the intervention against the author's documented pattern: a bad day becoming a bad
-- week. It has to work read from a lock screen, without the app being opened, which makes the
-- copy rules part of the mechanism rather than decoration.
--
-- The rules are written twice — `lib/summary.ts` for reading and `public.day_summary_body` for
-- running — and **they disagreed within minutes of being written**: `to_char`'s group
-- separator followed the database's `lc_numeric` and produced `500,000₫` where the Vietnamese
-- rendering is `500.000₫`, so the sentence the author would have read on his phone was the
-- wrong one. `lib/summary.test.ts` covers the copy that nothing calls. This file covers the
-- one that reaches his lock screen.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/2-8-summary-copy.sql
--
-- One transaction, rolled back at the end. It only calls a function — no account, no
-- settlement — so it is safe against any database including the author's own project.

begin;

do $$
declare
  v_body text;
begin
  -- -------------------------------------------------------------------------------
  -- 1. The separator that drifted.
  --
  -- Dots, not commas, and stated explicitly in the SQL rather than inherited from
  -- `lc_numeric` — which is what made the two copies disagree in the first place. This
  -- assertion is the reason the file exists.
  -- -------------------------------------------------------------------------------
  v_body := public.day_summary_body(4, 5, date '2026-08-18', 500000::bigint,
                                    'TryHackMe', 'No fap', 12);

  if v_body not like '%500.000₫%' then
    raise exception using message = format(
      'The amount reads wrongly in "%s". Vietnamese grouping is 500.000₫; a comma is the '
      'exact drift that shipped once already, and a lock screen is not a place anyone '
      'checks a number twice.', v_body);
  end if;

  if v_body like '%500,000%' then
    raise exception using message = format(
      'The amount uses a comma group separator: "%s". `to_char` follows lc_numeric unless '
      'told otherwise, so this breaks by changing a database setting, not by editing '
      'this function.', v_body);
  end if;

  -- Once, and only once. The money is named after the fact and never while asking — that is
  -- the morning gate's rule, and this message is the only place money may be named at all.
  if (length(v_body) - length(replace(v_body, '₫', ''))) <> 1 then
    raise exception using message = format(
      'The amount appears more than once in "%s".', v_body);
  end if;

  raise notice using message = format('Step 1 ok: "%s"', v_body);

  -- -------------------------------------------------------------------------------
  -- 2. A clean day names no money at all.
  --
  -- Not a formatting nicety. A day that cost nothing must not mention the price of a day
  -- that does — the number is a fact about failure and naming it anyway makes the message
  -- a threat.
  -- -------------------------------------------------------------------------------
  v_body := public.day_summary_body(5, 5, date '2026-08-18', null,
                                    'TryHackMe', 'No fap', 12);

  if v_body like '%₫%' then
    raise exception using message = format(
      'A clean day named an amount: "%s".', v_body);
  end if;

  if v_body not like 'Five of five%' then
    raise exception using message = format(
      'The count does not open the sentence: "%s".', v_body);
  end if;

  raise notice using message = format('Step 2 ok: "%s"', v_body);

  -- -------------------------------------------------------------------------------
  -- 3. Exactly one suggestion, and it does not repeat a name it just used.
  --
  -- Two suggestions is a to-do list, and a list is what this message exists to replace.
  -- When the commitment that held is also the one to start with, the sentence says "there"
  -- rather than saying the name twice like a machine filling a template.
  -- -------------------------------------------------------------------------------
  v_body := public.day_summary_body(1, 3, date '2026-08-18', 500000::bigint,
                                    'TryHackMe', 'TryHackMe', 4);

  if v_body not like '%Start there tomorrow.%' then
    raise exception using message = format(
      'The suggestion repeats a name it has already used: "%s".', v_body);
  end if;

  if (length(v_body) - length(replace(v_body, 'tomorrow', ''))) <> 8 then
    raise exception using message = format(
      'The word "tomorrow" appears more than once in "%s" — there is exactly one '
      'suggestion, or it is a to-do list.', v_body);
  end if;

  raise notice using message = format('Step 3 ok: "%s"', v_body);

  -- -------------------------------------------------------------------------------
  -- 4. The chain clause names what survived, and stays silent when nothing did.
  --
  -- A reset is never a notification's headline, and on the evening of a bad day it is not
  -- a footnote either. `day 0` must never appear.
  -- -------------------------------------------------------------------------------
  v_body := public.day_summary_body(0, 3, date '2026-08-18', 500000::bigint,
                                    null, 'No fap', null);

  if v_body like '%held though%' then
    raise exception using message = format(
      'The sentence claims something held on a day nothing did: "%s".', v_body);
  end if;

  if v_body not like 'None of three%' then
    raise exception using message = format(
      'A day where nothing held does not open with the count: "%s".', v_body);
  end if;

  v_body := public.day_summary_body(1, 3, date '2026-08-18', 500000::bigint,
                                    'TryHackMe', 'No fap', 0);

  if v_body like '%day 0%' then
    raise exception using message = format(
      '"day 0" reached the sentence: "%s". Zero is a count of nothing and reads as a '
      'scoreline; the clause is dropped instead.', v_body);
  end if;

  if v_body not like '%TryHackMe held though.%' then
    raise exception using message = format(
      'The survivor clause is missing or malformed at chain zero: "%s".', v_body);
  end if;

  raise notice using message = format('Step 4 ok: "%s"', v_body);

  -- -------------------------------------------------------------------------------
  -- 5. A limit, asserted as a limit rather than left to be discovered.
  --
  -- The counts are spelled as words from a fixed array of eleven, and anything above ten is
  -- clamped rather than rendered. With eleven commitments the sentence says "Ten of ten",
  -- which is wrong and quiet about it. The author has five, so this is recorded in
  -- deferred-work.md rather than fixed here — and asserted, so that fixing it fails this
  -- line instead of surprising someone.
  -- -------------------------------------------------------------------------------
  v_body := public.day_summary_body(11, 12, date '2026-08-18', null, null, 'No fap', null);

  if v_body not like 'Ten of ten%' then
    raise exception using message = format(
      'The word-count clamp changed: "%s". If this is now rendering 11 and 12 correctly, '
      'delete this assertion and the deferred-work entry with it.', v_body);
  end if;

  raise notice using message =
    'Step 5 ok: the known clamp above ten still reads "Ten of ten" (deferred, not fixed).';

  raise notice using message =
    'PASS. The sentence names the count, the money once and only when there is money, one '
    'suggestion, and only a chain that survived.';
end $$;

rollback;
