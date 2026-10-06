-- A timed window leaves time for its photo (Epic 6 retrospective item 47, finding A3).
--
-- Decided by hwt75 on 2026-10-05. `commitment_window_within_the_day` (20260828130000:63-69) allowed
-- a window to end at exactly 24:00. A claim made at 23:58 inside such a window lands, and then the
-- evidence insert is refused the instant midnight passes (20260903120000:144-149): a timed day is
-- decided at midnight by whether a photo landed, so the day fails for a photo the product itself
-- made impossible to attach. Thirty minutes is the margin: a window ending at 23:30 leaves at least
-- half an hour between the last valid claim and the midnight that judges it.
--
-- Replaces the old constraint rather than adding beside it, because the new one implies the old
-- (1410 < 1440) and two checks saying nearly the same thing invite the next reader to wonder which
-- one is real. Written on extracted minutes for the old one's reason -- `time + interval` wraps,
-- so `23:30 + 60 minutes` reads as 00:30 and would pass.
--
-- **Checked against the live project before writing this** (2026-10-05): no commitment, archived or
-- not, has a window ending after 23:30 -- the latest ends at 19:10. So it is added validated.
--
-- Four SQL files changed with it: 6-1 asserts the new edge on both sides, 6-6 widens its window
-- only as far as the rule allows, and the two files whose fixture needs a window containing "now"
-- declare a ci-clock-window of 0-22, since no window can contain an instant after 23:29.

alter table public.commitment
  drop constraint commitment_window_within_the_day;

alter table public.commitment
  add constraint commitment_window_leaves_time_for_the_photo
    check (
      due_time is null
      or (extract(hour from due_time) * 60
          + extract(minute from due_time)
          + late_window_minutes) <= 1410
    );

comment on constraint commitment_window_leaves_time_for_the_photo on public.commitment is
  'A timed window ends by 23:30 (minute 1410), so a claim made in its last minute still has half an
  hour to attach the photo before midnight decides the day. Replaces
  commitment_window_within_the_day (<= 1440), which let a window end at midnight and a day fail for
  a photo nobody could attach (Epic 6 retrospective item 47). Written on extracted minutes because
  time arithmetic wraps.';
