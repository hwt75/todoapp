-- One function was left reachable, and it is the one that names the price.
--
-- Every function in this schema revokes EXECUTE from `public`, `anon` and `authenticated` —
-- AD-2 keeps decisions off the HTTP boundary, and `20260819121500_close_function_exposure.sql`
-- exists because one that did not was reachable at /rest/v1/rpc/. `penalty_amount_dong()` was
-- written without the revoke and has been callable by anyone holding the publishable key ever
-- since.
--
-- It is not a leak: it returns the constant 500000, and that number is on the author's own
-- Ledger. It is a convention with a hole in it, found by the first check that read the whole
-- list instead of one function at a time (`supabase/tests/2-1-roles-and-rls.sql`). The reason
-- to close it is that the next function written by copying a neighbour should copy a rule
-- that holds everywhere, and an RPC endpoint nothing calls is surface for no benefit.
--
-- Settlement is unaffected: `settle_day` and `supersede_expiries` run as their definer and
-- call it from inside the database.

revoke execute on function public.penalty_amount_dong() from public, anon, authenticated;
