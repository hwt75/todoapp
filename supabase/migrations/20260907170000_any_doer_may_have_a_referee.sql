-- Any doer may have a referee. (Stage 2 of 2: open the gate.)
--
-- Story 4.5 declared "at most one referee, ever" a Non-Goal and enforced it with a partial unique
-- index on `profile (role) where role = 'referee'`. The maintainer has decided every account should
-- be able to invite its own, so that index goes.
--
-- It is safe to remove *only* because Stage 1 (20260907160000) landed first. Until then, seven
-- policies granted the referee reads with no owner comparison at all, and the argument for that was
-- precisely this index: exactly one referee could exist, authorised by the one real account.
-- Dropping it while those policies were unscoped would have turned every self-registered account
-- into a way to mint a reader of everybody's appeals, photos, settlements and debts.
--
-- What replaces it is `profile_one_referee_per_doer`, created in Stage 1: at most one referee *per
-- doer*, which is the guarantee the product actually wants. The reach that used to be "the world"
-- is now "the account that invited him", enforced by the policies rather than by scarcity.

drop index public.profile_single_referee;

comment on index public.profile_one_referee_per_doer is
  'At most one referee per doer, the constraint that replaced profile_single_referee ("at most one
  referee, ever") on 2026-09-07. A partial unique index rather than an application check for the
  same reason the old one was: a check-then-act race in the pairing path cannot make the guarantee
  on its own, and every row pairing to the same doer indexes to the same value.';
