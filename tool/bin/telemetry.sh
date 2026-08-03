#!/usr/bin/env bash
# telemetry.sh — per-model reliability + cost-value telemetry (TASK-7).
#
# Append-only JSONL under $PAD_STATE/telemetry/<model>/<date>.jsonl.
# The root may be redirected per caller with STITCHPAD_TELEMETRY_ROOT (relay
# mode keys it per pad — multi-pad F4 — so one machine's relay state never
# merges several pads' events into an undiscriminated bucket).
# BEST-EFFORT BY DESIGN: sp_telemetry_record can never fail a primary
# operation. Every failure path is silent; a drop counter in
# $PAD_STATE/telemetry/.drops records skipped writes when possible.
# The pad mutation lock is NEVER taken here — call sites invoke after
# their critical section (or from lock-free readers like wake).
#
# Events (e=):
#   wake            outcome=delivered|deferred|zero_run|noop|peek|failed dur_ms exit
#   say             outcome=posted|failed dur_ms
#   delivery        outcome=delivered|failed|cancelled|errored dur_ms
#   verdict         verdict=confirmed|rejected|held candidate detail
#   seal            artifact sha detail
#   false_terminal  count detail
#   turn            kind dur_ms outcome   (generic duration record)
#   outage|retry    detail count
#
# Any event may carry cost-value fields: tokens_in tokens_out cost_usd.
# Unknown/absent values are preserved and exposed as n/a by the summary
# reader — never silently zeroed.

_sp_tel_sanitize() {  # $1 = value → [A-Za-z0-9._-]{1,64} else "unknown"
  local v="${1:-}"
  v="$(printf '%s' "$v" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  [ -n "$v" ] || v="unknown"
  printf '%s' "$v"
}

# Resolve the model label for a seat: explicit env wins, then the
# per-seat meta record (.state/model.<seat>), else "unknown".
sp_telemetry_model() {  # $1 = seat
  local seat="${1:-}"
  if [ -n "${STITCHPAD_MODEL:-}" ]; then
    printf '%s' "$(_sp_tel_sanitize "$STITCHPAD_MODEL")"
    return
  fi
  if [ -n "$seat" ] && [ -n "${PAD_STATE:-}" ] && [ -f "$PAD_STATE/model.$seat" ] \
     && [ ! -L "$PAD_STATE/model.$seat" ]; then
    local m
    m="$(head -c 128 "$PAD_STATE/model.$seat" 2>/dev/null | tr -d '\r\n')"
    printf '%s' "$(_sp_tel_sanitize "$m")"
    return
  fi
  printf 'unknown'
}

# Provider mapping mirrors session-registry's; duplicated here so
# telemetry.sh has no ordering dependency on that library.
sp_telemetry_provider() {  # $1 = model
  local m
  m="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    gpt-*|o1-*|o3-*|o4-*) printf 'openai' ;;
    claude-*) printf 'anthropic' ;;
    deepseek*) printf 'deepseek' ;;
    kimi*) printf 'kimi' ;;
    gemini*) printf 'google' ;;
    *) printf 'unknown' ;;
  esac
}

# Millisecond clock. Python3 is the codebase's hard dependency (date-divider
# requires it); fall back to seconds*1000 so telemetry can never block on a
# missing interpreter.
sp_telemetry_now_ms() {
  local ms
  ms="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null)" || ms=""
  if [ -n "$ms" ] && printf '%s' "$ms" | grep -qx '[0-9][0-9]*'; then
    printf '%s' "$ms"
  else
    printf '%s000' "$(date +%s)"
  fi
}

_sp_tel_utc_date() {
  date -u +%F 2>/dev/null || printf 'unknown'
}

# Telemetry root: per-pad by default ($PAD_STATE/telemetry); relay mode and
# other multi-pad callers redirect with STITCHPAD_TELEMETRY_ROOT. Sanitized:
# only an absolute path is honored; anything else falls back to per-pad.
_sp_tel_root() {
  local root="${STITCHPAD_TELEMETRY_ROOT:-}"
  case "$root" in
    /*) printf '%s' "$root"; return 0 ;;
  esac
  printf '%s' "$PAD_STATE/telemetry"
}

# Best-effort drop counter. If even this fails, silence is the contract.
_sp_tel_bump_drop() {
  [ -n "${PAD_STATE:-}" ] && [ -d "$PAD_STATE" ] && [ ! -L "$PAD_STATE" ] || return 0
  local root
  root="$(_sp_tel_root)"
  mkdir -p "$root" 2>/dev/null || return 0
  [ ! -L "$root" ] || return 0
  printf '1\n' >> "$root/.drops" 2>/dev/null || true
}

# sp_telemetry_record <event> [k=v ...]  — never fails, never prints,
# never takes a lock, never exits nonzero. Recognized keys:
#   seat model provider outcome verdict dur_ms count candidate artifact sha
#   detail ts tokens_in tokens_out cost_usd
# Any other [a-z_][a-z0-9_]* key is preserved verbatim in the record.
sp_telemetry_record() {
  local ev="${1:-}"; shift || true
  [ -n "$ev" ] || return 0
  case "$ev" in
    wake|say|delivery|verdict|seal|false_terminal|turn|outage|retry) ;;
    *) return 0 ;;
  esac
  [ -n "${PAD_STATE:-}" ] && [ -d "$PAD_STATE" ] && [ ! -L "$PAD_STATE" ] || return 0
  local tel_root
  tel_root="$(_sp_tel_root)"
  if [ ! -d "$tel_root" ]; then
    mkdir -p "$tel_root" 2>/dev/null || { _sp_tel_bump_drop; return 0; }
  fi
  [ ! -L "$tel_root" ] || { _sp_tel_bump_drop; return 0; }

  # Parse k=v pairs
  local seat="" model="" provider="" outcome="" verdict="" dur_ms="" count="" \
        cand="" art="" sha="" det="" ts="" tin="" tout="" cost=""
  local -a extra=()
  local kv k v
  for kv in "$@"; do
    case "$kv" in
      seat=*)       seat="${kv#seat=}" ;;
      model=*)      model="${kv#model=}" ;;
      provider=*)   provider="${kv#provider=}" ;;
      outcome=*)    outcome="${kv#outcome=}" ;;
      verdict=*)    verdict="${kv#verdict=}" ;;
      dur_ms=*)     dur_ms="${kv#dur_ms=}" ;;
      count=*)      count="${kv#count=}" ;;
      candidate=*)  cand="${kv#candidate=}" ;;
      artifact=*)   art="${kv#artifact=}" ;;
      sha=*)        sha="${kv#sha=}" ;;
      detail=*)     det="${kv#detail=}" ;;
      ts=*)         ts="${kv#ts=}" ;;
      tokens_in=*)  tin="${kv#tokens_in=}" ;;
      tokens_out=*) tout="${kv#tokens_out=}" ;;
      cost_usd=*)   cost="${kv#cost_usd=}" ;;
      *)
        k="${kv%%=*}"; v="${kv#*=}"
        if printf '%s' "$k" | grep -qx '[a-z_][a-z0-9_]*'; then
          extra+=("$k" "$v")
        fi
        ;;
    esac
  done

  # Resolve identity
  [ -n "$model" ] || model="$(sp_telemetry_model "$seat")"
  model="$(_sp_tel_sanitize "$model")"
  seat="$(_sp_tel_sanitize "$seat")"
  [ -n "$provider" ] || provider="$(sp_telemetry_provider "$model")"
  provider="$(_sp_tel_sanitize "$provider")"

  # Build the JSON line via python3 — every value passed as argv, never
  # interpolated into code; unknown keys are preserved. macOS ships bash 3.2,
  # where expanding an EMPTY array under `set -u` raises "unbound variable"
  # and would silently drop the record — guard the expansion explicitly.
  local line _tel_had_u=""
  case "$-" in *u*) _tel_had_u=1 ;; esac
  [ -z "$_tel_had_u" ] || set +u
  line="$(python3 -c '
import json, sys, datetime
names = ["event","seat","model","provider","outcome","verdict","dur_ms",
         "count","candidate","artifact","sha","detail","ts",
         "tokens_in","tokens_out","cost_usd"]
args = sys.argv[1:]
fields = {}
i = 0
for n in names:
    v = args[i] if i < len(args) else ""
    i += 1
    if v == "":
        continue
    if n == "event":
        fields["e"] = v
    elif n in ("dur_ms", "count"):
        if v.isdigit():
            fields[n] = int(v)
    elif n == "ts":
        pass  # handled below
    else:
        fields[n] = v
ts = args[names.index("ts")] if names.index("ts") < len(args) else ""
try:
    if ts and ts.isdigit():
        t = int(ts)
        if t > 1_000_000_000_000:
            t = t // 1000
        fields["t"] = datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        fields["t"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
except Exception:
    fields["t"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
# remaining argv = extra k=v pairs
while i + 1 < len(args):
    fields[args[i]] = args[i+1]
    i += 2
print(json.dumps(fields, separators=(",", ":")))
' "$ev" "$seat" "$model" "$provider" "$outcome" "$verdict" "$dur_ms" \
    "$count" "$cand" "$art" "$sha" "$det" "$ts" "$tin" "$tout" "$cost" \
    "${extra[@]}" 2>/dev/null)" || line=""
  [ -z "$_tel_had_u" ] || set -u

  if [ -z "$line" ]; then
    _sp_tel_bump_drop
    return 0
  fi

  local sub="$(_sp_tel_root)/$model" day
  mkdir -p "$sub" 2>/dev/null || { _sp_tel_bump_drop; return 0; }
  [ ! -L "$sub" ] || { _sp_tel_bump_drop; return 0; }
  day="$(_sp_tel_utc_date)"
  if printf '%s\n' "$line" >> "$sub/$day.jsonl" 2>/dev/null; then
    return 0
  fi
  _sp_tel_bump_drop
  return 0
}

# ── Bounded reader ──────────────────────────────────────────────────
# sp_telemetry_summary [--json] [--model M] [--days N] [--limit N]
# Renders per-model reliability + cost-value rows. The read is bounded:
# only files with mtime within the last N days are scanned, and at most
# LIMIT lines total. Unknown values render as n/a, never 0.
sp_telemetry_summary() {
  local json=0 model_filter="" days=14 limit=100000
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --model) model_filter="${2:-}"; shift 2 ;;
      --days) days="${2:-14}"; shift 2 ;;
      --limit) limit="${2:-100000}"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$days" in *[!0-9]*) days=14 ;; esac
  case "$limit" in *[!0-9]*) limit=100000 ;; esac

  local root="$(_sp_tel_root)"
  if [ ! -d "$root" ] || [ -L "$root" ]; then
    if [ "$json" -eq 1 ]; then printf '{"models":[],"scanned":0,"drops":0}\n'; else echo "no telemetry yet (nothing recorded)"; fi
    return 0
  fi

  local drops=0
  if [ -f "$root/.drops" ] && [ ! -L "$root/.drops" ]; then
    drops="$(wc -l < "$root/.drops" 2>/dev/null | tr -d ' ' || echo 0)"
  fi

  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - days * 86400 ))

  root="$root" cutoff="$cutoff" limit="$limit" mf="$model_filter" json="$json" \
    drops="$drops" days="$days" python3 -c '
import json, os, sys, glob, datetime

root = os.environ["root"]; cutoff = int(os.environ["cutoff"])
limit = int(os.environ["limit"]); mf = os.environ.get("mf", "")
json_out = os.environ.get("json", "0") == "1"
drops = int(os.environ.get("drops", "0"))
days = int(os.environ.get("days", "14"))

files = sorted(glob.glob(os.path.join(root, "*", "*.jsonl")))
rows = {}
scanned = 0
for fp in files:
    try:
        if os.path.getmtime(fp) < cutoff:
            continue
    except OSError:
        continue
    with open(fp, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if scanned >= limit:
                break
            scanned += 1
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if not isinstance(ev, dict):
                continue
            model = str(ev.get("model") or "unknown")
            if mf and model != mf:
                continue
            r = rows.setdefault(model, {
                "seats": set(), "wake": 0, "delivered": 0, "deferred": 0,
                "zero": 0, "noop": 0, "peek": 0, "wfail": 0,
                "say_ok": 0, "say_fail": 0, "deliv_ok": 0, "deliv_fail": 0,
                "seals": 0, "conf": 0, "rej": 0, "held": 0, "ft": 0,
                "durs": [], "tok_in": 0, "tok_out": 0, "cost": 0.0,
                "has_cost": False, "has_tok": False, "events": {}})
            seat = str(ev.get("seat") or "?")
            if seat != "?" and seat != "unknown":
                r["seats"].add(seat)
            e = ev.get("e")
            r["events"][e] = r["events"].get(e, 0) + 1
            for tk in ("tokens_in", "tokens_out"):
                v = ev.get(tk)
                if v is not None:
                    try:
                        r["tok_in" if tk == "tokens_in" else "tok_out"] += int(v)
                        r["has_tok"] = True
                    except Exception:
                        pass
            c = ev.get("cost_usd")
            if c is not None:
                try:
                    r["cost"] += float(c)
                    r["has_cost"] = True
                except Exception:
                    pass
            dm = ev.get("dur_ms")
            if isinstance(dm, int):
                r["durs"].append(dm)
            if e == "wake":
                r["wake"] += 1
                oc = ev.get("outcome", "")
                if oc == "delivered": r["delivered"] += 1
                elif oc == "deferred": r["deferred"] += 1
                elif oc == "zero_run": r["zero"] += 1
                elif oc == "peek": r["peek"] += 1
                elif oc == "failed": r["wfail"] += 1
                else: r["noop"] += 1
            elif e == "say":
                if ev.get("outcome") == "failed": r["say_fail"] += 1
                else: r["say_ok"] += 1
            elif e == "delivery":
                oc = ev.get("outcome", "")
                if oc == "delivered": r["deliv_ok"] += 1
                else: r["deliv_fail"] += 1
            elif e == "seal":
                r["seals"] += 1
            elif e == "verdict":
                vd = ev.get("verdict", "")
                if vd == "confirmed": r["conf"] += 1
                elif vd == "rejected": r["rej"] += 1
                elif vd == "held": r["held"] += 1
            elif e == "false_terminal":
                try: r["ft"] += int(ev.get("count") or 1)
                except Exception: r["ft"] += 1
    if scanned >= limit:
        break

def fmt_num(v):
    return "n/a" if v is None else str(v)

def avg(durs):
    if not durs:
        return None
    return int(sum(durs) / len(durs))

if json_out:
    out = {"scanned": scanned, "drops": drops, "days": days, "models": []}
    for model in sorted(rows, key=lambda m: -rows[m]["wake"]):
        r = rows[model]
        out["models"].append({
            "model": model,
            "seats": sorted(r["seats"]),
            "wake_runs": r["wake"],
            "wake_outcomes": {"delivered": r["delivered"], "deferred": r["deferred"],
                              "zero_run": r["zero"], "noop": r["noop"], "peek": r["peek"],
                              "failed": r["wfail"]},
            "say": {"posted": r["say_ok"], "failed": r["say_fail"]},
            "delivery": {"delivered": r["deliv_ok"], "failed": r["deliv_fail"]},
            "seals": r["seals"],
            "verdicts": {"confirmed": r["conf"], "rejected": r["rej"], "held": r["held"]},
            "false_terminals": r["ft"],
            "avg_turn_ms": avg(r["durs"]),
            "tokens_in": r["tok_in"] if r["has_tok"] else None,
            "tokens_out": r["tok_out"] if r["has_tok"] else None,
            "cost_usd": round(r["cost"], 4) if r["has_cost"] else None,
            "events": r["events"],
        })
    print(json.dumps(out, separators=(",", ":")))
    sys.exit(0)

print("per-model reliability + cost-value telemetry (last %d days, %d rows scanned, %d drops)" % (days, scanned, drops))
print("%-22s %-24s %5s %4s %4s %4s %4s %4s %5s %6s %6s %5s %9s %4s %8s %8s %10s" % (
    "MODEL", "SEATS", "WK", "DEL", "DEF", "ZRO", "NOOP", "FAIL", "REL%",
    "AVGms", "SAY", "SEAL", "V(c/r/h)", "FT", "TOKIN", "TOKOUT", "COST$"))
print("-" * 130)
if not rows:
    print("(no telemetry events matched)")
for model in sorted(rows, key=lambda m: -rows[m]["wake"]):
    r = rows[model]
    attempts = r["delivered"] + r["wfail"]
    rel = ("%.0f" % (100.0 * r["delivered"] / attempts)) if attempts else "n/a"
    av = avg(r["durs"])
    avs = "n/a" if av is None else str(av)
    tki = str(r["tok_in"]) if r["has_tok"] else "n/a"
    tko = str(r["tok_out"]) if r["has_tok"] else "n/a"
    cs = "%.4f" % r["cost"] if r["has_cost"] else "n/a"
    seats = ",".join(sorted(r["seats"])) if r["seats"] else "?"
    verdict_col = "%d/%d/%d" % (r["conf"], r["rej"], r["held"])
    print("%-22s %-24s %5d %4d %4d %4d %4d %4d %5s %6s %6s %5d %9s %4d %8s %8s %10s" % (
        model[:22], seats[:24], r["wake"], r["delivered"], r["deferred"], r["zero"],
        r["noop"], r["wfail"], rel, avs, "%d/%d" % (r["say_ok"], r["say_fail"]),
        r["seals"], verdict_col, r["ft"], tki, tko, cs))
' || true
  return 0
}
