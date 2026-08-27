-- Epic 4 retrospective (2026-08-27), action item 6 (finding A7) -- nothing stopped attaching
-- an Auto-check to an Hours-per-day (`daily_hours_quota`) commitment through the ordinary
-- Task-setup UI, even though `commitments_owing()`
-- (`20260820140000_weekly_quota_is_not_judged_daily.sql:45`) excludes that cadence entirely,
-- so neither `settle_day()` nor `settle_week()` -- nor `auto_check_pending()`'s AD-13
-- settlement-gating guard, which only ever runs from those two -- would ever look at one.
-- An attached check would sit there with no path that could ever enforce it: not a live
-- exploit (confirmed by re-reading `auto_check_pending()`/`commitments_owing()` directly),
-- but a real, defensible-to-close ambiguity. Mirrors the existing `abstain` exclusion exactly.

alter table public.commitment
  add constraint commitment_auto_check_not_on_hours_quota check (
    auto_check_kind is null or cadence <> 'daily_hours_quota'
  );

comment on constraint commitment_auto_check_not_on_hours_quota on public.commitment is
  'Epic 4 retrospective (2026-08-27), finding A7: an Hours-per-day commitment is judged by '
  'banked Focus-Session minutes (commitments_owing() excludes daily_hours_quota entirely), '
  'never by a Declaration -- so no settlement path would ever consult an Auto-check attached '
  'to one. Mirrors commitment_auto_check_not_on_abstain''s own shape and reasoning.';
