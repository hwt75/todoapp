---
title: 'Story 1.3 findings — can TryHackMe be read from outside?'
story_key: '1-3-settle-whether-tryhackme-can-be-read-from-outside'
status: 'settled'
verdict: 'not-readable'
tested: '2026-08-18'
---

# Story 1.3 findings

**The question:** can a server with no browser session read the author's TryHackMe completion
history, with dates, repeatably?

**Answer: no.** FR-8's external-account Auto-check has no reachable target. Per the story's own
acceptance criteria, **FR-8 reduces to the timer Auto-check alone** for v1.

This was the highest-value unknown in the PRD (Open Question 2). It is now closed.

## What was tested, and what came back

All requests made 2026-08-18 with a normal desktop browser User-Agent, no cookies, no session —
which is exactly the position a `pg_cron`-driven Edge Function would be in.

| # | Target | Result |
|---|---|---|
| 1 | `GET /api/v2/public-profile/completed-rooms?user=<hash>&limit=3&page=1` | `429`, `X-Vercel-Mitigated: challenge`, HTML challenge page |
| 2 | `GET /p/<username>` (public profile page) | `429`, `X-Vercel-Mitigated: challenge` |
| 3 | `GET /robots.txt` | `429`, `X-Vercel-Mitigated: challenge` |
| 4 | `GET /api/v2/badges/public-profile?userPublicId=<hash>` | `429`, `X-Vercel-Mitigated: challenge` |
| 5 | `GET /api/usersBadges/<username>` | `429`, `X-Vercel-Mitigated: challenge` |
| 6 | `GET tryhackme-badges.s3.amazonaws.com/<username>.png` | **`200 OK`, `image/png`** — reachable |

Verbatim response headers for #1:

```
HTTP/1.1 429 Too Many Requests
Content-Type: text/html; charset=utf-8
Server: Vercel
X-Vercel-Mitigated: challenge
X-Vercel-Challenge-Token: 2.1787039059.60.YWVkMjEzYzMyZjg1MGQ2Yj...
```

The body is a "Vercel Security Checkpoint" page — a JavaScript proof-of-work that must be solved in a
browser to obtain a `_vercel_jwt` cookie.

**This is site-wide, not endpoint-specific.** `robots.txt` is challenged, which means nothing on
`tryhackme.com` is being served to a sessionless client. It was reproduced from two independent
network egresses, so it is the site's posture rather than one address being throttled.

## The three routes, and why each is closed

**1. The unofficial public-profile API.** `api/v2/public-profile/completed-rooms` is real and is what
the profile page itself calls — but only from inside a browser that has already cleared the
challenge. Server-side it returns the challenge, never JSON.

**2. The official API is not available to this account.** TryHackMe does publish an API, but it is
restricted to **Business and Classroom (Enterprise) plans**, authenticated with a `THM-API-KEY`
header issued to an organisation. An individual subscriber cannot obtain a key. Its shape is also
wrong for this use: it reports per-room scoreboards for an org's learners, not "what did this person
complete, and when."

**3. The badge is reachable but useless here.** The badge PNG lives on S3, outside the Vercel edge,
which is why it answers at all. It fails on two counts, either of which alone is fatal:

- It is a **rendered image**. Rank, points and a room count as pixels — no dates, no room identities.
  There is no completion *history* in it, only a running total.
- It is **stale**. At the time of test its `Last-Modified` was `Sat, 04 Jul 2026` — **45 days old**.
  It is plainly not regenerated when a room is completed.

A daily diff of the room counter was the one idea with any life in it. The staleness kills it: a
counter that may not move for six weeks cannot answer "was a room completed yesterday," which is the
only question FR-8 needed answered.

## The route deliberately not taken

Solving the proof-of-work and carrying the `_vercel_jwt` cookie would very likely reach the JSON.
It was not attempted and should not be, for two reasons that point the same way:

- It is circumventing a bot-detection control the site operator chose to switch on.
- Even setting that aside, it would be **the worst possible foundation for a load-bearing check**.
  The challenge can be retuned or tightened at any moment with no notice, and the Auto-check would
  begin failing silently — on a feature whose entire job is to be trusted when money rides on it.

An Auto-check that depends on evading a control is not an Auto-check; it is a countdown.

## What this changes

- **FR-8 (External account Auto-check) has no target in v1.** The TryHackMe Commitment runs with no
  Auto-check and keeps its Penalty, settled by the author's Declaration under FR-2a.
- **FR-8b already absorbs this** — "an Auto-check that cannot run reports itself unavailable and
  falls through to the author's Declaration; it never reports a miss." The architecture anticipated
  this outcome, so nothing structural has to change.
- **The timer is the only Auto-check in v1**, and it does not reach outside the product. Every other
  Commitment is settled by Declaration.
- Epic 4's external-account Auto-check work is removed from v1 scope.

## Caveat, and how to re-test

Vercel's challenge mode is a setting, and site operators sometimes enable it temporarily while under
attack. This finding is therefore a dated observation (2026-08-18), not a permanent law. It is firm
enough to plan v1 around — the Enterprise-only API and the dateless, stale badge are structural and
would still block FR-8 even if the challenge were lifted tomorrow.

To re-test, look for `200` and JSON rather than `429`:

```bash
curl -s -D - -o /dev/null "https://tryhackme.com/api/v2/public-profile/completed-rooms?user=<hash>&limit=3&page=1" -H "User-Agent: Mozilla/5.0"
```

The `<hash>` is the 24-character hex id in the `user` parameter of that same request on the author's
own profile page, readable from the browser network tab.

Even a `200` would only reopen the question. It would still need a repeatable request returning
**dated** completion data, and a judgement about depending on an undocumented endpoint that the
operator has already shown willingness to put behind a challenge.
