#!/usr/bin/env python3
"""Read-only Stitchpad/Pasture health snapshot.

Only local files and process metadata are read by default. ``--deep`` adds a
bounded loopback GET for Ocean seats. Runtime state is never repaired here:
malformed or stale files are reported as evidence, not rewritten.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import http.client
import itertools
import json
import os
import re
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


MAX_STATE_BYTES = 1_048_576
MAX_COUNTER = 2_147_483_647
MAX_PID = 2_147_483_647
MAX_EPOCH_SECONDS = 4_102_444_800  # 2100-01-01; rejects absurd false-green clocks.
DEEP_DEADLINE_SECONDS = 1.0
DELIVERY_KEYS = {
    "state", "generation", "ordinal", "message_id", "task_id", "accepted_at",
    "started_at", "completed_at", "error_at", "error_code", "turn_id", "turn_status",
}
DELIVERY_STATES = {
    "accepted", "started", "busy", "error", "in_flight", "cancel_pending",
    "deferred_dnd", "acceptance_unknown", "completed", "tombstoned",
    "errored", "cancelled",
}
DELIVERY_ATTENTION_STATES = {"cancel_pending", "deferred_dnd"}
DELIVERY_ERROR_STATES = {"error", "errored", "cancelled", "acceptance_unknown"}
DELIVERY_TIMESTAMP_KEYS = {"accepted_at", "started_at", "completed_at", "error_at"}
KEEPER_STATES = {"accepted", "in_flight", "completed", "acceptance_unknown"}

# ── Provider availability ─────────────────────────────────────────────
# Non-mutating probes against the Ocean daemon's turn-free surfaces. The
# daemon's /health is always hardcoded ok:true, so it can never be the sole
# routing decision.  We probe /v1/models (model catalog with per-model
# readiness) and /ready (provider credential + failover state) — both are
# GET-only and never post turns. Timestamps gate staleness; a stale ready:true
# or ready:false must age out instead of silently controlling routing.
PROVIDER_PROBE_DEADLINE_SECONDS = 1.5
PROVIDER_STALENESS_SECONDS = 90  # age out a probe older than this
PROVIDER_STATES = (
    "configured",           # ocean-adapter seat with a non-empty target
    "catalog_ready",        # /v1/models returned ok with model entries
    "probe_successful",     # at least one probe returned valid JSON in time
    "rate_limited",         # 429 or x-ratelimit-* evidence from any probe
    "actively_responding",  # all probes pass within deadline, no rate-limiting
)
# Endpoints that are safe non-mutating probes (GET only, no side effects).
PROVIDER_PROBE_PATHS = ("/v1/models", "/ready")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep a loopback diagnostic from following redirects off machine."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str,
                         headers: Any, newurl: str) -> None:
        return None


def reject_json_constant(value: str) -> None:
    raise ValueError(f"non_finite_number:{value}")


def bounded_scalar(value: Any, limit: int = 512) -> str | int | float | bool | None:
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value if len(value) <= limit else None
    if isinstance(value, int):
        return value if abs(value) <= 9_007_199_254_740_991 else None
    if isinstance(value, float):
        return value if value == value and value not in {float("inf"), float("-inf")} else None
    return None


def unavailable_scalar(reason: str) -> dict[str, Any]:
    return {"present": None, "value": None, "parse": f"unavailable:{reason}"}


def unavailable_heartbeat(reason: str) -> dict[str, Any]:
    return {
        "present": None, "parse_error": f"unavailable:{reason}", "age_seconds": None,
        "fresh": None, "pid": None, "pid_parse": f"unavailable:{reason}",
        "pid_alive": None, "parent_pid": None, "parent_pid_parse": f"unavailable:{reason}",
        "parent_alive": None, "reported_age_seconds": None,
        "reported_time_parse": f"unavailable:{reason}", "session": None,
        "surface": None, "target": None, "progress": "unavailable",
    }


def read_text(
    path: Path, limit: int = MAX_STATE_BYTES, *, root: Path | None = None,
) -> tuple[str | None, str | None]:
    try:
        if root is not None:
            try:
                relative = path.relative_to(root)
            except ValueError:
                return None, "outside_root_refused"
            current = root
            for part in relative.parts:
                current = current / part
                if current.is_symlink():
                    return None, "symlink_refused"
        if path.is_symlink():
            return None, "symlink_refused"
        if not path.is_file():
            return None, None
        if path.stat().st_size > limit:
            return None, f"too_large>{limit}"
        return path.read_text(encoding="utf-8", errors="replace"), None
    except OSError as exc:
        return None, f"read_error:{exc.__class__.__name__}"


def read_json(path: Path, *, root: Path | None = None) -> tuple[dict[str, Any] | None, str | None]:
    raw, error = read_text(path, root=root)
    if error or raw is None:
        return None, error
    try:
        value = json.loads(raw, parse_constant=reject_json_constant)
    except (ValueError, TypeError) as exc:
        return None, f"malformed_json:{exc.__class__.__name__}"
    return (value, None) if isinstance(value, dict) else (None, "json_not_object")


def strict_int(
    value: Any, *, allow_zero: bool = True, max_value: int = MAX_COUNTER,
) -> tuple[int | None, str]:
    if isinstance(value, bool):
        return None, "malformed"
    if isinstance(value, int):
        number = value
    elif isinstance(value, str) and value.strip().isdigit():
        text = value.strip()
        if len(text) > 20:
            return None, "malformed"
        try:
            number = int(text)
        except ValueError:
            return None, "malformed"
    elif value in (None, ""):
        return None, "missing"
    else:
        return None, "malformed"
    if number < 0 or number > max_value or (number == 0 and not allow_zero):
        return None, "malformed"
    return number, "ok"


def pid_alive(pid: int | None) -> bool | None:
    if not pid:
        return None
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False
    except (OSError, OverflowError, ValueError):
        return False


def file_age(path: Path, now: float) -> int | None:
    try:
        return max(0, int(now - path.stat().st_mtime))
    except OSError:
        return None


def safe_seat(name: str) -> bool:
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    return 0 < len(name) <= 64 and name[0].isalnum() and all(char in allowed for char in name)


def safe_token(value: str) -> bool:
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    return 0 < len(value) <= 64 and all(char in allowed for char in value)


def valid_timestamp(value: str) -> bool:
    if not value or len(value) > 64:
        return False
    if value.isdigit():
        number, parse = strict_int(value, max_value=MAX_EPOCH_SECONDS * 1000)
        return parse == "ok" and number is not None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return 2000 <= parsed.year <= 2100


def roster_rows(pad_md: Path) -> tuple[list[dict[str, str]], list[str], str]:
    raw, error = read_text(pad_md, 8 * MAX_STATE_BYTES)
    if raw is None:
        return [], [f"pad_file:{error or 'missing'}"], ""
    rows: list[dict[str, str]] = []
    issues: list[str] = []
    in_roster = False
    for line in raw.splitlines():
        if line.strip().startswith("```roster"):
            in_roster = True
            continue
        if in_roster and line.strip().startswith("```"):
            in_roster = False
            continue
        if not in_roster or not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = [field.strip() for field in line.strip().split("|")]
        if len(fields) < 2:
            issues.append(f"malformed_roster_line:{line[:120]}")
            continue
        if len(fields) >= 5 and fields[2] not in {"push", "pull"}:
            adapter, wake, target = fields[1], fields[3], fields[4]
        else:
            adapter = fields[1]
            wake = fields[2] if len(fields) >= 3 else "pull"
            target = fields[3] if len(fields) >= 4 else "-"
        rows.append({"name": fields[0], "adapter": adapter, "wake": wake, "target": target})
    if not rows and "```roster" not in raw:
        issues.append("roster_block:missing")
    elif not rows:
        issues.append("roster:empty")
    return rows, issues, raw


def session_bindings(state: Path) -> tuple[dict[str, list[str]], list[dict[str, str]], list[str]]:
    by_name: dict[str, list[str]] = {}
    all_bindings: list[dict[str, str]] = []
    issues: list[str] = []
    sessions = state / "sessions"
    if sessions.is_symlink():
        return {}, [], ["sessions:symlink_refused"]
    try:
        entries: list[Path] = []
        if sessions.is_dir():
            for index, entry in enumerate(sessions.iterdir()):
                if index >= 1024:
                    issues.append("sessions:truncated_at_1024")
                    break
                entries.append(entry)
            entries.sort()
    except OSError as exc:
        return {}, [], [f"sessions_read_error:{exc.__class__.__name__}"]
    for entry in entries:
        if not entry.is_file():
            continue
        value, error = read_text(entry, 4096, root=state)
        if error or value is None:
            issues.append(f"session:{entry.name}:{error or 'unreadable'}")
            continue
        name = value.strip()
        binding = {"session_id": entry.name, "name": name}
        all_bindings.append(binding)
        if not name:
            issues.append(f"session:{entry.name}:empty")
            continue
        by_name.setdefault(name, []).append(entry.name)
    return by_name, all_bindings, issues


def read_scalar(
    path: Path, *, root: Path | None = None, max_value: int = MAX_COUNTER,
) -> dict[str, Any]:
    raw, error = read_text(path, 4096, root=root)
    if raw is None:
        return {"present": path.is_file(), "value": None, "parse": error or "missing"}
    value, parse = strict_int(raw.strip(), max_value=max_value)
    return {"present": True, "value": value, "parse": parse, "raw": raw.strip()[:128] if parse != "ok" else None}


def heartbeat(state: Path, name: str, now: float) -> tuple[dict[str, Any], list[str]]:
    path = state / f"alive.{name}"
    obj, parse_error = read_json(path, root=state)
    age = None if parse_error in {"symlink_refused", "outside_root_refused"} else file_age(path, now)
    result: dict[str, Any] = {
        "present": path.is_file(), "parse_error": parse_error, "age_seconds": age,
        "fresh": age is not None and age < 90,
    }
    issues: list[str] = []
    if obj is None:
        result.update({"pid": None, "pid_parse": "missing", "pid_alive": None,
                       "parent_pid": None, "parent_pid_parse": "missing", "parent_alive": None,
                       "reported_age_seconds": None, "reported_time_parse": "missing",
                       "progress": "malformed" if parse_error else "missing"})
        if parse_error:
            issues.append(f"heartbeat:{parse_error}")
        else:
            issues.append("heartbeat:missing")
        return result, issues

    pid, pid_parse = strict_int(obj.get("pid"), allow_zero=False, max_value=MAX_PID)
    parent_value = obj.get("parentPid")
    if parent_value in (None, "", 0, "0"):
        parent, parent_parse = None, "missing"
    else:
        parent, parent_parse = strict_int(parent_value, allow_zero=False, max_value=MAX_PID)
    reported = obj.get("ts")
    reported_valid = (
        isinstance(reported, (int, float)) and not isinstance(reported, bool)
        and 0 <= reported <= MAX_EPOCH_SECONDS
    )
    reported_age = max(0, int(now - reported)) if reported_valid else None
    alive = pid_alive(pid)
    parent_live = pid_alive(parent)
    fresh = bool(result["fresh"])
    if not fresh:
        progress = "stale"
    elif pid_parse != "ok":
        progress = "malformed"
    elif alive:
        progress = "fresh"
    else:
        progress = "stalled"
    result.update({
        "pid": pid, "pid_parse": pid_parse, "pid_alive": alive,
        "parent_pid": parent, "parent_pid_parse": parent_parse, "parent_alive": parent_live,
        "reported_age_seconds": reported_age, "reported_time_parse": "ok" if reported_valid else "malformed",
        "session": bounded_scalar(obj.get("session")),
        "surface": bounded_scalar(obj.get("surface")), "target": bounded_scalar(obj.get("target")),
        "progress": progress,
    })
    if pid_parse == "malformed":
        issues.append("heartbeat:malformed_pid")
    elif alive is False:
        issues.append("heartbeat:dead_pid")
    if parent_parse == "malformed":
        issues.append("heartbeat:malformed_parent_pid")
    elif parent_live is False:
        issues.append("heartbeat:dead_parent")
    if not fresh:
        issues.append("heartbeat:stale")
    if not reported_valid:
        issues.append("heartbeat:malformed_time")
    for field in ("session", "surface", "target"):
        if obj.get(field) is not None and result[field] is None:
            issues.append(f"heartbeat:malformed_{field}")
    return result, issues


def engagement_index(raw: str, roster_names: list[str]) -> dict[str, Any]:
    """Parse the pad once and index addressed mentions/replies for every seat."""
    names = {name.lower() for name in roster_names if safe_seat(name)}
    result = {name: {"mentions": [], "replies": {}} for name in names}
    broadcasts: list[tuple[int, str]] = []
    agents = set(names)
    ordinal = 0
    author: str | None = None
    body_lines: list[str] = []
    first_content: str | None = None
    in_fence = False

    def flush() -> None:
        nonlocal ordinal, author, body_lines, first_content
        if author is None:
            return
        ordinal += 1
        first = (first_content or "").lower().strip()
        at_count = len(re.findall(r"@[a-z0-9_-]+", first))
        stripped = re.sub(r"^(@[a-z0-9_-]+[ \t]*)+", "", first).rstrip()
        silent = at_count < 2 and (
            stripped.startswith(".") or stripped.startswith("[ack]")
            or (author in agents and bool(re.fullmatch(
                r"(ack|read|noted|got it|standing down|standing by|stand by|will do|understood|done here|copy|sounds good)[. !]*",
                stripped,
            )))
        )
        body = " " + " ".join(body_lines).lower()
        addresses = [match.group(1) for match in re.finditer(
            r"(?:^|[ \t])@([a-z0-9_-]+)(?=[^a-z0-9_-]|$)", body,
        )]
        if author in result:
            if silent or addresses:
                target = None
                for token in body.split()[:20]:
                    match = re.match(r"^@([a-z0-9_-]+)", token)
                    candidate = match.group(1) if match else None
                    if candidate and candidate not in {author, "all"}:
                        target = candidate
                        break
                if target:
                    result[author]["replies"][target] = ordinal
        if not silent:
            addressed = set(addresses)
            if "all" in addressed:
                broadcasts.append((ordinal, author))
            for name in names.intersection(addressed):
                if name != author:
                    result[name]["mentions"].append((ordinal, author))

    for line in raw.splitlines():
        header = re.match(r"^## @([^ \t]+)", line)
        if header:
            flush()
            author = header.group(1).lower()
            body_lines = []
            first_content = None
            in_fence = False
            continue
        if author is None:
            continue
        if re.match(r"^[ \t]*```", line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if first_content is None and line.strip():
            first_content = line
        body_lines.append(re.sub(r"`[^`]*`", " ", line))
    flush()
    return {"seats": result, "broadcasts": broadcasts, "message_count": ordinal}


def precompute_open(
    index: dict[str, Any], roster_names: list[str], since_by_name: dict[str, int],
) -> dict[str, dict[str, int]]:
    """Resolve both open gates in one event pass using seat bitsets."""
    names = list(dict.fromkeys(
        name.lower() for name in roster_names if safe_seat(name)
    ))
    bit_for = {name: 1 << position for position, name in enumerate(names)}
    name_for = {bit: name for name, bit in bit_for.items()}
    all_seats = (1 << len(names)) - 1
    event_masks: dict[int, int] = {}

    # Explicit mentions cost one bit per address token already present in the
    # pad; handled ones are removed using each seat's latest reply by sender.
    for name, seat in index["seats"].items():
        bit = bit_for[name]
        for ordinal, sender in seat["mentions"]:
            if sender != name and seat["replies"].get(sender, 0) <= ordinal:
                event_masks[ordinal] = event_masks.get(ordinal, 0) | bit

    # Broadcasts remain one event each. For each sender, walk broadcasts and
    # replies newest-first so a single integer mask captures all seats whose
    # later same-sender reply handled that broadcast.
    broadcasts_by_sender: dict[str, list[int]] = {}
    for ordinal, sender in index["broadcasts"]:
        broadcasts_by_sender.setdefault(sender, []).append(ordinal)
    replies_by_sender: dict[str, list[tuple[int, int]]] = {}
    for name, seat in index["seats"].items():
        bit = bit_for[name]
        for sender, reply_ordinal in seat["replies"].items():
            replies_by_sender.setdefault(sender, []).append((reply_ordinal, bit))
    for sender, ordinals in broadcasts_by_sender.items():
        replies = sorted(replies_by_sender.get(sender, []), reverse=True)
        reply_index = 0
        handled_mask = 0
        author_bit = bit_for.get(sender, 0)
        for ordinal in reversed(ordinals):
            while reply_index < len(replies) and replies[reply_index][0] > ordinal:
                handled_mask |= replies[reply_index][1]
                reply_index += 1
            eligible = all_seats & ~handled_mask & ~author_bit
            if eligible:
                event_masks[ordinal] = event_masks.get(ordinal, 0) | eligible

    true_values = {name: 0 for name in names}
    next_values = {name: 0 for name in names}
    remaining_true = all_seats
    remaining_next = all_seats
    active_next = 0
    thresholds = sorted((since_by_name.get(name, 0), bit_for[name]) for name in names)
    threshold_index = 0

    def assign(mask: int, destination: dict[str, int], ordinal: int) -> None:
        while mask:
            bit = mask & -mask
            destination[name_for[bit]] = ordinal
            mask ^= bit

    for ordinal in range(1, index["message_count"] + 1):
        while threshold_index < len(thresholds) and thresholds[threshold_index][0] < ordinal:
            active_next |= thresholds[threshold_index][1]
            threshold_index += 1
        mask = event_masks.get(ordinal, 0)
        if not mask:
            continue
        true_hits = mask & remaining_true
        next_hits = mask & active_next & remaining_next
        assign(true_hits, true_values, ordinal)
        assign(next_hits, next_values, ordinal)
        remaining_true &= ~true_hits
        remaining_next &= ~next_hits
        if not remaining_true and not remaining_next:
            break
    return {"true": true_values, "next": next_values}


def parse_delivery(state: Path, name: str) -> tuple[dict[str, Any] | None, list[str]]:
    state_file = state / f"delivery.{name}.state"
    pending_file = state / f"delivery.{name}.pending"
    keeper_file = state / f"delivery.{name}.keeper-reservation"
    lock_pid_file = state / f"delivery.{name}.worker.lock.d" / "pid"
    turn_files = sorted(itertools.islice(
        glob.iglob(str(state / f"delivery.{glob.escape(name)}.turn.*")), 17,
    ))
    if not any((state_file.is_file(), pending_file.is_file(), keeper_file.is_file(),
                lock_pid_file.is_file(), bool(turn_files))):
        return None, []

    issues: list[str] = []
    snapshot: dict[str, str] = {}
    raw, error = read_text(state_file, root=state)
    malformed_lines: list[str] = []
    if error:
        issues.append(f"delivery_state:{error}")
    elif raw is not None:
        for line in raw.splitlines():
            if not line or "=" not in line:
                if line:
                    malformed_lines.append(line[:120])
                continue
            key, value = line.split("=", 1)
            if key not in DELIVERY_KEYS or key in snapshot or len(value) > 4096:
                malformed_lines.append(line[:120])
                continue
            if key in {"generation", "ordinal"} and value:
                if strict_int(value, allow_zero=False)[1] != "ok":
                    malformed_lines.append(line[:120])
                    continue
            if key in DELIVERY_TIMESTAMP_KEYS and value and not valid_timestamp(value):
                malformed_lines.append(line[:120])
                continue
            snapshot[key] = value
    if malformed_lines:
        issues.append("delivery_state:malformed_lines")
    delivery_state = snapshot.get("state")
    if delivery_state and delivery_state not in DELIVERY_STATES:
        issues.append(f"delivery_state:unknown:{delivery_state}")
    elif delivery_state in DELIVERY_ATTENTION_STATES | DELIVERY_ERROR_STATES:
        issues.append(f"delivery_state:{delivery_state}")

    pending: dict[str, Any] | None = None
    pending_raw, pending_error = read_text(pending_file, root=state)
    if pending_error:
        issues.append(f"delivery_pending:{pending_error}")
    elif pending_raw is not None:
        fields = pending_raw.rstrip("\n").split("|")
        keys = ["generation", "ordinal", "message_id", "task_id", "accepted_at", "adapter", "wake", "target"]
        generation = strict_int(fields[0], allow_zero=False)[1] if len(fields) == len(keys) else "malformed"
        ordinal = strict_int(fields[1], allow_zero=False)[1] if len(fields) == len(keys) else "malformed"
        if (len(fields) == len(keys) and generation == "ok" and ordinal == "ok"
                and all(0 < len(field) <= 512 for field in fields[2:])
                and valid_timestamp(fields[4])
                and safe_token(fields[5]) and fields[6] in {"push", "pull"}):
            pending = {**dict(zip(keys, fields)), "parse": "ok"}
        else:
            pending = {"raw": pending_raw[:256], "parse": "malformed"}
            issues.append("delivery_pending:malformed")

    keeper: dict[str, Any] | None = None
    keeper_raw, keeper_error = read_text(keeper_file, root=state)
    if keeper_error:
        issues.append(f"keeper_reservation:{keeper_error}")
    elif keeper_raw is not None:
        fields = keeper_raw.rstrip("\n").split("|")
        ordinal, ordinal_parse = strict_int(fields[0], allow_zero=True) if len(fields) == 4 else (None, "malformed")
        task_sentinel_valid = (
            ordinal_parse == "ok"
            and (ordinal != 0 or fields[1].startswith("keeper-task-"))
        )
        if (len(fields) == 4 and ordinal_parse == "ok" and fields[2] in KEEPER_STATES
                and task_sentinel_valid
                and bool(fields[1]) and bool(fields[3])
                and all(len(field) <= 512 for field in fields[1:])):
            keeper = {"ordinal": ordinal, "message_id": fields[1], "state": fields[2],
                      "attempt_id": fields[3], "parse": "ok"}
            if fields[2] == "acceptance_unknown":
                issues.append("keeper_reservation:acceptance_unknown")
        else:
            keeper = {"raw": keeper_raw[:256], "parse": "malformed"}
            issues.append("keeper_reservation:malformed")

    worker = read_scalar(lock_pid_file, root=state, max_value=MAX_PID)
    worker["pid_alive"] = pid_alive(worker.get("value")) if worker.get("parse") == "ok" else None
    if worker["present"] and worker["parse"] != "ok":
        issues.append("delivery_worker:malformed_pid")
    elif worker["present"] and worker["pid_alive"] is False:
        issues.append("delivery_worker:dead_pid")

    turns: list[dict[str, Any]] = []
    for filename in turn_files[:16]:
        path = Path(filename)
        turn_id, turn_error = read_text(path, 4096, root=state)
        generation = path.name.rsplit(".turn.", 1)[-1]
        if strict_int(generation, allow_zero=False)[1] != "ok":
            turn_error = turn_error or "malformed_generation"
        turns.append({"generation": generation,
                      "turn_id": turn_id.strip() if turn_id else None, "parse_error": turn_error})
    if len(turn_files) > 16:
        issues.append("delivery_turns:truncated_at_16")
    active = bool(worker.get("pid_alive") and delivery_state in {
        "started", "busy", "in_flight", "cancel_pending", "deferred_dnd",
    })
    pending_valid = bool(pending is not None and pending.get("parse") == "ok")
    state_valid = error is None and not malformed_lines and delivery_state in DELIVERY_STATES
    recoverable = bool(pending_valid and state_valid
                       and delivery_state in {
                           "accepted", "busy", "error", "cancel_pending", "deferred_dnd",
                       })
    last_result = {
        key: snapshot.get(key) for key in
        ("state", "completed_at", "error_at", "error_code", "turn_id", "turn_status")
        if snapshot.get(key) not in (None, "")
    } or None
    return {
        "state_file": {"present": state_file.is_file(), "values": snapshot, "malformed_lines": malformed_lines},
        "pending": pending, "keeper_reservation": keeper, "worker": worker, "turns": turns,
        "active": active, "recoverable": recoverable, "last_result": last_result,
    }, issues


def reset_recovery_provenance(state: Path, name: str) -> tuple[dict[str, Any], list[str]]:
    """Read the exact reset-owned pending marker without mutating it."""
    path = state / f"pending.{name}.reset"
    raw, error = read_text(path, 4096, root=state)
    if error:
        return ({"present": True, "parse": error, "ordinal": None, "identity": None},
                [f"reset_recovery:{error}"])
    if raw is None:
        return ({"present": False, "parse": "missing", "ordinal": None, "identity": None}, [])
    line = raw.rstrip("\n")
    fields = line.split("|")
    ordinal, ordinal_parse = strict_int(fields[0], allow_zero=False) if len(fields) == 2 else (None, "malformed")
    identity = fields[1] if len(fields) == 2 else ""
    identity_ok = bool(re.fullmatch(r"[0-9]{1,10}-[0-9]{1,20}", identity))
    if ordinal_parse == "ok" and identity_ok and "\n" not in line:
        return ({"present": True, "parse": "ok", "ordinal": ordinal,
                 "identity": identity}, [])
    return ({"present": True, "parse": "malformed", "ordinal": None,
             "identity": None, "raw": raw[:256]}, ["reset_recovery:malformed_provenance"])


def process_table() -> list[tuple[int, int, str]]:
    try:
        raw = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], text=True,
                             capture_output=True, timeout=3, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows: list[tuple[int, int, str]] = []
    for line in raw.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def watcher_health(state: Path, pad_md: Path, watch_start_grace: int) -> dict[str, Any]:
    lock = state / "watch.lock.d"
    pid_info = read_scalar(lock / "pid", root=state, max_value=MAX_PID)
    pid = pid_info.get("value") if pid_info.get("parse") == "ok" else None
    alive = pid_alive(pid)
    rows = process_table()
    command = next((cmd for proc, _parent, cmd in rows if proc == pid), None) if pid else None
    matches = bool(command and "watch.sh" in command)
    fswatch_rows = [(proc, parent) for proc, parent, cmd in rows if f"fswatch -0 {pad_md}" in cmd]
    parents = sorted({parent for _proc, parent in fswatch_rows})
    lock_symlink = lock.is_symlink()
    lock_age = None if lock_symlink else file_age(lock, time.time())
    generation_only = False
    if not lock_symlink and lock.is_dir():
        try:
            entries = list(lock.iterdir())
            generation = lock / "generation"
            generation_raw, generation_error = read_text(generation, 128, root=state)
            generation_only = (
                len(entries) == 1 and entries[0].name == "generation"
                and generation_error is None and generation_raw is not None
                and bool(re.fullmatch(r"[A-Za-z0-9._-]{1,128}", generation_raw))
            )
        except OSError:
            generation_only = False
    if lock_symlink:
        status = "malformed_lock"
    elif not lock.is_dir():
        status = "stopped"
    elif generation_only:
        status = "stale_lock" if (lock_age or 0) >= watch_start_grace else "starting"
    elif pid_info.get("parse") != "ok":
        status = "malformed_lock"
    elif not alive:
        status = "stale_lock"
    elif not matches:
        status = "pid_mismatch"
    elif len(parents) > 1:
        status = "duplicate"
    elif not fswatch_rows and (lock_age or 0) > 5:
        status = "stalled"
    else:
        status = "running"
    return {
        "status": status, "lock_present": lock.is_dir(), "lock_age_seconds": lock_age,
        "start_grace_seconds": watch_start_grace,
        "pid": pid, "pid_parse": pid_info.get("parse"), "pid_alive": alive,
        "pid_matches_watcher": matches, "fswatch_processes": len(fswatch_rows),
        "watcher_parents": parents, "singleton": len(parents) <= 1,
    }


def bounded_http_body(response: Any, deadline: float) -> bytes:
    chunks: list[bytes] = []
    total = 0
    reader = getattr(response, "read1", response.read)
    raw_stream = getattr(getattr(response, "fp", None), "raw", None)
    sock = getattr(raw_stream, "_sock", None)
    while total <= MAX_STATE_BYTES:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("whole-request deadline exceeded")
        if sock is not None:
            try:
                sock.settimeout(max(0.001, remaining))
            except OSError:
                # http.client can close the socket after buffering a small
                # response.  The buffered body is still safe to consume.
                sock = None
        chunk = reader(min(65_536, MAX_STATE_BYTES + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if time.monotonic() > deadline:
            raise TimeoutError("whole-request deadline exceeded")
    return b"".join(chunks)


def deep_ocean(target: str) -> dict[str, Any]:
    base = os.environ.get("OCEAN_DAEMON_URL", "http://127.0.0.1:4780").rstrip("/")
    try:
        parsed = urllib.parse.urlparse(base)
        hostname = parsed.hostname
        _ = parsed.port
    except ValueError as exc:
        return {"status": "malformed_url", "active_turn": None,
                "detail": exc.__class__.__name__}
    if (parsed.scheme != "http" or hostname not in {"127.0.0.1", "::1"}
            or parsed.username is not None or parsed.password is not None):
        return {"status": "refused_non_loopback", "active_turn": None}
    url = f"{base}/v1/agent/sessions/{urllib.parse.quote(target, safe='')}"
    deadline = time.monotonic() + DEEP_DEADLINE_SECONDS
    try:
        request = urllib.request.Request(url, method="GET", headers={"accept": "application/json"})
        # Ignore ambient HTTP_PROXY: an explicit loopback diagnostic must stay
        # loopback and never disclose target/session identifiers to a proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=max(0.001, deadline - time.monotonic())) as response:
            raw = bounded_http_body(response, deadline)
        if len(raw) > MAX_STATE_BYTES:
            return {"status": "response_too_large", "active_turn": None}
        value = json.loads(raw, parse_constant=reject_json_constant)
        if not isinstance(value, dict) or not isinstance(value.get("session"), dict):
            return {"status": "malformed_response", "active_turn": None,
                    "detail": "session_not_object"}
        session = value["session"]
        active_turn = bounded_scalar(session.get("active_turn"))
        session_status = bounded_scalar(session.get("status"))
        if ((session.get("active_turn") is not None and active_turn is None)
                or (session.get("status") is not None and session_status is None)):
            return {"status": "malformed_response", "active_turn": None,
                    "detail": "session_fields_not_scalar"}
        return {"status": "ok", "active_turn": active_turn, "session_status": session_status}
    except (TimeoutError, socket.timeout):
        return {"status": "timeout", "active_turn": None}
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, (TimeoutError, socket.timeout)):
            return {"status": "timeout", "active_turn": None}
        return {"status": "unavailable", "active_turn": None,
                "detail": exc.__class__.__name__}
    except OSError as exc:
        return {"status": "unavailable", "active_turn": None, "detail": exc.__class__.__name__}
    except (ValueError, TypeError) as exc:
        return {"status": "malformed_response", "active_turn": None, "detail": exc.__class__.__name__}


def _probe_endpoint(
    base: str, path: str, deadline: float, *, accept_statuses: frozenset[int] = frozenset({200}),
) -> dict[str, Any]:
    """Issue one bounded GET to a daemon endpoint. Never mutates — no POST body."""
    started = time.monotonic()
    url = f"{base}{path}"
    try:
        request = urllib.request.Request(url, method="GET", headers={"accept": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        remaining = max(0.001, deadline - time.monotonic())
        with opener.open(request, timeout=remaining) as response:
            raw = bounded_http_body(response, deadline)
        elapsed_ms = int((time.monotonic() - started) * 1000)
        status = response.getcode()
        if status not in accept_statuses:
            return {
                "status": "unexpected_status", "http_status": status,
                "elapsed_ms": elapsed_ms, "present": False,
            }
        if len(raw) > MAX_STATE_BYTES:
            return {"status": "response_too_large", "elapsed_ms": elapsed_ms, "present": False}
        value = json.loads(raw, parse_constant=reject_json_constant)
        if not isinstance(value, dict):
            return {"status": "malformed_response", "elapsed_ms": elapsed_ms, "present": False}
        # Carry the deserialized body so callers can inspect per-model readiness,
        # failover lists, etc. without re-fetching.
        return {"status": "ok", "elapsed_ms": elapsed_ms, "body": value, "present": True}
    except urllib.error.HTTPError as exc:
        elapsed_ms = int((time.monotonic() - started) * 1000)
        status_code = exc.code
        # Read headers for rate-limit evidence even on error responses.
        rate_limit_headers: dict[str, str] = {}
        for header in ("retry-after", "x-ratelimit-remaining", "x-ratelimit-reset",
                       "ratelimit-remaining", "ratelimit-reset"):
            value = exc.headers.get(header) or exc.headers.get(header.replace("-", "_"))
            if value:
                rate_limit_headers[header] = value[:128]
        if status_code == 429:
            return {
                "status": "rate_limited", "http_status": 429, "elapsed_ms": elapsed_ms,
                "rate_limit_headers": rate_limit_headers, "present": True,
            }
        return {
            "status": "http_error", "http_status": status_code, "elapsed_ms": elapsed_ms,
            "rate_limit_headers": rate_limit_headers if rate_limit_headers else None,
            "present": False,
        }
    except (TimeoutError, socket.timeout):
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return {"status": "timeout", "elapsed_ms": elapsed_ms, "present": False}
    except urllib.error.URLError as exc:
        elapsed_ms = int((time.monotonic() - started) * 1000)
        if isinstance(exc.reason, (TimeoutError, socket.timeout)):
            return {"status": "timeout", "elapsed_ms": elapsed_ms, "present": False}
        return {"status": "unavailable", "elapsed_ms": elapsed_ms,
                "detail": exc.__class__.__name__, "present": False}
    except OSError as exc:
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return {"status": "unavailable", "elapsed_ms": elapsed_ms,
                "detail": exc.__class__.__name__, "present": False}
    except (ValueError, TypeError) as exc:
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return {"status": "malformed_response", "elapsed_ms": elapsed_ms,
                "detail": exc.__class__.__name__, "present": False}


def provider_availability(daemon_url: str, now: float, *, stale_seconds: int = PROVIDER_STALENESS_SECONDS) -> dict[str, Any]:
    """Bounded, non-mutating provider availability snapshot.

    Probes the Ocean daemon's turn-free surfaces (/v1/models, /ready) and
    classifies the provider into explicit, timestamped states. This is the
    truth layer that /health's hardcoded ``ok:true`` cannot provide: a stale
    ready signal must never control routing decisions.

    The k3-outage acceptance scenario (0ms completed turns while /health was
    green) is caught here: when probes fail or time out while /health returns
    instantly, the provider lands in ``probe_successful`` at best — never
    ``actively_responding``.
    """
    now_int = int(now)
    deadline = time.monotonic() + PROVIDER_PROBE_DEADLINE_SECONDS
    endpoints: dict[str, dict[str, Any]] = {}

    # Probe each turn-free endpoint sequentially within the shared deadline.
    for path in PROVIDER_PROBE_PATHS:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            endpoints[path] = {"status": "deadline_exhausted", "elapsed_ms": 0, "present": False}
        else:
            endpoints[path] = _probe_endpoint(daemon_url, path, deadline)

    # ── Classify into explicit states ──────────────────────────────────
    states: list[dict[str, Any]] = []

    # configured: we were called with a daemon URL — the seat is ocean-backed.
    states.append({"state": "configured", "at": now_int})

    models_ep = endpoints.get("/v1/models", {})
    ready_ep = endpoints.get("/ready", {})

    # catalog_ready: /v1/models returned ok with a non-empty model list.
    if models_ep.get("status") == "ok" and isinstance(models_ep.get("body", {}).get("models"), list):
        model_entries = models_ep["body"]["models"]
        if model_entries:
            # Collect per-model ready counts for operator visibility.
            ready_count = sum(1 for m in model_entries if isinstance(m, dict) and m.get("ready"))
            states.append({
                "state": "catalog_ready", "at": now_int,
                "model_count": len(model_entries), "models_ready": ready_count,
            })

    # probe_successful: at least one probe returned a parseable JSON response.
    any_ok = any(ep.get("status") == "ok" for ep in endpoints.values())
    any_rate_limited = any(ep.get("status") == "rate_limited" for ep in endpoints.values())
    if any_ok:
        # Carry the fastest ok elapsed for timing visibility.
        ok_elapsed = min(
            (ep.get("elapsed_ms", 999_999) for ep in endpoints.values() if ep.get("status") == "ok"),
            default=None,
        )
        states.append({"state": "probe_successful", "at": now_int, "fastest_ok_ms": ok_elapsed})

    # rate_limited: any endpoint returned 429 or carried rate-limit headers.
    if any_rate_limited:
        states.append({"state": "rate_limited", "at": now_int})

    # actively_responding: ALL probes returned ok within the deadline AND no
    # rate-limiting was observed. This is the only state that should unblock
    # routing decisions.
    all_ok = all(ep.get("status") == "ok" for ep in endpoints.values())
    if all_ok and not any_rate_limited:
        max_elapsed = max(
            (ep.get("elapsed_ms", 0) for ep in endpoints.values()), default=0,
        )
        states.append({"state": "actively_responding", "at": now_int, "max_elapsed_ms": max_elapsed})

    # Derive a summary label from the best attained state.
    if states:
        best = states[-1]["state"]
    else:
        best = "unreachable"

    # Check staleness against any prior probe timestamp stored on disk.
    # The caller passes `now`; we compute age and mark stale when the freshest
    # endpoint probe is older than the staleness threshold.
    freshest_at = max(
        (now_int for ep in endpoints.values() if ep.get("present")), default=0,
    )
    if freshest_at == 0:
        freshest_at = now_int
    age_seconds = max(0, now_int - freshest_at)
    stale = age_seconds > stale_seconds

    return {
        "probed_at": now_int,
        "daemon_url": daemon_url,
        "states": states,
        "summary": best,
        "age_seconds": age_seconds,
        "stale": stale,
        "endpoints": endpoints,
    }


def severity(issues: list[str]) -> str:
    errors = ("duplicate_", "invalid_", "missing_adapter", "malformed", "dead_pid",
              "pid_mismatch", "acceptance_unknown", "delivery_state:error",
              "delivery_state:cancelled", "pad_file:")
    return "error" if any(any(token in issue for token in errors) for issue in issues) else ("warn" if issues else "ok")


def unavailable_seat(row: dict[str, str], reason: str, issues: list[str]) -> dict[str, Any]:
    safe_row = {key: value[:512] for key, value in row.items()}
    scalar = unavailable_scalar(reason)
    return {
        **safe_row, "runtime": None, "operator": False,
        "heartbeat": unavailable_heartbeat(reason),
        "ticker": {**scalar, "pid_alive": None}, "dnd": None,
        "seen_cursor": dict(scalar), "recovery_pending_ordinal": dict(scalar),
        "reset_recovery_provenance": {"present": False, "parse": f"unavailable:{reason}",
                                      "ordinal": None, "identity": None},
        "open_pending_ordinal": {"value": None, "status": f"unavailable:{reason}"},
        "next_unseen_ordinal": {"value": None, "status": f"unavailable:{reason}"},
        "session_bindings": [], "delivery": None, "deep_ocean": None,
        "issues": sorted(set(issues)), "repair": [], "status": "error",
    }


def build(args: argparse.Namespace) -> dict[str, Any]:
    now = time.time()
    pad_dir = Path(os.path.abspath(args.pad_dir))
    pad_md = Path(os.path.abspath(args.pad_md))
    state_input = Path(os.path.abspath(args.state_dir))
    state_refused = state_input.is_symlink()
    # A runtime-state symlink could otherwise turn a diagnostic into an
    # arbitrary-file reader. Point all probes at an impossible child of a
    # character device when the state root itself is untrusted.
    state = Path("/dev/null/stitchpad-health-refused-state") if state_refused else state_input
    adapter_dir = Path(os.path.abspath(args.adapter_dir))
    rows, pad_issues, pad_raw = roster_rows(pad_md)
    if state_refused:
        pad_issues.append("state_dir:symlink_refused")
    if len(rows) > 128:
        pad_issues.append(f"roster_truncated:{len(rows)}->128")
        rows = rows[:128]
    bindings, all_bindings, binding_issues = session_bindings(state)
    roster_names = [row["name"] for row in rows]
    orphan_bindings = [binding for binding in all_bindings if binding["name"] not in roster_names]
    target_counts: dict[str, int] = {}
    name_counts: dict[str, int] = {}
    deep_cache: dict[str, dict[str, Any]] = {}
    engagement = engagement_index(pad_raw, roster_names)
    seen_cache: dict[str, dict[str, Any]] = {}
    since_by_name: dict[str, int] = {}
    for name in roster_names:
        if not safe_seat(name) or name.lower() in seen_cache:
            continue
        if state_refused:
            seen = unavailable_scalar("state_symlink_refused")
        else:
            seen = read_scalar(state / f"seen.{name}", root=state)
        seen_cache[name.lower()] = seen
        since_by_name[name.lower()] = int(seen.get("value") or 0) if seen.get("parse") == "ok" else 0
    open_values = precompute_open(engagement, roster_names, since_by_name)

    for row in rows:
        name_counts[row["name"]] = name_counts.get(row["name"], 0) + 1
        if row["target"] and row["target"] != "-":
            target_counts[row["target"]] = target_counts.get(row["target"], 0) + 1

    seats: list[dict[str, Any]] = []
    # Resolve daemon URL once for all deep probes (provider + per-session).
    daemon_url = os.environ.get(
        "OCEAN_DAEMON_URL",
        getattr(args, "daemon_url", None) or "http://127.0.0.1:4780",
    ).rstrip("/")
    for row in rows:
        name, adapter, wake, target = row["name"], row["adapter"], row["wake"], row["target"]
        issues: list[str] = []
        repairs: list[str] = []
        if not safe_seat(name):
            issues.append("invalid_seat_name")
            seats.append(unavailable_seat(row, "invalid_seat_name", issues))
            continue
        target_too_long = len(target) > 512
        if target_too_long:
            issues.append("invalid_target:too_long")
            target = target[:512]
        if len(wake) > 16:
            issues.append("invalid_wake:too_long")
        runtime_raw = None
        if not state_refused:
            runtime_raw, _ = read_text(state / f"runtime.{name}", 4096, root=state)
        runtime = runtime_raw.strip() if runtime_raw else adapter
        operator = runtime in {"operator", "human"}
        if name_counts.get(name, 0) > 1:
            issues.append(f"duplicate_roster_name:{name_counts[name]}")

        seat_bindings = sorted(bindings.get(name, []))
        if not operator:
            if wake not in {"push", "pull"}:
                issues.append(f"invalid_wake:{wake}")
            if wake == "push" and target in {"", "-"}:
                issues.append("missing_target")
                repairs.append(f"set a verified target with: stitchpad set-wake {name} push <target> {adapter}")
            if target_counts.get(target, 0) > 1 and target not in {"", "-"}:
                issues.append(f"duplicate_target:{target_counts[target]}")
                repairs.append("re-pin each duplicated target to its one live seat; do not guess a terminal")
            if not safe_token(adapter) or not (adapter_dir / f"{adapter}.sh").is_file():
                issues.append(f"missing_adapter:{adapter}.sh")
                repairs.append(f"install or select an existing adapter for @{name}")
            if not state_refused and wake == "pull" and not seat_bindings:
                issues.append("missing_session_binding")
                repairs.append("rejoin from the authoritative runtime session to create one binding")
            if len(seat_bindings) > 1:
                issues.append(f"duplicate_session_bindings:{len(seat_bindings)}")
                repairs.append("end stale sessions, then rejoin only the authoritative live session")
            if not state_refused and adapter == "ocean" and target not in {"", "-"}:
                target_binding = next((item for item in all_bindings if item["session_id"] == target), None)
                if target_binding is None:
                    issues.append("ocean_target_unbound")
                elif target_binding["name"] != name:
                    issues.append(f"ocean_target_bound_to:{target_binding['name']}")

        true_open = {"value": open_values["true"].get(name.lower(), 0), "status": "ok"}
        if state_refused:
            unavailable = "state_symlink_refused"
            issues.append(f"state_unavailable:{unavailable}")
            hb = unavailable_heartbeat(unavailable)
            ticker = {**unavailable_scalar(unavailable), "pid_alive": None}
            seen = seen_cache[name.lower()]
            pending_stamp = unavailable_scalar(unavailable)
            reset_provenance = {"present": False, "parse": f"unavailable:{unavailable}",
                                "ordinal": None, "identity": None}
            next_unseen = {"value": None, "status": f"unavailable:{unavailable}"}
            dnd = None
            delivery = None
        else:
            hb, hb_issues = heartbeat(state, name, now)
            ticker = read_scalar(
                state / f"heartbeat.{name}.lock" / "pid", root=state, max_value=MAX_PID,
            )
            ticker["pid_alive"] = pid_alive(ticker.get("value")) if ticker.get("parse") == "ok" else None
            if ticker["present"] and ticker["parse"] != "ok":
                issues.append("ticker:malformed_pid")
            elif ticker["present"] and ticker["pid_alive"] is False:
                issues.append("ticker:dead_pid")
            if ticker.get("value") and hb.get("pid") and ticker["value"] != hb["pid"]:
                issues.append("ticker:pid_mismatch")
            if not operator:
                issues.extend(hb_issues)
                if hb.get("progress") in {"stale", "stalled", "malformed", "missing"}:
                    repairs.append("restart the authoritative seat/runtime; preserve wake cursors and re-run health")

            seen = seen_cache[name.lower()]
            if seen["present"] and seen["parse"] != "ok":
                issues.append("seen:malformed")
            pending_stamp = read_scalar(state / f"pending.{name}", root=state)
            if pending_stamp["present"] and pending_stamp["parse"] != "ok":
                issues.append("pending:malformed")
            reset_provenance, reset_issues = reset_recovery_provenance(state, name)
            issues.extend(reset_issues)
            if reset_provenance["present"] and reset_provenance["parse"] != "ok":
                repairs.append(
                    f"inspect pending.{name} and pending.{name}.reset together; malformed reset provenance is preserved and must never be auto-replayed or deleted by guesswork"
                )
            next_unseen = {"value": open_values["next"].get(name.lower(), 0), "status": "ok"}
            dnd = (state / f"dnd.{name}").is_file()
            if dnd and (true_open.get("value") or pending_stamp.get("value")):
                repairs.append(f"when ready, resume explicitly: STITCHPAD_NAME={name} stitchpad dnd off")

            delivery, delivery_issues = parse_delivery(state, name)
            issues.extend(delivery_issues)
            if delivery and delivery.get("recoverable") and not delivery["worker"].get("pid_alive"):
                repairs.append("restart the pad watcher; accepted delivery remains recoverable on disk")
            if (delivery and delivery.get("keeper_reservation")
                    and delivery["keeper_reservation"].get("state") == "acceptance_unknown"):
                repairs.append("hold position and inspect the keeper request; never auto-retry or advance an acceptance_unknown reservation")
        deep = None
        if args.deep and adapter == "ocean" and target not in {"", "-"}:
            if target_too_long:
                deep = {"status": "invalid_target", "active_turn": None}
            else:
                if target not in deep_cache:
                    deep_cache[target] = (deep_ocean(target) if len(deep_cache) < 16 else
                                          {"status": "skipped_limit", "active_turn": None})
                deep = deep_cache[target]
        seat = {
            **row, "target": target, "runtime": runtime, "operator": operator,
            "heartbeat": hb, "ticker": ticker, "dnd": dnd,
            "seen_cursor": seen, "recovery_pending_ordinal": pending_stamp,
            "reset_recovery_provenance": reset_provenance,
            "open_pending_ordinal": true_open, "next_unseen_ordinal": next_unseen,
            "session_bindings": seat_bindings, "delivery": delivery,
            "deep_ocean": deep, "issues": sorted(set(issues)),
            "repair": list(dict.fromkeys(repairs)),
        }
        seat["status"] = severity(seat["issues"])
        seats.append(seat)

    # ── Provider availability (after per-seat probes) ──────────────────
    # Probe the daemon's turn-free surfaces AFTER all per-seat deep_ocean
    # calls so a single-request test fixture is never consumed before its
    # intended consumer.  The provider snapshot is a separate truth layer
    # that /health's hardcoded ok:true cannot replace.
    provider = None
    if args.deep:
        try:
            parsed = urllib.parse.urlparse(daemon_url)
            hostname = parsed.hostname
            port_str = parsed.port
            port_ok = port_str is None or (isinstance(port_str, int) and 1 <= port_str <= 65535)
            if (parsed.scheme == "http" and hostname in {"127.0.0.1", "::1"}
                    and parsed.username is None and parsed.password is None
                    and port_ok):
                provider = provider_availability(daemon_url, now)
            else:
                reason = "refused_non_loopback"
                if parsed.scheme != "http":
                    reason = "malformed_url"
                elif not port_ok:
                    reason = "malformed_url"
                provider = {
                    "probed_at": int(now), "daemon_url": daemon_url,
                    "states": [], "summary": reason,
                    "age_seconds": 0, "stale": False, "endpoints": {},
                }
        except (ValueError, urllib.error.URLError, OSError) as exc:
            provider = {
                "probed_at": int(now), "daemon_url": daemon_url,
                "states": [], "summary": f"unavailable:{exc.__class__.__name__}",
                "age_seconds": 0, "stale": False, "endpoints": {},
            }

    pad_issues.extend(binding_issues)
    pad_issues.extend(f"orphan_session:{item['session_id']}->{item['name']}" for item in orphan_bindings)
    watcher = watcher_health(state, pad_md, args.watch_start_grace)
    if watcher["status"] in {"malformed_lock", "stale_lock", "pid_mismatch", "duplicate", "stalled"}:
        pad_issues.append(f"watcher:{watcher['status']}")
    pad_repairs: list[str] = []
    if watcher["status"] in {"malformed_lock", "stale_lock", "pid_mismatch", "stalled"}:
        pad_repairs.append("after confirming no live owner, run: stitchpad restart")
    elif watcher["status"] == "duplicate":
        pad_repairs.append("stop the duplicate watcher owners, then run one: stitchpad start")
    errors = sum(seat["status"] == "error" for seat in seats)
    warnings = sum(seat["status"] == "warn" for seat in seats)
    pad_status = severity(pad_issues)
    overall_status = "error" if errors or pad_status == "error" else (
        "warn" if warnings or pad_status == "warn" else "ok"
    )
    return {
        "schema_version": 1, "generated_at": int(now), "mode": "deep" if args.deep else "local",
        "pad": {"dir": str(pad_dir), "markdown": str(pad_md), "state_dir": str(state_input),
                "state_exists": not state_refused and state.is_dir(),
                "state_access": "symlink_refused" if state_refused else "ok",
                "watcher": watcher,
                "orphan_session_bindings": orphan_bindings, "issues": sorted(set(pad_issues)),
                "repair": pad_repairs},
        "seats": seats,
        "provider": provider,
        "summary": {"seats": len(seats), "ok": len(seats) - errors - warnings,
                    "warnings": warnings, "errors": errors, "pad_status": pad_status,
                    "pad_issues": len(set(pad_issues)), "overall_status": overall_status},
    }


def human(snapshot: dict[str, Any]) -> str:
    pad = snapshot["pad"]
    watcher = pad["watcher"]
    lines = [f"stitchpad health — {snapshot['mode']} read-only snapshot",
             f"watcher: {watcher['status']} pid={watcher['pid']} singleton={watcher['singleton']}"]
    provider = snapshot.get("provider")
    if provider:
        stale_tag = " STALE" if provider.get("stale") else ""
        age = provider.get("age_seconds", 0)
        lines.append(
            f"provider: {provider.get('summary','none')}{stale_tag} "
            f"age={age}s probed_at={provider.get('probed_at')} "
            f"states=[{', '.join(s['state'] for s in provider.get('states',[]))}]"
        )
        for path, ep in (provider.get("endpoints") or {}).items():
            extra = ""
            if ep.get("elapsed_ms") is not None:
                extra += f" {ep['elapsed_ms']}ms"
            if ep.get("rate_limit_headers"):
                extra += f" rate-limit={{{','.join(ep['rate_limit_headers'])}}}"
            lines.append(f"  {path}: {ep.get('status','?')}{extra}")
    for seat in snapshot["seats"]:
        hb = seat.get("heartbeat", {})
        open_ord = seat.get("open_pending_ordinal", {}).get("value")
        lines.append(
            f"@{seat['name']} [{seat['status']}] {seat['adapter']}/{seat['wake']} target={seat['target']} "
            f"heartbeat={hb.get('progress')} age={hb.get('age_seconds')}s pid={hb.get('pid')}/{hb.get('pid_alive')} "
            f"parent={hb.get('parent_pid')}/{hb.get('parent_alive')} dnd={seat.get('dnd')} "
            f"seen={seat.get('seen_cursor', {}).get('value')} open={open_ord}"
        )
        reset_provenance = seat.get("reset_recovery_provenance", {})
        if reset_provenance.get("present"):
            lines.append(f"  reset recovery: {reset_provenance}")
        delivery = seat.get("delivery")
        if delivery:
            lines.append(f"  delivery: state={delivery['state_file']['values'].get('state')} "
                         f"active={delivery['active']} recoverable={delivery['recoverable']} "
                         f"turn={delivery.get('last_result')}")
            if delivery.get("keeper_reservation"):
                lines.append(f"  keeper: {delivery['keeper_reservation']}")
        if seat.get("session_bindings"):
            lines.append(f"  sessions: {', '.join(seat['session_bindings'])}")
        for issue in seat.get("issues", []):
            lines.append(f"  ! {issue}")
        for repair in seat.get("repair", []):
            lines.append(f"  -> {repair}")
    for issue in pad.get("issues", []):
        lines.append(f"pad ! {issue}")
    for repair in pad.get("repair", []):
        lines.append(f"pad -> {repair}")
    summary = snapshot["summary"]
    lines.append(f"summary: {summary['overall_status']} — {summary['ok']} ok, "
                 f"{summary['warnings']} warning, {summary['errors']} error, "
                 f"{summary['pad_issues']} pad issue(s)")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--pad-dir", required=True)
    parser.add_argument("--pad-md", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--adapter-dir", required=True)
    parser.add_argument("--watch-start-grace", required=True, type=int)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--deep", action="store_true")
    parser.add_argument("--daemon-url", default=None,
                        help="Ocean daemon URL (default: $OCEAN_DAEMON_URL or http://127.0.0.1:4780)")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when the summary is error, 2 when only warnings "
                             "(default exits 0 regardless; see main())")
    parser.add_argument("-h", "--help", action="help")
    args = parser.parse_args()
    if args.watch_start_grace < 0:
        parser.error("--watch-start-grace must be non-negative")
    snapshot = build(args)
    if args.json:
        print(json.dumps(snapshot, sort_keys=True, separators=(",", ":"), allow_nan=False))
    else:
        print(human(snapshot))

    # EXIT CODE (k3 F3). This printed "summary: error — 0 ok, 1 warning, 1 error"
    # and returned 0, so `stitchpad health && echo healthy` said healthy and any
    # orchestrator scripting `health || alert` never alerted. The severity
    # roll-up was computed correctly and then thrown away at the exact boundary
    # a caller consumes.
    #
    # The default is DELIBERATELY still 0, and this is a compromise, not an
    # oversight. `health` is already called in places that capture its output
    # under `set -euo pipefail` with no guard — test/test-health-readonly.sh:194
    # does `local_json="$($SP health --json)"` — and an unannounced flip to
    # non-zero would turn a reporting fix into a new outage, including on a live
    # fleet whose callers are not all in this repo. So the exit code becomes
    # meaningful only when asked for.
    #
    # Callers that want the roll-up enforced:  stitchpad health --strict || alert
    # 1 = at least one error, 2 = warnings only, 0 = clean.
    if args.strict:
        summary = snapshot.get("summary", {})
        if summary.get("errors") or summary.get("pad_status") == "error":
            return 1
        if summary.get("warnings"):
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
