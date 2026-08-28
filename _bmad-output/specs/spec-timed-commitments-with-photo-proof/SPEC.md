---
id: SPEC-timed-commitments-with-photo-proof
companions:
  - brownfield.md
  - lifecycle.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# A commitment with an hour, and a photo that answers for it

## Why

A pain, and it is the product's own. Today every commitment is judged by one question asked the next morning — the author's word, given up to three days later, about a day that has already ended. That works for "did you go to the gym at all" and fails for everything with a moment in it: take the pill at 20:00, call your mother on Sunday evening, leave the house by 07:30. The author cannot express the moment, so the machine cannot enforce it, so the only enforcement is his own memory — which is the thing he paid money to stop relying on.

The same gap runs through evidence. Photo evidence already exists in this product, but only downstream of a loss: he can attach a photo when he *contests* a miss the machine filed. There is no way to show what he did at the moment he did it. So the record of a held day is a yes he typed the next morning, and a yes he typed the next morning is exactly what a person tired of losing money learns to type.

This spec closes both: a commitment may carry a time of day and a window around it, and inside that window a photo stands in for the morning question entirely.

## Capabilities

- **CAP-1**
  - **intent:** The author can set a specific local time of day on a commitment, and a window of minutes after it during which the commitment still counts as met.
  - **success:** A commitment saved with a time and a window persists both; a commitment saved without a time behaves exactly as it does today, with no change to any existing row.

- **CAP-2**
  - **intent:** The author can mark a timed commitment done on the same day it is due, at the moment he does it, rather than answering for it the next morning.
  - **success:** A claim filed at 20:14 on day D is recorded against day D, not day D−1, and the next morning's question does not ask about it.

- **CAP-3**
  - **intent:** The author attaches a photo to that claim, and the photo — not a typed answer — is what makes the day hold.
  - **success:** A claim with an accepted photo settles the day as held with no morning declaration involved. A claim whose photo has not arrived by the end of day D settles as failed.

- **CAP-4**
  - **intent:** The author's claim survives having no network at the moment he does the thing.
  - **success:** A claim filed with no connection is stored locally with the instant of the tap, flushes on reconnection, and is recorded against the day and time it was made — not the day and time it arrived.

- **CAP-5**
  - **intent:** A submitted photo holds the day by default; the referee reviews nothing on a schedule and instead may object to a specific day's proof.
  - **success:** With no referee action at all, every proven day settles as held. A referee objection on one day opens a case against that day and nothing else; no queue, no approval step, and no notification that demands the referee act.

- **CAP-6**
  - **intent:** The author is reminded at the time he chose, close enough to it that the time means what it says.
  - **success:** A commitment due at 20:30 produces a reminder that lands within the window that begins at 20:30 — never after the window has shut.

- **CAP-7**
  - **intent:** Today's surface shows, for each timed commitment, whether its window is ahead, open now, or shut — and whether its proof has landed.
  - **success:** A commitment whose window has closed unproven is visibly distinct from one still awaiting its hour, without opening anything or refreshing.

- **CAP-8**
  - **intent:** Before a time is saved, the author is told what a missed photo costs him.
  - **success:** The setup surface states, in the moment of turning a time on, that no photo by midnight is a failed day and that Grace Days are limited — the author never learns this by losing.

## Constraints

- **The window may not cross midnight.** `due_time + late_window_minutes` must land inside the same local day, enforced by a check constraint on the commitment. A window that crossed midnight would produce a photo captured on D+1 for a day D, which the existing evidence trigger refuses; the trigger is correct and is not being changed. The check compares extracted minutes against 1440 — Postgres `time` arithmetic wraps, so a constraint written as `due_time + interval` would accept exactly the case it exists to refuse.
- **The window is 5 to 240 minutes, defaulting to 30.** Below five minutes it cannot be hit in practice; beyond four hours a time of day stops naming one. Zero is refused: a window of zero requires landing on an exact second.
- **`due_time` is a wall-clock time, and its name says so.** Every `_at` column in this schema is a `timestamptz`. This value is a Postgres `time` — no date, no zone, resolved against `Asia/Ho_Chi_Minh` by whoever reads it. It is never named `_at`.
- **Midnight is the deadline, and there is nothing after it.** A timed commitment with no accepted photo by the end of its own local day is a failed day. It is not asked again the next morning, and it does not inherit the three-day declaration window. The only remaining remedy is a Grace Day, which is capped at two per calendar month.
- **The window is never called "grace."** "Grace Day" already names a countable forgiveness token in this product. The new field is `late_window_minutes`; the concept is a *late window*, and no surface, column, function, or copy string may use the other word for it.
- **Columns, not a new table.** The time and window live on `commitment`; the completion instant and the evidence link live on `declaration`. No occurrence or schedule table is introduced. Two tables narrating one event is how the data starts contradicting itself.
- **A same-day claim must not be filed against yesterday.** The day-derivation trigger currently subtracts one day unconditionally. It must branch on whether the commitment is timed, or every timed claim lands on the wrong day.
- **The settlement deadline becomes per-commitment.** Day close currently waits on one account-wide deadline of D+3. A timed commitment's deadline is midnight of D. A day containing both kinds must close each on its own clock.
- **The morning question skips timed commitments.** The reminder that asks for yesterday must exclude them, exactly as it already excludes hours-quota commitments. Their question died at midnight; asking it again would offer a second, softer answer.
- **The claim queues offline; the photo does not.** The offline queue is browser `Storage` holding JSON. It cannot hold a ten-megabyte image, and making it try would break the one promise that module exists to keep. The claim and the photo are therefore two writes with two fates.
- **Evidence storage is reused, not rebuilt.** The private bucket, the object-ownership policies, the capture-date rule, and the referee's existing viewer all stand. The work is detaching evidence from its appeal, not standing up a second store.
- **Capture date is read from the file, not from EXIF.** No EXIF dependency exists here and none is added. The existing limitation is inherited knowingly.
- **A frozen day accepts no evidence.** Once a day is frozen, a late-arriving photo is refused. It never reopens money that has already settled.
- **The server is the only judge.** Every rule above is enforced in the database. The client may refuse a bad draft to save a round trip; it may never be the place a rule lives. Idempotency keys are generated at the tap and reused by retries; all day and hour boundaries resolve in `Asia/Ho_Chi_Minh` and no client ever derives a date for storage; settlement remains the single writer of derived state.

## Non-goals

- **Monthly repeat.** No month-close layer exists in this product and none is built here. `daily` and `weekly_quota` are unchanged; the author's original request for a monthly cadence is deliberately not served.
- **A referee approval queue.** The referee is never given a list of photos to work through. Any design that requires the referee to act for a day to hold is out of scope.
- **Multiple times per day for one commitment.** One time, one window, one photo per commitment per day.
- **Timing an "avoid it" commitment.** There is no moment of doing to photograph.
- **Timing an hours-quota commitment.** It is judged by measured minutes and is already outside the declaration path entirely.
- **Editing or deleting a filed claim or its photo.** A statement of what he said stands; amending it is a separate recorded act with a ruling.
- **Migrating existing commitments.** They stay untimed and behave exactly as they do today.

## Success signal

The author sets "Thuốc — 20:00, cửa trễ 30 phút", is reminded at 20:00, photographs the pill at 20:12, and the day is held — with no morning question the next day, no referee action, and no typed word from him at all. In the same week he forgets to photograph one evening, and at midnight the day fails on its own, visibly, without anyone deciding it.

## Assumptions

- One `due_time` per commitment per day; multiple scheduled times for a single commitment are not modelled.
- Timed applies to `daily` and `weekly_quota` cadences only.
- `kind = abstain` cannot carry a time.
- Existing commitments stay untimed: a null time means today's morning-declaration behaviour, unchanged.
- The photo is optional on the claim only in the sense that it may arrive later the same day; a claim never becomes permanently valid without one.

## Open Questions

- How long does the referee have to object, and what does an objection produce — a reopened settlement, or an appeal-shaped case with its own ruling and deadline?
- If the referee objects after the day is frozen and its penalty resolved, does the objection move money, or is it recorded and inert?
- Does an objection put the burden back on the author (he must respond) or on the referee (he must state a reason)?
