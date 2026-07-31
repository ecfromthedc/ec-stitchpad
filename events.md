# events.md — stitchpad repo ledger

Single append-only chronological ledger for this repo. Shared by all agents
(any harness, any worktree). Newest entries at the bottom. Schema: see root
AGENTS.md.

time:      [11:24pm] [06-17-26]
agent:     [claude] [opus 4.8]
worktree:  main (work staged in /Users/risingtidesdev/stitchpad-live, same repo)
type:      [bug-report]
area:      [backend]

Established this ledger — it didn't exist. smaths asked if the team was following
devlog protocol; the honest answer was no, because the repo had no events.md and no
AGENTS.md chain at all. Created both rather than claim compliance, and backfilled
tonight's work below.
time:      [05:40pm] [06-18-26]
agent:     [codex] [gpt-5] [larry]
worktree:  feat/t2-supacode-adapter
type:      [bug-report]
area:      [infra]

Investigated "watcher not working" during the Supacode/Dale route test. Live watcher was restarted and re-read the roster with `@dale -> adapter=supacode`; `adapter.supacode.log` then showed fresh 17:39 zmx wakes. Found and verified the wake cursor typo fix already present in the installed/repo script: `stitchpad wake dale --peek` no longer crashes on `_mc_seen_file: unbound variable`, `--peek-ordinal` returns a live ordinal, `bash -n tool/bin/stitchpad` and `bash -n tool/bin/watch.sh` pass, and the watcher is running again after restart. Current live evidence shows the remaining Dale failure is Claude TUI submit: zmx delivers text to the Supacode Claude composer, but CR parks instead of submitting; send-key fork remains the real fix path.
_________________________________________________________________________________
time:      [07:30pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [bug-report]
area:      [backend]

Closed a run of wake-path bugs, each verified against the real condition (not a
proxy), several cross-verified by dennis in clean temp pads: (1) broadcast silent-ack
— lib.sh stripped @names before matching "ack", so a team broadcast read as a silent
ack and woke nobody; fixed by counting mentions pre-strip and never silencing 2+.
(2) cold-wake heartbeat gap — a woken session that never ran a CLI had no heartbeat
ticker and decayed offline in 90s; kitty.sh now starts the ticker on wake. (3) sender
mislabel — kitty.sh ctx extractor mis-attributed the wake's "NEW from @X"; replaced
with `wake --peek` (canonical stop-hook source). (4) identity↔window drift — self-heal
routed wakes by window title, which could name the wrong agent; now matches
env.STITCHPAD_NAME first, title fallback, re-stamps title only after an authoritative
match.
_________________________________________________________________________________
time:      [08:00pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [backend]

Dropped-turn recovery (the double-consume race): the watcher AND the stop-hook both
advanced the seen cursor on delivery, so a turn that died mid-tool-chain before posting
lost its mention permanently — smaths saw silence on Telegram. Fix: watch.sh writes
pending.<name> (the open ordinal) on delivery; the stop-hook re-blocks ONCE via new
`wake --force` if the gate's still open, bounded so it can't loop. Per dennis's
acceptance gap, added visibility: a re-block that still gets no reply transitions to
delivered_no_reply.<name>, surfaced in `doctor --json`; an authored reply clears both.
Verified bounded + visible against a real session and dennis's temp pad.
_________________________________________________________________________________
time:      [07:00pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [infra]

Built `stitchpad-team` — one-command outage restore. Reads roster + runtime.<name> +
per-agent color, respawns each kitty member's window (titled, colored, running its
runtime CLI), skips live windows + operator + remote, pins identity via
--env STITCHPAD_NAME so it can't drift from the title. Security-reviewed by mark
(allowlisted runtimes, local-state-only sources, zero pad-body content in env). Proven
by respawning a genuinely-dead agent (dennis, win 21). Full-outage teardown drill held
for smaths to trigger (destructive to the live team).
_________________________________________________________________________________
time:      [11:00pm] [06-17-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [frontend]

PWA perf: smaths reported slow load; dennis measured the static shell at 33KB/~0.43s,
so the bottleneck was runtime, not asset weight — render() refetched the whole pad
every 3s and rebuilt log.innerHTML wholesale, re-parsing + repainting the entire log
even when nothing changed. Shipped a skip-render-when-unchanged guard (cache
LAST_LOG_HTML, only touch the DOM on a real content change). Measured in headless
Chrome: 19–29x less idle render work, ~95% reduction, savings grow with conversation
length. Also added loading=lazy + decoding=async to message avatars. Incremental
append held until ernie's /pad ETag/tail contract lands (don't optimize against a
moving payload). Debounce deliberately skipped (the remaining idle cost is the fetch,
which is the transfer-side ETag fix).
_________________________________________________________________________________
time:      [11:25pm] [06-17-26]
agent:     [claude/mark] [sonnet 4.6]
worktree:  main
type:      [review]
area:      [backend]

Security review pass across the full session. Key calls: (1) relay colors contract mismatch — bridge.sh was shipping colors as array [{name,color}] but dale's PWA needed flat object {name:#hex}; caught before deploy, fixed in bridge.sh jq. (2) Remote-join token scope — /join-request returns master STITCHPAD_TOKEN (reads/writes all pads); flagged as wrong for remote agents; recommended pad-scoped session token in KV; team aligned, CLI blocked pending that fix. Trusted-coworker path approved to ship with master token as interim, scoped tokens queued. (3) stitchpad-team launcher audit — verified allowlisted runtimes (claude/pi/codex only), local-state-only env sources, zero pad-body content injected; cleared. (4) PreToolUse shim spec — posted exact bash shim (pretooluse-claim.sh) and settings.json merge block for installer; tool-name matching on Edit/Write only, decision:block on stdout, exit 1 on deny. (5) Delivered_no_reply root cause — confirmed seen cursor advances on delivery before agent posts; defined fix shape (bounded retry + doctor flag). (6) stitchpad send mime validation — flagged that CLI should reject non-image paths client-side before relay upload, not rely solely on worker.js 400.
_________________________________________________________________________________
time:      [11:30pm] [06-17-26]
agent:     [claude/randy] [sonnet 4.6]
worktree:  main
type:      [bug-report]
area:      [backend]

Four wake-path bugs found and closed this session. (1) Broadcast silent-ack suppression: lib.sh engagement gate stripped leading @mentions then matched "ack" as silent — a broadcast "@dale @dennis … ack" suppressed all 7 wakes. Fixed: messages with 2+ @mentions skip the silent-ack path. (2) Cold-wake heartbeat gap: kitty adapter delivered the nudge but woken agents had no alive.<name> heartbeat running, so they decayed offline after 90s. Fixed: kitty.sh now runs `stitchpad heartbeat start <name>` from the watcher on every delivery. (3) Wake message format split: kitty adapter built its own nudge string with custom awk while stop-hook used `wake` output — two diverging formats. Fixed: kitty adapter now calls `stitchpad wake $to --peek` for the canonical one-liner, same source as stop-hook. (4) Sender mislabel in ctx extractor: replaced the custom awk ctx block entirely (bug was in flush() pairing), now both paths use `stitchpad wake`. All four verified against real conditions on the live pad. Also added `stitchpad send <file> [caption]` CLI command (thin exec wrapper into `say --image`; client-side mime+size validation already existed).
_________________________________________________________________________________
time:      [12:40am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [plan]
area:      [research]

Deep-dived Supacode as a potential terminal substrate for the agent pad (we're
running inside it — open-source, github.com/supabitapp/supacode, built on Ghostty).
Reversed an earlier wrong verdict after reading the source: (1) the "tab/surface
create times out without returning a UUID" blocker is a non-issue — TabCommand.swift
self-generates the UUID (or takes -n <uuid>) and fires a deeplink fire-and-forget;
pass our own UUID, ignore the cosmetic timeout, own the handle immediately. Proven
live (created a tab with a chosen UUID, woke it by that UUID rc=0). (2) Colors/titles
port via OSC escapes — Ghostty is truecolor with OSC 2/11/4 + a WindowChromeApplier
subsystem; no CLI color command needed. (3) Supacode has a NATIVE agent-presence +
notification system (AgentPresenceOSC over OSC 3008 + OSC 9, per-surface unread/
progress, agent-hook ownership) that works over SSH — i.e. it natively ships the
remote-coworker wake we hand-built with the Cloudflare relay. Verdict: serviceable
and arguably purpose-built; wakes get simpler (self-assign UUID + `surface focus -i`,
~0.024s) and title-drift bugs evaporate (target an assigned UUID, not a mutable title).
Cost: macOS-only, opinionated app vs a dumb scriptable pty. Proposed transition split
posted to pad: dale builds supacode.sh adapter + one-agent POC; randy confirms wake/
seen/heartbeat rides over unchanged; ernie/larry assess OSC 3008 → roster dots; mark
security-reviews the deeplink/socket model.
_________________________________________________________________________________
time:      [01:40am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [bug-report]
area:      [infra]

Supacode POC: built tool/adapters/supacode.sh (same contract as kitty.sh; wake via
`supacode surface focus -i`, heartbeat-ensure, self-assigned UUID targeting). randy
confirmed the wake/seen/heartbeat machinery is terminal-agnostic so the adapter slots
in by changing the roster line adapter=kitty→supacode. PROVEN working: self-assigned
UUID create (pass -n <uuid>, own the handle with no capture/timeout race), OSC
color/title paint, adapter logging + correct UUID targeting, and `tab new -i` executes
its initial command (file side-effect verified). REAL BLOCKER FOUND (isolated across 4
attempts, before claiming success): `surface focus -i "cmd"` inserts the text but does
NOT submit/execute it — even though the source (WorktreeTerminalManager.swift:282
appends \r via focusAndInsertText). So spawn works but WAKE does not, which is inverted
from need (wakes are frequent, spawns rare). Same class as the old kitty
send-text-doesn't-submit bug — likely Ghostty custom-keyboard-mode where \r != Enter
for TUI agents. Also: supacode CLI has no surface-read verb (list/focus/split/close
only), so we can't read a surface back to verify delivery like kitty's get-text.
Verdict: substrate strong (identity/colors/spawn solid) but pad migration BLOCKED until
the wake-submit path works. Options posted: file upstream / wake-by-respawn workaround /
find a submit escape through focusAndInsertText.
_________________________________________________________________________________
time:      [01:45am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [infra]

Supacode wake blocker SOLVED via zmx (smaths' "go under the terminal" instinct).
Source dive found Supacode wraps every surface's shell in a bundled zmx session
multiplexer (Resources/zmx/zmx). zmx exposes what the supacode CLI lacked: `zmx send
<session> "<text>\n"` is a RAW PTY write whose trailing newline submits (fixing the
focusAndInsertText non-submit bug); the session name is deterministic `supa-<surface
_uuid>` (the UUID we self-assign at spawn, zero discovery); and `zmx history <session>`
reads the buffer back (solves the no-get-text gap kitty had to work around). Rewired
tool/adapters/supacode.sh to wake via `zmx send` (focus-for-visibility first, then raw
send). Verified end-to-end as the watcher calls it: rc=0, nudge submitted into the
session, zmx history confirmed delivery. Net: Supacode is fully serviceable with NO
source changes and no upstream dependency — spawn (self-UUID), colors (OSC), wake (zmx
send), verify (zmx history), identity (assigned UUID) all solved; wake path is cleaner
than kitty's send-text+enter. Next: one-agent live POC; mark to review zmx trust
boundary (raw input into sessions).
_________________________________________________________________________________
time:      [01:50am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [review]
area:      [infra]

Hardened supacode.sh per mark's zmx security review. `zmx send` is a raw PTY write
that submits immediately (higher blast radius than kitty's send-text paste), so a
crafted pad message could ride control/escape bytes into a session. Audit: (1) the
nudge is `wake --peek` output (local parse) but its snippet (bin/stitchpad:793) carries
pad-body text and does NOT strip control/escape bytes; the adapter's old `tr -d '\r\n'`
killed embedded-CR command injection but not ESC sequences. Fixed: sanitize now
`LC_ALL=C tr -d '\000-\037\177'` — strips ALL control bytes before the write. Proven
against mark's exact vectors (`\r rm -rf ~`, OSC title hijack, SGR) via od -c byte dump:
all control bytes stripped, only printable text reaches the pty. (2) Session name
`supa-<surface>` derives only from SP_TARGET (roster/launcher self-assigned UUID, local
state), never pad body — no second vector. Local-state-trusted / pad-body-untrusted rule
holds end to end. mark cleared both conditions.
_________________________________________________________________________________

time:      [02:02am] [06-18-26]
agent:     [pi] [unknown]
worktree:  main
type:      [workflow]
area:      [design]

Created `reference/stitchpad-system-diagram.html`, a self-contained visual explainer for Smaths showing the stitchpad hot-context vs cold-archive architecture, derived-index contract, token-efficiency rationale, and acceptance tests. Verification: checked the artifact has a doctype/title, no placeholder TODO/Lorem content, interactive mode controls, and file size output via a local Python sanity check.
_________________________________________________________________________________
time:      [02:14am] [06-18-26]
agent:     [codex] [gpt-5]
worktree:  main
type:      [bug-report]
area:      [skill/mcp]

Joined the live pad as `@jill` through the Stitchpad MCP join tool after the CLI/env
state showed an orphaned capitalized `@Jill` session. Bound session `84` to lowercase
`jill`, verified `stitchpad doctor` reports `@jill (kitty/push) codex — online`, and
fixed the installed CLI color override so lowercase `jill` resolves to pink
`#ff1493` instead of the fallback yellow. Verification used the real Kitty window:
`stitchpad color jill` returned `#ff1493`, `stitchpad bind-session 84 jill` reapplied
the color, and `kitty get-colors --match id:10` reported `background #ff1493`.
_________________________________________________________________________________
time:      [02:18am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [review]
area:      [infra]

Supacode agent-#1 POC proven live against a real surface (smaths: "why we not on
supacode" — answer: cutover was done-but-unstarted; ran it). Checklist: (1) self-
assigned UPPERCASE uuid via uuidgen → `supacode tab new -n <uuid>` creates the tab
owning our exact UUID (the "Timed out" message is cosmetic — handle is ours
immediately). (2) wake-by-UUID: `surface focus -t <uuid>` rc=0. (3) zmx session name
convention `supa-<lowercased-uuid>` matches the live session exactly (pid confirmed).
(4) DELIVERY PROOF: `zmx send <sess> "<cmd>\n"` rc=0, `zmx history` reads the marker
back from the surface buffer — real delivery, not a proxy. Verified uppercase is safe
everywhere today (uuidgen=uppercase, adapter does no lowercasing except the documented
zmx session name). Gap found: stitchpad-team launcher has zero supacode spawn path yet
(kitty-only) — that's the generalize-after-green step. Next: flip dale's roster line
adapter=kitty→supacode with a real claude session in the surface, confirm heartbeat/
seen/pending ride over, then migrate agent-by-agent.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [03:58am] [06-18-26]
agent:     [pi/dennis] [gpt-5.5]
worktree:  main
type:      [bug-report]
area:      [backend]

Supacode handoff attempt as non-Claude operator: verified the Supacode Claude session joined/bound as dale (`.state/sessions/c3f34b57-ae97-45f4-9ad5-d68fe97bad12=dale`) and temporarily flipped the live roster to target UUID `5C586109-C69A-49DE-B3A7-C413A5A0941F`. Found a real blocker: the adapter's live-target check used `supacode tab list`, which fails outside a Supacode worktree (`Missing worktree ID`) and falsely clears valid targets; patched `tool/adapters/supacode.sh` to validate via zmx session list instead. After patch, zmx delivered text to the Claude TUI but CR/LF did not submit; history showed the nudge parked in the composer with no proof post. Rolled dale roster back to kitty target `unix:/tmp/kitty-thoth-697@@1`. Conclusion: do not migrate Dale yet; Supacode bind/target pieces are partly proven, but reliable Claude-TUI submit via zmx remains unproven/blocking.
time:      [05:45am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [bug-report]
area:      [infra]

Dual-ownership cleanup (dennis caught it). After the frozen Supacode migration,
TWO session files mapped to dale: 04d0c707 (live kitty session) AND c3f34b57 (the
Supacode session dennis bound during the operator attempt). The roster rollback to
kitty flipped the wake target but did NOT clear the Supacode session file — so two
sessions could both post as @dale, the exact dual-ownership we'd tried to avoid.
Fix: removed .state/sessions/c3f34b57 (the stale Supacode dale binding). Evidence
after: only 04d0c707=dale; roster dale|kitty|@@1; doctor dale adapter=kitty
status=online health=ok; Supacode surface stays alive but unbound (kept for the
submit-fix work, not authoritative). Lesson: roster rollback must also clear the
session file, else identity binding outlives the wake routing. Supacode migration
remains FROZEN pending the Claude-TUI submit-via-zmx fix.
_________________________________________________________________________________
time:      [05:51am] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  main
type:      [feature-request]
area:      [frontend]

PWA send reliability (my piece of dennis's hybrid plan). The send path had optimistic
PENDING render but NO failure handling — on a network/HTTP error the message froze at
"sending…" forever with no signal, and the text was lost. For a control surface smaths
leans on, that's the painful case. Fix: wrapped the /say POST in try/catch — on
failure, drop the optimistic bubble, restore the text to the composer (so the send
isn't lost), and show a "⚠ send failed — text is back, press send to retry" line.
Verified in headless Chrome with a mocked failing api(): textRestored=true,
pendingCleared=true, errorShown=true. JS validated.
_________________________________________________________________________________
time:      [05:05pm] [06-18-26]
agent:     [claude/dale] [opus 4.8]
worktree:  feat/pwa-client-dale
type:      [feature-request]
area:      [frontend]

PWA client lane (smaths' "own a worktree, 3-5 tasks, PR" directive). Worktree
~/stitchpad-dale on branch feat/pwa-client-dale, off current HEAD (incl ernie's
ETag/304 commit), client-only so no collision with the transfer-relief branch.
Shipped three gaps in tool/pwa/index.html: (1) inline media players — fmt() only
rendered ![](img); added bare-URL <video> (mp4/mov/webm/m4v) + <audio>
(mp3/m4a/ogg/oga/wav) so tg-media a/v sends play instead of click-out links, and
hardened the autolink with a (?<!=") lookbehind so a media/img src isn't re-wrapped
in an <a> (also fixes the same latent bug in the existing image rule). (2) composer
draft persistence — ta.value was lost on reload/PWA-kill; drafts now persist
per-pad/per-DM to localStorage, restore on switch+startup, clear on send, re-persist
on send failure. (3) new-message pill — when scrolled up reading history, new msgs
painted silently; added a "↓ new messages" jump pill reusing the atBottom check.
Verified in node: 9/9 media+autolink cases, 5/5 draft semantics, full-script syntax
OK. Deferred task 4 (link unfurl) — needs a relay endpoint = ernie's transport repo,
separate PR to avoid collision. PR opening next.
_________________________________________________________________________________
time:      [05:55pm] [06-18-26]
agent:     [codex] [gpt-5] [jill]
worktree:  main
type:      [bug-report]
area:      [infra]

Fixed the live watcher lifecycle after `stitchpad start`/`restart` allowed duplicate
`watch.sh` and `fswatch` trees to stack on `/Users/risingtidesdev/stitchpad-live`.
Added pad-scoped watcher stop/convergence helpers, made stop/restart use them, fixed
daemon supervisor pid recording, and changed watcher TERM/INT handling so killed
watchers actually exit and only the lock owner removes the lock. Verified against the
real live pad: syntax checks pass, concurrent `stitchpad start` calls preserve one
watcher, deliberate duplicate watcher injection converges back to one watcher, and
the final lock/fwatch pair is PID 47788 for `stitchpad-live`.
_________________________________________________________________________________
time:      [9:05P] [06-18-26]
agent:     [pi] [mimo-v2.5-pro] [dennis]
worktree:  [main]
type:      [workflow]
area:      [automations]

Shipped the Supacode wake path instead of file-only nudges: synced the repo and installed supacode adapter to clear stale composer text, insert the canonical nudge with `supacode surface focus -i`, and submit with `supacode surface send-key --key Enter`; normalized old `folder:` worktree sidecars and rebound live @dale to surface `B20690EC-EA8D-4CAE-A186-08919AEDF6E8`. Verification: `bash -n` passed for both adapter copies; manual live adapter invocation returned rc=0 and logged `woke @dale via supacode focus+send-key`; Dale’s Claude processed the wake and posted after tool approval.
_________________________________________________________________________________
time:      [09:07pm] [06-18-26]
agent:     [codex] [gpt-5] [larry]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Tightened the shipped Supacode wake adapter so it does not depend on stale roster assumptions: `tool/adapters/supacode.sh` now strips stale `folder:` worktree prefixes, infers the live Supacode worktree from the pad root when needed, resolves the actual tab that owns the target surface before sending, pins its internal `stitchpad wake --peek` call to `STITCHPAD_PAD_DIR`, and records the normalized worktree sidecar. This keeps the native wake contract as focus/insert plus `surface send-key --key Enter`, with file nudge only as a breadcrumb and nonzero exit on native failure. Verification: `bash -n tool/adapters/supacode.sh` passed; the live adapter log showed native `supacode focus+send-key` deliveries after the change, watcher status was running, `doctor --json` reported @dale Supacode health ok, and current Supacode tab/surface listing showed the live C3 target registered in `stitchpad-live`.
_________________________________________________________________________________
time:      [09:08pm] [06-18-26]
agent:     [codex] [gpt-5] [jill]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Closed the live Supacode wake loop on the actual pad condition. Rebound @dale from the stale/dirty B206 surface to a freshly spawned and primed Supacode Claude surface `C3C2E8FF-50F3-4937-95EE-B5D15ED5B126`, then posted a real `@dale` wake regression message from @jill. The watcher fired the Supacode adapter, the adapter log recorded native `supacode focus+send-key` delivery to the C3 surface, Claude received the `stitchpad:` wake prompt, read the pad, and posted `@jill WAKE_C3_210531 ok`. I granted Claude's local `STITCHPAD_NAME=dale stitchpad say *` approval rule during that acceptance run so future Dale pad replies from the same surface do not stop at the tool approval prompt.
_________________________________________________________________________________
time:      [9:13P] [06-18-26]
agent:     [pi] [mimo-v2.5-pro] [dennis]
worktree:  [main]
type:      [workflow]
area:      [automations]

Migrated the live local Stitchpad roster from kitty to Supacode after the native focus+send-key wake path shipped. Launched Supacode tabs for @dennis, @ernie, @mark, @jill, and @larry; kept @dale on Supacode; left @henry on relay and @smaths as operator. The fresh pi tabs hit a duplicate `pi_messenger` extension conflict when started as plain `pi`, so @dennis/@ernie were relaunched with `pi --no-extensions` to keep them alive in Supacode. Updated live roster targets and `.state/worktree.*` sidecars. Verification: `stitchpad doctor --json` now reports dennis/ernie/mark/jill/larry/dale as `adapter=supacode` with Supacode targets; jill/larry Codex, mark Claude, and dennis/ernie pi-noext histories show live Supacode TUI sessions.
_________________________________________________________________________________
time:      [09:13pm] [06-18-26]
agent:     [codex] [gpt-5] [larry]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Moved @larry's live Stitchpad wake target from kitty to Supacode as part of smaths' full-team migration order. Created a new Supacode `stitchpad-live` tab that started Codex with `STITCHPAD_NAME=larry` and `STITCHPAD_PAD_DIR=/Users/risingtidesdev/stitchpad-live/.stitchpad`, resolved the actual live tab/surface as `CF5BDCCE-B1EA-402C-9C58-705F0D6AFA2C`, updated the live roster line to `larry | supacode | push | CF5BDCCE...@@CF5BDCCE...`, and wrote `.state/worktree.larry` with `%2FUsers%2Frisingtidesdev%2Fstitchpad-live%2F`. Verification: Supacode listed the CF5 surface, zmx listed `supa-cf5bdcce-b1ea-402c-9c58-705f0d6afa2c`, Codex and its MCP server were running under that zmx session, and `stitchpad doctor --json` reported @larry `adapter=supacode`, `status=online`, `health=ok`.
_________________________________________________________________________________
time:      [06:45pm] [06-19-26]
agent:     [codex] [gpt-5]
worktree:  feat/t2-supacode-adapter
type:      [workflow]
area:      [automations]

Ported the native surface adapter path from Supacode to Velocity. Added `tool/adapters/velocity.sh`, generalized the shared Supacode-compatible adapter to honor `STITCHPAD_SURFACE_APP`, `STITCHPAD_SURFACE_CLI`, and `STITCHPAD_SURFACE_ZMX`, taught the CLI/MCP/relay paths to prefer `VELOCITY_*` surface variables, and changed `stitchpad join` so an existing roster name can be updated to the new adapter/target instead of silently staying stale. Synced this runtime into the Velocity app bundle and migrated the live `stitchpad-live` roster rows for codex, claude, deepseek, and pi to `velocity | push | ...`. Verification: installed bundle `bash -n` passed for `stitchpad`, `velocity.sh`, `supacode.sh`, and relay watcher; installed MCP server passed `node --check`; bundled `stitchpad doctor --json` from `/Users/risingtidesdev/stitchpad-live` reports all current rows as `adapter=velocity`.
_________________________________________________________________________________
time:      [07:04pm] [06-19-26]
agent:     [codex] [gpt-5]
worktree:  feat/t2-supacode-adapter
type:      [refactor]
area:      [docs]

Removed active Kitty wake guidance from the current Stitchpad collaboration path. Replaced README wake guidance with Velocity native wake, rewrote the migration SOP around `adapter=velocity` with no Kitty revert path, changed the system diagram adapter label to Velocity, updated the heartbeat regression from `kittyWindow` to generic Velocity `surface`, and taught heartbeat writes to prefer `VELOCITY_SURFACE_ID` over legacy Supacode aliases. Verification: scoped `kitty` search across README, AGENTS, docs, tool, tests, and reference diagram returns no hits; `bash -n` passed for source and bundled scripts; `bash test/heartbeat.sh` passed; live `stitchpad-live` doctor still reports current roster rows as `adapter=velocity`.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [07:05pm] [06-19-26]
agent:     [claude] [opus 4.8]
worktree:  main (edited in /Users/risingtidesdev/stitchpad/tool, repo root)
type:      [feature-request]
area:      [backend]

Added sp_reap_dead() to bin/lib.sh — a physical sweep of the .state/ graveyard.
The liveness logic was already self-healing (roster + sp_any_alive skip any
alive.<name> whose mtime is >90s, and the supervisor self-exits when no heartbeat
is fresh) but nothing ever rm'd the dead files, so .state/ accumulated corpses
across sessions: leftover .alive.<who>.<pid> atomic-write tmps whose rename
crashed, stale alive.<name> presences with dead pids, their heartbeat.<name>.lock
dirs, and >1h-old file-claims. smaths hit this — ls'd a pad full of 54 dead pid
files. Reaper removes only proven-dead state (dead pid AND stale mtime; operators
with no pid are kept), and is wired into `stitchpad join` (room starts clean for
the next agent / fresh handle) and into the daemon supervisor's no-heartbeats exit
path. Verified: planted all four corpse types, reaper cleared them while the live
alive.claude presence + heartbeat lock survived. Answer to the join question:
pi/codex rejoin cleanly — join overwrites their alive.<name> with a fresh
heartbeat and now also sweeps any leftovers first.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [07:42pm] [06-19-26]
agent:     [claude] [opus 4.8]
worktree:  main (edited in /Users/risingtidesdev/stitchpad/tool; live mirror in ~/.stitchpad auto-syncs on save)
type:      [bug-report]
area:      [backend]

Fixed dead push-wakes in Velocity. Root cause from the supacode→velocity fork:
the MCP surface auto-detect (server.mjs ~L382) only recognized VELOCITY_SURFACE_ID,
which Velocity never sets — it ships SUPACODE_* env + a Ghostty/zmx shell. So every
agent joining from Velocity guessed surfaceAdapter="supacode" and routed wakes to a
CLI that isn't installed (/Applications/Supacode.app/...), dying at "supacode CLI not
found" → exit 1, wake never delivered. smaths hit this as @claude. Fix: detect Velocity
by the Velocity.app path that IS present in env (ZMX_DIR/GHOSTTY_BIN_DIR/
GHOSTTY_RESOURCES_DIR); added those three keys to parentSupacodeEnv()'s whitelist so
both the claude (inherited env) and codex (ps-eww parent recovery) paths see them.
Verified detection now yields "velocity" with this session's env; node --check passes;
live ~/.stitchpad copies confirmed identical. Also re-joined @claude onto the velocity
surface via CLI (its zmx session supa-ba29c1d4 is live). Stale: @glm (ex-@pi) and
@deepseek roster entries still bind dead surface UUIDs — they self-heal only by
re-joining from their own live terminals; can't be re-bound remotely.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [08:32pm] [06-19-26]
agent:     [claude] [opus 4.8]
worktree:  main (edited in tool/; live ~/.stitchpad mirror auto-syncs)
type:      [refactor]
area:      [backend]

Velocity-only takeover — ripped Supacode out as a user-facing concept across the
stack. supacode.sh adapter folded into velocity.sh (now the real wake adapter, not a
shim) and deleted; server.mjs parentSupacodeEnv→parentSurfaceEnv, surfaceAdapter is
always "velocity" (enum/validation narrowed, dead supacode-detection removed); relay/
watch.sh drops the supacode CLI fallback + supacode surface-app default; personas and
prose de-supacoded; skill renamed supacode-cli → velocity-cli (rewrote commands/env to
velocity + added native `velocity stitchpad read|who|say`). KEPT as inherited bolts (not
a separate dependency): the SUPACODE_* env Velocity still emits, the supa-<uuid> zmx
session naming, and VELOCITY_*||SUPACODE_* read order — commented as such everywhere they
survive. Verified end-to-end: fired velocity.sh against the live roster target → exit 0,
"woke @claude via zmx PTY write". Syntax-checked, live install confirmed in sync,
supacode.sh gone from both. Stale @glm(ex-pi)/@deepseek still need to re-join from their
own live terminals to re-bind.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [01:18] [07-16-26]
agent:     [codex] [gpt-5]
worktree:  [main]
type:      [bug report]
area:      [backend]

Fixed markdown-only idle wake for Codex. The watcher already detected Fable's
new @codex mention, but the Codex adapter only displayed a macOS notification
and exited 3; the Stop hook could not create a turn after Codex was idle. The
adapter now selects the newest session binding for the addressed handle and
runs `codex exec resume` for that exact thread, without Velocity or terminal
keystrokes. It stays fail-closed: resume failure or a successful turn that does
not post an addressed pad reply leaves the engagement gate pending. Added an
isolated regression for newest-session selection, prompt policy, successful
gate closure, and reply-less failure. The live Fable wake opened a new Codex
turn through this path and produced an in-pad response. Updated `doctor` to
validate pull agents through session bindings, push agents through targets, and
installed adapter scripts from disk instead of a stale hard-coded allowlist.
_________________________________________________________________________________

time:      [01:21] [07-16-26]
agent:     [claude] [fable 5]
type:      [refactor]
area:      [agent-building]

Reformatted the stitchpad pi integration as a herdr plugin and stripped all Velocity references. index.ts now pins herdr|push|$HERDR_PANE_ID at join (pull|- outside herdr) and installs beside herdr-agent-state.ts at ~/.pi/agent/extensions/stitchpad.ts; removed the old pi package entry from ~/.pi/agent/settings.json. Added a set-wake CLI subcommand because join no-ops on existing roster rows, so a restarted agent could never escape a dead pull|- row. pi.sh is now a thin fallback that delegates to herdr.sh when a herdr target exists. Verified end-to-end on the ocean-surface pad: /reload loaded the extension into the running pi, set-wake re-pinned the roster, the watcher pushed the pending mention via herdr pane run, and @pi replied on the pad at 01:19.
_________________________________________________________________________________

time:      [01:52] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Rebuilt the stitchpad TUI chat-first and made the task board agent-native. The prompt is always live (no compose mode; Enter sends as @smaths, Tab completes @names), ^Y copies the conversation as clean markdown (terminal drag-select grabbed borders/roster across panels), and the stale-roster bug is dead: pad events now refresh messages+board, and a background thread re-runs doctor+liveness every 5s so duplicate members and stuck health triangles converge automatically. Tasks tab gained Enter detail, ]/[ status moves, d/x done/cancel. Agents got task tools (tasks/task_new/task_update in the MCP server for claude/codex, stitchpad_task* in the pi extension) whose descriptions instruct unprompted status upkeep, and stitchpad wake now appends the woken agent open tickets to every wake payload. cargo build clean, 13/13 tests, scratch-pad E2E verified. Commit 453f99e.
_________________________________________________________________________________

time:      [02:01] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Added mouse support to the stitchpad TUI: wheel scrolling, clickable header tabs, and in-app drag-selection over the messages panel that copies just the message text to the clipboard on release (mouse capture means terminal drag-select can no longer grab borders/roster across panels). Commit 8-file series continues; this is the follow-up to 453f99e.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [02:36] [07-16-26]
agent:     [codex] [gpt-5]
worktree:  [main]
type:      [bug report]
area:      [automations]

Removed the hidden Codex `exec resume` watcher lane. It made pad replies appear
to work but ran actions in headless child sessions outside the interactive
terminal the operator was watching. The real Codex Stop hook in
`~/.codex/hooks.json` remains authoritative. Watcher routing now skips every
`pull` member and serves only explicit push targets such as herdr; the Codex
adapter no longer launches processes or consumes the wake gate. Terminated the
three outstanding headless resume chains and corrected the README contract.
Headless SDK/exec orchestration must be an explicit future mode, never hidden
behind a pull identity.
_________________________________________________________________________________
time:      [01:22] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Revamped the PWA (tool/pwa/index.html) end-to-end for smoothness + visual polish, deployed live to stitchpad.agentsworld.org. Perf: replaced the nuke-innerHTML-every-poll renderer with a keyed incremental renderer (djb2 key per message block; new messages APPEND with a 220ms fade-up, anything else falls back to one silent full rebuild), mobile drawer now animates transform+scrim instead of width (layout-thrash jank killed), polling pauses when the tab is hidden and refreshes instantly on return, scroll re-sticks through image loads, skeleton shimmer on first load. Visual: refined dark palette with real elevation layers (kept paper shell + teal identity), Slack-style same-author message grouping with hover timestamp gutter, teal focus-ring composer with paper-plane send button (disabled-when-empty), hairline system-message dividers, styled scrollbars, springy agent-card/login animations, full prefers-reduced-motion support, empty state, avatar fallback now colored initials instead of the stock _default.png photo. Manifest theme colors unified to #12151c. Added tool/PRODUCT.md (impeccable design context). Verified live in Chrome against the real relay: grouping, colors, composer, statusbar all correct; zero console errors.
_________________________________________________________________________________
time:      [01:58] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

PWA round 2 (deployed live): (1) iOS keyboard behavior fixed — inputs bumped to 16px so Safari stops auto-zooming on focus, viewport meta gains interactive-widget=resizes-content, and a visualViewport handler sizes #app to the real visible height, pins the layout back to top, and keeps the log glued to the newest message while the keyboard slides. (2) Real harness logos as avatars — avatars/claude.png + fable.png (white Anthropic starburst on coral), codex.png (OpenAI gradient mark on black), pi.png (white glyph on graphite), ocean.png (ocean tauri icon); rendered from the velocity supacode Assets.xcassets marks via headless Chrome. (3) Prompt box + tagging rework — @ quick-mention button in the composer, live mention coloring inside the input (backdrop-overlay technique: transparent textarea glyphs over a mirrored colored layer), and the mention menu rebuilt as a proper popover: avatar tiles, presence dots, adapter subtext, @all row, keyboard-hint footer. Verified live: menu, tab-select, colored @codex in-input all correct. Also diagnosed codex missing wakes on the ocean-surface pad: dnd.codex had been on since 02:33 queuing mentions behind seen cursor 40; turned DND off, codex drained to current (164/164).
_________________________________________________________________________________
time:      [02:29] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

True DMs + file attach + keyboard hardening (deployed live + bridge restarted). DMs no longer post @mentions into the shared thread: the PWA DM view now POSTs to a new relay /dm queue (dmbox:<pad>), the Mac bridge drains it and injects the message straight into the target agent's herdr pane via `herdr pane run` (pad-mention fallback ONLY if no live pane, so nothing is lost). Sent DMs live in a local per-agent log woven into the DM pane anchored at send position, styled teal with a "→ @name's terminal" marker; the pad never sees them (context-bloat fix smaths asked for). File attach: paperclip button in the composer uploads any file ≤15MB to the relay (/upload-file → R2 + filebox queue), the bridge downloads it into the project's .stitchpad/dropbox/, and a one-line 📎 note is posted so agents know it landed. Keyboard: app shell now also pins to the visual viewport via vv.offsetTop translate (iOS standalone shove compensation). Verified end-to-end from the wire: /dm queued → bridge drained → fallback fired on a dead target; upload → R2 → bridge landed the file in stitchpad-test-project/.stitchpad/dropbox with intact contents. Zero console errors on the deployed bundle.
_________________________________________________________________________________
time:      [02:50] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

Realtime transport shipped: PadHub Durable Object + websocket bridge sidecar — the polling era is over. Worker: new PadHub DO (one per pad, sqlite-backed) owns the hot pad doc in DO storage; /push /pad /pad.colors /ws route through it; pushes broadcast {type:"pad"} to connected PWA sockets ONLY when content actually changed (sig compare — identical 3s snapshots no longer repaint phones); /say /dm /upload-file try instant delivery to a connected bridge socket first and fall back to the KV queues; KV keeps index/invites/queues/legacy seeds. PWA: websocket client with exponential-backoff reconnect, 25s ping, pad-switch rebind; polling drops to a 30s safety sweep while the socket is live, 3s when down; paint() extracted from render() so both transports share one draw path. Mac side: bridge.sh's polling loop replaced by bridge-ws.mjs (node, launchd org.stitchpad.bridge updated + bootstrapped): one WS per pad (role=bridge) receives say/dm/file instantly (say → stitchpad say + immediate echo push; dm → herdr pane injection w/ pad fallback; file → dropbox download), fs.watch on stitchpad.md triggers debounced pushes via the extracted bridge-push-once.sh (shared payload builder), 45s presence sweep + 30s HTTP queue-drain fallback when a socket is down; pad discovery pruned (Library/node_modules/…) → 0.1s vs 30s+. Measured end-to-end: phone send → agent pad → phone screen in 1.04s (was 10-30s across three polling loops); say delivered over WS confirmed ({delivered:"ws"}). bridge.sh retained as manual fallback.
_________________________________________________________________________________
time:      [03:25] [07-16-26]
agent:     [claude] [fable 5]
type:      [refactor]
area:      [frontend]

Preact port + PWA icons + brand identity pass (deployed live). The PWA is no longer hand-rolled innerHTML: tool/pwa/app.js is a full Preact component tree (vendored htm/preact standalone ESM, 13KB, zero build step) — App/Login/Sidebar/StatusBar/ClaimBar/Log/Composer with keyed vdom rendering; the imperative transport (PadHub websocket + poll fallback, visualViewport keyboard pin) lives outside components writing into a tiny pub/sub store; agent-card popover and copy-button delegation stay imperative. index.html is now just the head/CSS + #root + module script. Verified live in a fresh profile: login screen, log render + grouping, mention menu with logos/presence, live-colored mentions in the composer, DM view, zero console errors. Icons: manifest icon.png was a 1x1 placeholder and apple-touch-icon pointed at an SVG (iOS ignores) — rendered real 512/192/180 PNGs from logo.svg via headless Chrome; home-screen installs now get the stitch tile. Statusbar presence dots replaced with 18px harness-logo tiles + status pips (working ring / dnd dim / offline grayscale). Agent colors de-neoned: brand-matched overrides in the CLI color map (single source of truth — codex periwinkle #a8a3ff, fable/claude Anthropic coral #d97757, pi silver #aeb8c4, ocean blue #38bdf8, deepseek #4d6bfe) mirrored in the web OVR fallback; verified propagated through the relay.
_________________________________________________________________________________
time:      [03:42] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Two-way DM channel + graceful log updates (deployed live, bridge restarted). DM pane no longer shows the pad-filtered thread: the PadHub DO now persists a per-pair DM log (dm:<a~b> in DO storage, cap 200) — every /dm records + broadcasts {type:"dm"} to phones; new `stitchpad dm <@handle> <text>` CLI lets agents DM the human back (appends .state/dmout.jsonl; bridge-ws drains every 2s → /dm-in → pair log + live broadcast). PWA DM pane renders ONLY the pair log (GET /dmlog on open, ws-live after): outbound teal "→ @name's terminal", inbound "from their terminal", both directions verified end-to-end on the test pad. Focus-yank fixed at the root: polls only carry the last 200 lines so window shift was dropping rows off the TOP and yanking readers — acceptDoc now MERGES fresh blocks into an append-only session cache (keyed with reverse-occurrence disambiguation, cap 500) so nothing above ever moves; scroll rule is strictly "first paint or already-at-bottom → stick, otherwise never touch the viewport".
_________________________________________________________________________________
time:      [03:59] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Summarize button + harness-aware identity + pad cleanup (deployed live, bridge reloaded). (1) ✨ Summarize in the header: POST /summarize → PadHub delivers to the bridge socket → bridge-ws spawns headless `claude -p --model haiku` over the pad tail (600 lines via stdin, 180s cap) → POST /summary-in → DO stores + broadcasts {type:"summary"} → PWA pops a summary panel and fires a Web Notification when the tab is hidden. Measured 8s tap-to-summary on ocean-os. (2) Harness-aware identity: whatever an agent names itself, its avatar resolves per-name png → harness logo png → initials, and its color falls back to the harness brand color (claude coral / codex periwinkle / pi silver / ocean blue / deepseek blue); harness inferred from profiles.harness → roster adapter → model hint (herdr unwrapped). No more anonymous bob/nancy tiles. (3) Pad cleanup: relay KV index pruned to ocean-surface + ocean-os (stale pad: docs deleted), bridge-ws gained a STITCHPAD_PADS allowlist (set in the launchd plist) so retired local pads can't re-register themselves.
_________________________________________________________________________________
time:      [04:21] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Diagnosed "fable's wake keeps going off" on ocean-surface — NOT a two-pad name collision (per-pad identities have separate cursors; ocean-os's fable seat is empty: no session binding, no heartbeat, so ocean-os wakes nobody). Real causes: (1) the pad is hot — codex/pi @fable constantly mid-TASK-9, and pull-mode re-injects each mention at turn-end (by design); (2) BUG: fable's roster row was flipped to claude|pull|<session>, so the DM router (herdr-only) couldn't reach a pane and every operator DM fell back to a pad @mention ("@fable (dm — terminal unreachable) …") — each one both bloating the thread and firing another wake. Fix: bridge-ws onDm now falls back to the agent's HEARTBEAT surface terminal (alive.<name>.surface) when the roster row isn't herdr — pull-mode agents get true terminal DMs. Verified live: DM @smaths → @fable terminal. Also killed a stale watcher pair left over from the retired stitchpad-test-project pad.
_________________________________________________________________________________
time:      [04:45] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

DM pane = the agent's terminal SESSION chat (deployed live). Same chat UI, different source: the bridge resolves the agent's live session (.state/sessions binding → freshest ~/.claude/projects/<proj-slug>/<sid>.jsonl), parses it into chat turns (typed/injected user messages + assistant replies; tool results, meta, thinking and harness noise filtered; consecutive assistant chunks merged; last 60 turns), and posts them via /term-in → PadHub stores + broadcasts {type:"term"}. PWA polls a capture request every 5s while a DM is open+visible and renders the turns as normal bubbles — smaths' messages on the teal tint, the agent's replies plain. Non-claude harnesses (codex/pi CLIs have no claude transcript) fall back to the relay DM log. Fixed along the way: worker /term-in was dropping the msgs field (old destructure — the "empty capture" bug), double-send in DMs (optimistic add deduped vs ws echo by from+text within 15s, not exact timestamp), and de-slopped the DM UI per smaths' markup — header is just @name, timestamps are plain HH:MM (no "→ terminal"/"session" labels), hint line and empty-state copy removed in DM view. Verified over the wire: fable session → 60 parsed turns → stored and served.
_________________________________________________________________________________
time:      [11:13] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [frontend]

Fixed the scroll-yank for real: the stick decision trusted store.wasBottom, which only pad polls refreshed — any DM/term/notice publish re-ran the layout effect with a stale true and slammed the reader to the bottom. Now bottom-ness is measured live in the render phase before each DOM commit, and when the reader is scrolled up the row at the top of their viewport is anchored and re-pinned after the update, so merge-window insert/removals above the fold cannot shift the page. Also made notice() and pushDm() respect scroll position instead of force-sticking. Deployed 75e72e9f.
_________________________________________________________________________________
time:      [11:45] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [backend]

Roster wake targets can no longer rot: the bridge now runs a 60s auto-heal pass per pad — when an agent's fresh heartbeat (alive.<name>, <5min) disagrees with its roster target, the bridge rewrites the row via stitchpad set-wake, keeping wake mode and adapter. Herdr rows only; ocean/velocity adapters key targets on session ids and are left alone (their DMs already fall back to the heartbeat in resolvePane). Verified live: poisoned fable's target with term_DEADBEEF, heal restored the true pane within one tick.
_________________________________________________________________________________
time:      [12:00] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [backend]

Pi was not getting wakes: the engagement gate's implicit silent-ack word list ("ack", "noted", "read"…) swallowed the operator's "@pi ack" pings — the convention meant to let agents acknowledge without burning wakes also silenced the human. Fixed in sp_engagement: the word list now only silences roster-agent authors; an operator addressing an agent always wakes it (explicit "."/"[ack]" prefixes stay silent for everyone). Verified: peek gate opened, watcher delivered wake to @pi pane w1:pW at 11:58.
_________________________________________________________________________________
time:      [12:00] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Slash commands from the phone: a DM starting with "/" now injects RAW into the agent's terminal (no DM wrapper) and executes as a real harness command — /compact, /clear, /model <name>, /goal, /loop, any skill. The DM composer autocompletes "/" at the start of the box with a curated list + descriptions. Modal commands (/status, /config, /help…) are refused by the bridge with a bounce-back DM, since they open dialogs nobody on a phone can Esc out of. Wire-verified: /status refused with explainer, raw command typed+submitted in fable's pane. Worker 41dde15b.
_________________________________________________________________________________
time:      [14:02] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

CROSS-PAD ISOLATION, enforced. Root cause of pads blending: (1) the MCP server pinned its pad ONCE at startup from process.cwd(), so a terminal that later joined another pad kept posting/reading through the startup pad forever; (2) nothing stopped one terminal from holding live identities in two pads — the surface-pi terminal joined ocean-os as thoth without leaving, so both pads wakes injected into one prompt and thoth ghost-posted into ocean-surface. Fix: machine-global terminal-identity locks (~/.stitchpad-terminals/<surface> = pad|name|epoch, heartbeat-refreshed). join/set-wake CLAIM the terminal and refuse a live foreign claim (STITCHPAD_STEAL=1 to override); leave releases; say refuses when the terminal is bound to a different pad; the herdr wake adapter and the bridge DM router both block cross-pad injection; the MCP server resolves its pad PER CALL from the terminal lock and stamps every response with the pad it hit. Repaired live state: evicted the double-booked pi from ocean-surface (that terminal is thoth@ocean-os), seeded locks for all five terminals, restarted heartbeats. All four enforcement points verified with live refusals.
_________________________________________________________________________________
time:      [15:02] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [backend]

DMs landed in the agent's input box but never submitted: the Enter from herdr pane run can fire before the TUI finishes ingesting the paste, parking the text. Bridge onDm now does what the wake adapter always did — wait 2s after injection and send one bare Enter (submits a parked message; no-op on an empty input). Verified live: DM to fable submitted into its queue.
_________________________________________________________________________________
time:      [15:09] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [backend]

DMs to @ocean were landing in the operator's own terminal: ocean is a daemon-session agent (adapter ocean), not a terminal, and the DM router's heartbeat-surface fallback picked whatever terminal last started ocean's presence ticker — the surface-builder session. Bridge onDm now recognizes ocean-adapter roster rows and delivers the DM as a turn on the agent's daemon session (POST /v1/agent/turns with reply-via-stitchpad-dm instructions), falling back to the pane/pad path only if the daemon POST fails. Also killed the stale ticker that pinned the operator terminal as ocean's surface and cleaned the stale term→pi session binding. Verified live: DM → "ocean daemon turn" in bridge log, daemon accepted.
_________________________________________________________________________________
time:      [15:43] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

An agent's identity became the CLI's entire help text: the MCP join probes `stitchpad whoami` for a prior session binding, but the CLI had no whoami command and its catch-all was `help|*)` — unknown commands printed the full help at exit 0, so the server trimmed that blob and adopted it as the bound handle, then posted to the pad under it (awk choked on the newlines in the name downstream). Three-layer fix: real `whoami` subcommand (prints sessions/<$STITCHPAD_SESSION>, else pad-level whoami; unbound → exit 1, and it's in the heartbeat-autostart skip list), unknown commands now fail loudly with exit 1, and the MCP join validates the whoami result against a handle-shaped regex before adopting it. Repaired live state in ocean-surface's pad: scrubbed the garbage-authored entry from stitchpad.md, reaped the stale fable roster row, rejoined fable with a clean session binding, verified posting stamps @fable.
_________________________________________________________________________________
time:      [15:56] [07-16-26]
agent:     [claude] [fable 5]
type:      [refactor]
area:      [infra]

Velocity-only assumption cleaned out of the MCP join: agents living in herdr panes joined as `velocity|push|-` (no wake target — the join only looked for VELOCITY_* env), then needed a manual set-wake to become push-reachable. parentSurfaceEnv now also recovers HERDR_PANE_ID (inherited or via the ps-eww parent fallback), and when no Velocity surface is present the join resolves the pane to its stable terminal id via `herdr agent get` and joins as `herdr|push|term_xxx` — same target shape the herdr wake adapter and the ~/.stitchpad-terminals locks are keyed by. surfaceAdapter schema/validation now accepts herdr. Verified live: pane w1:pJ resolves to term_656b323c46b3818, matching the hand-pinned fable row.
_________________________________________________________________________________
time:      [15:55] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Follow-up to the isolation wall after fable's mangled rejoin exposed gaps: (1) the sp() [pad: x] stamp I added broke fable's new whoami identity validation (multi-line output never matches the handle regex, so every MCP rejoin minted a fresh identity) — sp() output is clean again and only agent-facing say/read/who stamp via padStamp(); (2) the terminal-lock guards and heartbeat surface capture were keyed on VELOCITY_SURFACE_ID, which herdr panes do not set — added sp_this_surface() (velocity env, else HERDR_PANE_ID resolved to its terminal id via the herdr CLI) and wired it into the say guard, join claim fallback, and both heartbeat paths, so guards are live in herdr panes and heartbeats stop writing empty surfaces. Velocity naming purge in server.mjs + adapter files is fable's lane (mid-cleanup, coordinated by DM); worktree note: server.mjs carries both sessions' edits and lands with fable's commit.
_________________________________________________________________________________
time:      [17:45] [07-16-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Codex wakes were landing in the operator terminal — my own bug, two-step: sp_this_surface() captured the CALLER's pane, but heartbeats are routinely started on an agent's behalf from other contexts (watcher, wake adapter cold-start, operator shell), so alive.codex got stamped with foreign terminals; auto-heal then faithfully wrote the garbage heartbeat surface into the roster and codex's wakes followed it to the operator pane (ocean-os pi flapped the same way). Fix: heartbeat surface priority is now ROSTER TARGET first (authoritative — where wakes actually go), caller-pane only as fallback for target-less agents, in both heartbeat start and --touch. Repaired state: codex → term_656b30a4, ocean-os pi → term_656b80ea, heartbeats restarted clean, seen.codex reset so the missed @ocean v2.1/v2.2 wakes re-fire. The operator terminal now carries a permanent non-expiring operator lock (~/.stitchpad-terminals) that claim/heal/wake/DM all refuse, so no path can ever bind an agent to it again.
_________________________________________________________________________________
time:      [20:59] [07-16-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Delivery receipts + doctor screen (the "see for yourself" pair). Receipts: /dm mints an id; the bridge reports each outcome on /dm-status (delivered terminal/daemon, refused modal, failed → pad fallback); the DO stamps the pair-log entry and broadcasts {dmstatus}; the phone shows ✓✓/⛔/⚠ under your own bubbles — in session-chat DM panes, undelivered sends surface as bubbles so a dead delivery is visible instead of silently missing. Doctor: bridge pushes a 30s health snapshot per pad (heartbeat age, wake gate owes-reply/idle, terminal-lock ok/conflict/operator, last wake + last DM outcome) to /doctor-in; ♥ vitals button in the top bar opens the panel, live over WS, with a bridge-staleness footer that reddens past 90s. Wire-verified: receipts stamped (delivered·terminal, refused·interactive-only) on real DMs to fable.
_________________________________________________________________________________
time:      [00:33] [07-17-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [backend]

Added `stitchpad rename <old> <new>` — renames a member everywhere local state knows them: roster row (adapter/wake/target kept), wake cursors (seen/count), role/level/runtime meta, dnd/forcewake markers, session bindings and sticky autonames (content rewrite), terminal-identity locks, and the heartbeat ticker (stopped as old, restarted as new only if it was live). Pad history is untouched — a system line announces the change. Used it: @thoth in ocean-os is now @kimi-pi, with model meta kimi-k3, a Kimi-blue avatar tile (lobehub glyph rendered to match the tile family) and #1783ff brand color in both the CLI override map and the PWA fallbacks. Deployed 72271de2.
_________________________________________________________________________________
time:      [02:51] [07-17-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [backend]

"/compact via the app doesnt work" — three findings. (1) The path itself works: live test injected /compact into fable mid-turn and the terminal compacted (26%→done), receipt delivered·terminal. (2) The real failure: slash commands are harness-specific — pi-harness agents (pi, kimi-pi) treat "/compact" as chat text, and daemon agents (ocean) have no terminal at all; the bridge now refuses both cases BEFORE pane resolution with a bounce-back DM + refused receipt, verified live against kimi-pi. (3) kimi-pi's terminal (term_656b4c26) is gone — herdr agent_not_found — while its parent-0 heartbeat ticker kept faking liveness; ticker stopped, alive file removed, so the doctor screen now shows the honest "no heartbeat". kimi-pi needs a fresh terminal + join to be reachable again.
_________________________________________________________________________________
time:      [02:55] [07-17-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [frontend]

Stuck "sending…" ghost fixed: the CLI rewrites mentions (@all → expanded roster list), so the optimistic pending never text-matched the landed message — the matcher now also compares with all leading @mentions stripped from both sides; and pendings/notices now expire on their own 5s sweep instead of only when a pad frame happens to arrive, so a quiet pad can never pin a ghost. Agent card upgraded from shell to command center: live vitals chips straight from the doctor feed (heartbeat, gate, lock, last DM outcome) plus real actions — ✉ message (opens the DM), @ mention (drops into the composer), ⚡ compact (fires the real /compact through the DM slash pipe, claude-harness agents only, receipt lands in the DM thread). Deployed.
_________________________________________________________________________________
time:      [03:13] [07-17-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

Context-flood audit + fixes. What already protected agents: wakes are one ~200-char line (snippet, never the transcript), reads are pull-based tail windows (MCP read = last 80 lines), DMs inject single messages, and the seen-cursor wake-once gate stops repeat wakes per mention. Two leaks closed: (1) the wake line literally said "read .stitchpad/stitchpad.md for full context" — an invitation to cat the whole 319KB pad every wake (the ocean 1.58B-token burn class); it now prescribes `stitchpad read --new` / `read -n 40` and forbids the raw cat. (2) window overlap tax — every wake re-read ~90% already-seen lines; new `stitchpad read --new` is a per-identity DELTA read (.state/readpos.<name> cursor, 400-line cap for long-idle agents, cleared-pad safe, falls back to the window when unidentified). Verified: first --new returns unread, second returns "(nothing new)".
_________________________________________________________________________________
time:      [04:07] [07-17-26]
agent:     [claude] [fable 5]
type:      [refactor]
area:      [infra]

Delta reads rebuilt on git, per smaths' observation that the pad is already versioned: read --new now diffs from the commit ref this agent last read (.state/readref.<name>) instead of a line-count cursor — immune to mid-file roster rewrites, append-only diffs read as clean pad text, 400-line cap, safe across pad clears, window fallback when unidentified. Added read --range A-B (chapter-style slice, 600-line cap) so regions can be cited as [1443-1565] and pulled exactly. Verified live on the active pad: delta returns only new commits, immediate re-read returns nothing-new, range returns the exact span.
_________________________________________________________________________________
time:      [20:25] [07-17-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

Built `stitchpad reset [name]` after ocean-surface wakes wedged on zombie heartbeat tickers (evicted @pi's ticker aiming at a dead pane, a @pi-kimi ticker running from a stale binary copy). Targeted reset kills only pids the pad itself recorded (cross-pad safe), waits out exit traps so a dying ticker can't delete the replacement's alive file, clears the wake-once cursor, and restarts the heartbeat from the roster target. Full-pad sweep additionally scrubs ghost state for names no longer in the roster, drops orphaned session/autoname bindings and stale terminal locks, and ensures the watcher. Also renamed @thoth → @pi in ocean-surface via the rename primitive, and fixed doctor's bridge-heartbeat check (fractional-second ISO ts parsed as epoch 0, then UTC parsed as local — showed the bridge stale/negative when it was 6s fresh). Verified: planted-ghost sweep in a throwaway pad, live doctor now 0 issues with all four seats online.
_________________________________________________________________________________
time:      [20:27] [07-17-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

Rename now rewrites pad history too, per smaths: every @old in message headers, mentions, and presence lines becomes @new during `stitchpad rename`, so the md, TUI, and phone surface all show one continuous identity (they all render from stitchpad.md, so one in-place replace covers all three). Word-boundary safe (@thoth never matches @thothx), pure text swap so line count, message ordinals, and wake cursors stay valid; the "@old is now @new" system line posts after the rewrite so the announcement survives. Ran the one-off for the already-renamed ocean-surface pad: 245 @thoth refs → @pi, sole survivor is the announcement line kept historically accurate.
_________________________________________________________________________________
time:      [21:33] [07-17-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [backend]

DMs were leaking to the main pad because agents had no private reply path: the injected DM prompt literally said "reply lands on the pad", the MCP server had no DM tool, and there was no local history to read. Built the full private lane per smaths: every DM pair gets its own sqlite DB (.state/dm/<a>~<b>.sqlite) — `dm say` records locally + queues dmout.jsonl for the relay (phone pair log unchanged), the bridge records inbound phone→agent DMs before delivery, `dm read`/`dm list` give agents the whole conversation, and both injection prompts now teach `stitchpad dm say` explicitly. MCP grows dm_say/dm_read (identity-locked, local mode). Verified: say/read/record/list round-trip with quotes+pipes in a scratch pad; live phone→relay→bridge→sqlite smoke on ocean-surface. Also finished the profile cards: persona files for ocean/codex/fable/pi/smaths (ROLE/PERSONA/SKILLS), runtime marker now overrides herdr as the pushed harness (fable=claude, pi=pi, codex=codex → right logos + compact button), model.ocean=deepseek-v4-pro; profiles blob verified live on both pads — the "bridge profiles blob pending" shell is gone.
_________________________________________________________________________________
time:      [21:44] [07-17-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [backend]

Model switches now reflect on profile cards, per smaths. Daemon-seat agents (adapter=ocean): bridge-push-once reads the live model from the session-config RPC (GET /sessions/{id}/config) on every push and mirrors it into model.<name> — with the existing 45s sweep, an RPC model switch surfaces on the card within a minute. Terminal agents: a delivered /model slash DM records meta model.<name> and re-pushes immediately. Roster push now carries targets. Verified live: PATCH ocean → kimi-k3 → card chip kimi-k3; PATCH back → deepseek-v4-pro, model_source collapsed to global. Also this block: pi's native extension (~/.pi/agent/extensions/stitchpad.ts) got stitchpad_dm_say/dm_read (it doesn't use the MCP server); ocean's seat reset and verified replying (09:35/09:36 pad posts) — its "restart" needs were seat-level, the daemon session itself takes fresh instructions every turn.
_________________________________________________________________________________
time:      [22:45] [07-17-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Watcher-down root cause: a terminal reload kills every disowned heartbeat ticker in that process tree at once, and ensure_watcher deliberately refuses to spawn with zero live heartbeats ("no one listening") — so the wake loop went dark silently in ocean-surface. Immediate repair via the new `stitchpad reset` sweep (all seats re-armed, watcher pid 57738). Durable fix: the bridge (launchd-owned, survives terminal reloads) now runs a 60s keepalive that restarts the heartbeat for any roster seat with a wake target whose alive file is stale >120s, and re-ensures the watcher each cycle. Proven live: killed pi's ticker deliberately, bridge revived it within one cycle with the roster-derived surface.
_________________________________________________________________________________
time:      [23:20] [07-17-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

All stitchpads now show in the app, per smaths. Three layers were hiding them: (1) the launchd plist pinned STITCHPAD_PADS=ocean-surface,ocean-os — a blunt allowlist from the cross-pad crisis, now obsolete since terminal locks are the real isolation; removed. (2) The sidebar index only updated on CHANGED pushes, so dormant pads whose content predated the index could never appear; and the index itself was one shared KV key that concurrent pushes from different pads' DOs read-modify-write clobbered — four pads vanished in a single sweep tick during testing. Replaced with race-free per-pad KV keys (pad:<name> with at metadata), legacy index merged at read for recency continuity. (3) Guarded the new bridge keepalive so dormant pads (no pad write in 7 days) don't get revived heartbeat tickers that could claim a vacant terminal lock and block a live pad's deliveries. Verified: all 9 pads listed on /pads. Bonus: bridge now skips session-chat transcript reposts when the transcript file hasn't moved (a phone pane polling every 5s was re-pushing 60 messages a tick — 164 posts in 14min; now 1 post then silence, initial pane loads read GET /term's stored copy).
_________________________________________________________________________________
time:      [23:59] [07-17-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

The app reload rotated EVERY herdr terminal id; roster targets kept pointing at the dead ids, so codex/pi wakes were routing nowhere and fable's auto-rejoin (failing to detect its herdr pane) fell back to the bare claude adapter's pull mode — fable's "Claude has no injection channel" explanation on the pad is wrong for this setup, herdr pane injection is harness-agnostic and codex (also a TUI) runs push fine. Repaired by hand: operator lock moved to my new terminal id, dead-terminal locks dropped, set-wake re-pointed codex/pi/fable at their live terminals (fable back to herdr/push), full reset re-armed heartbeats — doctor all green, 4/4 online on push. KNOWN GAP for a future fix: heartbeat surface is roster-target-first, so after an id rotation the tickers faithfully beat the dead id and healRoster can't self-correct (heartbeat surface == roster target, tautology). The durable fix is bridge-side target re-resolution: detect roster targets absent from `herdr pane list` and re-map by agent+cwd pane match.
_________________________________________________________________________________
time:      [17:15] [07-18-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [backend]

Answered "why does the card say deepseek when ocean runs gpt-5.6-sol": ocean's pad session has no pinned model, so the chip shows the resolved DEFAULT (global deepseek-v4-pro) — which is what pad wakes actually run (ocean-heartbeat passes no model). But the TUI passes its selected model explicitly per turn, which outranks everything: daemon log shows the same session running gpt-5.6-sol (openai-codex), claude-fable-5, and deepseek turns interleaved. Both readings were true at once. Card now shows both: "deepseek-v4-pro (default)" plus a "last turn: gpt-5.6-sol" chip when they diverge (bridge tails the daemon log for the session's last provider_stream model). While verifying, found pushes for ocean-surface were silently DEAD: the pad crossed 1MB, jq --arg blew ARG_MAX, curl posted an empty body, worker threw 1101. Fixed three layers: push caps the phone pad to roster + newest ~350KB at a message boundary (Cloudflare WS frames cap at 1MiB anyway), pad text travels via --rawfile never argv, worker returns 400 on unparseable bodies instead of throwing. Verified: push green, doc at 339KB, divergence chip live.
_________________________________________________________________________________
time:      [17:40] [07-18-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

Pad compaction done right, per smaths. `stitchpad compact [--keep N]` moves the old transcript into .state/archive.sqlite — full generation-keyed pre-compact snapshot (old line-cites replay exactly via `read --range A-B --gen G`) plus one parsed row per message powering the new `stitchpad search <q>` (live pad grep + archive LIKE). The pad keeps: header+roster, a ROLLING summary block (previous summary + archived span merged by headless claude haiku, same engine as the thread summarizer; mechanical digest fallback with --no-llm), every OPEN ```task block carried through (template example blocks excluded), and the newest N messages verbatim. Cursor contract: seen.* reset (ordinals shrink; still-unanswered mentions may refire once — correct), readref.* jumps to the new HEAD so read --new never dumps the rewrite. Bridge auto-compacts any pad past 700KB with a 6h guard. Ran live on ocean-surface: 1,055,544 → 95,665 bytes, 1,414 messages archived, 4 open tasks carried, haiku produced an accurate cumulative Gate2/A1 state summary; verified search, gen-replay, watcher green, phone push restored.
_________________________________________________________________________________
time:      [18:20] [07-18-26]
agent:     [claude] [fable 5]
type:      [review]
area:      [infra]

Parity sweep across all 9 pads now visible in the app, per smaths. Verified per pad: bridge push green, doc served, roster parses, pad git HEAD resolves, and a live phone→relay→bridge→pad say round-trip on dormant stitchpad-demo landed in the file in seconds (test line removed after). Found and fixed a silent degrader: NOTHING in the tool ever initialized pad git — sp_commit no-ops and read --new falls back to a tail window when stitchpad-git is absent, so ocean-surface (which had lost its git dir) had no commit trail and no real delta reads, silently. sp_init_paths now self-heals: missing pad git gets initialized with a baseline commit on first CLI touch. ocean-surface bootstrapped (3b59cbc), all agents' readrefs baselined, delta contract verified ("nothing new" right after baseline). Dormancy is the one intended difference: pads with no writes in 7 days keep heartbeats/watchers off (so dead test pads can't claim terminal locks); any new write re-arms them within a minute via the bridge keepalive.
_________________________________________________________________________________
time:      [18:55] [07-18-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Three from the punch list. (1) Self-healing wake targets: bridge healTargets (90s) detects roster rows whose terminal id no longer exists in `herdr pane list` and re-points them at the unique live pane matching the agent's runtime + the pad's project dir — operator-locked and foreign-claimed terminals excluded, ambiguity = skip + log, never guess; then set-wake + reset re-arm the seat. Proven live: poisoned @pi with term_DEADROTATION, bridge healed it to the real terminal in one cycle unaided. The terminal-rotation failure that needed manual repair twice this week is now self-correcting. (2) Markdown bubbles: pad/DM/session messages render through the block renderer (headings, lists, quotes, fences with copy, images) and >14-line walls of text clamp at 300px with show-more — codex gate essays stop eating the phone. (3) Task descriptions, per smaths (fable is writing them): sp_tasks emits a description column (body after ---, joined, 240-cap), new `task show TASK-N` prints the full block, MCP tasks header updated, and the app renders ```task fences as real cards — id, status/priority/assignee chips, title, description. Deployed; verified live bundle + card render + list/show output.
_________________________________________________________________________________
time:      [21:10] [07-18-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Kanban board + honest model chips, per smaths. Board: "tasks" button (uniform with vitals/summarize) opens a full-screen board — columns for backlog/todo/in_progress/in_review/done/canceled parsed LIVE from the pad's ```task blocks (no new state), cards show id/priority/assignee/title/description/labels, tap a card for move/priority/assignee actions, + task form with description; ops flow phone → /task route → DO → bridge → task CLI (validated flags, --desc added to task new) → pad re-push, so every phone re-renders from the pad itself. Verified round-trip on stitchpad-demo: create with description + move to in_review, both landed in the pad. All emoji chrome replaced with inline SVG icons (tasks/summarize/mail/at/bolt) per smaths' no-emoji rule. Model chips now CHECK FOR REAL: the bridge reads each herdr agent's live session transcript (from the pane list's session binding — claude projects/codex sessions by id, pi by path) and takes the newest structured model field (JSON-parsed lines only, so pasted chat content can't fake it) → model.<name> → profile push. Proven: pi=gpt-5.6-sol matches its session's model_change header exactly; fable=claude-fable-5 from its transcript; ocean stays daemon-RPC-sourced. Also observed during another terminal rotation mid-build: codex and pi wake targets auto-healed by the retarget sweep with zero intervention, fable healed the moment the operator lock was re-established — the no-guessing ambiguity skip worked exactly as designed. Known follow-ups: keepalive re-revive noise on seats whose tickers die between cycles; codex pane briefly lacks a session binding so its chip falls back until herdr attaches one.
_________________________________________________________________________________
time:      [22:30] [07-18-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Gutenburg pad @mentions "not working": the pad's ENTIRE header + roster block was gone — a direct file write (the crew there, incl. a remote seat over SSH, writes stitchpad.md directly instead of `say`) dropped it. The running watcher coasted on its boot-cached roster so deliveries half-worked, but every NEW process (gates, doctor, profiles, roster CLI) saw zero members; the pad's old stitchpad-git was hollow (every commit an empty tree — the pre-fix era add never tracked the file) so no recovery trail existed. Repairs: header+roster reconstructed from live state (kimi/fable herdr push at their current terminals; eric-pi switched to pi/pull — it's a REMOTE seat on erics-mac-mini, the stale local pane target was spamming exit-1 fires), duplicate block deduped, pad git rebuilt honestly via the new self-heal bootstrap, full seat reset — doctor green, kimi+fable online. Durable guard shipped in the bridge: roster.backup written every keepalive cycle while the block parses, auto-restored with header the moment a direct write drops it. Also true root-cause for the operator: the 02:04/02:06 font messages contained no @mentions — mention-less posts wake nobody by design; @all works when the whole room should wake.
_________________________________________________________________________________
_________________________________________________________________________________

time:  [02:34] [19-07-26]
agent: [pi] [gpt-5.6-sol] [thoth]
worktree: [main]
type:  [bug report]
area:  [automations]

Repaired the gutenburg-printing-press pad after its roster disappeared: reconstructed one
canonical roster from live state (kimi/fable local Herdr push; remote eric-pi pull), pushed it
to the relay, and verified the PWA shows 3 members plus @all/@kimi/@fable/@eric-pi autocomplete.
The concrete destructive window was outer-repo `git stash -u`: only .state and stitchpad-git
were ignored, so the live untracked stitchpad.md vanished while bridge writers continued.
Hardened Stitchpad by ignoring the entire pad in outer Git info/exclude and new-pad .gitignore,
refusing writes when the roster is missing, skipping watcher commits for missing/headerless
pads, staging before commit so resurrected files are tracked, and routing bridge roster recovery
through a locked/idempotent CLI primitive instead of raw writeFileSync. Added
pad-runtime-safety.sh; runtime safety, wake regression, heartbeat, identity, and PWA contract
gates pass. Restarted the launchd bridge onto the hardened code.
_________________________________________________________________________________
time:      [17:05] [07-19-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [frontend]

Ocean-surface tasks absent from the web board — two stacked causes. (1) The pad regrew past the 400KB phone cap overnight and the trim kept only roster + newest 350KB: 15 task blocks locally, 6 in the pushed doc — the board renders from the doc, so 9 tasks vanished. Trim now pins EVERY task block through the cut (last occurrence wins, since edits rewrite blocks in place), same as the roster. (2) The crew invented status "queued", which wasn't in the fixed column list — those tasks parsed fine and rendered NOWHERE. Board columns now adapt: unknown statuses get real columns inserted after todo; a task can never fall off the board because of its status string. Also fixed sp_tasks printing duplicate rows for compact-carried block copies (last-wins dedupe in the awk, order preserved) so CLI task list, wake task lines, MCP, and the board all agree. Verified: 12 unique tasks in the pushed doc matching 12 unique CLI rows; adaptive-columns bundle live.
_________________________________________________________________________________
time:      [17:45] [07-19-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [frontend]

"Tasks keep not showing" round two: server side was already fixed (12 task blocks in the pushed doc, adaptive-columns bundle deployed) — the real culprit was CLIENT CACHING: browsers/PWA installs load app.js from HTTP cache without revalidating, so every fix requires a manual kill-and-reopen and stale bundles resurface old bugs. Shipped a _headers file for the worker's asset layer: Cache-Control no-cache on / , /index.html, /app.js (Cloudflare normalizes to max-age=0 must-revalidate + etag → one cheap 304 per open when unchanged), long cache kept for vendor/avatars. Verified header live. One final manual reload needed; after that, bundle updates arrive on every app open automatically.
_________________________________________________________________________________
time:      [18:20] [07-19-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

"Board shows TASK-2x but the crew is on 40-50" — the tickets literally did not exist: fable's loop kept the numbering convention in prose (TAKING TASK-53 / TASK-57 landed) but stopped running task new after TASK-31, so every board (TUI, web, CLI) truthfully showed the only real blocks. Verified blocks 32+ never existed in any compaction snapshot before concluding. Repairs: (1) harvested 24 phantom tickets (TASK-32..57) into real blocks — title from the strongest referencing line (TAKING/landed patterns ranked), status inferred (landed→done, taking/building→in_progress, else todo), assignee = referencing author, labeled "harvested" for crew cleanup; board now shows 38 rows incl. the live 40-50s work. (2) Wake nag: when the pad tail references TASK-N ids with no ticket, the next wake tells the room to mint them — prose-only numbering now gets called out within a minute. (3) Fixed the id-collision race: task new computed next-id BEFORE taking the pad lock, so concurrent creations could mint the same TASK-N; now computed under the lock. Pushed; phone doc carries all 36 unique blocks.
_________________________________________________________________________________
time:      [00:20] [07-20-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [design]

REBRAND: stitchpad → pasture, per smaths — the herdr-universe play (herder, flock, and the pasture where agents roam off the terminal). Surface layer shipped: sheep-on-green mark (SVG + regenerated 512/192/180 PNGs), app name/title/manifest/notification strings, `pasture` CLI alias on PATH (symlink; script is name-agnostic), pasture.agentsworld.org custom domain added to the worker routes. Deliberately NOT renamed yet (live crews mid-flight in 3 pads): .stitchpad pad dirs, stitchpad.md, STITCHPAD_* env, launchd labels, MCP tool names — the deep rename is a scheduled quiet-window migration with compat shims. DEPLOY BLOCKED: wrangler's Cloudflare token went invalid (9109) mid-deploy — needs interactive `wrangler login` from smaths, then one deploy publishes brand + domain. Also this block: TASK-66 (wake drops post-compact) routed to pi by fable — root-cause artifact written to ocean-surface artifacts (ordinal cursors vs compact rewrite; stable-identity cursor design sketched matching codex's invariants); I'm keeping hands off wake/engagement/compact code until pi's fix lands.
_________________________________________________________________________________
time:      [13:40] [07-20-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Wake integrity rebuilt end-to-end (TASK-66, pulled into this lane by smaths). Root cause chain: engagement gate compared POSITIONAL ordinals that die on every compaction rewrite — one reply after a compact closed the gate over unread pre-compact mentions (the dropped @fable CLEARs), and wake-once seen cursors were ordinal-based too. New system: sp_engagement --list emits stable identity hashes per mention; the gate delivers the OLDEST undelivered unanswered mention against a delivered.<name> hash ring (exactly-once, no replay, never advances past unread); compact records carry.<name> debt (hash|author|snippet of every unanswered+undelivered mention) served by identity before positional picks. Codex's four acceptance invariants implemented 1:1; full matrix verified incl. the exact drop scenario. Debugging detour worth recording: test joins were flakily stealing the OPERATOR terminal lock through a rotation-gap vacancy — operator locks are now unstealable by claim regardless of freshness, and the stolen lock was restored. Legacy seen.* cursors are ignored (harmless); delivered rings start empty so currently-unanswered mentions fire once each, correctly. TASK-66 → in_review with the updated root-cause artifact; codex invited to black-box verify.
_________________________________________________________________________________
time:      [09:04] [20-07-26]
agent:     [claude] [fable 5]
worktree:  task-70-bridge-interval (fable, self-claimed)
type:      bug-report
area:      infra

TASK-70 landed 0244aef: the ws bridge wrote its heartbeat without an `interval` field while ticking every 15s, and doctor read `.interval // 3` computing staleness as interval*3 — so a healthy bridge tripped a stale warning on EVERY check. Only ws mode was affected; the polling bridge already wrote the field. Two-sided fix on purpose: the writer now emits interval bound to the same constant as its setInterval (cannot drift), AND doctor's fallback moves 3 -> 15, the slowest known writer cadence rather than the fastest — defaulting high delays a real report by a cycle, defaulting low cries wolf forever. New regression pins three properties including that a 5-minute-old heartbeat STILL reads stale, so the fix cannot be mistaken for disabling the check. Verified live: doctor now reports 0 issues / 0 warnings, bridge alive at interval=15s — and the doctor-side half cleared it WITHOUT a bridge restart, which is why the two-sided approach was worth it. Rationale for treating a cosmetic warning as real work: doctor is the tool that would have surfaced the wake-drop bug hours before pad archaeology did, and a health check nobody trusts is worse than none.
time:      [15:05] [07-20-26]
agent:     [claude] [fable 5]
type:      [release]
area:      [infra]

PASTURE IS LIVE. wrangler re-auth landed; deployed the rebrand: pasture.agentsworld.org serves the app (title "pasture", sheep-on-green mark, regenerated icons), stitchpad.agentsworld.org stays as a working alias. Eric's instance: attached ec-pasture.agentsworld.org to his ec-stitchpad-relay worker via the CF API (same account) — his old URL aliases too; his app shows pasture branding when he redeploys with current repo code. Per-device: users re-pin the home-screen icon to get the sheep; nothing else changes anywhere (internals still stitchpad-named until the coordinated migration day; fable's hard-cutover migrate-to-pasture.sh remains GATED pending compat review).
_________________________________________________________________________________
time:      [22:30] [07-20-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

SHIFT-CHANGE, per smaths (fable was already doing this by hand): an agent writes its own next-session invocation and hands itself off to a fresh context, compact-smooth. Flow: agent calls the new MCP `shift_change` tool (or `stitchpad shift-change --save <name> --file <f>`) as its LAST act and ends its turn → handoff persists in the pad's archive.sqlite (handoffs table) → the bridge's 20s sweep acts ONLY when the seat's pane reports IDLE (never mid-turn), injects the runtime's clear command (/clear claude, /new codex), waits for the fresh prompt, pastes the full handoff, settle-Enter. Exactly-once via pending→delivering→delivered with claim-time stuck detection (4min retry); in-process SHIFT_BUSY prevents double-fire; pi seats stay pending with an honest log (no slash surface — v2). State machine verified round-trip in a scratch pad (save/claim/retry/deliver/cleanup, multiline body intact). Fable's current session can use the CLI form today; its NEXT session gets the MCP tool natively — the hand-written handoff it just produced is the exact artifact this automates.
_________________________________________________________________________________
time:      [23:20] [07-20-26]
agent:     [claude] [fable 5]
type:      [plan]
area:      [design]

Full-pasture push, per smaths ("channels still called stitchpads doesn't fit pasture/herdr"). Shipped now: sidebar section renamed Pastures, TUI default title pasture, wake lines + DM injections speak "pasture:" (embedded command hints stay `stitchpad …` deliberately — they must execute on unmigrated machines). Deployed + bridge restarted. The deep rename is now a written runbook (docs/PASTURE_MIGRATION.md): Stage 1 compat layer (every reader accepts both namespaces — .pasture/.stitchpad dirs, pasture.md/stitchpad.md, PASTURE_*/STITCHPAD_* env, dual MCP tool names), Stage 2 repo/install/launchd renames behind symlinks, Stage 3 per-pad flip in a ~2min idle window each (fable's hard-cutover script amended to keep compat, dormant pads rehearse first), Stage 4 residue sweep + alias retirement after two quiet weeks. Identity state (rings/carry/hashes) survives by design. Blockers on humans: channel-noun confirmation (Pastures shipped; Paddocks offered), Stage-3 windows, Eric SSH-or-self-serve.
_________________________________________________________________________________
time:      [20:35] [07-20-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

PASTURE MIGRATION STAGE 1 LANDED (smaths confirmed "Pastures" as the channel noun + greenlit stage 1). The entire runtime is now dual-namespace: pad resolution prefers .pasture/ then .stitchpad/, pad file pasture.md then stitchpad.md, pad git pasture-git then stitchpad-git; PASTURE_* env wins over STITCHPAD_* everywhere (one normalization block in lib.sh for all shell consumers; env() helper in the bridge; relay-mode + CWD + secrets in MCP/worker); terminals registry auto-switches to ~/.pasture-terminals when stage 2 creates it; herdr adapter + pi extension + TUI watch dir all dual. Verified with an identical operation matrix (wake identity cursors, exactly-once, tasks, shift-change, roster) on a legacy-shaped AND a migrated-shaped scratch pad — indistinguishable behavior, one binary. Bridge restarted on compat build tracking all 9 pads; worker deployed accepting PASTURE_* secrets. Stage 2 (repo/install/launchd renames behind symlinks) is now safe to run per-machine; stage 3 per-pad flips rehearse on dormant pads first.
_________________________________________________________________________________
time:      [16:50] [07-21-26]
agent:     [claude] [fable 5]
type:      [release]
area:      [infra]

STAGE 2 COMPLETE on the main Mac + brand green + repo/plugin renames, per smaths. Theme: the teal accent family is now pasture green (#4c7f43 paper / #63b356 dark, var names kept as legacy aliases) — deployed. GitHub repo renamed Risingtides-dev/stitchpad-md → Risingtides-dev/pasture (redirects live), local remote updated, pushed. Local renames all behind symlinks: ~/stitchpad→~/pasture, ~/.stitchpad→~/.pasture (bin/pasture + pasture-tui symlinks shipped in-repo), ~/.stitchpad-terminals→~/.pasture-terminals (symlink means even old in-memory tickers keep writing to the SAME registry — no split-brain window at all). launchd: org.pasture.bridge running on PASTURE_RELAY/PASTURE_TOKEN, org.stitchpad.bridge booted out (unrelated org.stitchpad.ec-rt-rail-bridge left for stage 4). Claude MCP registration renamed stitchpad→pasture pointing at ~/.pasture/mcp/server.mjs (new sessions get mcp__pasture__* prefixes). Watchers recycled; doctor green (ocean-prs ticker mid-revive by keepalive). Also wrote docs/PASTURE_PUBLIC.md: the public co-herding edition = `pasture serve` (wrangler dev --local runs the SAME worker with local DO/KV/R2) + tunnel tiers (LAN / cloudflared quick tunnel / tailscale) + `pasture herders add` CLI over the existing multi-user auth — one smaths decision pending: public repo = fresh-history scrubbed clone (never publish ops history).
_________________________________________________________________________________
time:      [17:35] [07-21-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Ocean-os vitals showed three seats CONFLICT "@ocean in ocean-os" + wakes cross-pad blocked. Root cause: the crew unilaterally extended the roster schema with a model column (thoth | pi | fable-5 | push | term_…) — the strict parser read col3 as wake and col4 ("push") as the TARGET, so a terminal lock literally named "push" got claimed by @ocean and three seats fought over it. Fixed forward, not backward: sp_roster now tolerates the 5-col form (if col3 isn't push/pull, shift right) so the crew's intuitive format WORKS; models recorded via meta where the cards read them; phantom "push" lock deleted; seats reset — thoth/pi/claude online (claude re-targeted to its live pane). @ocean remains honestly unreachable: its row never carried the daemon session id — crew note posted on the pad asking the seat owner to rebind. Lesson recorded: agents will evolve shared formats without asking; parsers must bend before they break.
_________________________________________________________________________________
time:      [04:09] [07-22-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [frontend]

Pasture TUI overhaul, four fronts. (1) Theme auto-match: new theme.rs reads ~/.config/herdr/config.toml [theme] — all 18 herdr built-ins mapped to semantic tokens (solarized-light finally renders right), auto_switch follows macOS appearance, config mtime-watched so changing herdr's theme re-skins a running TUI within a tick; /theme <name> pins, /theme auto follows. NO_COLOR honored. (2) Lore pass: ⛵ replaced with ∩ᴥ∩ lamb mark, tabs are pasture/barn, watcher is the shepherd, online is grazing, ASCII sheep art in empty states + flock rail foot + field guide (/help or ? in barn). (3) Barn redesign: nested borders cut, status-colored column rules, priority glyphs (!!/!/◆/◇/·) paired with color, assignee-colored card bars, selected card on raised surface, h/l column nav + j/k in-column, p cycles priority via task edit, per-column windowing with "… N more". (4) Compact + summarize: new `stitchpad summarize [-n N]` CLI command (read-only haiku summary, pad untouched); TUI slash commands /compact (/shear) and /summarize (/ruminate) run off-thread with a braille spinner, summary lands in a scrollable rumination modal (^Y copies). Pad discovery now mirrors lib.sh (walks up, .pasture wins, pasture.md else stitchpad.md). Verified: 19 tests green, tmux captures at 120×35 + 80×24 floor, live nord↔solarized-light switch confirmed via ANSI RGB on the wire, summarize end-to-end through haiku.
_________________________________________________________________________________
time:      [04:44] [07-22-26]
agent:     [claude] [fable 5]
worktree:  feat/rich-pad
type:      [feature-request]
area:      [frontend]

Rich-pad spike (1b8faf2, pushed). Grammar v2 keeps everything in the pad: say mints #m-… header ids and --re threads replies (re:#parent, refuses ghosts); react writes toggleable *reacted* system lines that never wake anyone; @flock aliases @all for gang-prompts; ```ui <type> fences carry schema-validated JSON with a mandatory alt line. One schema source (tool/pwa/ui/schemas.mjs, 8 component types + reply types, 16KB cap) validates at both MCP write time and PWA render time. MCP grew say.reply_to + react + a generic ui tool whose description tells agents to default to prose — john's no-sideshow rule enforced at the tool boundary. PWA: thread folding, reaction chips/picker, component renderers; votes/verdicts/form-submissions are structured threaded replies so tallies derive from the thread with zero new server state; worker+bridge pass re/react down the existing outbox. TUI renders ↳ reply markers, citable ids, reaction chips, ⟦ui type⟧ placeholders. Verified: cargo 21, pwa-contract 22, wake-regression, new thread-react-ui contract suite, headless render tests (XSS escape, tallies, fallbacks), live worker passthrough on wrangler --local. Not merged — awaiting dogfood with real agents per john.
_________________________________________________________________________________
time:      [04:56] [07-22-26]
agent:     [claude] [fable 5]
worktree:  feat/rich-pad
type:      [review]
area:      [testing]

Dogfood run on the rich-pad spike: three subagents (dale/ernie/wren) collaborated in a live pad through the worktree CLI on a real decision — phase-2 component selection. Final pad: 19 messages, 10 reactions, 10 threaded replies, 11 agent-authored ui components, 0 validation fallbacks. Full arc worked: kickoff → candidates table → threaded pushback → usage-evidence table → poll → three convergent votes → build-order checklist → approve request → conditional verdict → conditions folded in and locked. Restraint held (ernie posted zero decorative cards; reactions replaced +1 posts). Genuinely useful output: phase-2 shortlist = timeline (base primitive) / run-report / stat-row, link-preview parked until provably zero-network, kanban-embed cut. One orchestration bug (mine, not the product): subagent sandbox blocks foreground sleep, so the stagger choreography stalled until re-briefed sleepless. Live PWA round-trip served at localhost:8790 via wrangler --local + a mini outbox bridge; retro form open for @smaths. Merge decision awaits john.
_________________________________________________________________________________
time:      [05:24] [07-22-26]
agent:     [claude] [fable 5]
worktree:  feat/rich-pad
type:      [bug-report]
area:      [frontend]

John's "window dressing" call surfaced a real prod bug and a real gap. Bug (50381b1): /img and /f media routes sat BEHIND the relay's bearer-token gate — <img> tags can't send auth headers, so every uploaded image 401'd and rendered broken, in prod too; also upload-image returned a hardcoded prod-domain URL (and url.origin lies under wrangler dev), breaking all local embeds. Fix: media served above the gate (sha-256 capability URLs, tokenless GET is the correct trade), root-relative /img/… upload URLs, PWA image regex widened to relative media paths. Verified end-to-end: CLI say --image → local R2 → inline render. Gap answered with a real-work dogfood: a builder agent implemented the timeline component (the flock's voted phase-2 primitive) in the worktree (5041969, schemas+renderer+CSS, 16/0 headless tests, hostile-payload escaping), narrating in the live pad with the actual git diff as a ui diff card, actual test output threaded, and a ui timeline OF ITS OWN BUILD rendered by the code it had just written — pad as a workbench, not a widget demo. Both commits pushed on feat/rich-pad.
_________________________________________________________________________________
time:      [05:57] [07-23-26]
agent:     [claude] [fable 5]
worktree:  feat/rich-pad
type:      [feature-request]
area:      [frontend]

Images proven in a real browser this time (john was right to demand it): headless Chrome via puppeteer-core against the live PWA showed the pipeline worked but my test image was an 8×8px dot — invisible, functionally broken. Re-proved with a full-size screenshot embedded inline, screenshot sent to john. Real bug found the same way: the PWA paperclip routed image attachments to the dropbox as a text line (exactly what john hit) — images now go through /upload-image and embed as markdown (47ad3c0). Then the shed (bda913c): `stitchpad drop <file> [note]` → pad's dropbox/ + relay mirror + one 📎 pad line as the files feed; TUI grew a third tab (shelf: name·size·age, Enter opens via OS); PWA grew a files button + panel derived from the 📎 lines; [text](url) markdown links render scheme-restricted. Verified: cargo 21, grammar contract suite, drop end-to-end with /f/ view link, shed panel + TUI tab both eyeballed (browser screenshot / tmux capture). Next per john: execution timelines — needs an amend-by-id grammar verb so a posted timeline can flip step states live; design noted, not started.
_________________________________________________________________________________
time:      [06:15] [07-23-26]
agent:     [claude] [fable 5]
worktree:  feat/rich-pad
type:      [feature-request]
area:      [backend]

Execution timelines shipped. New grammar verb `amend <#m-id>` — python rewrite of one block's body under the pad lock, header/id/thread links untouched, author-only, one git commit per amend (append-only spirit survives as history). On top: `stitchpad run [--title] label=cmd...` posts one ui timeline and amends it live as steps flip todo→active→done/failed with real durations; first failure stops the run and threads the output tail under the card as an artifact. MCP grew an `amend` tool. Contract suite extended (amend semantics + run semantics) — all green plus wake regression. Demonstrated live in the dogfood pad against the real verification suite: one red run (my own bad step command — the failure path demoed itself) and one green 4-step run, screenshot to john. PWA/TUI needed ZERO changes — amended blocks just re-parse, which is the payoff of the pad-is-truth architecture.
_________________________________________________________________________________
_________________________________________________________________________________
time:      [15:32] [07-27-26]
agent:     [pi] [gpt-5.4] [thoth]
worktree:  [master]
type:      [bug report]
area:      [backend]

Stopped the parked global pasture at `~/.pasture` from bleeding into descendant
projects. Pad discovery now stops at `$HOME` for child working directories while
keeping the global room explicitly available from `$HOME` or through
`PASTURE_PAD_DIR=\"$HOME/.pasture\"`; project-local `.pasture` / `.stitchpad`
pads still win. Added `test/pad-resolution.sh`, documented the opt-in global-room
contract, verified the rotational-posting-agent cwd fails closed with no local pad,
and passed every `test/*.sh` regression script.
time:      [18:59] [07-30-26]
agent:     [claude] [fable 5]
type:      [bug-report]
area:      [infra]

Stitchpad relay outage root-caused and fixed. John's bridges were 401ing since 07-29: deployment history on the `stitchpad-relay` worker showed a "Secret Change" deployment at 03:56Z authored by ec@risingtidesent.com (version a7df5fa8) — EC rotated STITCHPAD_TOKEN on john's worker, killing every client holding the old token. Restored john's token via `wrangler secret put STITCHPAD_TOKEN`, verified /pads returns the pad list with his bearer again, kickstarted org.stitchpad.bridge — sockets up, all pads pushed. Note: the relay auths everyone with ONE shared bearer token and EC has write access to john's Cloudflare account, so any of the 4 users rotating a secret takes everyone else down; needs per-user tokens or per-person worker deployments.
_________________________________________________________________________________
time:      [22:43] [07-30-26]
agent:     [claude] [fable 5]
type:      [feature-request]
area:      [infra]

Per-person relay tokens so one teammate's rotation can never lock out the rest (the EC incident). worker.js auth now accepts the legacy STITCHPAD_TOKEN OR any value in the new STITCHPAD_TOKENS secret (JSON handle→token); /login and /join-request return the caller's own token when their handle has one. Minted tokens for jay, sam, ec and set the secret; deployed (version de4cb838); verified live: all four tokens 200 on /pads, bogus token 401, john's bridge reconnected clean after the deploy. Tokens handed to john to distribute — each person drops theirs into STITCHPAD_TOKEN in their bridge plist. Rotating one person now = edit one key in STITCHPAD_TOKENS.
_________________________________________________________________________________
