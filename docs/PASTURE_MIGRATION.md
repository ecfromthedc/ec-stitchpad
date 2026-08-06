# Pasture migration — the full rename, staged so nothing breaks mid-shift

> **Current stage (2026-08-06): Stage 1 landed; Stage 2 complete on the main
> Mac.** The compat layer is live (`sp_find_pad` resolves `.pasture/` first,
> then `.stitchpad/`; `PASTURE_*` env wins with `STITCHPAD_*` fallback), the
> launchd bridge runs as `org.pasture.bridge`, and `~/.stitchpad` and
> `~/.pasture` resolve to the same place. Stages 3–4 (per-pad flip, residue
> sweep) are NOT started — which is why `stitchpad` is still the name you see
> in most paths, the CLI, and the env. Both names work everywhere. Note: the
> in-repo `stitchpad bridge install` still writes the legacy
> `org.stitchpad.bridge` label — a fresh machine gets that label until its own
> Stage 2; the main Mac's pasture-labeled plists were the Stage-2 migration.

Goal: zero "stitchpad" anywhere — repo, code, dirs, env, plugins, launchd, app — without
dropping a single wake, DM, or task while three live crews keep working.

## Already done (visible layer — shipped)
- App: name, title, manifest, icons, sheep mark, sidebar "Pastures", notification prose
- Domains: pasture.agentsworld.org + ec-pasture.agentsworld.org (old URLs alias forever)
- CLI: `pasture` + `pasture-tui` on PATH (same binaries)
- Agent-facing prose: wake lines and DM injections say "pasture:" (embedded COMMANDS still
  say `stitchpad …` on purpose — they must run on unmigrated machines)

## Stage 1 — compat layer (safe to land anytime; no behavior change for old names)
Make every reader accept BOTH namespaces so migrated and unmigrated coexist:
- lib.sh `sp_find_pad`/`sp_init_paths`: resolve `.pasture/` first, else `.stitchpad/`;
  `pasture.md` first, else `stitchpad.md`; terminals registry: read both
  `~/.pasture-terminals` and `~/.stitchpad-terminals`, write to whichever exists for a seat
- Every env var: `PASTURE_*` wins, `STITCHPAD_*` fallback (lib.sh, bridge, MCP, adapters,
  pi extension, worker login vars)
- bridge findPads: `-name .pasture -o -name .stitchpad`; push-once, doctor, keepalive,
  retarget, shift-change: path joins go through one helper
- MCP + pi extension: register `pasture_*` tool names ALONGSIDE `stitchpad_*` (same handlers)
- TUI: reads whichever pad file exists
Gate: full wake/DM/task/compact/shift-change matrix green on a `.pasture`-named scratch pad
AND on a legacy-named one, same binary.

## Stage 2 — repo + install rename (one machine at a time, any time after Stage 1)
- `~/stitchpad` → `~/pasture` with symlink `~/stitchpad → ~/pasture` (hooks in
  ~/.claude/settings.json and ~/stitchpad-md checkouts keep working via symlink)
- `tool/bin/pasture` + `tool/bin/pasture-tui` exist as symlinks to the
  `stitchpad` binaries (the tree kept `stitchpad` as the real file and made
  `pasture` the alias — the reverse of the original plan, same effect)
- `~/.stitchpad` install → `~/.pasture` + symlink
- launchd: install org.pasture.bridge plist, bootout org.stitchpad.bridge (same binary path
  via new names)
- Worker env: add PASTURE_USER/PASS/TOKEN/USERS as duplicates; code reads both (Stage 1)

## Stage 3 — per-pad flip (the ONLY step that needs a quiet window per pad)
Use the reviewed flip script (fable's migrate-to-pasture.sh, amended: keep Stage-1 compat
runtime, don't strip aliases): per pad, agents idle →
`.stitchpad/ → .pasture/`, `stitchpad.md → pasture.md`, `stitchpad-git → pasture-git`,
state untouched (hashes/rings/carry survive by design), watcher restart, roster verify,
one test wake per seat. ~2 minutes per pad. Order: dormant pads first (free rehearsal),
then gutenburg (Eric coordinated), then ocean-os, then ocean-surface.

## Stage 4 — sweep the residue (after all pads flipped, all machines Stage-2)
- Rename internal identifiers at leisure (sp_ prefix stays — it's "shared pasture" now)
- Remove `stitchpad_*` tool aliases + `STITCHPAD_*` env fallbacks after 2 quiet weeks
- Update AGENTS/handoff docs, personas, memory notes; retire the old repo name on GitHub

## Machines checklist
- [x] main Mac (Stage 1+2 complete — see the stage marker at the top)
- [ ] each remaining machine runs Stage 2 when its operator has a window
      (per-operator details live in evidence/, not here)

## Human calls needed
1. Channel noun confirmed: "Pastures" (alternative if preferred: "Paddocks" — herding-true
   for per-project rooms; one-line change)
2. The Stage-3 window per active pad (agents idle ~2 min each)
