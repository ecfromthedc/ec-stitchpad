# Open observations — patterns seen, not yet proven

This file is deliberately **not** `KNOWN-WEDGES.md`.

Every entry there has a repro, a recovery, and a fix. Every entry **here** is
something a crew noticed while doing other work: real enough to write down,
not yet understood well enough to build a guard around.

That distinction matters more than it looks. A guard built on a pattern nobody
confirmed becomes a false alarm, and a check that cries wolf on a schedule is
one the operator learns to scroll past — at which point it is worse than no
check at all. We hit exactly that three times in one night (a schedule light
keyed to content, a deploy script probing during its own restart window, an
ingest alarm firing at a run four seconds old). So: observations stay
observations until someone can make them fail on demand.

**If you confirm one of these, move it to `KNOWN-WEDGES.md` with a fix.
If you disprove one, delete it and say so.** Both are progress.

---

## O1. A seat can drift onto a task nobody assigned

**Seen:** 2026-08-13. A seat was dispatched to finish a mirror lane. Its next
status post reported progress on a task from an earlier session that was not on
the register at all — a caption-map lane with its own branch, being carried
forward as though it were current work. It was otherwise behaving well: it
refused to merge without a cross-review verdict, it posted status. It was
simply doing the wrong thing, carefully.

**Why it is hard to guard:** "working on the wrong thing" is not distinguishable
from "working on a dependency you did not know about" without reading the work.
A naive check — does the branch name match the brief? — would fire constantly
on legitimate side-quests, prerequisite fixes, and test-harness repairs, which
are often exactly what a good seat should do. That is the false-alarm trap
above.

**What made it visible:** comparing the seat's pad post against the register,
by hand. Nothing automatic caught it.

**What might confirm it:** does drift correlate with rotation? This seat was
rotated mid-lane, and a fresh session inherits only its brief. If a rotated
seat reaches for an older, more familiar task when its brief is ambiguous, that
is testable — and the fix would be in how briefs carry position, not in a
detector.

**Interim practice:** when rotating mid-lane, write the seat's exact position
into the brief ("you posted X, nothing was pushed, pick up at Y"). Done
consistently this appeared to prevent it, but that is one crew's impression,
not a measurement.

---

## O2. Very long briefs may correlate with silent idling

**Seen:** 2026-08-13, three times. A seat given a long, multi-part brief
(several numbered tasks, extensive context, several hundred words) returned to
`completed` having produced nothing at all — no commit, no push, no pad post,
an untouched worktree. The same seat, given a single-task brief that opened
with "ONE TASK ONLY, nothing else until it is posted", produced work.

**Why this is only an observation:** the sample is tiny and hopelessly
confounded. Those same seats were also near their turn ceiling, where they go
inert anyway (`KNOWN-WEDGES` #8). Long briefs were also, by definition, the
ones handed out late in a build when the register was messiest. Brief length,
seat age, and task ambiguity all moved together. Any of the three explains it.

**What would separate them:** dispatch a FRESH seat (low turns) with a long
multi-part brief and a matched fresh seat with the same work split into
sequential single-task briefs. If only the long-brief seat goes quiet, it is
the brief. That experiment has not been run.

**Interim practice:** if a seat has gone quiet twice, re-dispatch with one task
and an explicit "nothing else until it is posted". That is cheap and does no
harm whether or not the hypothesis holds. It is not evidence.

---

## O3. A merge can silently revert a fix applied minutes earlier

**Seen:** 2026-08-13. A test harness was fixed to stage a helper script, then a
merge took the other branch's version of that same file and the fix disappeared
— with no conflict, because only one side had changed it since the merge base.
The suite went red again for the same reason it had gone red before.

**Why it is not in KNOWN-WEDGES:** this is ordinary git semantics, not a
stitchpad wedge. It is here because of what caught it: the pre-ship gate
refused to deploy, and the *reason* it gave was identical to the one from ten
minutes earlier. That repetition is the signal.

**Interim practice:** when a gate fails with a message you have already fixed
today, suspect the merge before you suspect the fix. And re-run the full gate
after every merge, not only after every edit.

---

## O4. Seats coordinating their own reviews worked well — worth keeping

Not a failure. Recorded because it is worth not losing.

Two seats independently negotiated a review between themselves on the pad: one
posted a precise review range, corrected its own commit reference in a
follow-up when it noticed the range was wrong, and the other returned a verdict
with findings ranked by severity. The orchestrator did not broker it.

The mechanism that made it possible is `stitchpad say` from a rostered
delegate (`KNOWN-WEDGES` #7). Anything that weakens that — a stricter terminal
identity check, say — would quietly remove this, and the loss would not show up
as an error anywhere. It would just mean more work routed through the lead.
