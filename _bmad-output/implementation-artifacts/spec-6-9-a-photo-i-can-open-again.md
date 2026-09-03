---
title: 'Story 6.9 — A photo I can open again'
type: 'feature'
created: '2026-09-03'
status: 'done'
review_loop_iteration: 1
baseline_commit: '3a4bcbd384d6c2e4b2ba70515a5c30e06cde3763'
story_key: '6-9-a-photo-i-can-open-again'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-6-8-a-photo-i-can-keep-against-any-commitment.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Evidence has been write-only to the author since Story 6.3 — the product's only
signed-URL read belongs to the referee's appeal viewer, so the referee can open a photo and the
author cannot, while the upload control tells him only he can. Story 6.8 sharpened it: a record he
deliberately keeps is worth less than a proof that merely has to exist.

**Approach:** One read, rendered at the three places a photo can be asked for — the day it was taken
(Today), a past day (the commitment's history), and the screen an hours-quota commitment opens
instead of a history (Focus Session). Access does not change: the doer's own rows and objects are
already reachable, so no migration and no policy.

## Boundaries & Constraints

**Always:**
- **No schema change and no policy change.** `evidence: read own` and the owner branch of
  `appeal-evidence objects: owner reads own` already reach a commitment-day photo. If the viewer
  seems to need more, the bug is in the viewer.
- One signing helper, one failure vocabulary, one alt-text rule, shared by every site — three copies
  of a signing loop is how three surfaces start disagreeing about who may see a photo.
- Signed from the ordinary authenticated client, never a service key.
- A photo that cannot be signed is reported as a count, never dropped from the list.
- Photos are read back from the server, never echoed from local upload state.

**Ask First:**
- Any change to the referee's read policies, or to `evidence_object_is_a_commitment_day()`. Story
  6.8 narrowed both so a commitment-day photo reaches the referee as neither object nor row; a
  viewer for the author must not widen either.
- Any need to store a new column, or to add `.select()` plumbing that makes an upload's success
  depend on a read.

**Never:**
- No delete, no replace, no re-upload from the viewer. Editing a filed photo stays a non-goal.
- No download control, no share, no full-screen lightbox, no gallery navigation.
- No back-filling: this shows what exists, and creates no route to attach a photo to a past day.
- Nothing rendered for a day with no photo — no placeholder, no empty frame, no "no photo" label
  against a day that never needed one.
- No verdict language anywhere in the copy. These are records; the pill already says what the day was.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Today, photo attached | `requires_photo` row, photo filed today | The photo is shown on that row's block | N/A |
| Today, just uploaded | Upload reports saved | The photo appears without a manual reload | Re-read fails → saved message stands, photo section says it could not load |
| History | Chains detail for a commitment with photos on some days | Each such day shows its photo; days without one show exactly what they show today | Row read fails → existing failed view |
| Hours quota | `daily_hours_quota` row with `requires_photo` | Focus Session shows the photo for the day it reports on | Same as Today |
| No photos | Commitment has none | Nothing about photos renders anywhere | N/A |
| Signing fails for one | Two photos, one URL cannot be signed | The other renders; a counted note reports the failure | Never a silently shorter list |
| Not the owner | A row or object belonging to another account | Never returned | RLS, no application check |
| Referee | Referee session anywhere near a commitment-day photo | Still zero rows, zero objects | Story 6.8's narrowing, unchanged |

</frozen-after-approval>

## Code Map

- `components/referee-appeal-detail.tsx:157-183` — **the pattern to extract, not to copy.** Rows via
  `evidence.select('id,storage_path')`; a sequential loop calling
  `storage.from('appeal-evidence').createSignedUrl(row.storage_path, 3600)`; `:180-183` the per-item
  failure that increments `evidenceFailures` and `continue`s rather than aborting. `:262-280` the
  render: a bare `<img>` with `// eslint-disable-next-line @next/next/no-img-element` and the reason
  (a signed URL into a private bucket is not fetchable by `next/image`'s optimiser), plus
  `<p role="status">` for the failure count. `lib/referee.ts:322` `RefereeEvidenceItem`, `:357`
  `evidenceAlt(index, total)`. **This component keeps working unchanged; it may adopt the shared
  helper only if that is a pure refactor with its own tests still green.**
- `lib/evidence.ts` — where the shared read belongs, beside `evidenceObjectPath`, `fileCapturedOn`,
  `isEvidenceDated` and `EVIDENCE_COPY`. New copy goes in `EVIDENCE_COPY`, for the reason its own
  comment already gives: copy is a rule, testable without a browser.
- `components/today.tsx:684-736` — the all-day `requires_photo` block; `:685` the
  `requires_photo && !row.due_time` filter. `:403-465` `attachProof` — note it inserts with **no**
  `.select()`, so nothing comes back and the row id is not held anywhere; `:179` `evidenceState` is
  `idle|uploading|saved|failed` and knows no `storage_path`. `:219` the parallel `Promise.all` every
  read is added to, each error checked — where today's evidence read belongs. `:554`
  `onOpen={row.cadence === 'daily_hours_quota' ? onOpenFocus : onOpenChain}` — the routing that
  makes the third site necessary.
- `components/chains-detail.tsx:53-61` the two reads, `:80-86` the `days` array
  (`{day, outcome}`, sorted descending; `d.day` is exactly an `evidence.for_day`), `:132-155` the
  `.card` / `.row` / `.row-main` / `.row-name` render a photo attaches under. `:33-34` its stated
  rule — *"Nothing here is computed"* — which a read does not violate and a derived "should have had
  a photo" would.
- `components/focus-session.tsx:155` `day` — already derived from the same instant the figure is
  drawn from, and already moves across local midnight. The photo section reads that day and needs no
  second clock. `:350-447` the render, `card card-pad stack` blocks to sit beside.
- `supabase/migrations/20260903120000_a_photo_i_can_keep_against_any_commitment.sql:236-262` — the
  owner read policy with its third `exists` branch on `commitment`, `objects.name` qualified.
  `:346-372` the two referee narrowings. **Read-only: this story changes neither.**
- `supabase/tests/6-8-a-photo-i-can-keep-against-any-commitment.sql:368-380` — the owner reading his
  own commitment-day object back under the `authenticated` role, count 1; `:408-416` another doer
  reads 0. **This is the proof the story needs no migration.** No new SQL test is required.
- `app/globals.css:657-662` — the one `img` rule in the product (`display:block; max-width:100%;
  height:auto; border-radius`), written for the referee's evidence and now serving three more sites.
  `.card`/`.card-pad`/`.stack` `:104-178`, `.row`/`.row-main`/`.row-name`/`.row-muted` `:404-442`.
- `components/referee-appeal-detail.test.tsx:77-84` — the `createSignedUrl` mock shape to mirror;
  `:176` asserts the call as `('appeal-1/proof.jpg', 3600)`.
- `components/today.test.tsx:41-49` — `storage.from()` exposes **`upload` only**; add
  `createSignedUrl`. `components/chains-detail.test.tsx:21-35` — **no `storage` key at all**, and the
  `from()` mock resolves on the *first* `.eq()`, so a two-`eq` or `.in()` read needs the query object
  made chainable first.

## Tasks & Acceptance

**Execution:**
- [x] `lib/evidence.ts` — one exported reader that takes a commitment id and the days wanted, reads
      `evidence` rows, signs each `storage_path` for 3600s, and returns the signed items plus a
      count of the ones that could not be signed. Alt text and every new string live in
      `EVIDENCE_COPY`. No component computes a URL or an alt string itself.
- [x] `lib/evidence.test.ts` — the helper's own cases: no rows, all signed, one signing failure, a
      read failure. These cover the I/O Matrix rows that are not about placement.
- [x] `components/today.tsx` — read today's evidence for `requires_photo` rows in the existing
      `Promise.all`, render each photo in that row's block, and re-read after a successful upload so
      a just-attached photo appears without a reload.
- [x] `components/chains-detail.tsx` — read this commitment's evidence and render each day's photo
      inside that day's row. Days without one render exactly as they do now.
- [x] `components/focus-session.tsx` — the photo for the day the screen reports on, using that
      screen's own `day`. This is the only route an `daily_hours_quota` commitment has.
- [x] `components/today.test.tsx`, `components/chains-detail.test.tsx`,
      `components/focus-session.test.tsx` — add `createSignedUrl` to the storage mocks (and a
      `storage` key plus a chainable query object to `chains-detail`'s), then cover each placement
      case in the I/O Matrix, including the signing-failure note and the just-uploaded refresh.

**Acceptance Criteria:**
- Given a photo the author filed on any commitment, when he opens the surface that commitment's row
  leads to, then he can see it — including an `abstain` commitment and an hours-quota one.
- Given no schema or policy change was made, when `supabase/tests/6-8-*.sql` runs, then it passes
  unmodified, and a referee session still reads zero rows and zero objects for a commitment-day photo.
- Given a photo whose URL cannot be signed, when the surface renders, then the remaining photos are
  shown and the failure is reported as a count rather than a shorter list.

## Spec Change Log

## Design Notes

**Why the helper.** Three placements is the condition under which this repo has grown drift before;
Story 6.3's migration says it plainly about the store itself — a second copy is how two surfaces
start disagreeing about who may see a photo. A signing loop deciding expiry, failure handling and
alt text is that same shape. `lib/evidence.ts` already owns the write-side rules and is tested
without a browser.

**Why Today re-reads rather than remembering.** `attachProof` inserts with no `.select()`, so the row
id never reaches the client, and adding one would make an upload's reported success depend on a
second round trip that can fail on its own. Re-reading leaves the server the only thing that says
what exists, for one query on a screen already issuing eight in parallel.

**Why Focus Session, not a new route.** `chain_current` has nothing for `daily_hours_quota` by
construction, so its Chains detail is empty and `today.tsx:554` routes that tap to Focus Session
instead. A second destination for one cadence would put the same photo behind two doors. That screen
already derives the day it reports on and already moves across midnight — it needs a section, not a
clock.

## Verification

**Commands:**
- `npm test` — expected: all existing tests pass, plus the new helper and placement cases.
- `npx tsc --noEmit`, `npm run lint`, `npm run format:check` — expected: clean.
- Every file under `supabase/tests/` — expected: 37 pass, 0 fail, **unmodified**. A change here means
  the story reached for a policy it was told not to touch.
- `npm run migrations:check` — expected: local and remote still match, no new migration.

## Suggested Review Order

**The one read**

- The whole story's shape: many commitments, many days, one round trip each way.
  [`evidence.ts:154`](../../lib/evidence.ts#L154)

- Batched signing — one call for every path, with failures reported per item.
  [`evidence.ts:216`](../../lib/evidence.ts#L216)

- Bounded: a year of history becomes three requests, not a 4KB query string.
  [`evidence.ts:90`](../../lib/evidence.ts#L90)

- Checked between round trips, so leaving a screen stops the work.
  [`evidence.ts:182`](../../lib/evidence.ts#L182)

- Named once, so the writer and the reader cannot drift onto two buckets or two expiries.
  [`evidence.ts:71`](../../lib/evidence.ts#L71)

**The one render**

- The render half in one place, so three surfaces cannot grow three vocabularies.
  [`kept-photos.tsx:82`](../../components/kept-photos.tsx#L82)

- An hour-old URL that has expired becomes a count, never a broken frame.
  [`kept-photos.tsx:94`](../../components/kept-photos.tsx#L94)

- Failures tagged to the read they belong to, so a stale note never outlives its day.
  [`kept-photos.tsx:38`](../../components/kept-photos.tsx#L38)

- Its own class, so the referee's full-size evidence is untouched.
  [`globals.css:668`](../../app/globals.css#L668)

**The three places a photo is asked for**

- The history renders first; photos arrive after. A history without them is still the history.
  [`chains-detail.tsx:127`](../../components/chains-detail.tsx#L127)

- One batched read for every flagged row, kept out of the main parallel read on purpose.
  [`today.tsx:376`](../../components/today.tsx#L376)

- Cleared at midnight alongside the upload state it sits beside.
  [`today.tsx:242`](../../components/today.tsx#L242)

- The only route an hours-quota commitment has, on the day that screen already reports.
  [`focus-session.tsx:241`](../../components/focus-session.tsx#L241)

- Tagged with the commitment and day it answers for, so a stale count never renders.
  [`focus-session.tsx:145`](../../components/focus-session.tsx#L145)
