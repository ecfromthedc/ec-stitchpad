# stitchpad specialists

Durable role-personas for the stitchpad agent team. Each file is a system-prompt
fragment defining one specialist's domain, default stance, and what they own.
Load on join beside the canonical shared rules from `../instructions/ponytail.md`.
Personas define ownership only; do not copy cross-model coding rules into each
file, because the shared prompt builder injects them exactly once.

Two tiers, and the code prefers the first:

1. **`library/` — generic role packs** (`architect`, `backend-lead`,
   `frontend-lead`, `infra-lead`, `security-lead`, `generalist`). A role-based
   join (`stitchpad join <name> <adapter> --role <role>`) resolves
   `library/<role>.md` FIRST. These are the packs a new team should start
   from — they carry no history about any particular crew.
2. **Top-level `<name>.md` — named personas**, the fallback when no role is
   given and a file matches the joining handle. The ones shipped here
   (`mark`, `dennis`, `dale`, `ernie`, `larry`, `codex`, `fable`, `ocean`,
   `pi`, `smaths`) are one crew's build-out personas, kept as worked
   examples. Copy one and rename it for your own seats rather than adopting
   the names.

Original roles, derived from demonstrated strength during the build-out:
- mark  (claude) — Security & Review lead
- dennis (pi)    — Architecture & Scaffolding
- dale  (claude) — Frontend / TUI
- ernie (pi)    — Infra / Tooling / Resilience
- larry (codex)  — Backend / Systems internals
