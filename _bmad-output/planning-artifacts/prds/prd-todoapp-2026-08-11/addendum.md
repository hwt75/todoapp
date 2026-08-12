---
title: "Addendum: todoapp PRD"
status: final
created: 2026-08-11
updated: 2026-08-11
---

# Addendum

Depth from the PRD conversation that architecture, UX, and story work will need, plus rationale for
options considered and set aside. Not part of the PRD.

## Revised during UX (2026-08-11)

Two decisions taken in the UX phase overturned settled PRD scope, and the PRD was patched rather than
left to drift.

**In-app Commitment editing came back.** The PRD had ruled it out on the grounds that five fixed
commitments do not justify a create/edit/delete flow for a solo builder. The author asked for it
directly. The cost is real but the argument against it was weaker than it looked: he cannot know in
advance which commitments are worth staking money on, and a fixed set makes that unlearnable.

**Verification tiers collapsed into optional Auto-checks.** The PRD modelled Machine / Declared /
Timer as three exclusive tiers assigned per commitment. The author asked for automatic checks to be
opt-in at creation time instead. The resulting model is simpler, not more complex: every Commitment
is declared, and an Auto-check merely files that declaration on his behalf. It also removes an
awkwardness the tiered model never resolved — that Timer was a "verification tier" which verified
nothing.

That change forced a question the tiered model had hidden: when an Auto-check says missed and the
author says done, who wins? FR-2a settles it on whether money is at stake. Machine wins where a
Penalty rides on it, appealable to the Referee; the author's word wins where none does, with no
Appeal and no referee involvement at all. Rejected alternatives were *machine always wins* (turns
every penalty-free commitment into an argument with a sensor) and *the author always wins* (leaves
Auto-checks with no authority anywhere, making the gym commitment as honor-based as the abstinence
one).

## Where this PRD departs from the brief

Three departures, all deliberate, all the author's call.

**The verification tiering was inverted.** The brief's stated principle was that only
machine-verifiable commitments carry money. Applied literally to the author's real week, this put
500,000 VND on tasks he already completes reliably and nothing at all on the abstinence commitment
that is the reason the product exists. He overrode it: the Declared tier now carries the Penalty.

This is a genuine weakening of the anti-cheat story, and it should be named honestly for whoever
reads this later. The entire mechanism rests on the author pressing a button that costs him money
when nobody could otherwise know. That is close to Beeminder's honour model, which the brief
explicitly judged insufficient for a user who has already failed this task alone many times. What
makes it more than an honour system is only partly the Referee — the Referee collects, but the
Referee is never the one who detects. The detection step has no second party in it.

The design response is §4.4: never ask for a voluntary confession, ask a blocking question the next
morning at the first phone pickup. The author's morning is fixed and observed — 07:30, wash, fifteen
minutes of exercise, then phone for Facebook and OKX prices — which makes that slot reliable in a way
no other moment of his day is. The bet is that he will not lie at 07:30 about the night before,
even though he would not volunteer it at 23:30. Untested.

**A new failure mode entered scope.** The brief's axis was slip-then-vanish. In PRD discovery the
author named a second, unrelated failure: distraction at the *start* of work, not collapse partway
through. This lands squarely on the open-ended commitments the brief had already conceded it could
not help — no finish line, no verification, no money. Focus Sessions (§4.5) exist to answer it, and
they are the one feature in this PRD with no ancestor in the brief.

**The Penalty is flat and uncapped.** Flat per Failed Day rather than per missed Commitment, and with
no ceiling.

## Options considered and rejected

**A Penalty cap or weekly stop-loss.** Argued on the grounds that an uncapped flat Penalty compounds
fast — a bad week reaches 3.5 million VND — and that the brief already ranks "penalties accelerate
the abandonment they exist to prevent" as risk three. At four consecutive Failed Days, deleting the
app is the author's most rational available move, and the product then loses in exactly the way it
was designed to prevent. **Rejected by the author**, on the grounds that he can afford it. Worth
recording that this answers a different question than the one asked: affordability was never the
concern, motivation was. SM-C2 exists as the tripwire.

**Per-Commitment Penalties (500,000 VND each).** Rejected in favor of flat-per-day. Per-Commitment
removes the "the day is already lost" cliff, but a bad day reaches 1.5 million VND and becomes its own
reason to uninstall.

**500,000 VND divided across the day's Penalty-carrying Commitments.** Preserves partial stakes with a
hard daily ceiling. Rejected as more arithmetic than the author wanted.

The chosen flat model has a known cliff: once one Penalty-carrying Commitment is missed, the rest of
the day carries no stakes. FR-10's rule that the system does not announce mid-day that the day is
lost, plus independent per-Commitment Chains, are the mitigations. Both are untested design guesses
and are the first thing to revisit if the author starts abandoning afternoons.

**Attention policing inside Focus Sessions.** Three levels were offered: none, soft (detect a long
absence and ask if he is still working), and strict (leaving the app voids the session, which would
make the session verifiable enough to carry money). The author chose none — pressing start counts.
The reasoning that supports this: a timer that punishes checking a message is a timer he stops
starting, and the failure being addressed is *starting*. The loophole is accepted knowingly, and it
is precisely why company work carries no Penalty.

**Money on morning exercise.** Dropped. Already habitual at 07:30, so money adds no motivation, while
a phone left on a desk produces a false miss that — under the flat Penalty — costs the entire day's
500,000 VND. Pure downside.

**Three commitments cut from v1** — financial-report research, VHM news tracking, the horoscope agent
build. None had a stated Cadence, none is verifiable, none can carry a Penalty. They would have
lengthened the list without receiving anything from the product. They return cheaply once Focus
Sessions work.

## Technical notes for architecture

- **Notification-first is an architectural constraint, not a UX preference.** The author will not open
  the app. Day summaries, quota arithmetic, appeal rulings and interventions must be fully legible in
  a notification body. Scheduling and delivery reliability on iOS is therefore load-bearing in a way
  it is not for most apps, and background delivery limits should be checked early.
- **The blocking morning Declaration needs a real mechanism.** iOS cannot literally block the phone.
  Candidates: a notification that cannot be cleared without an action, a Live Activity, a lock-screen
  widget, or a launch-time modal that the app cannot be used past. Whichever is chosen, the trigger
  is "first interaction after a configured morning hour", not a fixed alarm time.
- **Geofence dwell, not entry.** Entry alone is defeated by walking through. Dwell needs background
  location and will hit iOS permission and battery constraints; the always-on permission prompt is
  itself a UX risk.
- **TryHackMe access is unconfirmed and gates FR-8.** Settle before architecture. If it fails, that
  Commitment moves to the Declared tier and the morning Declaration carries two questions.
- **Focus Sessions must survive backgrounding and lock**, and bank correctly if the app is killed
  mid-session.
- **Offline reconciliation matters more than usual** because a missing network producing a Failed Day
  would charge real money for an infrastructure fault.
- **Two roles from day one**: authentication, a synchronizing backend, evidence upload and storage,
  and a submit → held → rule → notify-back flow. This is not a local todo app, and it is being built
  by one person.
- **The author's iOS/Swift experience is still unstated.** Ask before sizing anything.

## Parked

- Product name.
- Platform vision. The unsolved problem is referee supply: a friend who genuinely cares does not
  scale, a stranger has no reason to chase you, and a paid referee reopens the regulatory questions
  v1 was designed to avoid.
- Reducing what the Referee must say out loud. FR-21's pre-written message is a first attempt; the
  more the product carries the awkward part, the longer the Referee survives.
