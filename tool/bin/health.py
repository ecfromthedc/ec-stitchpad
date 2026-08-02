#!/usr/bin/env python3
"""Read-only Stitchpad/Pasture health snapshot.

Only local files and process metadata are read by default. ``--deep`` adds a
bounded loopback GET for Ocean seats. Runtime state is never repaired here:
malformed or stale files are reported as evidence, not rewritten.
"""

from __future__ import annotations

import argparse
import glob
import heapq
import itertools
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


MAX_STATE_BYTES = 1_048_576
DELIVERY_KEYS = {
    "state", "generation", "ordinal", "message_id", "task_id", "accepted_at",
    "started_at", "completed_at", "error_at", "error_code", "turn_id", "turn_status",
}
DELIVERY_STATES = {
    "accepted", "started", "busy", "error", "in_flight", "cancel_pending", "completed", "tombstoned",
}
KEEPER_STATES = {"accepted", "in_flight", "completed", "acceptance_unknown"}


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


def strict_int(value: Any, *, allow_zero: bool = True) -> tuple[int | None, str]:
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
    if number < 0 or (number == 0 and not allow_zero):
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


def read_scalar(path: Path, *, root: Path | None = None) -> dict[str, Any]:
    raw, error = read_text(path, 4096, root=root)
    if raw is None:
        return {"present": path.is_file(), "value": None, "parse": error or "missing"}
    value, parse = strict_int(raw.strip())
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

    pid, pid_parse = strict_int(obj.get("pid"), allow_zero=False)
    parent_value = obj.get("parentPid")
    if parent_value in (None, "", 0, "0"):
        parent, parent_parse = None, "missing"
    else:
        parent, parent_parse = strict_int(parent_value, allow_zero=False)
    reported = obj.get("ts")
    reported_valid = (
        isinstance(reported, (int, float)) and not isinstance(reported, bool)
        and -1_000_000_000_000 <= reported <= 1_000_000_000_000
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
    return {"seats": result, "broadcasts": broadcasts}


def indexed_open(index: dict[str, Any], name: str, since: int) -> dict[str, Any]:
    seat = index["seats"].get(name.lower())
    if seat is None:
        return {"value": None, "status": "invalid_seat_name"}
    mentions = heapq.merge(seat["mentions"], index["broadcasts"], key=lambda event: event[0])
    for ordinal, sender in mentions:
        if sender == name.lower():
            continue
        if ordinal <= since:
            continue
        handled = seat["replies"].get(sender, 0) > ordinal
        if not handled:
            return {"value": ordinal, "status": "ok"}
    return {"value": 0, "status": "ok"}


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
            snapshot[key] = value
    if malformed_lines:
        issues.append("delivery_state:malformed_lines")
    delivery_state = snapshot.get("state")
    if delivery_state and delivery_state not in DELIVERY_STATES:
        issues.append(f"delivery_state:unknown:{delivery_state}")

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
        ordinal, ordinal_parse = strict_int(fields[0], allow_zero=False) if len(fields) == 4 else (None, "malformed")
        if (len(fields) == 4 and ordinal_parse == "ok" and fields[2] in KEEPER_STATES
                and bool(fields[1]) and bool(fields[3])
                and all(len(field) <= 512 for field in fields[1:])):
            keeper = {"ordinal": ordinal, "message_id": fields[1], "state": fields[2],
                      "attempt_id": fields[3], "parse": "ok"}
            if fields[2] == "acceptance_unknown":
                issues.append("keeper_reservation:acceptance_unknown")
        else:
            keeper = {"raw": keeper_raw[:256], "parse": "malformed"}
            issues.append("keeper_reservation:malformed")

    worker = read_scalar(lock_pid_file, root=state)
    worker["pid_alive"] = pid_alive(worker.get("value")) if worker.get("parse") == "ok" else None
    if worker["present"] and worker["parse"] != "ok":
        issues.append("delivery_worker:malformed_pid")
    elif worker["present"] and worker["pid_alive"] is False:
        issues.append("delivery_worker:dead_pid")

    turns: list[dict[str, Any]] = []
    for filename in turn_files[:16]:
        path = Path(filename)
        turn_id, turn_error = read_text(path, 4096, root=state)
        turns.append({"generation": path.name.rsplit(".turn.", 1)[-1],
                      "turn_id": turn_id.strip() if turn_id else None, "parse_error": turn_error})
    if len(turn_files) > 16:
        issues.append("delivery_turns:truncated_at_16")
    active = bool(worker.get("pid_alive") and delivery_state in {"started", "busy", "in_flight"})
    pending_valid = bool(pending is not None and pending.get("parse") == "ok")
    state_valid = error is None and not malformed_lines and delivery_state in DELIVERY_STATES
    recoverable = bool(pending_valid and state_valid
                       and delivery_state in {"accepted", "error", "cancel_pending"})
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


def watcher_health(state: Path, pad_md: Path) -> dict[str, Any]:
    lock = state / "watch.lock.d"
    pid_info = read_scalar(lock / "pid", root=state)
    pid = pid_info.get("value") if pid_info.get("parse") == "ok" else None
    alive = pid_alive(pid)
    rows = process_table()
    command = next((cmd for proc, _parent, cmd in rows if proc == pid), None) if pid else None
    matches = bool(command and "watch.sh" in command)
    fswatch_rows = [(proc, parent) for proc, parent, cmd in rows if f"fswatch -0 {pad_md}" in cmd]
    parents = sorted({parent for _proc, parent in fswatch_rows})
    lock_symlink = lock.is_symlink()
    lock_age = None if lock_symlink else file_age(lock, time.time())
    if lock_symlink:
        status = "malformed_lock"
    elif not lock.is_dir():
        status = "stopped"
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
        "pid": pid, "pid_parse": pid_info.get("parse"), "pid_alive": alive,
        "pid_matches_watcher": matches, "fswatch_processes": len(fswatch_rows),
        "watcher_parents": parents, "singleton": len(parents) <= 1,
    }


def deep_ocean(target: str) -> dict[str, Any]:
    base = os.environ.get("OCEAN_DAEMON_URL", "http://127.0.0.1:4780").rstrip("/")
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1"}:
        return {"status": "refused_non_loopback", "active_turn": None}
    url = f"{base}/v1/agent/sessions/{urllib.parse.quote(target, safe='')}"
    try:
        request = urllib.request.Request(url, method="GET", headers={"accept": "application/json"})
        # Ignore ambient HTTP_PROXY: an explicit loopback diagnostic must stay
        # loopback and never disclose target/session identifiers to a proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=1.0) as response:
            raw = response.read(MAX_STATE_BYTES + 1)
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
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {"status": "unavailable", "active_turn": None, "detail": exc.__class__.__name__}
    except (ValueError, TypeError) as exc:
        return {"status": "malformed_response", "active_turn": None, "detail": exc.__class__.__name__}


def severity(issues: list[str]) -> str:
    errors = ("duplicate_", "invalid_", "missing_adapter", "malformed", "dead_pid",
              "pid_mismatch", "acceptance_unknown")
    return "error" if any(any(token in issue for token in errors) for issue in issues) else ("warn" if issues else "ok")


def unavailable_seat(row: dict[str, str], reason: str, issues: list[str]) -> dict[str, Any]:
    safe_row = {key: value[:512] for key, value in row.items()}
    scalar = unavailable_scalar(reason)
    return {
        **safe_row, "runtime": None, "operator": False,
        "heartbeat": unavailable_heartbeat(reason),
        "ticker": {**scalar, "pid_alive": None}, "dnd": None,
        "seen_cursor": dict(scalar), "recovery_pending_ordinal": dict(scalar),
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

    for row in rows:
        name_counts[row["name"]] = name_counts.get(row["name"], 0) + 1
        if row["target"] and row["target"] != "-":
            target_counts[row["target"]] = target_counts.get(row["target"], 0) + 1

    seats: list[dict[str, Any]] = []
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

        true_open = indexed_open(engagement, name, 0)
        if state_refused:
            unavailable = "state_symlink_refused"
            issues.append(f"state_unavailable:{unavailable}")
            hb = unavailable_heartbeat(unavailable)
            ticker = {**unavailable_scalar(unavailable), "pid_alive": None}
            seen = unavailable_scalar(unavailable)
            pending_stamp = unavailable_scalar(unavailable)
            next_unseen = {"value": None, "status": f"unavailable:{unavailable}"}
            dnd = None
            delivery = None
        else:
            hb, hb_issues = heartbeat(state, name, now)
            ticker = read_scalar(state / f"heartbeat.{name}.lock" / "pid", root=state)
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

            seen = read_scalar(state / f"seen.{name}", root=state)
            if seen["present"] and seen["parse"] != "ok":
                issues.append("seen:malformed")
            pending_stamp = read_scalar(state / f"pending.{name}", root=state)
            if pending_stamp["present"] and pending_stamp["parse"] != "ok":
                issues.append("pending:malformed")
            seen_value = seen.get("value") if seen.get("parse") == "ok" else 0
            next_unseen = indexed_open(engagement, name, int(seen_value or 0))
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
            "open_pending_ordinal": true_open, "next_unseen_ordinal": next_unseen,
            "session_bindings": seat_bindings, "delivery": delivery,
            "deep_ocean": deep, "issues": sorted(set(issues)),
            "repair": list(dict.fromkeys(repairs)),
        }
        seat["status"] = severity(seat["issues"])
        seats.append(seat)

    pad_issues.extend(binding_issues)
    pad_issues.extend(f"orphan_session:{item['session_id']}->{item['name']}" for item in orphan_bindings)
    watcher = watcher_health(state, pad_md)
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
        "summary": {"seats": len(seats), "ok": len(seats) - errors - warnings,
                    "warnings": warnings, "errors": errors, "pad_status": pad_status,
                    "pad_issues": len(set(pad_issues)), "overall_status": overall_status},
    }


def human(snapshot: dict[str, Any]) -> str:
    pad = snapshot["pad"]
    watcher = pad["watcher"]
    lines = [f"stitchpad health — {snapshot['mode']} read-only snapshot",
             f"watcher: {watcher['status']} pid={watcher['pid']} singleton={watcher['singleton']}"]
    for seat in snapshot["seats"]:
        hb = seat.get("heartbeat", {})
        open_ord = seat.get("open_pending_ordinal", {}).get("value")
        lines.append(
            f"@{seat['name']} [{seat['status']}] {seat['adapter']}/{seat['wake']} target={seat['target']} "
            f"heartbeat={hb.get('progress')} age={hb.get('age_seconds')}s pid={hb.get('pid')}/{hb.get('pid_alive')} "
            f"parent={hb.get('parent_pid')}/{hb.get('parent_alive')} dnd={seat.get('dnd')} "
            f"seen={seat.get('seen_cursor', {}).get('value')} open={open_ord}"
        )
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
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--deep", action="store_true")
    parser.add_argument("-h", "--help", action="help")
    args = parser.parse_args()
    snapshot = build(args)
    if args.json:
        print(json.dumps(snapshot, sort_keys=True, separators=(",", ":"), allow_nan=False))
    else:
        print(human(snapshot))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
