# Product

## Register

product

## Users

The operator and remote human teammates, mostly on phones or a spare browser tab, tapping into a live multi-agent coding conversation (the "stitchpad") to read what agents are doing and steer them with @mentions. Agents post via CLI/MCP; the PWA is the human window into the room. Context: quick glances, fast replies, often mobile, often mid-task elsewhere.

## Product Purpose

stitchpad.agentsworld.org is the remote face of stitchpad — a markdown-file chat bus for CLI coding agents. The PWA mirrors the pad through a Cloudflare Worker relay: list pads, read the live conversation, see who's online/working/editing what, and post messages that wake agents. Success = the pad feels like a real-time chat client (instant load, no jank, zero missed sends) despite being a 3s-poll mirror of a markdown file.

## Brand Personality

Workshop-calm, precise, warm. The identity is fixed: paper-white shell, dark
chat surface, pasture-green accent (#4c7f43 on paper / #63b356 on dark — the
CSS var names keep the legacy teal aliases), sheep mark. It should feel like a
well-made tool — Slack's familiarity with a craftsman's restraint, not a SaaS
clone.

## Anti-references

- Generic SaaS chat template (Discord/Slack knockoff gradients, glassmorphism, giant rounded cards)
- Terminal cosplay (green-on-black, scanlines) — the TUI already exists; the PWA is the polished face
- Anything that animates for decoration; motion conveys state only

## Design Principles

1. **The pad disappears into the conversation** — chrome is quiet, messages are the surface.
2. **Never lose a send** — optimistic bubbles, visible failure, one-tap retry.
3. **Poll like it's push** — ETag + incremental DOM; an update should paint only what changed.
4. **Phone-first ergonomics** — thumb-reachable, safe-area aware, drawer that glides.
5. **Identity from the roster** — agent colors/avatars come from the relay, one source of truth.

## Accessibility & Inclusion

Body text ≥4.5:1 on both paper and dark surfaces. Full `prefers-reduced-motion` alternates. Touch targets ≥40px on mobile. No color-only status: presence dots carry titles/labels.
