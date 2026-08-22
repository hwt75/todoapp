-- The two copies of the copy rules drifted within minutes of being written.
--
-- `to_char(..., 'FM999G999G999')` uses `G`, the *locale-aware* group separator, which
-- follows the database's `lc_numeric`. That gave `500,000₫` while `lib/money.ts`'s
-- `formatDong` gives the Vietnamese `500.000₫` — and the one the author would actually have
-- read on his lock screen was the wrong one.
--
-- Fixed by making the separator explicit rather than inherited. The seam itself — one rule
-- written twice, in two languages — is recorded in deferred-work.md, because a rule kept in
-- step by hand will drift again.

create or replace function public.day_summary_body(
  p_held integer,
  p_total integer,
  p_day date,
  p_amount bigint,
  p_survivor text,
  p_suggestion text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select concat_ws(' ',
    initcap((array['none','one','two','three','four','five','six','seven','eight','nine','ten'])[
      least(p_held, 10) + 1]),
    'of',
    (array['none','one','two','three','four','five','six','seven','eight','nine','ten'])[
      least(p_total, 10) + 1],
    'on ' || to_char(p_day, 'FMDay') || '.',
    case when p_amount is not null
         -- Dots, not commas: Vietnamese grouping, matching `formatDong`. Explicit rather
         -- than inherited from lc_numeric, which is what made them disagree.
         then 'That''s ' || translate(to_char(p_amount, 'FM999G999G999'), ',', '.') || '₫.'
    end,
    case when p_survivor is not null then p_survivor || ' held though.' end,
    case when p_survivor is not null and p_survivor = p_suggestion
         then 'Start there tomorrow.'
         else 'Start with ' || p_suggestion || ' tomorrow.'
    end
  );
$$;

revoke execute on function public.day_summary_body(integer, integer, date, bigint, text, text)
  from public, anon, authenticated;
