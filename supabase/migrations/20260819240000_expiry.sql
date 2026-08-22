-- Silence closes a day against him after 48 hours, and an answer that was timely but
-- delivered late takes it back.
--
-- Two things here are load-bearing and neither is obvious.
--
-- 1. An expiry never writes a declaration. `public.declaration` is what the *author said*,
--    and putting a synthetic 'slipped' in it would be the product speaking in his voice
--    about a day he said nothing. The expiry lives in the settlement instead: the verdict
--    knows the day closed on the clock rather than on his word.
--
-- 2. A correction is a new settlement row referencing the old one (AD-9), never an update.
--    Losing the trace of why a penalty appeared and then vanished is exactly what makes a
--    ledger untrustworthy, and this is the first thing in the product that can make one
--    vanish.

alter type public.day_verdict add value if not exists 'expired';
