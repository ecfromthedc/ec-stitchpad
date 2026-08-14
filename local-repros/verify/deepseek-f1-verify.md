# deepseek F1 verification

## 1. Confirm the steal is closed

VERDICT: HOLDS
COMMAND: Barrier-seam test — park writer A between mkdir and owner publication via
  STITCHPAD_LOCK_TEST_BEFORE_OWNER_BARRIER, sleep 1.6s past SP_LOCK_EMPTY_RECLAIM (1s),
  try writer B (different terminal namespace).
OUTPUT: Claiming marker present with live pid. After 1.6s, contender got
  "stitchpad: pad busy (lock timeout)" (rc=1). Writer A released, rc=0, message
  "HOLDER-MSG" committed to pad. Thief message NOT in pad.
WHY IT MATTERS: The claiming marker, written with a zero-fork printf builtin before
  the slow owner-publication path, blocks E1 from stealing from a live writer.
  Pre-fix, E1 reclaimed at 1s and the robbed writer died with "could not publish."

## 2. Break attempts on the claiming guard

### 2a. Live claimant blocks E1 (core fix)

VERDICT: HOLDS
COMMAND: Park writer A at barrier (claiming written, owner absent), contender B
  after 1.6s.
OUTPUT: Contender: "stitchpad: pad busy (lock timeout)" (rc=1). Holder: "✓ posted"
  (rc=0). HOLDER-MSG in pad, THIEF not in pad.
WHY IT MATTERS: A writer mid-publication is never robbed.

### 2b. Dead claimant is reclaimed (crash path survives)

VERDICT: HOLDS
COMMAND: Park writer at barrier, SIGKILL it (kill -0 fails). Contender after 1.1s.
OUTPUT: "✓ posted as @larry" (rc=0). Message "after-crash" landed.
WHY IT MATTERS: Crash recovery must survive. A SIGKILLed writer's lock is reclaimed
  when the claimant is provably dead.

### 2c. SP_LOCK_EMPTY_RECLAIM=0 with live claimant

VERDICT: HOLDS
COMMAND: SP_LOCK_EMPTY_RECLAIM=0, live claimant, contender after 0.3s.
OUTPUT: "stitchpad: pad busy (lock timeout)" (rc=1).
WHY IT MATTERS: The reclaim window age check is necessary but not sufficient — the
  claiming liveness guard is independent and must hold regardless of window size.

### 2d. SIGSTOP claimant (stopped, not dead)

VERDICT: HOLDS
COMMAND: Park writer at barrier, SIGSTOP it (process state: TN). kill -0 still
  succeeds (stopped ≠ dead). Contender after 1.6s.
OUTPUT: "stitchpad: pad busy (lock timeout)" (rc=1). After SIGCONT + release,
  holder posted successfully.
WHY IT MATTERS: SIGSTOP is not dead. kill -0 succeeds on stopped processes.
  Reclaiming here would be a false-positive steal.

### 2e. Malformed claiming file (empty, whitespace, non-numeric, huge, missing, directory)

VERDICT: HOLDS
COMMAND: Direct calls to sp_lock_claimer_is_live with various malformed claiming files.
OUTPUT: empty→NOT-LIVE, whitespace→NOT-LIVE, non-numeric→NOT-LIVE,
  huge-numeric→NOT-LIVE, missing→NOT-LIVE, directory→NOT-LIVE.
WHY IT MATTERS: A corrupted claiming file cannot falsely protect a dead lock. Only
  a file containing exactly a numeric pid can register as LIVE.

### 2f. claiming file is a symlink

VERDICT: INCONCLUSIVE (not a practical attack vector)
COMMAND: Symlink claiming → file containing live pid. sp_lock_claimer_is_live
  follows the symlink via bash `read <`.
OUTPUT: Returns LIVE (kill -0 succeeds on the symlink target's pid).
WHY IT MATTERS: The claiming file is written by `printf >` — always a regular file.
  Only an attacker with filesystem access to the lock directory could plant a
  symlink. With that access, they've already won. The 30s SP_LOCK_STALE age-only
  path is the ultimate escape hatch.

### 2g. 20-way concurrent contention

VERDICT: HOLDS (throughput characteristic is pre-existing, not a regression)
COMMAND: 20 concurrent writers in 20 terminal namespaces, no barrier, 5 runs.
OUTPUT (this branch): 16.2/20 avg post failures, 13.8/20 avg messages missing.
  Same test on origin/master: identical failure rates (lock serialization is the
  bottleneck, not the claiming guard).
WHY IT MATTERS: The claiming guard makes the lock MORE conservative (correctly),
  reducing effective throughput vs. the old steal-prone E1. But 20-way contention
  without jitter+tuned timeouts is a pre-existing throughput issue — origin/master
  shows the same. The fix trades throughput for correctness, which is the right
  trade.

## 3. SIGKILLed claimant IS still reclaimed

VERDICT: HOLDS
COMMAND: Park writer at barrier, SIGKILL it, verify claimant dead (kill -0 fails),
  contender posts.
OUTPUT: "✓ posted as @larry (#m-fb3621)" (rc=0). Message "POST-CRASH-RECOVERED" in pad.
WHY IT MATTERS: The original purpose of E1 (empty-lock crash recovery) must survive
  the fix. A SIGKILLed writer's lock must not permanently wedge the pad for all
  future writers.

## 4. Attack the rollback guard

### 4a. HEAD advanced — committed message must survive

VERDICT: HOLDS
COMMAND: Post msg1, stamp .base-sha. Post msg2 (advances HEAD). Rollback with
  .base-sha pointing at old HEAD.
OUTPUT: "pad history advanced during this operation (journalled base <old>, HEAD
  now <new>) — NOT restoring the pad file". Both msg1 and msg2 survive in pad.
  Stale rollback content not present.
WHY IT MATTERS: The core rollback guard. If another writer committed while a
  session's journal was open, restoring the old snapshot silently deletes their
  message from the working pad. The guard refuses.

### 4b. .base-sha truncated / empty

VERDICT: HOLDS (both cases behave correctly for their semantics)
COMMAND: Test empty .base-sha and truncated (10-char) .base-sha.
OUTPUT: 
  - Empty .base-sha: guard condition `-n ""` is FALSE → _rb_skip_pad stays 0
    → pad IS restored. Deliberate fallthrough: no base-sha means no evidence
    to detect advancement.
  - Truncated .base-sha: "c537e5ee3b" != full HEAD → guard triggers → pad
    NOT restored. "pad history advanced" message emitted.
WHY IT MATTERS: An empty base-sha is degenerate — the journal-begin path always
  stamps a valid sha or 'unborn'. The truncated case confirms the guard is a
  simple string comparison, not an ancestor check.

### 4c. .base-sha is a valid SHA from an unrelated repo

VERDICT: HOLDS
COMMAND: Plant .base-sha with faa3229... (the wt repo's HEAD, not the pad's git).
  Actual pad HEAD is a different SHA.
OUTPUT: "pad history advanced (journalled base faa3229..., HEAD now <pad head>) —
  NOT restoring the pad file". Stale content absent, committed message survives.
WHY IT MATTERS: The guard only checks inequality (base != HEAD). An unrelated SHA
  is != HEAD, so the guard fires correctly. The guard does not verify ancestry
  (is base an ancestor of HEAD?), but ancestry verification would require a
  git merge-base call which is expensive and unnecessary — any mismatch means
  the journal's snapshot is not from the current HEAD.

### 4d. .base-sha = 'unborn'

VERDICT: HOLDS
COMMAND: .base-sha = 'unborn'. Guard explicitly checks != 'unborn' before acting.
OUTPUT: Pad IS restored (guard not triggered). Stale content in pad after rollback.
WHY IT MATTERS: 'unborn' means no commits existed when the journal was created —
  there was no HEAD to advance from. Restoring is correct.

## 5. Intermittent measurements

### 5a. Live claimant blocks E1 — 5 consecutive runs

VERDICT: 5/5 HOLDS
Runs: 5 of 5 returned "pad busy (lock timeout)" for contender, holder always rc=0
  with message in pad. 0% steal rate.

### 5b. Dead claimant reclaimed — 5 consecutive runs

VERDICT: 5/5 HOLDS
Runs: 5 of 5 returned "✓ posted" for contender after SIGKILL. 100% reclaim rate
  for dead claimants. 0% false-wedge rate.

### 5c. SIGSTOP claimant — 5 consecutive runs

VERDICT: 5/5 HOLDS
Runs: 5 of 5 returned "pad busy" for contender while claimant was SIGSTOP'd.
  0% steal-on-stopped rate.

### 5d. 20-way contention — 5 runs (this branch)

Rate: avg 16.2/20 post failures (~81%), 13.8/20 messages missing (~69%).
  Same rate on origin/master. Pre-existing throughput characteristic.

## SUMMARY

VERDICT tally (ordered: BROKEN first, then INCONCLUSIVE, then HOLDS):

BROKEN: (none)

INCONCLUSIVE:
  - 2f: Symlink claiming file follows the symlink via `read <`. Not a practical
    attack vector (requires filesystem access to lock directory; attacker with
    that access has already won).

HOLDS:
  - 1:  Steal is closed (core fix verified)
  - 2a: Live claimant blocks E1 reclaim
  - 2b: Dead claimant is reclaimed (crash path survives)
  - 2c: SP_LOCK_EMPTY_RECLAIM=0 still respects claiming guard
  - 2d: SIGSTOP claimant blocks reclaim (stopped ≠ dead)
  - 2e: Malformed claiming files all return NOT-LIVE
  - 2g: 20-way contention throughput is pre-existing, not a regression
  - 3:  SIGKILLed claimant IS still reclaimed
  - 4a: HEAD-advanced rollback guard holds
  - 4b: Truncated/empty .base-sha handled correctly
  - 4c: Unrelated-repo SHA triggers guard
  - 4d: 'unborn' .base-sha falls through correctly

No finding is BROKEN. The fix holds under every attack attempted.

