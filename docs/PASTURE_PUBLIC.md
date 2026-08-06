# Pasture — public edition blueprint (co-herding for everyone)

> **STATUS: blueprint, NOT BUILT.** Nothing in this file exists as a command
> yet — there is no `pasture serve` and no `pasture herders`; trying them on
> day one will get you "unknown command". The "Order of work" at the bottom is
> the build list. What DOES exist today: the Cloudflare worker + PWA
> (`tool/relay/`, `tool/pwa/`), the bridge (`stitchpad bridge install`), and
> the multi-herder auth layer the blueprint builds on.

The pitch: your agents graze in one shared field, you herd them from your phone.
No Cloudflare account required to start — localhost + a tunnel.

## Architecture (same code, zero forks)
- `pasture serve` — runs the EXISTING worker.js locally via `wrangler dev --local`
  (miniflare: local Durable Objects, KV, R2 on disk). Serves the PWA + API on
  http://localhost:8787. No cloud, no account.
- The bridge points at it: PASTURE_RELAY=http://localhost:8787 (compat layer
  already reads PASTURE_*). Everything else — pads, wakes, DMs, board, doctor,
  shift-change — is unchanged.

## Reaching it from a phone (guidance tiers, `pasture serve --tunnel …`)
1. **LAN**: open http://<your-mac>.local:8787 — zero setup, home wifi only
2. **Cloudflare quick tunnel**: `cloudflared tunnel --url http://localhost:8787`
   → free public trycloudflare.com URL, no account
3. **Tailscale**: `tailscale serve 8787` (tailnet) or `funnel` (public) —
   the private-by-default option
4. Graduation path: real CF worker + custom domain (what we run) — docs walk it

## Co-herding (multi-herder, one field)
- ALREADY SUPPORTED by the auth layer: PASTURE_USERS is a {user: {pass, handle}}
  map; each herder logs in with their own handle; presence, DMs, tasks, and the
  board are handle-based. What's missing is ONLY ergonomics:
  - `pasture herders add <handle>` → generates a passphrase, writes .dev.vars
    (local) or `wrangler secret put` (cloud), prints an invite blurb
  - `pasture herders ls / rm`
- Remote AGENT seats (an agent on a co-herder's machine) already work via
  invite tokens (/invite → /join-request) — document as "guest flock".

## Repo strategy (decision needed: smaths)
- Private ops repo: github.com/Risingtides-dev/pasture (renamed today; contains
  our evidence/events.md history + crew personas)
- Public repo: FRESH-HISTORY clone (single initial commit — our history has
  operational detail; never publish it). Scrub: evidence/events.md, personas/ (ship
  neutral samples), any tokens/hosts, .claude wiring. Name: `pasture`
  (public) vs keeping ops private under `pasture-ops` — smaths picks.

## Order of work
1. `pasture serve` command (wrangler dev wrapper + .dev.vars bootstrap + first-run
   user creation) — the whole local loop
2. `pasture herders` CLI
3. Tunnel flags + docs with screenshots
4. Public repo scrub + README with the sheep
5. install.sh one-liner: `curl -fsSL …/install | bash`
