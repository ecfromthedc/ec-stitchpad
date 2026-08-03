#!/usr/bin/env python3
"""Stitchpad autonomous-build coordination helper (durability MVP core).

This module owns every operation that must be exact: scrubbed Git invocation,
native SHA-1/SHA-256 object identity, the validated external payload root, the
retained directory-FD / ``O_NOFOLLOW`` root binding, safe archive extraction and
inventory, the bounded Ocean ``GET /v1/requests`` observation boundary, off-argv
FD capabilities, process-registration evidence, write-once report sealing, and
verified/abandoned closure.

``tool/bin/coordination.sh`` is Bash 3.2 front control only; it validates argument
shape, never reads a capability, and forwards to this helper.

Design of record: ``durability-pr-design-v5.md`` (PASS review
``durability-pr-design-v5-review.md``).

Deliberate non-goals: this is a *cooperative* same-user boundary. It detects
protocol and integrity violations. It does not sandbox a deliberately hostile
same-UID process and it does not prove which Unix process authored a commit.
There is no signal, cleanup, deletion, retry, reassignment, provider mutation,
scheduler, or reconciliation path anywhere in this file.

Targets Apple system Python 3.9 (no 3.10+ syntax or library surface).
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import http.client
import json
import os
import re
import secrets
import select
import stat as statmod
import subprocess
import sys
import time
import unicodedata


# ---------------------------------------------------------------------------
# Section 0. Constants and fixed limits
# ---------------------------------------------------------------------------

PROTOCOL_VERSION = 1
COORD_DIRNAME = "stitchpad-coordination"
COORD_VERSION_DIR = "v1"

DEFAULT_PAYLOAD_BASE_PARENT = "/private/tmp"
DEFAULT_PAYLOAD_BASE_NAME = "stitchpad-review-payloads"
DEFAULT_PAYLOAD_BASE = DEFAULT_PAYLOAD_BASE_PARENT + "/" + DEFAULT_PAYLOAD_BASE_NAME

OCEAN_HOST = "127.0.0.1"
OCEAN_PORT = 4780
OCEAN_PATH = "/v1/requests"

DIR_MODE = 0o700
FILE_MODE = 0o600
EXEC_MODE = 0o700

MAX_RECORD_BYTES = 262144
MAX_TREE_ENTRIES = 20000
MAX_ARCHIVE_BYTES = 134217728
MAX_MEMBER_BYTES = 16777216
MAX_REPORT_BYTES = 262144
MAX_HTTP_BYTES = 1048576
MAX_HTTP_CHUNK = 65536
MAX_PATH_BYTES = 1024
MAX_COMPONENTS = 64
MAX_PROCESSES = 64
MAX_OBSERVATIONS = 4096
MAX_CHECKPOINTS = 4096
MAX_GIT_OUTPUT = 33554432
MAX_DIR_ENTRIES = 20000
MAX_CMD_DISPLAY = 160

TOKEN_HEX_LEN = 64
TOKEN_WIRE_LEN = TOKEN_HEX_LEN + 1  # exact 64 hex + one newline

FD_DEADLINE_SECONDS = 5.0
GIT_TIMEOUT_SECONDS = 120.0
PS_TIMEOUT_SECONDS = 15.0
HTTP_CONNECT_SECONDS = 2.0
HTTP_TOTAL_SECONDS = 5.0

TEST_ROOT_ENV = "STITCHPAD_COORD_TEST_ROOT"
TEST_PORT_ENV = "STITCHPAD_COORD_TEST_PORT"
TEST_PAYLOAD_BASE_ENV = "STITCHPAD_COORD_TEST_PAYLOAD_BASE"
TEST_CRASH_ENV = "STITCHPAD_COORD_TEST_CRASH_AFTER"
TEST_PS_FAKE_ENV = "STITCHPAD_COORD_TEST_PS_FAKE"
TEST_MARKER_NAME = "TEST_MODE_V1"

# Test-only determinism hooks (DeepSeek blueprint W3/W4). Both are honored
# exclusively under a fully validated section-9 test root; in production the
# environment variables are inert.
_TEST_MODE = {"enabled": False, "root": None}


def _enable_test_hooks(base):
    if base.test_root is not None:
        _TEST_MODE["enabled"] = True
        _TEST_MODE["root"] = base.test_root["path"]


def crash_hook(point):
    """Deterministic kill-window crash point for gates 4/18 (test root only)."""
    if not _TEST_MODE["enabled"]:
        return
    if os.environ.get(TEST_CRASH_ENV) == point:
        os._exit(134)


def _ps_fake(args):
    """Deterministic ps substitution for gate 21 (test root only).

    The hook value names a directory directly beneath the validated test root
    holding up to three fixture files: ``lstart`` (for ``-o lstart=``),
    ``detail`` (for ``-o ppid=,pgid=,command=``), and ``table`` (for the
    ``-A`` process table). A missing key file classifies as ``unknown``.
    """
    if not _TEST_MODE["enabled"]:
        return None
    raw = os.environ.get(TEST_PS_FAKE_ENV) or ""
    if not raw:
        return None
    root = _TEST_MODE["root"] + "/"
    if not raw.startswith(root):
        return None
    rel = raw[len(root):]
    if not rel or "/" in rel or rel in (".", ".."):
        return None
    if args and args[0] == "-A":
        key = "table"
    elif any("lstart=" in str(part) for part in args):
        key = "lstart"
    else:
        key = "detail"
    path = raw + "/" + key
    try:
        info = os.lstat(path)
    except OSError:
        return None
    if not statmod.S_ISREG(info.st_mode) or info.st_size > 65536:
        return None
    try:
        with open(path, "rb") as handle:
            return handle.read().decode("utf-8", "replace")
    except OSError:
        return None

HEX_RE = re.compile(r"\A[0-9a-f]+\Z")
TOKEN_RE = re.compile(r"\A[0-9a-f]{64}\Z")
UUID_RE = re.compile(
    r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z"
)
ACTOR_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
ROLE_RE = re.compile(r"\A[a-z][a-z0-9-]{0,31}\Z")
ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")
ENTRY_NAME_RE = re.compile(r"\A[0-9a-f]{32}\.[0-9a-f]{16}\Z")
REF_RE = re.compile(r"\Arefs/[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\Z")

VERDICTS = ("PASS", "HOLD", "FAIL")

# Exact Ocean raw states and their projections (section 9 of the design).
OCEAN_STATE_TABLE = {
    "queued": ("accepted", False),
    "running": ("running", False),
    "waiting_for_permission": ("waiting", False),
    "cancelling": ("cancel_pending", False),
    "completed": ("completed", True),
    "errored": ("failed", True),
    "cancelled": ("canceled", True),
}
TERMINAL_COMPLETIONS = ("completed", "failed", "canceled")

# Safe local Git overrides. Only built-in subcommands are ever invoked.
GIT_SAFE_CONFIG = (
    "-c", "core.fileMode=true",
    "-c", "core.fsmonitor=false",
    "-c", "core.untrackedCache=false",
    "-c", "core.hooksPath=/dev/null",
    "-c", "submodule.recurse=false",
    "-c", "core.ignoreCase=false",
    "-c", "core.precomposeUnicode=false",
    "-c", "core.protectHFS=true",
    "-c", "core.protectNTFS=true",
)

KIND_DIR = 1
KIND_FILE = 2
KIND_LINK = 3

GIT_MODE_DIR = 0o40000
GIT_MODE_FILE = 0o100644
GIT_MODE_EXEC = 0o100755
GIT_MODE_LINK = 0o120000


class CoordError(Exception):
    """Every refusal is an exact machine code plus bounded human detail."""

    def __init__(self, code, detail="", extra=None):
        Exception.__init__(self, "%s: %s" % (code, detail) if detail else code)
        self.code = code
        self.detail = detail
        self.extra = extra or {}


def fail(code, detail="", **extra):
    raise CoordError(code, detail, extra)


# ---------------------------------------------------------------------------
# Section 1. Strict parsing, validators, digests
# ---------------------------------------------------------------------------

def _reject_duplicate_keys(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            fail("json_duplicate_key", "duplicate key %r" % (key,))
        out[key] = value
    return out


def strict_json_loads(text):
    if isinstance(text, bytes):
        try:
            text = text.decode("utf-8")
        except UnicodeDecodeError:
            fail("json_not_utf8", "payload is not valid UTF-8")
    try:
        return json.loads(text, object_pairs_hook=_reject_duplicate_keys)
    except CoordError:
        raise
    except ValueError as exc:
        fail("json_malformed", str(exc)[:200])


def canonical_json_bytes(obj):
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii") + b"\n"


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def length_prefixed(*parts):
    out = b""
    for part in parts:
        if isinstance(part, str):
            part = part.encode("utf-8")
        out += len(part).to_bytes(8, "big") + part
    return out


def hash_key(*parts):
    return hashlib.sha256(length_prefixed(*parts)).hexdigest()


def blob_hasher(algo):
    if algo == "sha1":
        return hashlib.sha1()
    if algo == "sha256":
        return hashlib.sha256()
    fail("object_format_unsupported", "algorithm %r" % (algo,))


def blob_oid_bytes(algo, data):
    hasher = blob_hasher(algo)
    hasher.update(("blob %d\0" % len(data)).encode("ascii"))
    hasher.update(data)
    return hasher.hexdigest()


def oid_hex_len(algo):
    return 40 if algo == "sha1" else 64


def require_oid(value, algo, what="oid"):
    if not isinstance(value, str) or len(value) != oid_hex_len(algo):
        fail("oid_not_full", "%s must be exactly %d lowercase hex characters"
             % (what, oid_hex_len(algo)))
    if not HEX_RE.match(value):
        fail("oid_not_full", "%s is not lowercase hex" % (what,))
    return value


def require_match(pattern, value, code, what):
    if not isinstance(value, str) or not pattern.match(value):
        fail(code, "invalid %s" % (what,))
    return value


def require_int(value, low, high, code, what):
    if isinstance(value, bool) or not isinstance(value, int):
        fail(code, "%s must be an integer" % (what,))
    if value < low or value > high:
        fail(code, "%s out of range" % (what,))
    return value


def bounded(text, limit):
    if text is None:
        return ""
    if not isinstance(text, str):
        text = str(text)
    text = "".join(ch if ch.isprintable() else "." for ch in text)
    return text[:limit]


def nfd_casefold(text):
    return unicodedata.normalize("NFD", text).casefold()


# ---------------------------------------------------------------------------
# Section 2. Off-argv FD capabilities
# ---------------------------------------------------------------------------

def _fd_flags(fd):
    try:
        return fcntl.fcntl(fd, fcntl.F_GETFL)
    except OSError as exc:
        fail("fd_unusable", "F_GETFL failed: %s" % (exc.strerror,))


def _fd_stat(fd, what):
    try:
        return os.fstat(fd)
    except OSError as exc:
        fail("fd_unusable", "%s fstat failed: %s" % (what, exc.strerror))


def _require_regular_capability_fd(fd, info, what):
    if info.st_uid != os.getuid():
        fail("fd_owner_mismatch", "%s is not owned by the current user" % (what,))
    perm = statmod.S_IMODE(info.st_mode)
    if perm & ~0o600:
        fail("fd_mode_too_broad", "%s mode must be no broader than 0600" % (what,))
    if info.st_nlink != 1:
        fail("fd_extra_links", "%s has extra hard links" % (what,))
    try:
        offset = os.lseek(fd, 0, os.SEEK_CUR)
    except OSError as exc:
        fail("fd_unusable", "%s is not seekable: %s" % (what, exc.strerror))
    if offset != 0:
        fail("fd_offset_nonzero", "%s offset must be zero" % (what,))


def write_capability_fd(fd, token):
    """Write exactly 64 lowercase hex plus one newline. Never truncate."""
    require_match(TOKEN_RE, token, "capability_malformed", "capability")
    info = _fd_stat(fd, "capability output fd")
    flags = _fd_flags(fd)
    accmode = flags & os.O_ACCMODE
    if accmode not in (os.O_WRONLY, os.O_RDWR):
        fail("fd_not_writable", "capability output fd is not writable")
    if flags & os.O_APPEND:
        fail("fd_append_mode", "capability output fd must not be append-mode")
    payload = (token + "\n").encode("ascii")
    if statmod.S_ISREG(info.st_mode):
        _require_regular_capability_fd(fd, info, "capability output fd")
        if info.st_size != 0:
            fail("fd_not_empty", "capability output fd must be empty")
        written = 0
        while written < len(payload):
            written += os.write(fd, payload[written:])
        os.fsync(fd)
        return
    if statmod.S_ISFIFO(info.st_mode):
        _pipe_write_exact(fd, payload)
        return
    fail("fd_type_rejected", "capability output fd must be a regular file or pipe")


def _pipe_write_exact(fd, payload):
    deadline = time.monotonic() + FD_DEADLINE_SECONDS
    old = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, old | os.O_NONBLOCK)
    try:
        written = 0
        while written < len(payload):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("fd_deadline", "capability pipe write deadline exceeded")
            ready = select.select([], [fd], [], min(remaining, 0.25))[1]
            if not ready:
                continue
            try:
                written += os.write(fd, payload[written:])
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                fail("fd_unusable", "capability pipe write failed: %s" % (exc.strerror,))
    finally:
        fcntl.fcntl(fd, fcntl.F_SETFL, old)


def read_capability_fd(fd):
    """Read exactly 64 lowercase hex plus one newline, then require EOF."""
    info = _fd_stat(fd, "capability input fd")
    flags = _fd_flags(fd)
    accmode = flags & os.O_ACCMODE
    if accmode not in (os.O_RDONLY, os.O_RDWR):
        fail("fd_not_readable", "capability input fd is not readable")
    if statmod.S_ISREG(info.st_mode):
        _require_regular_capability_fd(fd, info, "capability input fd")
        if info.st_size != TOKEN_WIRE_LEN:
            fail("fd_size_mismatch", "capability input fd must hold exactly %d bytes"
                 % (TOKEN_WIRE_LEN,))
        raw = b""
        while len(raw) < TOKEN_WIRE_LEN:
            chunk = os.read(fd, TOKEN_WIRE_LEN - len(raw))
            if not chunk:
                fail("fd_short_read", "capability input fd ended early")
            raw += chunk
        if os.read(fd, 1):
            fail("fd_trailing_bytes", "capability input fd has trailing bytes")
    elif statmod.S_ISFIFO(info.st_mode):
        raw = _pipe_read_exact(fd, TOKEN_WIRE_LEN)
    else:
        fail("fd_type_rejected", "capability input fd must be a regular file or pipe")
    if len(raw) != TOKEN_WIRE_LEN or raw[-1:] != b"\n":
        fail("capability_malformed", "capability wire format mismatch")
    try:
        token = raw[:TOKEN_HEX_LEN].decode("ascii")
    except UnicodeDecodeError:
        fail("capability_malformed", "capability is not ASCII")
    require_match(TOKEN_RE, token, "capability_malformed", "capability")
    return token


def _pipe_read_exact(fd, count):
    """Read until EOF within one monotonic total deadline, then require that
    the complete stream is exactly ``count`` bytes.

    An open writer that never closes fails as ``fd_deadline``; any byte beyond
    ``count`` fails as ``fd_trailing_bytes``; EOF early fails as
    ``fd_short_read``. There is no acceptance without explicit EOF.
    """
    deadline = time.monotonic() + FD_DEADLINE_SECONDS
    old = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, old | os.O_NONBLOCK)
    try:
        raw = b""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("fd_deadline",
                     "capability pipe deadline exceeded before EOF")
            ready = select.select([fd], [], [], min(remaining, 0.25))[0]
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                fail("fd_unusable", "capability pipe read failed: %s" % (exc.strerror,))
            if not chunk:
                break  # explicit EOF: the writer closed its end
            raw += chunk
            if len(raw) > count:
                fail("fd_trailing_bytes",
                     "capability pipe carries more than %d bytes" % (count,))
        if len(raw) != count:
            fail("fd_short_read",
                 "capability pipe ended after %d bytes, expected %d"
                 % (len(raw), count))
        return raw
    finally:
        fcntl.fcntl(fd, fcntl.F_SETFL, old)


def mint_capability():
    """Return (token, verifier-record). Only the verifier is ever stored."""
    token = secrets.token_hex(32)
    salt = secrets.token_hex(16)
    return token, {
        "salt": salt,
        "verifier": hash_key(salt, token),
        "algorithm": "sha256-length-prefixed-v1",
    }


def capability_matches(record, token):
    if not isinstance(record, dict):
        return False
    salt = record.get("salt")
    verifier = record.get("verifier")
    if not isinstance(salt, str) or not isinstance(verifier, str):
        return False
    if record.get("algorithm") != "sha256-length-prefixed-v1":
        return False
    return secrets.compare_digest(hash_key(salt, token), verifier)


# ---------------------------------------------------------------------------
# Section 3. Retained-FD filesystem primitives
# ---------------------------------------------------------------------------

REQUIRED_DIR_FD_FUNCS = (
    os.open, os.mkdir, os.stat, os.unlink, os.rmdir, os.rename, os.link,
    os.symlink, os.readlink,
)


def assert_platform_support():
    for func in REQUIRED_DIR_FD_FUNCS:
        if func not in os.supports_dir_fd:
            fail("platform_unsupported",
                 "os.%s lacks dir_fd support" % (func.__name__,))
    if os.stat not in os.supports_follow_symlinks:
        fail("platform_unsupported", "os.stat lacks follow_symlinks support")


class FDSet(object):
    """Retains directory FDs for the whole duration of one operation."""

    def __init__(self):
        self._fds = []

    def keep(self, fd):
        self._fds.append(fd)
        return fd

    def close_all(self):
        while self._fds:
            fd = self._fds.pop()
            try:
                os.close(fd)
            except OSError:
                pass

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close_all()
        return False


def identity(info):
    if statmod.S_ISDIR(info.st_mode):
        kind = "directory"
    elif statmod.S_ISREG(info.st_mode):
        kind = "regular"
    elif statmod.S_ISLNK(info.st_mode):
        kind = "symlink"
    else:
        kind = "other"
    return {"dev": info.st_dev, "ino": info.st_ino, "type": kind}


def same_identity(left, right):
    if not isinstance(left, dict) or not isinstance(right, dict):
        return False
    for key in ("dev", "ino", "type"):
        if left.get(key) != right.get(key):
            return False
    return True


def lstat_at(dir_fd, name, code="path_missing", what=None):
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError as exc:
        fail(code, "%s: %s" % (what or name, exc.strerror))


def try_lstat_at(dir_fd, name):
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return None


def open_dir_at(dir_fd, name, code="dir_open_failed", what=None):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        return os.open(name, flags, dir_fd=dir_fd)
    except OSError as exc:
        fail(code, "%s: %s" % (what or name, exc.strerror))


def open_file_at(dir_fd, name, code="file_open_failed", what=None):
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        return os.open(name, flags, dir_fd=dir_fd)
    except OSError as exc:
        fail(code, "%s: %s" % (what or name, exc.strerror))


def bind_dir_at(fds, dir_fd, name, expect=None, what=None, code="root_replaced"):
    """lstat -> O_NOFOLLOW open -> fstat, with optional stable-identity match."""
    entry = lstat_at(dir_fd, name, code=code, what=what)
    if not statmod.S_ISDIR(entry.st_mode):
        fail(code, "%s is not a directory" % (what or name,))
    fd = fds.keep(open_dir_at(dir_fd, name, code=code, what=what))
    opened = os.fstat(fd)
    if identity(entry) != identity(opened):
        fail(code, "%s changed between lstat and open" % (what or name,))
    if expect is not None and not same_identity(identity(opened), expect):
        fail(code, "%s identity does not match the recorded root" % (what or name,))
    return fd, identity(opened)


def require_owned_dir(info, expect_mode, what, code="unsafe_mode"):
    if info.st_uid != os.getuid():
        fail("unsafe_owner", "%s is not owned by the current user" % (what,))
    if statmod.S_IMODE(info.st_mode) != expect_mode:
        fail(code, "%s mode is not %04o" % (what, expect_mode))


def mkdir_owned(dir_fd, name, mode=DIR_MODE):
    try:
        os.mkdir(name, mode, dir_fd=dir_fd)
    except FileExistsError:
        return False
    except OSError as exc:
        fail("mkdir_failed", "%s: %s" % (name, exc.strerror))
    return True


def ensure_owned_dir(fds, dir_fd, name, what, mode=DIR_MODE):
    """Create-if-absent then bind with exact owner/mode. Never follows a link.

    An existing entry with a foreign owner, wrong mode, symlink type, or an
    unstable identity fails closed; the helper never repairs foreign state.
    """
    created = False
    old_mask = os.umask(0o077)
    try:
        created = mkdir_owned(dir_fd, name, mode)
    finally:
        os.umask(old_mask)
    entry = lstat_at(dir_fd, name, code="unsafe_path", what=what)
    if statmod.S_ISLNK(entry.st_mode) or not statmod.S_ISDIR(entry.st_mode):
        fail("unsafe_path", "%s is not a real directory" % (what,))
    fd = fds.keep(open_dir_at(dir_fd, name, code="unsafe_path", what=what))
    opened = os.fstat(fd)
    if identity(entry) != identity(opened):
        fail("unsafe_path", "%s changed between lstat and open" % (what,))
    if statmod.S_IMODE(opened.st_mode) != mode:
        if not created:
            fail("unsafe_mode", "%s mode is not %04o" % (what, mode))
        os.fchmod(fd, mode)
        opened = os.fstat(fd)
    require_owned_dir(opened, mode, what)
    return fd, identity(opened)


def fsync_dir(fd):
    try:
        os.fsync(fd)
    except OSError:
        # Directory fsync is best-effort on some filesystems; publication
        # ordering (temp -> rename -> READY) still holds.
        pass


def write_file_at(dir_fd, name, data, mode=FILE_MODE):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        fd = os.open(name, flags, mode, dir_fd=dir_fd)
    except OSError as exc:
        fail("write_failed", "%s: %s" % (name, exc.strerror))
    try:
        written = 0
        while written < len(data):
            written += os.write(fd, data[written:])
        os.fchmod(fd, mode)
        os.fsync(fd)
        info = os.fstat(fd)
    finally:
        os.close(fd)
    if info.st_nlink != 1:
        fail("write_failed", "%s gained hard links" % (name,))
    return identity(info)


def read_file_at(dir_fd, name, limit, what=None, require_mode=True):
    fd = open_file_at(dir_fd, name, code="record_missing", what=what)
    try:
        info = os.fstat(fd)
        if not statmod.S_ISREG(info.st_mode):
            fail("record_invalid", "%s is not a regular file" % (what or name,))
        if info.st_uid != os.getuid():
            fail("record_invalid", "%s is not owned by the current user" % (what or name,))
        if require_mode and statmod.S_IMODE(info.st_mode) & ~0o600:
            fail("record_invalid", "%s mode is broader than 0600" % (what or name,))
        if info.st_size > limit:
            fail("record_invalid", "%s exceeds %d bytes" % (what or name, limit))
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
            if len(data) > limit:
                fail("record_invalid", "%s exceeds %d bytes" % (what or name, limit))
        return data
    finally:
        os.close(fd)


def atomic_publish(dir_fd, name, data, mode=FILE_MODE):
    tmp = ".tmp.%s.%s" % (name, secrets.token_hex(8))
    write_file_at(dir_fd, name=tmp, data=data, mode=mode)
    try:
        os.rename(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError as exc:
        try:
            os.unlink(tmp, dir_fd=dir_fd)
        except OSError:
            pass
        fail("publish_failed", "%s: %s" % (name, exc.strerror))
    fsync_dir(dir_fd)


def list_dir_at(dir_fd, what="directory"):
    dup = os.dup(dir_fd)
    try:
        names = os.listdir(dup)
    except OSError as exc:
        os.close(dup)
        fail("dir_read_failed", "%s: %s" % (what, exc.strerror))
    else:
        os.close(dup)
    if len(names) > MAX_DIR_ENTRIES:
        fail("dir_too_large", "%s has too many entries" % (what,))
    names.sort()
    return names


def remove_owned_scratch(parent_fd, name, depth=0):
    """Bounded removal of a helper-created scratch tree.

    This exists only for the per-invocation scrubbed-Git HOME/XDG root that this
    helper itself creates. It never follows a symlink, never crosses into a
    directory it did not just stat as a real owned directory, is depth- and
    count-bounded, and is never reachable from any CLI verb. It is not a
    cleanup/prune facility for coordination state or review payloads.
    """
    if depth > 4:
        return
    info = try_lstat_at(parent_fd, name)
    if info is None:
        return
    if statmod.S_ISLNK(info.st_mode) or not statmod.S_ISDIR(info.st_mode):
        try:
            os.unlink(name, dir_fd=parent_fd)
        except OSError:
            pass
        return
    if info.st_uid != os.getuid():
        return
    try:
        fd = open_dir_at(parent_fd, name)
    except CoordError:
        return
    try:
        dup = os.dup(fd)
        try:
            entries = os.listdir(dup)
        finally:
            os.close(dup)
        if len(entries) > 512:
            return
        for entry in entries:
            remove_owned_scratch(fd, entry, depth + 1)
    except OSError:
        return
    finally:
        os.close(fd)
    try:
        os.rmdir(name, dir_fd=parent_fd)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Section 4. Validated external payload root (exact component policy)
# ---------------------------------------------------------------------------

class PayloadBase(object):
    def __init__(self, path, fd, ident, fds, test_root=None):
        self.path = path
        self.fd = fd
        self.identity = ident
        self.fds = fds
        self.test_root = test_root


def _bind_trusted_root_component(fds, parent_fd, name, path, allow_sticky=False):
    """Root-owned ancestor: real directory, uid 0, never group/other writable."""
    entry = lstat_at(parent_fd, name, code="unsafe_ancestor", what=path)
    if statmod.S_ISLNK(entry.st_mode):
        fail("unsafe_ancestor", "%s is a symlink" % (path,))
    if not statmod.S_ISDIR(entry.st_mode):
        fail("unsafe_ancestor", "%s is not a real directory" % (path,))
    fd = fds.keep(open_dir_at(parent_fd, name, code="unsafe_ancestor", what=path))
    opened = os.fstat(fd)
    if identity(entry) != identity(opened):
        fail("unsafe_ancestor", "%s changed between lstat and open" % (path,))
    if opened.st_uid != 0:
        fail("unsafe_ancestor", "%s is not root-owned" % (path,))
    mode = statmod.S_IMODE(opened.st_mode)
    if allow_sticky:
        # The single narrow exception: the canonical sticky temporary directory.
        if mode != 0o1777:
            fail("unsafe_ancestor",
                 "%s must be the canonical sticky 01777 temporary directory" % (path,))
    else:
        if mode & 0o022:
            fail("unsafe_ancestor", "%s is group- or world-writable" % (path,))
    return fd, identity(opened)


def bind_private_tmp(fds):
    """Bind / -> /private -> /private/tmp with exact component trust."""
    root_fd = fds.keep(open_dir_at(None, "/", code="unsafe_ancestor", what="/"))
    root_info = os.fstat(root_fd)
    if root_info.st_uid != 0:
        fail("unsafe_ancestor", "/ is not root-owned")
    if statmod.S_IMODE(root_info.st_mode) & 0o022:
        fail("unsafe_ancestor", "/ is group- or world-writable")
    if not statmod.S_ISDIR(root_info.st_mode):
        fail("unsafe_ancestor", "/ is not a directory")
    private_fd, _ = _bind_trusted_root_component(fds, root_fd, "private", "/private")
    tmp_fd, tmp_id = _bind_trusted_root_component(
        fds, private_fd, "tmp", "/private/tmp", allow_sticky=True
    )
    return tmp_fd, tmp_id


def _test_mode_root(fds, tmp_fd):
    """Honor a test root only when every section-9 precondition holds."""
    raw = os.environ.get(TEST_ROOT_ENV) or ""
    if not raw:
        return None
    prefix = DEFAULT_PAYLOAD_BASE_PARENT + "/"
    if not raw.startswith(prefix):
        fail("test_root_rejected",
             "%s must be directly beneath %s" % (TEST_ROOT_ENV, DEFAULT_PAYLOAD_BASE_PARENT))
    name = raw[len(prefix):]
    if not name or "/" in name or name in (".", ".."):
        fail("test_root_rejected", "%s must be a single literal child name" % (TEST_ROOT_ENV,))
    entry = lstat_at(tmp_fd, name, code="test_root_rejected", what=raw)
    if statmod.S_ISLNK(entry.st_mode) or not statmod.S_ISDIR(entry.st_mode):
        fail("test_root_rejected", "%s is not a real directory" % (raw,))
    fd = fds.keep(open_dir_at(tmp_fd, name, code="test_root_rejected", what=raw))
    opened = os.fstat(fd)
    if identity(entry) != identity(opened):
        fail("test_root_rejected", "%s changed between lstat and open" % (raw,))
    require_owned_dir(opened, DIR_MODE, raw, code="test_root_rejected")
    marker = lstat_at(fd, TEST_MARKER_NAME, code="test_root_rejected",
                      what="%s/%s" % (raw, TEST_MARKER_NAME))
    if not statmod.S_ISREG(marker.st_mode):
        fail("test_root_rejected", "test-mode marker is not a regular file")
    if marker.st_uid != os.getuid() or statmod.S_IMODE(marker.st_mode) != FILE_MODE:
        fail("test_root_rejected", "test-mode marker must be a current-UID 0600 file")
    return {"path": raw, "fd": fd, "identity": identity(opened)}


def open_payload_base(fds):
    """Return the validated payload base with retained ancestor FDs."""
    assert_platform_support()
    tmp_fd, _ = bind_private_tmp(fds)
    test_root = _test_mode_root(fds, tmp_fd)

    if test_root is not None:
        raw = os.environ.get(TEST_PAYLOAD_BASE_ENV) or ""
        if raw:
            prefix = test_root["path"] + "/"
            if not raw.startswith(prefix):
                fail("payload_base_rejected",
                     "%s must be a direct child of the test root" % (TEST_PAYLOAD_BASE_ENV,))
            name = raw[len(prefix):]
            if not name or "/" in name or name in (".", ".."):
                fail("payload_base_rejected",
                     "%s must be a single literal child name" % (TEST_PAYLOAD_BASE_ENV,))
            parent_fd = test_root["fd"]
            base_path = raw
        else:
            parent_fd = test_root["fd"]
            name = DEFAULT_PAYLOAD_BASE_NAME
            base_path = test_root["path"] + "/" + name
    else:
        if os.environ.get(TEST_PAYLOAD_BASE_ENV) or os.environ.get(TEST_PORT_ENV):
            fail("test_override_rejected",
                 "test overrides require a fully validated %s" % (TEST_ROOT_ENV,))
        parent_fd = tmp_fd
        name = DEFAULT_PAYLOAD_BASE_NAME
        base_path = DEFAULT_PAYLOAD_BASE

    fd, ident = ensure_owned_dir(fds, parent_fd, name, base_path, mode=DIR_MODE)
    _reject_git_component_chain(base_path)
    return PayloadBase(base_path, fd, ident, fds, test_root)


def _reject_git_component_chain(path):
    for component in path.split("/"):
        if not component:
            continue
        if nfd_casefold(component) == ".git":
            fail("unsafe_ancestor", "path component %r normalizes to .git" % (component,))


def assert_payload_outside_repo(base_path, payload_path, repo):
    """Payload must not equal, contain, or live inside any repository path."""
    protected = [repo["top"], repo["common_dir"]] + list(repo.get("worktrees", []))
    for candidate in (base_path, payload_path):
        for guard in protected:
            if not guard:
                continue
            if candidate == guard:
                fail("payload_inside_repo", "payload path equals a repository path")
            if candidate.startswith(guard.rstrip("/") + "/"):
                fail("payload_inside_repo", "payload path is inside a repository path")
            if guard.startswith(candidate.rstrip("/") + "/"):
                fail("payload_inside_repo", "payload path contains a repository path")


def assert_no_git_discovery(path, git_home):
    """Scrubbed Git, without any ceiling, must not discover a repository here."""
    result = git_raw(
        ["-C", path, "rev-parse", "--show-toplevel"], git_home, check=False, ceiling=None
    )
    if result["rc"] == 0 and result["out"].strip():
        fail("payload_git_discoverable",
             "a Git worktree is discoverable at or above the payload base")
    result = git_raw(
        ["-C", path, "rev-parse", "--git-dir"], git_home, check=False, ceiling=None
    )
    if result["rc"] == 0 and result["out"].strip():
        fail("payload_git_discoverable",
             "a Git directory is discoverable at or above the payload base")


def reviewer_ceiling(base):
    """Helper-derived reviewer launch ceiling (DeepSeek blueprint P0/W1).

    Probed against Apple Git 2.50.1: with the reviewer's cwd *equal* to the
    ceiling, Git still walks upward and discovers an ancestor repository, so a
    ceiling of ``src`` cannot protect gates 8/12. The ceiling is therefore the
    canonical payload *base* — the root-most helper-owned directory, itself
    proven ``.git``-free by base validation — never caller-provided, never the
    src directory. The launch wrapper (deferred to the review-core increment)
    sets ``GIT_CEILING_DIRECTORIES`` to exactly this value plus
    ``GIT_DISCOVERY_ACROSS_FILESYSTEM=0``.
    """
    return base.path


# ---------------------------------------------------------------------------
# Section 5. Scrubbed Git, canonical identity, clean worktrees
# ---------------------------------------------------------------------------

# Every helper-created scratch root and retained FD set is registered here so
# that `main` can dispose of exactly what this process created on EVERY exit
# path, including refusals. Before this ledger existed, any CoordError raised
# after `make_git_home` stranded a `scrub.<16hex>` directory under the payload
# base forever (observed residue; see docs/AUTONOMOUS-BUILDS.md section on the
# scratch ledger). Disposal is bounded, no-follow, current-UID only, and never
# touches anything this process did not create.
_SCRATCH = {"homes": [], "fdsets": []}


def release_owned_scratch_ledger():
    while _SCRATCH["homes"]:
        home = _SCRATCH["homes"].pop()
        try:
            home.release()
        except Exception:
            pass
    while _SCRATCH["fdsets"]:
        fds = _SCRATCH["fdsets"].pop()
        try:
            fds.close_all()
        except Exception:
            pass


class GitHome(object):
    """A fresh helper-owned HOME/XDG root for every scrubbed Git subprocess."""

    def __init__(self, base_fd, base_path, name):
        self.base_fd = base_fd
        self.base_path = base_path
        self.name = name
        self.path = base_path + "/" + name
        self.released = False

    def release(self):
        if self.released:
            return
        self.released = True
        remove_owned_scratch(self.base_fd, self.name)


def make_git_home(fds, base):
    name = "scrub.%s" % (secrets.token_hex(8),)
    old_mask = os.umask(0o077)
    try:
        if not mkdir_owned(base.fd, name, DIR_MODE):
            fail("scratch_exists", "scrubbed Git home collided")
        fd = fds.keep(open_dir_at(base.fd, name, code="unsafe_path", what=name))
        os.fchmod(fd, DIR_MODE)
        for child in ("config", "cache", "data", "state"):
            mkdir_owned(fd, child, DIR_MODE)
    finally:
        os.umask(old_mask)
    home = GitHome(base.fd, base.path, name)
    _SCRATCH["homes"].append(home)
    return home


def git_env(git_home, ceiling=None):
    env = {}
    for key, value in os.environ.items():
        if key.startswith("GIT_"):
            continue
        env[key] = value
    home = git_home.path if git_home is not None else None
    if home:
        env["HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/config"
        env["XDG_CACHE_HOME"] = home + "/cache"
        env["XDG_DATA_HOME"] = home + "/data"
        env["XDG_STATE_HOME"] = home + "/state"
        env["TMPDIR"] = home
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_ASKPASS"] = "/bin/false"
    env["GIT_ATTR_NOSYSTEM"] = "1"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_PAGER"] = "cat"
    env["GIT_FLUSH"] = "1"
    env["LC_ALL"] = "C"
    env["LANG"] = "C"
    if ceiling is not None:
        env["GIT_CEILING_DIRECTORIES"] = ceiling
        env["GIT_DISCOVERY_ACROSS_FILESYSTEM"] = "0"
    return env


def git_raw(args, git_home, check=True, ceiling=None, limit=MAX_GIT_OUTPUT,
            binary=False):
    argv = ["git"] + list(GIT_SAFE_CONFIG) + list(args)
    try:
        proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL, env=git_env(git_home, ceiling), cwd="/",
            close_fds=True,
        )
    except OSError as exc:
        fail("git_unavailable", "cannot run git: %s" % (exc.strerror,))
    try:
        out, err = proc.communicate(timeout=GIT_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        fail("git_timeout", "git %s timed out" % (args[0] if args else "",))
    if len(out) > limit:
        fail("git_output_too_large", "git output exceeded %d bytes" % (limit,))
    result = {
        "rc": proc.returncode,
        "raw": out,
        "err": bounded(err.decode("utf-8", "replace"), 400),
    }
    if not binary:
        result["out"] = out.decode("utf-8", "replace")
    else:
        result["out"] = ""
    if check and proc.returncode != 0:
        fail("git_failed", "git %s failed: %s"
             % (" ".join(str(a) for a in args[:3]), result["err"]))
    return result


def git_line(args, git_home, ceiling=None, check=True):
    result = git_raw(args, git_home, check=check, ceiling=ceiling)
    if result["rc"] != 0:
        return None
    return result["out"].strip()


def canonical_dir(path):
    """cd -P / pwd -P equivalent, without realpath(1) or readlink -f."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    except OSError as exc:
        fail("path_unresolvable", "%s: %s" % (path, exc.strerror))
    try:
        saved = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fchdir(fd)
            resolved = os.getcwd()
        finally:
            os.fchdir(saved)
            os.close(saved)
    finally:
        os.close(fd)
    return resolved


def resolve_repo(path, git_home):
    """Canonical top-level is the worktree identity, never a subdirectory."""
    if not isinstance(path, str) or not path:
        fail("worktree_invalid", "worktree path is required")
    if not os.path.isdir(path):
        fail("worktree_invalid", "%s is not a directory" % (bounded(path, 200),))
    top = git_line(["-C", path, "rev-parse", "--show-toplevel"], git_home, check=False)
    if not top:
        fail("not_a_worktree", "%s is not inside a Git worktree" % (bounded(path, 200),))
    top = canonical_dir(top)

    common = git_line(["-C", top, "rev-parse", "--git-common-dir"], git_home, check=False)
    if not common:
        fail("not_a_worktree", "cannot resolve the Git common directory")
    if not common.startswith("/"):
        common = top + "/" + common
    common = canonical_dir(common)

    algo = git_line(["-C", top, "rev-parse", "--show-object-format"], git_home, check=False)
    if algo not in ("sha1", "sha256"):
        fail("object_format_unsupported", "unsupported object format %r" % (algo,))

    head = git_line(["-C", top, "rev-parse", "--verify", "--quiet", "HEAD"],
                    git_home, check=False)
    tree = git_line(["-C", top, "rev-parse", "--verify", "--quiet", "HEAD^{tree}"],
                    git_home, check=False)
    if not head or not tree:
        fail("head_unborn", "worktree HEAD does not resolve to a commit")
    require_oid(head, algo, "HEAD")
    require_oid(tree, algo, "HEAD tree")

    ref = git_line(["-C", top, "symbolic-ref", "-q", "HEAD"], git_home, check=False)
    if ref:
        require_match(REF_RE, ref, "ref_invalid", "HEAD ref")
    else:
        ref = None

    worktrees = []
    listing = git_raw(["-C", top, "worktree", "list", "--porcelain"],
                      git_home, check=False)
    if listing["rc"] == 0:
        for line in listing["out"].splitlines():
            if line.startswith("worktree "):
                candidate = line[len("worktree "):].strip()
                if candidate:
                    worktrees.append(candidate)

    repo_id = hash_key(common)
    return {
        "algo": algo,
        "top": top,
        "common_dir": common,
        "repo_id": repo_id,
        "head": head,
        "tree": tree,
        "ref": ref,
        "detached": ref is None,
        "worktrees": worktrees,
        "worktree_key": hash_key(repo_id, top),
        "ref_key": hash_key(repo_id, ref) if ref else None,
    }


def require_native_commit(repo, oid, git_home, what="commit"):
    require_oid(oid, repo["algo"], what)
    resolved = git_line(
        ["-C", repo["top"], "rev-parse", "--verify", "--quiet",
         "--end-of-options", oid + "^{commit}"], git_home, check=False
    )
    if resolved != oid:
        fail("commit_not_native", "%s is not a commit object in this repository" % (what,))
    kind = git_line(["-C", repo["top"], "cat-file", "-t", "--", oid],
                    git_home, check=False)
    if kind != "commit":
        fail("commit_not_native", "%s does not name a commit" % (what,))
    return oid


DIRT_CATEGORIES = (
    "staged", "unstaged", "unmerged", "deleted", "typechange", "modechange",
    "untracked",
)


def clean_scan(repo, git_home):
    """Refuse staged, unstaged, mode/type, deleted, untracked, ignored-looking dirt."""
    counts = dict((name, 0) for name in DIRT_CATEGORIES)
    digest_parts = []

    def consume(raw, staged):
        fields = raw.split(b"\0")
        index = 0
        while index < len(fields):
            head = fields[index]
            if not head:
                index += 1
                continue
            if not head.startswith(b":"):
                index += 1
                continue
            parts = head[1:].split(b" ")
            if len(parts) < 5:
                fail("scan_malformed", "unexpected git diff-index output")
            src_mode = parts[0]
            dst_mode = parts[1]
            status = parts[4]
            index += 1
            if index >= len(fields):
                fail("scan_malformed", "truncated git diff-index output")
            path = fields[index]
            index += 1
            code = status[:1]
            if code in (b"R", b"C"):
                if index >= len(fields):
                    fail("scan_malformed", "truncated rename record")
                index += 1
            digest_parts.append(length_prefixed(
                b"staged" if staged else b"worktree", src_mode, dst_mode, status, path
            ))
            if code == b"U":
                counts["unmerged"] += 1
            elif code == b"D":
                counts["deleted"] += 1
            elif code == b"T":
                counts["typechange"] += 1
            elif src_mode != dst_mode and dst_mode != b"000000":
                counts["modechange"] += 1
            elif staged:
                counts["staged"] += 1
            else:
                counts["unstaged"] += 1

    staged_raw = git_raw(
        ["-C", repo["top"], "diff-index", "--cached", "--raw", "-z",
         "--no-textconv", "--no-ext-diff", repo["head"], "--"],
        git_home, binary=True,
    )["raw"]
    worktree_raw = git_raw(
        ["-C", repo["top"], "diff-index", "--raw", "-z",
         "--no-textconv", "--no-ext-diff", repo["head"], "--"],
        git_home, binary=True,
    )["raw"]
    consume(staged_raw, True)
    consume(worktree_raw, False)

    # No exclude-standard: an ignored-looking untracked path is dirt too.
    others = git_raw(["-C", repo["top"], "ls-files", "--others", "-z"],
                     git_home, binary=True)["raw"]
    for path in others.split(b"\0"):
        if not path:
            continue
        counts["untracked"] += 1
        digest_parts.append(length_prefixed(b"other", path))

    total = sum(counts.values())
    digest = sha256_hex(b"".join(sorted(digest_parts)))
    return {"clean": total == 0, "total": total, "counts": counts, "digest": digest}


def require_clean(repo, git_home, operation):
    scan = clean_scan(repo, git_home)
    if not scan["clean"]:
        raise CoordError(
            "worktree_dirty",
            "%s requires a clean worktree (%d dirty entries)" % (operation, scan["total"]),
            {"scan": scan},
        )
    return scan


# ---------------------------------------------------------------------------
# Section 6. State root, records, transition mutex
# ---------------------------------------------------------------------------

RECORD_SCHEMAS = {
    "lease": (
        "version", "kind", "generation", "lease_id", "repo_id", "top", "common_dir",
        "actor", "algo", "ref", "detached", "base_head", "expected_head",
        "expected_tree", "capability", "worktree_key", "ref_key", "state",
        "created_at", "updated_at", "released_at", "clean_digest", "checkpoint_count",
    ),
    "claim": (
        "version", "kind", "generation", "lease_id", "repo_id", "top", "ref",
        "actor", "created_at", "claim_key", "claim_type",
    ),
    "review": (
        "version", "kind", "generation", "review_id", "repo_id", "top", "common_dir",
        "algo", "commit", "tree", "author_actor", "reviewer_actor", "provider",
        "state", "created_at", "updated_at", "lease_id", "process_capability",
        "payload_name", "closure", "closure_reason",
    ),
    "pointer": (
        "version", "kind", "generation", "review_id", "payload_base", "payload_path",
        "payload_name", "payload_identity", "src_identity", "manifest_digest",
        "inventory_digest", "created_at",
    ),
    "manifest": (
        "version", "kind", "generation", "review_id", "algo", "commit", "tree",
        "repo_id", "entry_count", "inventory_digest", "src_identity",
        "payload_identity", "launch_digest", "helper_digest", "created_at",
        "ceiling",
    ),
    "facts": (
        "version", "kind", "generation", "review_id", "session_id", "request_id",
        "bound_at", "cancel_requested", "cancel_requested_at", "terminal_observed",
        "terminal_completion", "terminal_at", "report_sealed", "report_digest",
        "report_verdict", "report_sealed_at", "artifact_verified", "verified_at",
        "closure", "closure_reason", "closed_at", "conflict",
        "contract_commit", "contract_report", "contract_sidecar",
        "contract_sidecar_digest",
        "false_terminal", "false_terminal_reason", "false_terminal_at",
        "provider", "provider_model", "session_rotation_required",
        "last_activity_at",
    ),
    "latest": (
        "version", "kind", "generation", "review_id", "phase", "raw_state",
        "observed_at", "diagnostic", "diagnostic_at", "observation_count",
    ),
    "observation": (
        "version", "kind", "generation", "review_id", "raw_state", "phase",
        "terminal", "observed_at", "evidence_digest", "diagnostic", "raw_model",
    ),
    "process": (
        "version", "kind", "generation", "review_id", "role", "pid", "ppid", "pgid",
        "lstart", "command_digest", "command_display", "registered_at",
    ),
    "checkpoint": (
        "version", "kind", "generation", "lease_id", "old", "new", "tree", "actor",
        "ref", "recorded_at",
    ),
}


def new_record(kind, generation, fields):
    if kind not in RECORD_SCHEMAS:
        fail("record_kind_unknown", "unknown record kind %r" % (kind,))
    record = {"version": PROTOCOL_VERSION, "kind": kind, "generation": generation}
    record.update(fields)
    allowed = RECORD_SCHEMAS[kind]
    if set(record.keys()) != set(allowed):
        fail("record_schema_mismatch",
             "%s record must carry exactly the %s schema keys" % (kind, kind))
    return record


# Fields legitimately holding a nested object; everything else must be a
# scalar (None/bool/int/str) within bounds.
RECORD_DICT_FIELDS = {
    "lease": ("capability",),
    "review": ("process_capability",),
    "pointer": ("payload_identity", "src_identity"),
    "manifest": ("src_identity", "payload_identity"),
}
CAPABILITY_FIELDS = ("capability", "process_capability")
MAX_RECORD_STRING = 4096
MAX_RECORD_INT = 2 ** 62


def _validate_identity_field(value, name):
    if value is None:
        return
    if not isinstance(value, dict):
        fail("record_field_type", "%s identity field is not an object" % (name,))
    if set(value.keys()) - {"dev", "ino", "type"}:
        fail("record_field_type", "%s identity field has unexpected keys" % (name,))
    for key in ("dev", "ino"):
        if key in value and (not isinstance(value[key], int)
                             or isinstance(value[key], bool)
                             or value[key] < 0 or value[key] > MAX_RECORD_INT):
            fail("record_field_type", "%s identity %s is out of bounds" % (name, key))
    if "type" in value and value["type"] not in ("directory", "regular", "symlink", "other"):
        fail("record_field_type", "%s identity type is invalid" % (name,))


def validate_record(record, kind, name):
    if not isinstance(record, dict):
        fail("record_invalid", "%s is not a JSON object" % (name,))
    if record.get("version") != PROTOCOL_VERSION:
        fail("record_version_mismatch", "%s has an unsupported version" % (name,))
    if record.get("kind") != kind:
        fail("record_kind_mismatch", "%s is not a %s record" % (name, kind))
    generation = record.get("generation")
    require_int(generation, 1, 2 ** 40, "record_invalid", "%s generation" % (name,))
    allowed = RECORD_SCHEMAS[kind]
    if set(record.keys()) != set(allowed):
        fail("record_schema_mismatch",
             "%s record keys do not exactly match the %s schema" % (name, kind))
    dict_fields = RECORD_DICT_FIELDS.get(kind, ())
    for key, value in record.items():
        if key in dict_fields:
            if key in CAPABILITY_FIELDS:
                continue  # validated by the capability block below
            _validate_identity_field(value, "%s.%s" % (name, key))
            continue
        if value is None or isinstance(value, bool):
            continue
        if isinstance(value, int):
            if value < 0 or value > MAX_RECORD_INT:
                fail("record_field_bounds", "%s.%s is out of bounds" % (name, key))
            continue
        if isinstance(value, str):
            if len(value) > MAX_RECORD_STRING:
                fail("record_field_bounds", "%s.%s exceeds %d characters"
                     % (name, key, MAX_RECORD_STRING))
            continue
        fail("record_field_type", "%s.%s has a non-scalar value" % (name, key))
    for field in CAPABILITY_FIELDS:
        if field not in dict_fields:
            continue
        capability = record.get(field)
        if not isinstance(capability, dict) or \
                set(capability.keys()) != {"salt", "verifier", "algorithm"}:
            fail("record_field_type", "%s %s verifier is malformed" % (name, field))
        for cap_key in ("salt", "verifier"):
            if not isinstance(capability[cap_key], str) or \
                    not HEX_RE.match(capability[cap_key]):
                fail("record_field_type",
                     "%s %s %s is not hex" % (name, field, cap_key))
    return record


def publish_record(fds, parent_fd, entry_name, kind, record, what):
    """temp -> fsync -> rename -> directory fsync -> READY last."""
    validate_record(record, kind, what)
    data = canonical_json_bytes(record)
    if len(data) > MAX_RECORD_BYTES:
        fail("record_too_large", "%s exceeds %d bytes" % (what, MAX_RECORD_BYTES))
    entry_fd, _ = ensure_owned_dir(fds, parent_fd, entry_name, what)
    # Retract READY first: a crash mid-update must read as incomplete, never free.
    try:
        os.unlink("READY", dir_fd=entry_fd)
        fsync_dir(entry_fd)
    except FileNotFoundError:
        pass
    except OSError as exc:
        fail("publish_failed", "%s READY retract failed: %s" % (what, exc.strerror))
    atomic_publish(entry_fd, "record.json", data)
    crash_hook("record.published")
    ready = canonical_json_bytes({
        "version": PROTOCOL_VERSION,
        "generation": record["generation"],
        "digest": sha256_hex(data),
    })
    atomic_publish(entry_fd, "READY", ready)
    return entry_fd


def read_record(parent_fd, entry_name, kind, what, allow_missing=False):
    entry = try_lstat_at(parent_fd, entry_name)
    if entry is None:
        if allow_missing:
            return None
        fail("record_missing", "%s is absent" % (what,))
    if not statmod.S_ISDIR(entry.st_mode) or statmod.S_ISLNK(entry.st_mode):
        fail("record_invalid", "%s is not a real directory" % (what,))
    if entry.st_uid != os.getuid():
        fail("record_invalid", "%s is not owned by the current user" % (what,))
    if statmod.S_IMODE(entry.st_mode) != DIR_MODE:
        fail("record_invalid", "%s mode is not 0700" % (what,))
    entry_fd = open_dir_at(parent_fd, entry_name, code="record_invalid", what=what)
    try:
        ready_raw = try_lstat_at(entry_fd, "READY")
        if ready_raw is None:
            raise CoordError("transition_incomplete",
                             "%s has no READY marker" % (what,),
                             {"entry": entry_name})
        ready = strict_json_loads(
            read_file_at(entry_fd, "READY", 4096, what="%s READY" % (what,))
        )
        data = read_file_at(entry_fd, "record.json", MAX_RECORD_BYTES,
                            what="%s record.json" % (what,))
        record = strict_json_loads(data)
        validate_record(record, kind, what)
        if ready.get("generation") != record["generation"]:
            raise CoordError("transition_incomplete",
                             "%s READY generation mismatch" % (what,))
        if ready.get("digest") != sha256_hex(data):
            raise CoordError("transition_incomplete",
                             "%s READY digest mismatch" % (what,))
        return {"record": record, "entry": entry_name, "identity": identity(entry)}
    finally:
        os.close(entry_fd)


class StateRoot(object):
    """<common-dir>/stitchpad-coordination/v1 — metadata only, never payload."""

    def __init__(self, fds, repo, create=True):
        self.repo = repo
        self.fds = fds
        common_fd = fds.keep(open_dir_at(None, repo["common_dir"],
                                         code="common_dir_missing",
                                         what=repo["common_dir"]))
        if create:
            coord_fd, _ = ensure_owned_dir(fds, common_fd, COORD_DIRNAME,
                                           "coordination root")
            root_fd, _ = ensure_owned_dir(fds, coord_fd, COORD_VERSION_DIR,
                                          "coordination v1 root")
            self.fd = root_fd
            self.leases = ensure_owned_dir(fds, root_fd, "leases", "leases")[0]
            claims = ensure_owned_dir(fds, root_fd, "claims", "claims")[0]
            self.claims = claims
            self.claim_worktrees = ensure_owned_dir(
                fds, claims, "worktrees", "worktree claims")[0]
            self.claim_refs = ensure_owned_dir(fds, claims, "refs", "ref claims")[0]
            self.reviews = ensure_owned_dir(fds, root_fd, "reviews", "reviews")[0]
            self.incidents = ensure_owned_dir(fds, root_fd, "incidents", "incidents")[0]
        else:
            coord = try_lstat_at(common_fd, COORD_DIRNAME)
            if coord is None:
                self.fd = None
                return
            coord_fd = fds.keep(open_dir_at(common_fd, COORD_DIRNAME))
            if try_lstat_at(coord_fd, COORD_VERSION_DIR) is None:
                self.fd = None
                return
            root_fd = fds.keep(open_dir_at(coord_fd, COORD_VERSION_DIR))
            self.fd = root_fd
            self.leases = fds.keep(open_dir_at(root_fd, "leases"))
            claims = fds.keep(open_dir_at(root_fd, "claims"))
            self.claims = claims
            self.claim_worktrees = fds.keep(open_dir_at(claims, "worktrees"))
            self.claim_refs = fds.keep(open_dir_at(claims, "refs"))
            self.reviews = fds.keep(open_dir_at(root_fd, "reviews"))
            self.incidents = fds.keep(open_dir_at(root_fd, "incidents"))

    @property
    def present(self):
        return self.fd is not None


LOCK_NAME = "transition.lock.d"


class TransitionMutex(object):
    """Repository-wide atomic transition lock. Never age-reclaimed."""

    def __init__(self, state):
        self.state = state
        self.held = False
        self.nonce = None

    def acquire(self):
        old_mask = os.umask(0o077)
        try:
            try:
                os.mkdir(LOCK_NAME, DIR_MODE, dir_fd=self.state.fd)
            except FileExistsError:
                raise CoordError(
                    "transition_in_progress",
                    "another coordination transition holds the repository mutex",
                )
            except OSError as exc:
                fail("lock_failed", "cannot create the transition mutex: %s"
                     % (exc.strerror,))
        finally:
            os.umask(old_mask)
        self.held = True
        self.nonce = secrets.token_hex(16)
        lock_fd = open_dir_at(self.state.fd, LOCK_NAME)
        try:
            os.fchmod(lock_fd, DIR_MODE)
            atomic_publish(lock_fd, "record.json", canonical_json_bytes({
                "version": PROTOCOL_VERSION,
                "nonce": self.nonce,
                "pid": os.getpid(),
                "acquired_at": int(time.time()),
            }))
            atomic_publish(lock_fd, "READY", canonical_json_bytes({
                "version": PROTOCOL_VERSION, "nonce": self.nonce,
            }))
        finally:
            os.close(lock_fd)
        fsync_dir(self.state.fd)
        return self

    def release(self):
        if not self.held:
            return
        try:
            lock_fd = open_dir_at(self.state.fd, LOCK_NAME)
        except CoordError:
            self.held = False
            return
        try:
            for name in ("READY", "record.json"):
                try:
                    os.unlink(name, dir_fd=lock_fd)
                except FileNotFoundError:
                    pass
            for name in list_dir_at(lock_fd, "transition mutex"):
                if name.startswith(".tmp."):
                    try:
                        os.unlink(name, dir_fd=lock_fd)
                    except OSError:
                        pass
        finally:
            os.close(lock_fd)
        try:
            os.rmdir(LOCK_NAME, dir_fd=self.state.fd)
        except OSError as exc:
            fail("lock_release_failed", "cannot release the transition mutex: %s"
                 % (exc.strerror,))
        fsync_dir(self.state.fd)
        self.held = False

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *_exc):
        self.release()
        return False


def sample_mutex(state):
    if state.fd is None:
        return None
    info = try_lstat_at(state.fd, LOCK_NAME)
    if info is None:
        return None
    sample = {"dev": info.st_dev, "ino": info.st_ino, "nonce": None}
    try:
        lock_fd = open_dir_at(state.fd, LOCK_NAME)
    except CoordError:
        return sample
    try:
        raw = try_lstat_at(lock_fd, "READY")
        if raw is not None:
            try:
                ready = strict_json_loads(
                    read_file_at(lock_fd, "READY", 4096, what="mutex READY"))
                sample["nonce"] = ready.get("nonce")
            except CoordError:
                sample["nonce"] = None
    finally:
        os.close(lock_fd)
    return sample


def double_sampled(state, reader):
    """Lock-free read: sample mutex, read, sample again. Never infer 'free'."""
    before = sample_mutex(state)
    if before is not None:
        raise CoordError("transition_in_progress",
                         "a coordination transition is in progress")
    value = reader()
    after = sample_mutex(state)
    if after is not None:
        raise CoordError("transition_in_progress",
                         "a coordination transition started during the read")
    return value


# ---------------------------------------------------------------------------
# Section 7. Path preflight, safe extraction, stable inventory
# ---------------------------------------------------------------------------

def _decode_tree_path(raw):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("path_not_utf8", "tree path is not valid UTF-8 (macOS MVP restriction)")
    if not text:
        fail("path_empty", "tree path is empty")
    if len(raw) > MAX_PATH_BYTES:
        fail("path_too_long", "tree path exceeds %d bytes" % (MAX_PATH_BYTES,))
    if text.startswith("/"):
        fail("path_absolute", "tree path is absolute")
    if "\0" in text:
        fail("path_invalid", "tree path contains NUL")
    components = text.split("/")
    if len(components) > MAX_COMPONENTS:
        fail("path_too_deep", "tree path exceeds %d components" % (MAX_COMPONENTS,))
    for component in components:
        if component == "":
            fail("path_invalid", "tree path has an empty component")
        if component in (".", ".."):
            fail("path_traversal", "tree path contains a dot or dot-dot component")
        if nfd_casefold(component) == ".git":
            fail("path_git_component", "tree path contains a normalized .git component")
    return text, components


def parse_tree(repo, commit, git_home):
    """Strict `git ls-tree -r -z --full-tree` parse; only blobs and symlinks."""
    raw = git_raw(
        ["-C", repo["top"], "ls-tree", "-r", "-z", "--full-tree", commit],
        git_home, binary=True,
    )["raw"]
    entries = []
    seen_paths = set()
    for chunk in raw.split(b"\0"):
        if not chunk:
            continue
        if len(entries) >= MAX_TREE_ENTRIES:
            fail("tree_too_large", "tree exceeds %d entries" % (MAX_TREE_ENTRIES,))
        head, sep, path_raw = chunk.partition(b"\t")
        if not sep:
            fail("tree_malformed", "unexpected ls-tree record")
        fields = head.split(b" ")
        if len(fields) != 3:
            fail("tree_malformed", "unexpected ls-tree fields")
        mode_raw, type_raw, oid_raw = fields
        try:
            mode = int(mode_raw.decode("ascii"), 8)
        except (UnicodeDecodeError, ValueError):
            fail("tree_malformed", "unparseable tree mode")
        kind_name = type_raw.decode("ascii", "replace")
        if kind_name == "commit" or mode == 0o160000:
            fail("tree_gitlink", "submodule gitlinks are rejected")
        if kind_name != "blob":
            fail("tree_unexpected_type", "unexpected tree entry type %r" % (kind_name,))
        if mode not in (GIT_MODE_FILE, GIT_MODE_EXEC, GIT_MODE_LINK):
            fail("tree_mode_rejected", "rejected tree mode %06o" % (mode,))
        oid = oid_raw.decode("ascii", "replace")
        require_oid(oid, repo["algo"], "tree entry oid")
        text, components = _decode_tree_path(path_raw)
        if path_raw in seen_paths:
            fail("tree_duplicate_path", "duplicate tree path")
        seen_paths.add(path_raw)
        entries.append({
            "path": text,
            "raw": path_raw,
            "components": components,
            "mode": mode,
            "oid": oid,
            "kind": KIND_LINK if mode == GIT_MODE_LINK else KIND_FILE,
        })
    return entries


def preflight_layout(entries):
    """Implied directories, raw prefix conflicts, sibling NFD+casefold collisions."""
    file_paths = set(entry["path"] for entry in entries)
    dirs = set()
    for entry in entries:
        for depth in range(1, len(entry["components"])):
            dirs.add("/".join(entry["components"][:depth]))
    conflict = dirs & file_paths
    if conflict:
        fail("path_prefix_conflict",
             "a blob path is also used as a directory path")

    # Sibling-scoped collision keys: NFD+casefold per component, compared only
    # against siblings under the same normalized parent.
    siblings = {}
    def register(parent_components, name, full):
        parent_key = "/".join(nfd_casefold(part) for part in parent_components)
        key = (parent_key, nfd_casefold(name))
        existing = siblings.get(key)
        if existing is not None and existing != full:
            fail("path_collision",
                 "sibling paths collide after NFD+casefold normalization")
        siblings[key] = full

    for path in sorted(dirs) + sorted(file_paths):
        components = path.split("/")
        register(components[:-1], components[-1], path)

    return sorted(dirs, key=lambda value: (value.count("/"), value))


TAR_BLOCK = 512


def _parse_pax_records(records):
    keys = {}
    cursor = 0
    while cursor < len(records):
        space = records.find(b" ", cursor)
        if space < 0:
            fail("archive_pax_override", "malformed pax record")
        try:
            length = int(records[cursor:space].decode("ascii"), 10)
        except (UnicodeDecodeError, ValueError):
            fail("archive_pax_override", "malformed pax record length")
        if length < 3 or cursor + length > len(records):
            fail("archive_pax_override", "pax record overruns its header")
        body = records[space + 1:cursor + length]
        if not body.endswith(b"\n") or b"=" not in body:
            fail("archive_pax_override", "malformed pax record body")
        key, _, value = body[:-1].partition(b"=")
        if key in keys:
            fail("archive_pax_override", "duplicate pax record key")
        keys[key] = value
        cursor += length
    return keys


def _tar_octal(field, what):
    text = field.split(b"\0")[0].split(b" ")[0]
    if not text:
        return 0
    try:
        return int(text.decode("ascii"), 8)
    except (UnicodeDecodeError, ValueError):
        fail("archive_malformed", "unparseable tar %s field" % (what,))


def parse_tar(data, expect_comment=None):
    """Minimal strict ustar reader with the match-only pax `x` rule (W2).

    `git archive` legitimately emits a pax extended header (`x`) carrying
    `path=` for names longer than the ustar name/prefix split. Accept such a
    header only when it immediately precedes its entry, carries exactly one
    `path=` record and no other override keys, and the resolved path is then
    validated against the exact tree/implied-directory set by
    `preflight_archive` — any override that changes the name fails there.
    A single leading global (`g`) header is accepted only when its payload is
    exactly `comment=<native commit OID hex>` (the shape `git archive` always
    emits); when ``expect_comment`` is given the value must equal it exactly.
    Every other global header, GNU longname/longlink (`L`/`K`/`X`), and any
    override key besides `path=` is rejected.
    """
    # GLM cross-review P2: `expect_comment` is normalized to bytes exactly once
    # here with a hard type guard, so a bytes-vs-str caller can never reach the
    # comparison below and raise AttributeError instead of failing closed.
    if expect_comment is not None:
        if isinstance(expect_comment, bytes):
            expect_bytes = expect_comment
        elif isinstance(expect_comment, str):
            try:
                expect_bytes = expect_comment.encode("ascii")
            except UnicodeEncodeError:
                fail("archive_pax_override", "expected commit comment is not ASCII")
        else:
            fail("archive_pax_override",
                 "expected commit comment has an unsupported type")
        if not (len(expect_bytes) in (40, 64) and
                all(byte in b"0123456789abcdef" for byte in expect_bytes)):
            fail("archive_pax_override",
                 "expected commit comment is not a native commit OID")
    else:
        expect_bytes = None
    members = []
    offset = 0
    total = len(data)
    pending_path = None
    seen_global = False
    seen_comment = None
    while offset + TAR_BLOCK <= total:
        header = data[offset:offset + TAR_BLOCK]
        if header == b"\0" * TAR_BLOCK:
            break
        stored = header[148:156]
        blanked = header[:148] + b" " * 8 + header[156:]
        checksum = _tar_octal(stored, "checksum")
        # Signed checksum as a pure integer sum: valid UTF-8 names carry bytes
        # >127 and must never be pushed through a bytearray (P1-4).
        signed_sum = sum(
            (byte - 256) if byte > 127 else byte for byte in blanked
        )
        if checksum not in (sum(blanked), signed_sum):
            fail("archive_checksum", "tar header checksum mismatch")
        magic = header[257:263]
        if magic not in (b"ustar\0", b"ustar "):
            fail("archive_format", "unsupported tar header format")
        typeflag = header[156:157]
        size = _tar_octal(header[124:136], "size")
        if size < 0 or size > MAX_MEMBER_BYTES:
            fail("archive_member_too_large", "tar member exceeds %d bytes"
                 % (MAX_MEMBER_BYTES,))
        payload_offset = offset + TAR_BLOCK
        padded = ((size + TAR_BLOCK - 1) // TAR_BLOCK) * TAR_BLOCK
        if payload_offset + padded > total:
            fail("archive_truncated", "tar member payload is truncated")
        offset = payload_offset + padded

        if typeflag == b"x":
            if pending_path is not None:
                fail("archive_pax_override", "consecutive pax extended headers")
            records = data[payload_offset:payload_offset + size]
            keys = _parse_pax_records(records)
            if set(keys) != {b"path"}:
                fail("archive_pax_override",
                     "pax extended header carries keys other than path=")
            pending_path = keys[b"path"]
            continue
        if typeflag == b"g":
            # git archive always prepends one global header whose payload is
            # exactly `comment=<commit-oid>`; it overrides no path. Accept only
            # that exact shape, only in first position; every other global
            # header (any other key, or any later position) is an override and
            # is rejected. (Reconciles blueprint W2 with observed Apple Git
            # 2.50.1 output.)
            if members or pending_path is not None or seen_global:
                fail("archive_pax_override",
                     "unexpected pax global header position")
            seen_global = True
            records = data[payload_offset:payload_offset + size]
            keys = _parse_pax_records(records)
            if set(keys) != {b"comment"}:
                fail("archive_pax_override",
                     "pax global header carries keys other than comment=")
            comment = keys[b"comment"]
            if not (len(comment) in (40, 64) and
                    all(byte in b"0123456789abcdef" for byte in comment)):
                fail("archive_pax_override",
                     "pax global comment is not a native commit OID")
            seen_comment = comment
            if expect_bytes is not None and comment != expect_bytes:
                fail("archive_pax_override",
                     "pax global comment does not name the pinned commit")
            continue
        if typeflag in (b"L", b"K", b"X"):
            fail("archive_pax_override",
                 "GNU longname/longlink override headers are rejected")
        if typeflag == b"1":
            fail("archive_hardlink", "tar hard links are rejected")
        if typeflag in (b"3", b"4"):
            fail("archive_device", "tar device nodes are rejected")
        if typeflag == b"6":
            fail("archive_fifo", "tar FIFOs are rejected")
        if typeflag in (b"7", b"S", b"D", b"M", b"N", b"V"):
            fail("archive_special", "tar sparse/contiguous/special members are rejected")
        if typeflag not in (b"0", b"\0", b"2", b"5"):
            fail("archive_special", "unsupported tar typeflag %r" % (typeflag,))

        if pending_path is not None:
            raw_path = pending_path
            pending_path = None
        else:
            name = header[0:100].split(b"\0")[0]
            prefix = header[345:500].split(b"\0")[0]
            raw_path = (prefix + b"/" + name) if prefix else name
        raw_path = raw_path.rstrip(b"/")
        linkname = header[157:257].split(b"\0")[0]
        mode = _tar_octal(header[100:108], "mode")

        if typeflag == b"5":
            kind = KIND_DIR
        elif typeflag == b"2":
            kind = KIND_LINK
        else:
            kind = KIND_FILE
        if kind != KIND_LINK and linkname:
            fail("archive_unexpected_link", "unexpected tar linkname")
        if kind == KIND_LINK and not linkname:
            fail("archive_unexpected_link", "tar symlink has no target")
        if kind != KIND_FILE and size != 0:
            fail("archive_malformed", "non-regular tar member has a payload")
        text, components = _decode_tree_path(raw_path)
        members.append({
            "path": text,
            "raw": raw_path,
            "components": components,
            "kind": kind,
            "mode": mode,
            "size": size,
            "offset": payload_offset,
            "link": linkname,
        })
        if len(members) > MAX_TREE_ENTRIES * 2 + 8:
            fail("archive_too_many_members", "tar has too many members")
    if pending_path is not None:
        fail("archive_pax_override", "pax extended header has no following entry")
    # GLM cross-review P2: when the caller pinned a commit, the archive MUST
    # actually carry the global comment header naming it. Without this an
    # archive with the comment header stripped would silently pass the pin.
    if expect_bytes is not None and seen_comment is None:
        fail("archive_pax_override",
             "archive carries no pax global comment naming the pinned commit")
    return members


def preflight_archive(members, entries, implied_dirs):
    """Every header must match the exact tree/implied-directory set."""
    expected_files = {}
    for entry in entries:
        expected_files[entry["path"]] = entry
    expected_dirs = set(implied_dirs)
    seen = set()
    for member in members:
        if member["path"] in seen:
            fail("archive_duplicate", "duplicate tar member")
        seen.add(member["path"])
        if member["kind"] == KIND_DIR:
            if member["path"] not in expected_dirs:
                fail("archive_unexpected_member",
                     "tar directory member is not in the implied directory set")
            continue
        entry = expected_files.get(member["path"])
        if entry is None:
            fail("archive_unexpected_member", "tar member is not in the pinned tree")
        if entry["kind"] != member["kind"]:
            fail("archive_kind_mismatch", "tar member kind disagrees with the tree")
        for depth in range(1, len(member["components"])):
            parent = "/".join(member["components"][:depth])
            if parent in expected_files:
                fail("archive_parent_conflict", "tar member parent is not a directory")
    for path in expected_files:
        if path not in seen:
            fail("archive_missing_member", "tar is missing a pinned tree entry")
    for path in expected_dirs:
        if path not in seen:
            fail("archive_missing_member", "tar is missing an implied directory")


def encode_inventory(records):
    """u64be(path_len)|path|u8(kind)|u32be(git_mode)|u16be(oid_len)|oid"""
    out = b""
    for raw_path, kind, git_mode, oid_hex in sorted(records, key=lambda item: item[0]):
        oid_bytes = bytes.fromhex(oid_hex) if oid_hex else b""
        out += len(raw_path).to_bytes(8, "big")
        out += raw_path
        out += bytes([kind])
        out += git_mode.to_bytes(4, "big")
        out += len(oid_bytes).to_bytes(2, "big")
        out += oid_bytes
    return out


class DirCache(object):
    """Retained directory FDs for every extraction/inventory parent."""

    def __init__(self, fds, root_fd):
        self.fds = fds
        self.cache = {"": root_fd}

    def get(self, path):
        fd = self.cache.get(path)
        if fd is None:
            fail("root_replaced", "extraction parent directory is missing")
        return fd

    def add(self, path, fd):
        self.cache[path] = fd


def extract_tree(fds, src_fd, data, members, entries, implied_dirs, algo):
    """Create every member relative to retained directory FDs. No extractor."""
    cache = DirCache(fds, src_fd)
    inventory = []

    for path in implied_dirs:
        components = path.split("/")
        parent_fd = cache.get("/".join(components[:-1]))
        name = components[-1]
        old_mask = os.umask(0o077)
        try:
            if not mkdir_owned(parent_fd, name, DIR_MODE):
                fail("extract_exists", "extraction target already exists")
        finally:
            os.umask(old_mask)
        entry_info = lstat_at(parent_fd, name, code="root_replaced", what=path)
        if statmod.S_ISLNK(entry_info.st_mode) or not statmod.S_ISDIR(entry_info.st_mode):
            fail("extract_parent_symlink", "extraction parent is not a real directory")
        dir_fd = fds.keep(open_dir_at(parent_fd, name, code="root_replaced", what=path))
        opened = os.fstat(dir_fd)
        if identity(entry_info) != identity(opened):
            fail("root_replaced", "extraction directory changed between lstat and open")
        os.fchmod(dir_fd, DIR_MODE)
        opened = os.fstat(dir_fd)
        require_owned_dir(opened, DIR_MODE, path)
        cache.add(path, dir_fd)
        inventory.append((path.encode("utf-8"), KIND_DIR, GIT_MODE_DIR, ""))

    by_path = dict((entry["path"], entry) for entry in entries)
    for member in members:
        if member["kind"] == KIND_DIR:
            continue
        entry = by_path[member["path"]]
        components = member["components"]
        parent_fd = cache.get("/".join(components[:-1]))
        name = components[-1]
        if member["kind"] == KIND_FILE:
            payload = data[member["offset"]:member["offset"] + member["size"]]
            if len(payload) != member["size"]:
                fail("archive_truncated", "tar member payload is truncated")
            mode = EXEC_MODE if entry["mode"] == GIT_MODE_EXEC else FILE_MODE
            # O_RDWR so the very bytes written are re-read from the same open
            # FD and hashed; full stable metadata (identity/size/mode/mtime_ns/
            # nlink) is compared across the write, the verify read, and the
            # post-close lstat. A same-inode content swap cannot pass (P1-3).
            flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            try:
                fd = os.open(name, flags, mode, dir_fd=parent_fd)
            except OSError as exc:
                fail("extract_failed", "%s: %s" % (member["path"], exc.strerror))
            try:
                written = 0
                while written < len(payload):
                    written += os.write(fd, payload[written:])
                os.fchmod(fd, mode)
                os.fsync(fd)
                before = os.fstat(fd)
                os.lseek(fd, 0, os.SEEK_SET)
                hasher = blob_hasher(algo)
                hasher.update(("blob %d\0" % before.st_size).encode("ascii"))
                read_total = 0
                while True:
                    chunk = os.read(fd, 65536)
                    if not chunk:
                        break
                    read_total += len(chunk)
                    if read_total > before.st_size:
                        fail("extract_unstable", "%s grew during verification"
                             % (member["path"],))
                    hasher.update(chunk)
                if read_total != before.st_size:
                    fail("extract_unstable", "%s shrank during verification"
                         % (member["path"],))
                after_read = os.fstat(fd)
            finally:
                os.close(fd)
            if identity(before) != identity(after_read) \
                    or after_read.st_size != before.st_size \
                    or after_read.st_mtime_ns != before.st_mtime_ns \
                    or after_read.st_mode != before.st_mode \
                    or after_read.st_nlink != before.st_nlink:
                fail("extract_unstable",
                     "%s changed during verification" % (member["path"],))
            if hasher.hexdigest() != entry["oid"]:
                fail("blob_oid_mismatch", "extracted blob does not match the pinned OID")
            after = lstat_at(parent_fd, name, code="root_replaced", what=member["path"])
            if identity(before) != identity(after):
                fail("root_replaced", "extracted file identity changed")
            if after.st_nlink != 1:
                fail("extract_hardlink", "extracted file gained hard links")
            if after.st_size != member["size"] \
                    or after.st_mtime_ns != before.st_mtime_ns:
                fail("extract_unstable", "extracted file changed after verification")
            if statmod.S_IMODE(after.st_mode) != mode:
                fail("extract_unstable", "extracted file mode changed")
            inventory.append((member["raw"], KIND_FILE, entry["mode"], entry["oid"]))
        else:
            target = member["link"]
            computed = blob_oid_bytes(algo, target)
            if computed != entry["oid"]:
                fail("blob_oid_mismatch", "symlink target does not match the pinned OID")
            try:
                os.symlink(target.decode("utf-8"), name, dir_fd=parent_fd)
            except UnicodeDecodeError:
                fail("path_not_utf8", "symlink target is not valid UTF-8")
            except OSError as exc:
                fail("extract_failed", "%s: %s" % (member["path"], exc.strerror))
            link_info = lstat_at(parent_fd, name, code="root_replaced",
                                 what=member["path"])
            if not statmod.S_ISLNK(link_info.st_mode):
                fail("extract_failed", "symlink was not created as a symlink")
            readback = os.readlink(name, dir_fd=parent_fd)
            if readback.encode("utf-8") != target:
                fail("extract_unstable", "symlink target changed after creation")
            inventory.append((member["raw"], KIND_LINK, GIT_MODE_LINK, entry["oid"]))

    return inventory, cache


def walk_inventory(fds, src_fd, algo):
    """Final inventory: retained FDs, O_NOFOLLOW, stable re-fstat, no outside bytes."""
    records = []
    pending = [("", src_fd)]
    visited = 0
    while pending:
        prefix, dir_fd = pending.pop(0)
        before = os.fstat(dir_fd)
        names = list_dir_at(dir_fd, prefix or "src")
        for name in names:
            if name in (".", ".."):
                continue
            visited += 1
            if visited > MAX_TREE_ENTRIES * 2:
                fail("inventory_too_large", "source tree exceeds the inventory bound")
            path = (prefix + "/" + name) if prefix else name
            if nfd_casefold(name) == ".git":
                fail("inventory_git_component", "a .git component appeared in src")
            info = lstat_at(dir_fd, name, code="inventory_unstable", what=path)
            raw_path = path.encode("utf-8")
            if statmod.S_ISDIR(info.st_mode):
                child = fds.keep(open_dir_at(dir_fd, name, code="inventory_unstable",
                                             what=path))
                opened = os.fstat(child)
                if identity(info) != identity(opened):
                    fail("inventory_unstable", "%s changed between lstat and open" % (path,))
                records.append((raw_path, KIND_DIR, GIT_MODE_DIR, ""))
                pending.append((path, child))
            elif statmod.S_ISLNK(info.st_mode):
                target = os.readlink(name, dir_fd=dir_fd)
                again = lstat_at(dir_fd, name, code="inventory_unstable", what=path)
                if identity(info) != identity(again) \
                        or again.st_mtime_ns != info.st_mtime_ns:
                    fail("inventory_unstable", "%s symlink identity changed" % (path,))
                oid = blob_oid_bytes(algo, target.encode("utf-8"))
                records.append((raw_path, KIND_LINK, GIT_MODE_LINK, oid))
            elif statmod.S_ISREG(info.st_mode):
                fd = open_file_at(dir_fd, name, code="inventory_unstable", what=path)
                try:
                    opened = os.fstat(fd)
                    if identity(info) != identity(opened):
                        fail("inventory_unstable", "%s changed between lstat and open"
                             % (path,))
                    if opened.st_nlink != 1:
                        fail("inventory_hardlink", "%s has extra hard links" % (path,))
                    if opened.st_size > MAX_MEMBER_BYTES:
                        fail("inventory_too_large", "%s exceeds the member bound" % (path,))
                    hasher = blob_hasher(algo)
                    hasher.update(("blob %d\0" % opened.st_size).encode("ascii"))
                    read_total = 0
                    while True:
                        chunk = os.read(fd, 65536)
                        if not chunk:
                            break
                        read_total += len(chunk)
                        if read_total > opened.st_size:
                            fail("inventory_unstable", "%s grew during the walk" % (path,))
                        hasher.update(chunk)
                    if read_total != opened.st_size:
                        fail("inventory_unstable", "%s shrank during the walk" % (path,))
                    final = os.fstat(fd)
                    if identity(opened) != identity(final) \
                            or final.st_size != opened.st_size \
                            or final.st_mtime_ns != opened.st_mtime_ns \
                            or final.st_mode != opened.st_mode \
                            or final.st_nlink != opened.st_nlink:
                        fail("inventory_unstable", "%s changed during read" % (path,))
                    perm = statmod.S_IMODE(final.st_mode)
                    if perm == EXEC_MODE:
                        git_mode = GIT_MODE_EXEC
                    elif perm == FILE_MODE:
                        git_mode = GIT_MODE_FILE
                    else:
                        fail("inventory_mode_rejected",
                             "%s has an unexpected mode %04o" % (path, perm))
                    records.append((raw_path, KIND_FILE, git_mode, hasher.hexdigest()))
                finally:
                    os.close(fd)
            else:
                fail("inventory_special", "%s is not a regular file, directory, or symlink"
                     % (path,))
        after = os.fstat(dir_fd)
        if identity(before) != identity(after) \
                or after.st_mtime_ns != before.st_mtime_ns:
            fail("inventory_unstable",
                 "%s directory changed during the walk" % (prefix or "src",))
        # Re-enumerate: an entry added after the first snapshot must make the
        # whole walk fail, never produce a torn inventory (P1-3).
        if list_dir_at(dir_fd, prefix or "src") != names:
            fail("inventory_unstable",
                 "%s directory entries changed during the walk" % (prefix or "src",))
    return records


# ---------------------------------------------------------------------------
# Section 8. Payload root binding and flat paired records
# ---------------------------------------------------------------------------

def publish_flat_record(dir_fd, name, kind, record, what):
    validate_record(record, kind, what)
    data = canonical_json_bytes(record)
    if len(data) > MAX_RECORD_BYTES:
        fail("record_too_large", "%s exceeds %d bytes" % (what, MAX_RECORD_BYTES))
    ready_name = name + ".READY"
    try:
        os.unlink(ready_name, dir_fd=dir_fd)
        fsync_dir(dir_fd)
    except FileNotFoundError:
        pass
    except OSError as exc:
        fail("publish_failed", "%s READY retract failed: %s" % (what, exc.strerror))
    atomic_publish(dir_fd, name, data)
    crash_hook("record.published")
    atomic_publish(dir_fd, ready_name, canonical_json_bytes({
        "version": PROTOCOL_VERSION,
        "generation": record["generation"],
        "digest": sha256_hex(data),
    }))


def read_flat_record(dir_fd, name, kind, what, allow_missing=False):
    if try_lstat_at(dir_fd, name) is None:
        if allow_missing:
            return None
        fail("record_missing", "%s is absent" % (what,))
    if try_lstat_at(dir_fd, name + ".READY") is None:
        raise CoordError("transition_incomplete", "%s has no READY marker" % (what,))
    ready = strict_json_loads(read_file_at(dir_fd, name + ".READY", 4096,
                                           what="%s READY" % (what,)))
    data = read_file_at(dir_fd, name, MAX_RECORD_BYTES, what=what)
    record = strict_json_loads(data)
    validate_record(record, kind, what)
    if ready.get("generation") != record["generation"]:
        raise CoordError("transition_incomplete", "%s READY generation mismatch" % (what,))
    if ready.get("digest") != sha256_hex(data):
        raise CoordError("transition_incomplete", "%s READY digest mismatch" % (what,))
    return record


class RootBinding(object):
    """Section 5 protocol: base -> payload -> src, retained for the operation."""

    def __init__(self, fds, base, payload_name, expect_payload=None, expect_src=None):
        self.fds = fds
        self.base = base
        self.name = payload_name
        self.expect_payload = expect_payload
        self.expect_src = expect_src
        self.payload_fd = None
        self.src_fd = None
        self.payload_identity = None
        self.src_identity = None

    def bind(self):
        require_match(ENTRY_NAME_RE, self.name, "payload_name_invalid", "payload name")
        self.payload_fd, self.payload_identity = bind_dir_at(
            self.fds, self.base.fd, self.name,
            expect=self.expect_payload, what="payload directory",
        )
        info = os.fstat(self.payload_fd)
        require_owned_dir(info, DIR_MODE, "payload directory")
        self.src_fd, self.src_identity = bind_dir_at(
            self.fds, self.payload_fd, "src",
            expect=self.expect_src, what="payload src directory",
        )
        src_info = os.fstat(self.src_fd)
        require_owned_dir(src_info, DIR_MODE, "payload src directory")
        return self

    def recheck(self):
        """Re-lstat the published entries, re-fstat the retained FDs, and
        repeat the owner/exact-mode policy (P1-3)."""
        entry = lstat_at(self.base.fd, self.name, code="root_replaced",
                         what="payload directory")
        if not same_identity(identity(entry), self.payload_identity):
            fail("root_replaced",
                 "the published payload entry no longer names the bound directory")
        if entry.st_uid != os.getuid() \
                or statmod.S_IMODE(entry.st_mode) != DIR_MODE:
            fail("root_replaced",
                 "the published payload entry lost its owner/mode policy")
        retained = os.fstat(self.payload_fd)
        if not same_identity(identity(retained), self.payload_identity):
            fail("root_replaced", "the retained payload FD identity changed")
        require_owned_dir(retained, DIR_MODE, "payload directory")
        src_entry = lstat_at(self.payload_fd, "src", code="root_replaced",
                             what="payload src directory")
        if not same_identity(identity(src_entry), self.src_identity):
            fail("root_replaced",
                 "the published src entry no longer names the bound directory")
        if src_entry.st_uid != os.getuid() \
                or statmod.S_IMODE(src_entry.st_mode) != DIR_MODE:
            fail("root_replaced",
                 "the published src entry lost its owner/mode policy")
        retained_src = os.fstat(self.src_fd)
        if not same_identity(identity(retained_src), self.src_identity):
            fail("root_replaced", "the retained src FD identity changed")
        require_owned_dir(retained_src, DIR_MODE, "payload src directory")
        return True


# ---------------------------------------------------------------------------
# Section 9. Exact Ocean bind/refresh boundary
# ---------------------------------------------------------------------------

def resolve_ocean_port(base):
    raw = os.environ.get(TEST_PORT_ENV)
    if not raw:
        return OCEAN_PORT
    if base is None or base.test_root is None:
        fail("test_override_rejected",
             "%s requires a fully validated test root" % (TEST_PORT_ENV,))
    if not re.match(r"\A[0-9]{1,5}\Z", raw):
        fail("test_port_rejected", "test port must be decimal")
    port = int(raw, 10)
    if port < 1024 or port > 65535:
        fail("test_port_rejected", "test port must be within 1024..65535")
    return port


def ocean_get_requests(port):
    """Exact GET /v1/requests over numeric loopback. Bounded and nonterminal."""
    if not re.match(r"\A127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\Z", OCEAN_HOST):
        fail("provider_host_invalid", "provider host is not numeric loopback")
    deadline = time.monotonic() + HTTP_TOTAL_SECONDS
    conn = http.client.HTTPConnection(OCEAN_HOST, port, timeout=HTTP_CONNECT_SECONDS)
    try:
        conn.request("GET", OCEAN_PATH, headers={
            "Host": "%s:%d" % (OCEAN_HOST, port),
            "Accept": "application/json",
            "Connection": "close",
        })
        response = conn.getresponse()
        if response.status != 200:
            return {"ok": False, "diagnostic": "provider_http_status_%d" % (response.status,)}
        body = b""
        while True:
            if time.monotonic() > deadline:
                return {"ok": False, "diagnostic": "provider_http_deadline"}
            chunk = response.read(MAX_HTTP_CHUNK)
            if not chunk:
                break
            body += chunk
            if len(body) > MAX_HTTP_BYTES:
                return {"ok": False, "diagnostic": "provider_http_oversize"}
    except CoordError:
        raise
    except (OSError, http.client.HTTPException, ValueError) as exc:
        return {"ok": False,
                "diagnostic": "provider_http_error:%s" % (bounded(str(exc), 80),)}
    finally:
        try:
            conn.close()
        except Exception:
            pass
    try:
        parsed = strict_json_loads(body)
    except CoordError as exc:
        return {"ok": False, "diagnostic": "provider_%s" % (exc.code,)}
    if isinstance(parsed, dict):
        rows = parsed.get("requests")
    elif isinstance(parsed, list):
        rows = parsed
    else:
        rows = None
    if not isinstance(rows, list):
        return {"ok": False, "diagnostic": "provider_payload_shape"}
    return {"ok": True, "rows": rows, "digest": sha256_hex(body)}


def select_request_row(rows, request_id, session_id):
    matches = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        row_request = row.get("id")
        if not isinstance(row_request, str):
            row_request = row.get("request_id")
        row_session = row.get("session_id")
        if not isinstance(row_session, str):
            row_session = row.get("session")
        if row_request == request_id and row_session == session_id:
            matches.append(row)
    if len(matches) > 1:
        return None, "provider_row_ambiguous"
    if not matches:
        return None, "provider_row_missing"
    return matches[0], None


def project_state(raw_state):
    if not isinstance(raw_state, str):
        return None, None, False
    mapped = OCEAN_STATE_TABLE.get(raw_state)
    if mapped is None:
        return None, None, False
    return mapped[0], raw_state, mapped[1]


# ---------------------------------------------------------------------------
# Section 10. Process evidence (observation only, zero signals)
# ---------------------------------------------------------------------------

def _ps(args):
    fake = _ps_fake(args)
    if fake is not None:
        return fake
    try:
        proc = subprocess.Popen(
            ["ps"] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            env={"LC_ALL": "C", "LANG": "C", "PATH": "/bin:/usr/bin"},
            close_fds=True,
        )
    except OSError:
        return None
    try:
        out, _err = proc.communicate(timeout=PS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        return None
    if proc.returncode != 0:
        return ""
    return out.decode("utf-8", "replace")


def sample_process(pid):
    """Two matching `LC_ALL=C ps -o lstart=` samples plus PPID/PGID evidence."""
    require_int(pid, 2, 2 ** 31 - 1, "pid_invalid", "pid")
    first = _ps(["-o", "lstart=", "-p", str(pid)])
    if first is None:
        return {"state": "unknown"}
    first = first.strip()
    if not first:
        return {"state": "exited"}
    second = _ps(["-o", "lstart=", "-p", str(pid)])
    if second is None:
        return {"state": "unknown"}
    second = second.strip()
    if not second:
        return {"state": "exited"}
    if first != second:
        return {"state": "unstable"}
    detail = _ps(["-o", "ppid=,pgid=,command=", "-p", str(pid)])
    if detail is None:
        return {"state": "unknown"}
    detail = detail.strip()
    if not detail:
        return {"state": "exited"}
    fields = detail.split(None, 2)
    if len(fields) < 3:
        return {"state": "unknown"}
    try:
        ppid = int(fields[0], 10)
        pgid = int(fields[1], 10)
    except ValueError:
        return {"state": "unknown"}
    command = fields[2]
    return {
        "state": "alive",
        "lstart": bounded(first, 64),
        "ppid": ppid,
        "pgid": pgid,
        "command_digest": sha256_hex(command.encode("utf-8", "replace")),
        "command_display": bounded(command, MAX_CMD_DISPLAY),
    }


def classify_process(record):
    # A record registered without a live baseline sample (the helper could not
    # observe the PID at registration time) can never be resolved later: an
    # empty `ps` is indistinguishable from "never existed". It stays unknown
    # and therefore blocks closure (blueprint gate 21).
    if record.get("lstart") is None:
        return "unknown"
    sample = sample_process(record["pid"])
    state = sample.get("state")
    if state == "exited":
        return "exited"
    if state in ("unknown", "unstable"):
        return "unknown"
    if sample.get("lstart") != record.get("lstart"):
        return "reused"
    # Same start time but different command image: a foreign process now owns
    # this PID, so the evidence is unresolved, never alive (P2-2; gate 21).
    if sample.get("command_digest") != record.get("command_digest"):
        return "foreign"
    return "alive"


def _process_table():
    raw = _ps(["-A", "-o", "pid=,ppid=,command="])
    if raw is None:
        return None
    rows = []
    for line in raw.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) < 3:
            continue
        try:
            pid = int(fields[0], 10)
            ppid = int(fields[1], 10)
        except ValueError:
            continue
        rows.append({"pid": pid, "ppid": ppid, "command": fields[2]})
        if len(rows) > 65536:
            break
    return rows


def scan_unregistered(review_id, payload_path, registered_pids):
    """Read-only discriminator scan. Never signals, never matches this process tree."""
    rows = _process_table()
    if rows is None:
        return {"state": "unknown", "pids": []}
    by_pid = dict((row["pid"], row) for row in rows)
    ancestors = set()
    cursor = os.getpid()
    for _hop in range(64):
        if cursor in ancestors or cursor <= 0:
            break
        ancestors.add(cursor)
        row = by_pid.get(cursor)
        if row is None:
            break
        cursor = row["ppid"]
    found = []
    for row in rows:
        if row["pid"] in ancestors or row["pid"] in registered_pids:
            continue
        command = row["command"]
        if review_id in command or (payload_path and payload_path in command):
            found.append(row["pid"])
        if len(found) >= MAX_PROCESSES:
            break
    return {"state": "clean" if not found else "unregistered", "pids": found}


def process_evidence(fds, payload_fd, review_id, payload_path):
    """Load every registered process record and classify it. No mutation."""
    if try_lstat_at(payload_fd, "processes") is None:
        return {"records": [], "classes": {}, "blockers": ["processes_missing"]}
    dir_fd = fds.keep(open_dir_at(payload_fd, "processes"))
    records = []
    for name in list_dir_at(dir_fd, "processes"):
        # Hostile or partial evidence makes the review red; it is never
        # silently skipped (P2-3).
        if not name.endswith(".json") or not ID_RE.match(name[:-5]):
            fail("process_evidence_invalid",
                 "unexpected entry in the process evidence directory")
        record = read_flat_record(dir_fd, name, "process", "process record %s" % (name,))
        records.append(record)
        if len(records) > MAX_PROCESSES:
            fail("process_table_too_large", "too many registered processes")
    classes = {}
    blockers = []
    registered = set()
    for record in records:
        registered.add(record["pid"])
        state = classify_process(record)
        classes["%s:%d" % (record["role"], record["pid"])] = state
        if state != "exited":
            blockers.append("process_%s" % (state,))
    scan = scan_unregistered(review_id, payload_path, registered)
    if scan["state"] == "unregistered":
        blockers.append("process_unregistered_discriminator")
    elif scan["state"] == "unknown":
        blockers.append("process_scan_unknown")
    return {
        "records": records,
        "classes": classes,
        "blockers": sorted(set(blockers)),
        "clean": not blockers,
        "scan": scan["state"],
    }


# ---------------------------------------------------------------------------
# Section 11. Write-once report sealing
# ---------------------------------------------------------------------------

REPORT_COMMIT_RE = re.compile(r"^Reviewed-Commit: ([0-9a-f]{40}|[0-9a-f]{64})$", re.M)
REPORT_VERDICT_RE = re.compile(r"^Verdict: (PASS|HOLD|FAIL)$", re.M)
REPORT_REVIEWER_RE = re.compile(r"^Reviewer: ([A-Za-z0-9][A-Za-z0-9._-]{0,63})$", re.M)


def parse_report(data, commit, reviewer_actor):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        fail("report_not_utf8", "report is not valid UTF-8")
    checks = (
        ("Reviewed-Commit", REPORT_COMMIT_RE),
        ("Verdict", REPORT_VERDICT_RE),
        ("Reviewer", REPORT_REVIEWER_RE),
    )
    values = {}
    for label, pattern in checks:
        matches = pattern.findall(text)
        if len(matches) != 1:
            fail("report_header_invalid",
                 "report must contain exactly one anchored %s header" % (label,))
        values[label] = matches[0]
    if values["Reviewed-Commit"] != commit:
        fail("report_commit_mismatch", "report does not name the pinned commit")
    if values["Reviewer"] != reviewer_actor:
        fail("report_reviewer_mismatch", "report does not name the bound reviewer actor")
    return {"verdict": values["Verdict"], "reviewed_commit": values["Reviewed-Commit"],
            "reviewer": values["Reviewer"]}


def seal_report(fds, binding, commit, reviewer_actor):
    """Copy inbox -> 0600 O_EXCL temp -> hard link to absent sealed/report.txt."""
    payload_fd = binding.payload_fd
    if try_lstat_at(payload_fd, "inbox") is None:
        fail("report_missing", "the payload has no inbox directory")
    inbox_fd = fds.keep(open_dir_at(payload_fd, "inbox"))
    sealed_fd = fds.keep(open_dir_at(payload_fd, "sealed"))

    existing = try_lstat_at(sealed_fd, "report.txt")
    if existing is not None:
        fail("report_already_sealed", "a sealed report already exists")

    pending = try_lstat_at(inbox_fd, "report.pending")
    if pending is None:
        fail("report_missing", "inbox/report.pending is absent")
    if statmod.S_ISLNK(pending.st_mode):
        fail("report_symlink", "inbox/report.pending is a symlink")
    if not statmod.S_ISREG(pending.st_mode):
        fail("report_not_regular", "inbox/report.pending is not a regular file")

    fd = open_file_at(inbox_fd, "report.pending", code="report_missing",
                      what="inbox/report.pending")
    try:
        info = os.fstat(fd)
        if not statmod.S_ISREG(info.st_mode):
            fail("report_not_regular", "inbox/report.pending is not a regular file")
        if info.st_uid != os.getuid():
            fail("report_owner", "inbox/report.pending is not owned by the current user")
        if statmod.S_IMODE(info.st_mode) & ~0o600:
            fail("report_mode", "inbox/report.pending mode is broader than 0600")
        if info.st_size < 1 or info.st_size > MAX_REPORT_BYTES:
            fail("report_size", "inbox/report.pending size must be 1..%d bytes"
                 % (MAX_REPORT_BYTES,))
        if not same_identity(identity(info), identity(pending)):
            fail("report_unstable", "inbox/report.pending changed between lstat and open")
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
            if len(data) > MAX_REPORT_BYTES:
                fail("report_size", "inbox/report.pending grew past the bound")
        final = os.fstat(fd)
        if not same_identity(identity(final), identity(info)) or final.st_size != info.st_size:
            fail("report_unstable", "inbox/report.pending changed during the read")
        if len(data) != info.st_size:
            fail("report_unstable", "inbox/report.pending size disagreed with its content")
    finally:
        os.close(fd)

    parsed = parse_report(data, commit, reviewer_actor)
    digest = sha256_hex(data)

    tmp_name = ".report.%s" % (secrets.token_hex(8),)
    write_file_at(sealed_fd, tmp_name, data, mode=FILE_MODE)
    try:
        try:
            os.link(tmp_name, "report.txt", src_dir_fd=sealed_fd,
                    dst_dir_fd=sealed_fd, follow_symlinks=False)
        except FileExistsError:
            fail("report_already_sealed", "a sealed report appeared concurrently")
        except OSError as exc:
            fail("report_publish_failed", "cannot publish the sealed report: %s"
                 % (exc.strerror,))
        temp_info = lstat_at(sealed_fd, tmp_name, code="report_unstable",
                             what="sealed temp")
        final_info = lstat_at(sealed_fd, "report.txt", code="report_unstable",
                              what="sealed/report.txt")
        if not same_identity(identity(temp_info), identity(final_info)):
            raise CoordError("transition_incomplete_report",
                             "sealed names do not reference the same inode")
        if temp_info.st_nlink != 2 or final_info.st_nlink != 2:
            raise CoordError("transition_incomplete_report",
                             "sealed link count is not 2 before unlink")
        if sha256_hex(read_file_at(sealed_fd, "report.txt", MAX_REPORT_BYTES,
                                   what="sealed/report.txt")) != digest:
            raise CoordError("transition_incomplete_report",
                             "sealed report digest changed before unlink")
        crash_hook("seal.linked")
        os.unlink(tmp_name, dir_fd=sealed_fd)
        fsync_dir(sealed_fd)
    except CoordError:
        raise
    after = lstat_at(sealed_fd, "report.txt", code="report_unstable",
                     what="sealed/report.txt")
    if not same_identity(identity(after), identity(final_info)):
        raise CoordError("transition_incomplete_report",
                         "sealed report identity changed after unlink")
    if after.st_nlink != 1:
        raise CoordError("transition_incomplete_report",
                         "sealed report link count is not 1 after unlink")
    if sha256_hex(read_file_at(sealed_fd, "report.txt", MAX_REPORT_BYTES,
                               what="sealed/report.txt")) != digest:
        raise CoordError("transition_incomplete_report",
                         "sealed report digest changed after unlink")
    binding.recheck()
    return {"digest": digest, "verdict": parsed["verdict"], "bytes": len(data)}


def read_sealed_report(fds, binding, commit, reviewer_actor):
    sealed_fd = fds.keep(open_dir_at(binding.payload_fd, "sealed"))
    info = try_lstat_at(sealed_fd, "report.txt")
    if info is None:
        return None
    if statmod.S_ISLNK(info.st_mode) or not statmod.S_ISREG(info.st_mode):
        fail("report_not_regular", "sealed/report.txt is not a regular file")
    if info.st_nlink != 1:
        raise CoordError("transition_incomplete_report",
                         "sealed report has an unexpected link count")
    data = read_file_at(sealed_fd, "report.txt", MAX_REPORT_BYTES,
                        what="sealed/report.txt")
    parsed = parse_report(data, commit, reviewer_actor)
    return {"digest": sha256_hex(data), "verdict": parsed["verdict"],
            "bytes": len(data)}


def detect_incomplete_report(fds, payload_fd):
    """Crash residue: a stale sealed temp or nlink=2 final refuses every advance."""
    if try_lstat_at(payload_fd, "sealed") is None:
        return None
    sealed_fd = fds.keep(open_dir_at(payload_fd, "sealed"))
    stale = [name for name in list_dir_at(sealed_fd, "sealed")
             if name.startswith(".report.")]
    info = try_lstat_at(sealed_fd, "report.txt")
    if stale:
        return "transition_incomplete_report"
    if info is not None and statmod.S_ISREG(info.st_mode) and info.st_nlink != 1:
        return "transition_incomplete_report"
    return None


# ---------------------------------------------------------------------------
# Section 12. Lease transaction commands
# ---------------------------------------------------------------------------

def precheck_capability_fd(fd, direction):
    """Validate a capability FD before any state mutation; never write here."""
    info = _fd_stat(fd, "capability %s fd" % (direction,))
    flags = _fd_flags(fd)
    if statmod.S_ISREG(info.st_mode):
        _require_regular_capability_fd(fd, info, "capability %s fd" % (direction,))
        if direction == "output":
            if info.st_size != 0:
                fail("fd_not_empty", "capability output fd must be empty")
            if (flags & os.O_ACCMODE) not in (os.O_WRONLY, os.O_RDWR):
                fail("fd_not_writable", "capability output fd is not writable")
            if flags & os.O_APPEND:
                fail("fd_append_mode", "capability output fd must not be append-mode")
        return
    if statmod.S_ISFIFO(info.st_mode):
        return
    fail("fd_type_rejected", "capability %s fd must be a regular file or pipe" % (direction,))


def open_context(args, create_state=True, need_git_home=True):
    """Common front matter: validated base, scrubbed Git home, canonical repo."""
    fds = FDSet()
    _SCRATCH["fdsets"].append(fds)
    base = open_payload_base(fds)
    _enable_test_hooks(base)
    git_home = make_git_home(fds, base) if need_git_home else None
    repo = resolve_repo(getattr(args, "worktree", None) or getattr(args, "repo", None)
                        or os.getcwd(), git_home)
    assert_payload_outside_repo(base.path, base.path, repo)
    state = StateRoot(fds, repo, create=create_state)
    return {"fds": fds, "base": base, "git_home": git_home, "repo": repo,
            "state": state}


def find_worktree_claim(state, repo, allow_missing=True):
    if not state.present:
        return None
    return read_record(state.claim_worktrees, repo["worktree_key"], "claim",
                       "worktree claim", allow_missing=allow_missing)


def load_lease(state, lease_id, allow_missing=False):
    require_match(ID_RE, lease_id, "lease_id_invalid", "lease id")
    return read_record(state.leases, lease_id, "lease", "lease record",
                       allow_missing=allow_missing)


def lease_head_state(repo, lease, git_home):
    if lease is None:
        return "no_lease"
    if lease.get("detached") != repo["detached"] or lease.get("ref") != repo["ref"]:
        return "head_moved_conflicted"
    expected = lease.get("expected_head")
    if expected == repo["head"]:
        return "matches"
    if not isinstance(expected, str):
        return "head_moved_conflicted"
    result = git_raw(["-C", repo["top"], "merge-base", "--is-ancestor",
                      expected, repo["head"]], git_home, check=False)
    if result["rc"] == 0:
        return "head_moved_pending_checkpoint"
    return "head_moved_conflicted"


def cmd_lease_acquire(args):
    ctx = open_context(args)
    fds, base, git_home, repo, state = (
        ctx["fds"], ctx["base"], ctx["git_home"], ctx["repo"], ctx["state"])
    require_match(ACTOR_RE, args.actor, "actor_invalid", "actor")
    precheck_capability_fd(args.token_out_fd, "output")
    require_native_commit(repo, args.base, git_home, "base")
    if repo["head"] != args.base:
        fail("base_mismatch", "--base does not match the current worktree HEAD")
    scan = require_clean(repo, git_home, "lease acquire")

    token, verifier = mint_capability()
    now = int(time.time())
    mutex = TransitionMutex(state)
    with mutex:
        if find_worktree_claim(state, repo) is not None:
            fail("lease_conflict", "this worktree already has a coordination claim")
        if repo["ref_key"] is not None:
            existing = read_record(state.claim_refs, repo["ref_key"], "claim",
                                   "ref claim", allow_missing=True)
            if existing is not None:
                fail("lease_conflict", "this ref already has a coordination claim")
        lease_id = secrets.token_hex(16)
        if try_lstat_at(state.leases, lease_id) is not None:
            fail("lease_conflict", "lease identifier collision")
        lease = new_record("lease", 1, {
            "lease_id": lease_id,
            "repo_id": repo["repo_id"],
            "top": repo["top"],
            "common_dir": repo["common_dir"],
            "actor": args.actor,
            "algo": repo["algo"],
            "ref": repo["ref"],
            "detached": repo["detached"],
            "base_head": args.base,
            "expected_head": args.base,
            "expected_tree": repo["tree"],
            "capability": verifier,
            "worktree_key": repo["worktree_key"],
            "ref_key": repo["ref_key"],
            "state": "active",
            "created_at": now,
            "updated_at": now,
            "released_at": None,
            "clean_digest": scan["digest"],
            "checkpoint_count": 0,
        })
        lease_fd = publish_record(fds, state.leases, lease_id, "lease", lease,
                                  "lease record")
        ensure_owned_dir(fds, lease_fd, "checkpoints", "lease checkpoints")
        claim_fields = {
            "lease_id": lease_id, "repo_id": repo["repo_id"], "top": repo["top"],
            "ref": repo["ref"], "actor": args.actor, "created_at": now,
        }
        publish_record(fds, state.claim_worktrees, repo["worktree_key"], "claim",
                       new_record("claim", 1, dict(claim_fields, **{
                           "claim_key": repo["worktree_key"], "claim_type": "worktree"})),
                       "worktree claim")
        if repo["ref_key"] is not None:
            publish_record(fds, state.claim_refs, repo["ref_key"], "claim",
                           new_record("claim", 1, dict(claim_fields, **{
                               "claim_key": repo["ref_key"], "claim_type": "ref"})),
                           "ref claim")

    write_capability_fd(args.token_out_fd, token)
    result = {
        "ok": True, "command": "lease-acquire", "lease_id": lease_id,
        "repo_id": repo["repo_id"], "top": repo["top"], "actor": args.actor,
        "ref": repo["ref"] or "DETACHED", "expected_head": args.base,
        "algo": repo["algo"], "generation": 1, "clean_digest": scan["digest"],
        "capability_delivered": "fd",
    }
    git_home.release()
    fds.close_all()
    return result


def cmd_lease_status(args):
    ctx = open_context(args, create_state=False)
    fds, git_home, repo, state = ctx["fds"], ctx["git_home"], ctx["repo"], ctx["state"]
    payload = {
        "ok": True, "command": "lease-status", "repo_id": repo["repo_id"],
        "top": repo["top"], "common_dir": repo["common_dir"], "algo": repo["algo"],
        "head": repo["head"], "tree": repo["tree"],
        "ref": repo["ref"] or "DETACHED", "detached": repo["detached"],
    }
    if not state.present:
        payload.update({"lease_state": "none", "head_state": "no_lease",
                        "transition": "none", "status": "green"})
        git_home.release()
        fds.close_all()
        return payload

    def reader():
        claim = find_worktree_claim(state, repo)
        if claim is None:
            return {"claim": None, "lease": None}
        lease = load_lease(state, claim["record"]["lease_id"])["record"]
        ref_claim = None
        if lease["ref_key"] is not None:
            ref_entry = read_record(state.claim_refs, lease["ref_key"], "claim",
                                    "ref claim", allow_missing=True)
            ref_claim = ref_entry["record"] if ref_entry is not None else None
        validate_claim_records(lease, claim["record"], ref_claim)
        return {"claim": claim["record"], "lease": lease}

    try:
        snapshot = double_sampled(state, reader)
    except CoordError as exc:
        payload.update({"lease_state": exc.code, "head_state": "unknown",
                        "transition": "in_progress"
                        if exc.code == "transition_in_progress" else "none",
                        "status": "red", "detail": exc.detail})
        git_home.release()
        fds.close_all()
        return payload

    lease = snapshot["lease"]
    if lease is None:
        payload.update({"lease_state": "none", "head_state": "no_lease",
                        "transition": "none", "status": "green"})
    else:
        payload.update({
            "lease_state": lease["state"],
            "lease_id": lease["lease_id"],
            "lease_actor": lease["actor"],
            "generation": lease["generation"],
            "expected_head": lease["expected_head"],
            "checkpoint_count": lease["checkpoint_count"],
            "head_state": lease_head_state(repo, lease, git_home),
            "transition": "none",
        })
        payload["status"] = "green" if payload["head_state"] in (
            "matches", "head_moved_pending_checkpoint") else "red"
    git_home.release()
    fds.close_all()
    return payload


def validate_claim_records(lease, worktree_claim, ref_claim):
    """One generation and one identity across lease + worktree claim + ref claim.

    Every cross-record ID, key, repo/top/ref field, and the common generation
    must agree; a missing, mismatched, or generation-swapped claim fails
    closed (P1-2; design §6; blueprint gates 2/6/7/23).
    """
    expected = [("worktree", lease["worktree_key"], worktree_claim)]
    if lease["ref_key"] is not None:
        expected.append(("ref", lease["ref_key"], ref_claim))
    for claim_type, key, claim in expected:
        if claim is None:
            fail("claim_missing", "the %s claim is absent" % (claim_type,))
        if claim["claim_type"] != claim_type or claim["claim_key"] != key:
            fail("claim_mismatch", "the %s claim key/type is wrong" % (claim_type,))
        if claim["lease_id"] != lease["lease_id"] \
                or claim["repo_id"] != lease["repo_id"] \
                or claim["top"] != lease["top"] \
                or claim["ref"] != lease["ref"]:
            fail("claim_mismatch",
                 "the %s claim does not describe this lease" % (claim_type,))
        if claim["generation"] != lease["generation"]:
            fail("generation_mismatch",
                 "the %s claim is on a different generation" % (claim_type,))


def _authorize_lease(state, repo, token, git_home):
    claim = find_worktree_claim(state, repo, allow_missing=True)
    if claim is None:
        fail("lease_absent", "this worktree holds no coordination claim")
    lease_entry = load_lease(state, claim["record"]["lease_id"])
    lease = lease_entry["record"]
    if lease["state"] != "active":
        fail("lease_not_active", "the lease is not active")
    if not capability_matches(lease.get("capability"), token):
        fail("capability_rejected", "the supplied capability does not authorize this lease")
    if lease["repo_id"] != repo["repo_id"] or lease["top"] != repo["top"]:
        fail("identity_mismatch", "the lease does not describe this worktree")
    if lease["worktree_key"] != repo["worktree_key"] \
            or lease["ref_key"] != repo["ref_key"]:
        fail("identity_mismatch", "the lease claim keys do not match this worktree")
    if lease["ref"] != repo["ref"] or lease["detached"] != repo["detached"]:
        fail("head_moved_conflicted", "the worktree ref or detached state changed")
    ref_claim = None
    if lease["ref_key"] is not None:
        ref_claim = read_record(state.claim_refs, lease["ref_key"], "claim",
                                "ref claim", allow_missing=True)
        if ref_claim is None:
            fail("claim_missing", "the attached ref claim is absent")
        ref_claim = ref_claim["record"]
    validate_claim_records(lease, claim["record"], ref_claim)
    return lease


def cmd_lease_checkpoint(args):
    ctx = open_context(args, create_state=False)
    fds, git_home, repo, state = ctx["fds"], ctx["git_home"], ctx["repo"], ctx["state"]
    if not state.present:
        fail("lease_absent", "this repository has no coordination state")
    token = read_capability_fd(args.token_fd)
    require_native_commit(repo, args.old, git_home, "--old")
    require_native_commit(repo, args.new, git_home, "--new")
    if args.old == args.new:
        fail("checkpoint_identical", "--old and --new are the same commit")

    mutex = TransitionMutex(state)
    with mutex:
        lease = _authorize_lease(state, repo, token, git_home)
        if lease["expected_head"] != args.old:
            fail("head_moved_conflicted", "--old is not the recorded expected head")
        if repo["head"] != args.new:
            fail("head_moved_conflicted", "the worktree HEAD is not --new")
        if repo["ref"] is not None:
            tip = git_line(["-C", repo["top"], "rev-parse", "--verify", "--quiet",
                            repo["ref"]], git_home, check=False)
            if tip != args.new:
                fail("head_moved_conflicted", "the attached ref tip is not --new")
        ancestor = git_raw(["-C", repo["top"], "merge-base", "--is-ancestor",
                            args.old, args.new], git_home, check=False)
        if ancestor["rc"] != 0:
            fail("head_moved_conflicted", "--new is not a fast-forward descendant of --old")
        # Final immediate reread: a second movement during the transaction loses.
        confirm = resolve_repo(repo["top"], git_home)
        if confirm["head"] != args.new or confirm["ref"] != repo["ref"] \
                or confirm["detached"] != repo["detached"]:
            fail("head_moved_conflicted", "HEAD moved again during the checkpoint")
        tree = confirm["tree"]

        generation = lease["generation"] + 1
        if lease["checkpoint_count"] >= MAX_CHECKPOINTS:
            fail("checkpoint_limit", "the lease has too many checkpoints")
        lease_fd = fds.keep(open_dir_at(state.leases, lease["lease_id"]))
        checkpoints_fd, _ = ensure_owned_dir(fds, lease_fd, "checkpoints",
                                             "lease checkpoints")
        entry_name = "%06d.json" % (generation,)
        if try_lstat_at(checkpoints_fd, entry_name) is not None:
            fail("checkpoint_exists", "a checkpoint already exists for this generation")
        publish_flat_record(checkpoints_fd, entry_name, "checkpoint",
                            new_record("checkpoint", generation, {
                                "lease_id": lease["lease_id"],
                                "old": args.old, "new": args.new, "tree": tree,
                                "actor": lease["actor"], "ref": repo["ref"],
                                "recorded_at": int(time.time()),
                            }), "checkpoint record")

        updated = dict(lease)
        updated["generation"] = generation
        updated["expected_head"] = args.new
        updated["expected_tree"] = tree
        updated["updated_at"] = int(time.time())
        updated["checkpoint_count"] = lease["checkpoint_count"] + 1
        publish_record(fds, state.leases, lease["lease_id"], "lease", updated,
                       "lease record")
        claim = read_record(state.claim_worktrees, repo["worktree_key"], "claim",
                            "worktree claim")["record"]
        claim = dict(claim)
        if claim["lease_id"] != lease["lease_id"] \
                or claim["claim_key"] != repo["worktree_key"] \
                or claim["claim_type"] != "worktree" \
                or claim["generation"] != lease["generation"]:
            fail("claim_mismatch",
                 "the worktree claim changed during the checkpoint")
        claim["generation"] = generation
        publish_record(fds, state.claim_worktrees, repo["worktree_key"], "claim",
                       claim, "worktree claim")
        if repo["ref_key"] is not None:
            # The ref claim was proven to belong to this lease by
            # _authorize_lease; require it to still exist on the pre-update
            # generation and never silently skip or overwrite a swap (P1-2).
            ref_claim = read_record(state.claim_refs, repo["ref_key"], "claim",
                                    "ref claim", allow_missing=False)
            ref_record = dict(ref_claim["record"])
            if ref_record["lease_id"] != lease["lease_id"] \
                    or ref_record["claim_key"] != repo["ref_key"] \
                    or ref_record["claim_type"] != "ref" \
                    or ref_record["repo_id"] != repo["repo_id"] \
                    or ref_record["top"] != repo["top"] \
                    or ref_record["ref"] != repo["ref"] \
                    or ref_record["generation"] != lease["generation"]:
                fail("claim_mismatch",
                     "the ref claim changed during the checkpoint")
            ref_record["generation"] = generation
            publish_record(fds, state.claim_refs, repo["ref_key"], "claim",
                           ref_record, "ref claim")

    result = {"ok": True, "command": "lease-checkpoint",
              "lease_id": lease["lease_id"], "generation": generation,
              "old": args.old, "new": args.new, "tree": tree,
              "checkpoint_count": updated["checkpoint_count"]}
    git_home.release()
    fds.close_all()
    return result


def _remove_exact_claim(state, dir_fd, key, what):
    """Remove exactly one manifest-backed claim entry. No glob, no recursion."""
    require_match(re.compile(r"\A[0-9a-f]{64}\Z"), key, "claim_key_invalid", what)
    info = try_lstat_at(dir_fd, key)
    if info is None:
        return False
    if statmod.S_ISLNK(info.st_mode) or not statmod.S_ISDIR(info.st_mode):
        fail("claim_invalid", "%s is not a real directory" % (what,))
    entry_fd = open_dir_at(dir_fd, key, code="claim_invalid", what=what)
    try:
        names = list_dir_at(entry_fd, what)
        for name in names:
            if name not in ("record.json", "READY") and not name.startswith(".tmp."):
                fail("claim_unexpected_entry",
                     "%s contains an unexpected entry" % (what,))
        for name in names:
            try:
                os.unlink(name, dir_fd=entry_fd)
            except FileNotFoundError:
                pass
        fsync_dir(entry_fd)
    finally:
        os.close(entry_fd)
    try:
        os.rmdir(key, dir_fd=dir_fd)
    except OSError as exc:
        fail("claim_release_failed", "%s: %s" % (what, exc.strerror))
    fsync_dir(dir_fd)
    return True


def cmd_lease_release(args):
    ctx = open_context(args, create_state=False)
    fds, git_home, repo, state = ctx["fds"], ctx["git_home"], ctx["repo"], ctx["state"]
    if not state.present:
        fail("lease_absent", "this repository has no coordination state")
    token = read_capability_fd(args.token_fd)
    require_native_commit(repo, args.head, git_home, "--head")
    scan = require_clean(repo, git_home, "lease release")

    mutex = TransitionMutex(state)
    with mutex:
        lease = _authorize_lease(state, repo, token, git_home)
        if lease["expected_head"] != args.head:
            fail("head_moved_conflicted", "--head is not the recorded expected head")
        if repo["head"] != args.head:
            fail("head_moved_conflicted", "the worktree HEAD is not --head")
        if repo["ref"] is not None:
            tip = git_line(["-C", repo["top"], "rev-parse", "--verify", "--quiet",
                            repo["ref"]], git_home, check=False)
            if tip != args.head:
                fail("head_moved_conflicted", "the attached ref tip is not --head")
        updated = dict(lease)
        updated["generation"] = lease["generation"] + 1
        updated["state"] = "released"
        updated["released_at"] = int(time.time())
        updated["updated_at"] = updated["released_at"]
        updated["clean_digest"] = scan["digest"]
        publish_record(fds, state.leases, lease["lease_id"], "lease", updated,
                       "lease record")
        removed = []
        if _remove_exact_claim(state, state.claim_worktrees, lease["worktree_key"],
                               "worktree claim"):
            removed.append("worktree")
        if lease["ref_key"]:
            if _remove_exact_claim(state, state.claim_refs, lease["ref_key"],
                                   "ref claim"):
                removed.append("ref")

    result = {"ok": True, "command": "lease-release", "lease_id": lease["lease_id"],
              "generation": updated["generation"], "head": args.head,
              "claims_removed": ",".join(removed) or "none",
              "history_retained": True, "clean_digest": scan["digest"]}
    git_home.release()
    fds.close_all()
    return result


# ---------------------------------------------------------------------------
# Section 13. Review create (commit pin, payload extraction, launch wrapper)
# ---------------------------------------------------------------------------

# Identity-input environment variables recorded (not trusted) by review create.
# Each is a description of the invoking actor, never an authority: the review is
# pinned to the native commit, and the process capability is minted here.
_MODEL_ENV = "STITCHPAD_MODEL"
_SESSION_ENV = "STITCHPAD_SESSION"
_REQUEST_ENV = "STITCHPAD_REQUEST"
_WORKTREE_ENV = "STITCHPAD_WORKTREE"
# Contract env vars: populate the facts.contract dict at review-create time.
# Each is optional — a missing env means the artifact is not contracted.
_CONTRACT_COMMIT_ENV = "STITCHPAD_CONTRACT_COMMIT"
_CONTRACT_REPORT_ENV = "STITCHPAD_CONTRACT_REPORT"
_CONTRACT_SIDECAR_ENV = "STITCHPAD_CONTRACT_SIDECAR"
_CONTRACT_SIDECAR_DIGEST_ENV = "STITCHPAD_CONTRACT_SIDECAR_DIGEST"


def _read_contract():
    """Build the contract dict from env; None if no contract is specified."""
    commit = _bounded_env(_CONTRACT_COMMIT_ENV, limit=128)
    report = _bounded_env(_CONTRACT_REPORT_ENV, limit=MAX_PATH_BYTES)
    sidecar = _bounded_env(_CONTRACT_SIDECAR_ENV, limit=MAX_PATH_BYTES)
    sidecar_digest = _bounded_env(_CONTRACT_SIDECAR_DIGEST_ENV, limit=128)
    contract = {}
    if commit:
        contract["commit"] = commit
    if report:
        contract["report"] = report
    if sidecar:
        contract["sidecar"] = sidecar
    if sidecar_digest:
        contract["sidecar_digest"] = sidecar_digest
    return contract if contract else None


def _facts_contract(facts):
    """Assemble the contract dict from flattened scalar facts fields.

    The record layer enforces scalar-only fields (validate_record), so the
    contract is persisted as contract_commit/report/sidecar/sidecar_digest
    and reassembled here. None when the dispatch declared no contract.
    """
    contract = {}
    for flat, key in (("contract_commit", "commit"),
                      ("contract_report", "report"),
                      ("contract_sidecar", "sidecar"),
                      ("contract_sidecar_digest", "sidecar_digest")):
        value = facts.get(flat)
        if value:
            contract[key] = value
    return contract or None


def _parse_series_sidecar(data):
    """Parse fleet series sidecar bytes (``shasum -a 256`` output).

    Accepts ``<64-hex><whitespace>[*]<filename>`` on the first line, as
    produced by ``shasum -a 256 report.md > report.md.sha256``. Returns the
    lowercase digest or None when unparseable.
    """
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None
    line = text.split("\n")[0].strip()
    m = re.match(r"^([0-9A-Fa-f]{64})[ \t]+\*?\S.*$", line)
    if m is None:
        return None
    return m.group(1).lower()


def _sha256_file(path):
    """Stream a file's sha256; None on OSError."""
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(65536)
                if not chunk:
                    break
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def _check_contract_satisfaction(contract, repo=None):
    """Verify contract artifacts by existence + sidecar checksum.

    Never trusts seat claims — verifies filesystem and git object state
    directly.  The sidecar follows the fleet series format (``shasum -a
    256`` output) and must pin the report's actual digest; an optional
    contract ``sidecar_digest`` additionally pins the sidecar's own bytes.
    ``repo`` (optional) enables commit-existence verification against the
    review's own object store.  Returns (satisfied, blockers_list).
    """
    blockers = []
    if contract is None:
        return True, blockers
    report_path = contract.get("report")
    if report_path and not os.path.isfile(report_path):
        blockers.append("contract_report_missing")
    sidecar_path = contract.get("sidecar")
    if sidecar_path:
        if not os.path.isfile(sidecar_path):
            blockers.append("contract_sidecar_missing")
        else:
            sidecar_digest = _sha256_file(sidecar_path)
            if sidecar_digest is None:
                blockers.append("contract_sidecar_unreadable")
            else:
                if contract.get("sidecar_digest") \
                        and sidecar_digest != contract["sidecar_digest"]:
                    blockers.append("contract_sidecar_digest_mismatch")
                try:
                    with open(sidecar_path, "rb") as fh:
                        pinned = _parse_series_sidecar(
                            fh.read(MAX_RECORD_BYTES + 1))
                except OSError:
                    pinned = None
                if pinned is None:
                    blockers.append("contract_sidecar_malformed")
                elif report_path and os.path.isfile(report_path):
                    report_digest = _sha256_file(report_path)
                    if report_digest is None:
                        blockers.append("contract_report_unreadable")
                    elif report_digest != pinned:
                        blockers.append("contract_report_digest_mismatch")
    commit = contract.get("commit")
    if commit:
        if not HEX_RE.match(commit):
            blockers.append("contract_commit_invalid")
        elif repo is not None:
            result = git_raw(["-C", repo["top"], "cat-file", "-e",
                              "%s^{commit}" % (commit,)],
                             None, check=False)
            if result["rc"] != 0:
                blockers.append("contract_commit_missing")
    return len(blockers) == 0, blockers


def _bounded_env(name, limit=128):
    raw = os.environ.get(name)
    if raw is None:
        return None
    if not isinstance(raw, str):
        return None
    if len(raw) > limit:
        fail("identity_input_too_long", "%s exceeds %d characters" % (name, limit))
    return raw


def _git_archive(repo, commit, git_home):
    """Bounded `git archive` of the pinned commit, returned as raw bytes."""
    argv = ["-C", repo["top"], "archive", "--format=tar", commit]
    result = git_raw(argv, git_home, binary=True, limit=MAX_ARCHIVE_BYTES)
    if result["rc"] != 0:
        fail("archive_failed", "git archive failed: %s" % (result["err"],))
    data = result["raw"]
    if not data or len(data) > MAX_ARCHIVE_BYTES:
        fail("archive_failed", "git archive produced no usable output")
    return data


def _build_launch_wrapper(ceiling, src_path, worktree_path):
    """Return the bytes of the reviewer launch wrapper.

    The wrapper sets ``GIT_CEILING_DIRECTORIES`` to the helper-derived ceiling
    (the payload *base*, proven ``.git``-free by base validation) and
    ``GIT_DISCOVERY_ACROSS_FILESYSTEM=0`` before exec'ing the reviewer with cwd
    pinned to the extracted ``src`` tree. It is pure argv composition derived
    from values this helper computed; it carries no capability and no caller
    input beyond the paths the helper itself bound.
    """
    lines = [
        "#!/bin/bash",
        "# Stitchpad reviewer launch wrapper (generated by coordination_verify.py).",
        "# Applies the helper-derived Git discovery ceiling and pins cwd to src.",
        "set -uo pipefail",
        'export GIT_CEILING_DIRECTORIES="%s"' % (ceiling.replace('"', '\\"'),),
        "export GIT_DISCOVERY_ACROSS_FILESYSTEM=0",
        'cd "%s" || exit 70' % (src_path.replace('"', '\\"'),),
        'STITCHPAD_WORKTREE="%s" exec "$@"' % (worktree_path.replace('"', '\\"'),),
        "",
    ]
    return "\n".join(lines).encode("utf-8")


def _validate_author_lease(state, repo, git_home, commit, author_actor):
    """The author must hold an active lease whose expected_head is the pinned
    commit or an ancestor of it, and the author actor must match.

    This binds the review to a real lease/checkpoint lineage: the review commit
    is within the author's leased-and-checkpointed history, never a free-floating
    OID. Distinct actors (author != reviewer) is enforced by the caller.
    """
    claim = find_worktree_claim(state, repo, allow_missing=True)
    if claim is None:
        fail("lease_absent", "no coordination lease covers this worktree")
    lease = load_lease(state, claim["record"]["lease_id"])["record"]
    if lease["state"] != "active":
        fail("lease_not_active", "the author lease is not active")
    if lease["actor"] != author_actor:
        fail("actor_mismatch",
             "the lease actor is not the review author actor")
    if lease["repo_id"] != repo["repo_id"] or lease["top"] != repo["top"]:
        fail("identity_mismatch", "the lease does not describe this worktree")
    expected = lease["expected_head"]
    if expected == commit:
        return lease
    # The pinned commit must be reachable from the author's expected_head
    # (a checkpoint the author already recorded), proving the lineage.
    result = git_raw(["-C", repo["top"], "merge-base", "--is-ancestor",
                      expected, commit], git_home, check=False)
    if result["rc"] != 0:
        fail("commit_outside_lease",
             "the pinned commit is not within the author lease lineage")
    return lease


def cmd_review_create(args):
    # Actor validation BEFORE any payload/git work: a self-review is refused
    # with its own distinct code before opening the coordination context,
    # so no expensive tree extraction or git plumbing runs for a doomed call.
    require_match(ACTOR_RE, args.author_actor, "actor_invalid", "author actor")
    require_match(ACTOR_RE, args.reviewer_actor, "actor_invalid", "reviewer actor")
    if args.author_actor == args.reviewer_actor:
        fail("actor_self",
             "the author and reviewer actors must be distinct")

    ctx = open_context(args)
    fds, base, git_home, repo, state = (
        ctx["fds"], ctx["base"], ctx["git_home"], ctx["repo"], ctx["state"])
    require_native_commit(repo, args.commit, git_home, "review commit")
    tree_oid = git_line(
        ["-C", repo["top"], "rev-parse", "--verify", "--quiet",
         args.commit + "^{tree}"], git_home, check=False
    )
    if not tree_oid:
        fail("commit_not_native", "the pinned commit has no tree object")
    require_oid(tree_oid, repo["algo"], "review tree")
    if args.provider != "ocean":
        fail("provider_unsupported",
             "only the ocean provider is supported by review create")
    precheck_capability_fd(args.process_token_out_fd, "output")

    lease = _validate_author_lease(state, repo, git_home, args.commit,
                                   args.author_actor)

    review_id = secrets.token_hex(16)
    if try_lstat_at(state.reviews, review_id) is not None:
        fail("review_conflict", "review identifier collision")

    # Pre-extraction: strict tree preflight before touching the payload base.
    entries = parse_tree(repo, args.commit, git_home)
    implied_dirs = preflight_layout(entries)

    # Create the payload directory under the validated base: <review_id>.<16hex>.
    payload_name = "%s.%s" % (review_id, secrets.token_hex(8))
    require_match(ENTRY_NAME_RE, payload_name, "payload_name_invalid", "payload name")
    payload_path = base.path + "/" + payload_name
    assert_payload_outside_repo(base.path, payload_path, repo)
    payload_fd, payload_identity = ensure_owned_dir(
        fds, base.fd, payload_name, "payload directory", mode=DIR_MODE)
    src_fd, src_identity = ensure_owned_dir(
        fds, payload_fd, "src", "payload src directory", mode=DIR_MODE)

    binding = RootBinding(fds, base, payload_name,
                          expect_payload=payload_identity, expect_src=src_identity)

    # git archive -> strict tar parse -> archive preflight -> extraction.
    archive_data = _git_archive(repo, args.commit, git_home)
    members = parse_tar(archive_data, expect_comment=args.commit)
    preflight_archive(members, entries, implied_dirs)
    inventory, _cache = extract_tree(
        fds, src_fd, archive_data, members, entries, implied_dirs, repo["algo"])
    final_records = walk_inventory(fds, src_fd, repo["algo"])
    inventory_bytes = encode_inventory(inventory)
    final_bytes = encode_inventory(final_records)
    if inventory_bytes != final_bytes:
        fail("inventory_mismatch",
             "extracted inventory disagrees with the final walked inventory")
    inventory_digest = sha256_hex(inventory_bytes)

    # The payload must not be a discoverable Git repository under scrubbed Git.
    git_home_scrub = make_git_home(fds, base)
    assert_no_git_discovery(payload_path, git_home_scrub)
    git_home_scrub.release()

    ceiling = reviewer_ceiling(base)

    # Launch wrapper: materialized under the payload and hashed for the manifest.
    launch_bytes = _build_launch_wrapper(ceiling, payload_path + "/src", repo["top"])
    launch_digest = sha256_hex(launch_bytes)

    # Identity inputs (recorded, never trusted).
    model = _bounded_env(_MODEL_ENV)
    session_id = _bounded_env(_SESSION_ENV)
    request_id = _bounded_env(_REQUEST_ENV)
    worktree_id = _bounded_env(_WORKTREE_ENV, limit=MAX_PATH_BYTES)

    # Process-registration capability minted here, off argv — never caller-set.
    token, verifier = mint_capability()
    now = int(time.time())

    mutex = TransitionMutex(state)
    with mutex:
        # Re-confirm idempotency under the lock.
        if try_lstat_at(state.reviews, review_id) is not None:
            fail("review_conflict", "review identifier collision")
        binding.recheck()

        # Manifest: pinned commit/tree/inventory/launch/ceiling facts.
        manifest = new_record("manifest", 1, {
            "review_id": review_id,
            "algo": repo["algo"],
            "commit": args.commit,
            "tree": tree_oid,
            "repo_id": repo["repo_id"],
            "entry_count": len(entries),
            "inventory_digest": inventory_digest,
            "src_identity": src_identity,
            "payload_identity": payload_identity,
            "launch_digest": launch_digest,
            "helper_digest": sha256_hex(canonical_json_bytes({
                "ceiling": ceiling, "provider": args.provider,
            })),
            "created_at": now,
            "ceiling": ceiling,
        })
        publish_flat_record(payload_fd, "manifest.json", "manifest", manifest,
                            "review manifest")

        # Pointer: where the payload lives in the external payload root.
        pointer = new_record("pointer", 1, {
            "review_id": review_id,
            "payload_base": base.path,
            "payload_path": payload_path,
            "payload_name": payload_name,
            "payload_identity": payload_identity,
            "src_identity": src_identity,
            "manifest_digest": sha256_hex(canonical_json_bytes(manifest)),
            "inventory_digest": inventory_digest,
            "created_at": now,
        })
        publish_flat_record(payload_fd, "pointer.json", "pointer", pointer,
                            "review pointer")

        # Facts: initial bound state, identity and contract inputs recorded.
        contract = _read_contract() or {}
        facts = new_record("facts", 1, {
            "review_id": review_id,
            "session_id": session_id,
            "request_id": request_id,
            "bound_at": now,
            "cancel_requested": False,
            "cancel_requested_at": None,
            "terminal_observed": False,
            "terminal_completion": None,
            "terminal_at": None,
            "report_sealed": False,
            "report_digest": None,
            "report_verdict": None,
            "report_sealed_at": None,
            "artifact_verified": False,
            "verified_at": None,
            "closure": None,
            "closure_reason": None,
            "closed_at": None,
            "conflict": None,
            "contract_commit": contract.get("commit"),
            "contract_report": contract.get("report"),
            "contract_sidecar": contract.get("sidecar"),
            "contract_sidecar_digest": contract.get("sidecar_digest"),
            "false_terminal": False,
            "false_terminal_reason": None,
            "false_terminal_at": None,
            "provider": args.provider,
            "provider_model": model,
            "session_rotation_required": False,
            "last_activity_at": now,
        })
        publish_flat_record(payload_fd, "facts.json", "facts", facts,
                            "review facts")

        # Launch wrapper published last, after all records are sealed.
        write_file_at(payload_fd, "launch.sh", launch_bytes, mode=EXEC_MODE)

        # Review record: the authoritative coordination entry.
        review = new_record("review", 1, {
            "review_id": review_id,
            "repo_id": repo["repo_id"],
            "top": repo["top"],
            "common_dir": repo["common_dir"],
            "algo": repo["algo"],
            "commit": args.commit,
            "tree": tree_oid,
            "author_actor": args.author_actor,
            "reviewer_actor": args.reviewer_actor,
            "provider": args.provider,
            "state": "created",
            "created_at": now,
            "updated_at": now,
            "lease_id": lease["lease_id"],
            "process_capability": verifier,
            "payload_name": payload_name,
            "closure": None,
            "closure_reason": None,
        })
        publish_record(fds, state.reviews, review_id, "review", review,
                       "review record")

    # Capability delivered last, after READY publication.
    write_capability_fd(args.process_token_out_fd, token)

    result = {
        "ok": True, "command": "review-create", "review_id": review_id,
        "repo_id": repo["repo_id"], "top": repo["top"],
        "commit": args.commit, "tree": tree_oid, "algo": repo["algo"],
        "author_actor": args.author_actor, "reviewer_actor": args.reviewer_actor,
        "provider": args.provider, "lease_id": lease["lease_id"],
        "payload_name": payload_name, "payload_path": payload_path,
        "ceiling": ceiling, "entry_count": len(entries),
        "inventory_digest": inventory_digest, "launch_digest": launch_digest,
        "generation": 1, "capability_delivered": "fd",
    }
    if worktree_id is not None:
        result["worktree_identity"] = worktree_id
    git_home.release()
    fds.close_all()
    return result


# ---------------------------------------------------------------------------
# Section 13b. Review bind, refresh, status
# ---------------------------------------------------------------------------

# Known provider state strings mapped to normalized review phases. Unknown raw
# states are preserved verbatim as diagnostic evidence; they never fail refresh.
_STATE_PHASE = {
    "queued": "pending",
    "running": "active",
    "active": "active",
    "completed": "terminal",
    "succeeded": "terminal",
    "failed": "terminal",
    "cancelled": "terminal",
    "canceled": "terminal",
    "timed_out": "terminal",
    "timeout": "terminal",
}

# States that are sticky terminal: once observed, the review does not regress.
_TERMINAL_STATES = frozenset(
    ("completed", "succeeded", "failed", "cancelled", "canceled",
     "timed_out", "timeout"))

# Maximum number of observation records retained per review. Older observations
# are left in place (evidence is never erased) but the latest.json pointer only
# tracks the most recent; verify/close walk the full observations directory.
_MAX_OBSERVATIONS_REPORTED = 64

# Bound on stale-session seconds: if last_activity_at is older than this and the
# review is not terminal, status projects a fail-closed blocker for verify/close.
# Default: 24 hours. Configurable via STITCHPAD_COORD_STALE_SECONDS.
_STALE_SECONDS_ENV = "STITCHPAD_COORD_STALE_SECONDS"
_DEFAULT_STALE_SECONDS = 86400  # 24 hours


def _stale_threshold_seconds():
    """Return the stale-session threshold in seconds.

    Reads STITCHPAD_COORD_STALE_SECONDS, validates it is a reasonable
    integer (>= 60, <= 2592000), and falls back to the 24-hour default.
    """
    raw = os.environ.get(_STALE_SECONDS_ENV)
    if raw is None:
        return _DEFAULT_STALE_SECONDS
    try:
        val = int(raw)
    except (ValueError, TypeError):
        fail("stale_threshold_invalid",
             "%s must be an integer" % (_STALE_SECONDS_ENV,))
    if val < 60 or val > 2592000:
        fail("stale_threshold_invalid",
             "%s must be between 60 and 2592000 seconds (1 min – 30 days)"
             % (_STALE_SECONDS_ENV,))
    return val


def _load_review(state, review_id):
    """Load and validate the review record by its frozen positional ID."""
    require_match(ID_RE, review_id, "review_id_invalid", "review id")
    entry = read_record(state.reviews, review_id, "review",
                        "review record", allow_missing=True)
    if entry is None:
        fail("review_not_found", "no review with id %s" % (review_id,))
    return entry["record"]


def _open_payload(fds, base, review):
    """Open the payload directory for an existing review by its payload_name."""
    payload_name = review["payload_name"]
    require_match(ENTRY_NAME_RE, payload_name,
                  "payload_name_invalid", "payload name")
    entry = try_lstat_at(base.fd, payload_name)
    if entry is None:
        fail("payload_missing",
             "the payload directory for this review is absent")
    if not statmod.S_ISDIR(entry.st_mode) or statmod.S_ISLNK(entry.st_mode):
        fail("payload_invalid", "the payload directory is not a real directory")
    if entry.st_uid != os.getuid():
        fail("payload_invalid", "the payload directory is not owned by you")
    if statmod.S_IMODE(entry.st_mode) != DIR_MODE:
        fail("payload_invalid", "the payload directory mode is not 0700")
    payload_fd = fds.keep(open_dir_at(base.fd, payload_name,
                                      code="payload_invalid",
                                      what="payload directory"))
    opened = os.fstat(payload_fd)
    if identity(entry) != identity(opened):
        fail("payload_invalid",
             "the payload directory changed between lstat and open")
    return payload_fd


def _read_facts(payload_fd):
    """Read the review facts flat record, allowing missing for pre-bind state."""
    return read_flat_record(payload_fd, "facts.json", "facts",
                            "review facts", allow_missing=True)


# Bound on the cross-review identity-uniqueness scan at bind time.  Beyond it
# the bind refuses closed rather than guessing at global uniqueness.
_MAX_REVIEWS_SCAN = 4096


def _read_payload_facts_scoped(base, review):
    """Read another review's facts without retaining its payload FD.

    Used by the bind-time global identity-uniqueness scan, which may walk
    many reviews in one operation and must not exhaust the process FD table.
    An absent or non-directory payload yields no facts (the review record is
    authoritative for existence); a present-but-unreadable facts record fails
    closed through read_flat_record.
    """
    payload_name = review["payload_name"]
    require_match(ENTRY_NAME_RE, payload_name,
                  "payload_name_invalid", "payload name")
    entry = try_lstat_at(base.fd, payload_name)
    if entry is None or not statmod.S_ISDIR(entry.st_mode) \
            or statmod.S_ISLNK(entry.st_mode):
        return None
    payload_fd = open_dir_at(base.fd, payload_name,
                             code="payload_invalid", what="payload directory")
    try:
        return _read_facts(payload_fd)
    finally:
        os.close(payload_fd)


def _read_pointer(payload_fd):
    return read_flat_record(payload_fd, "pointer.json", "pointer",
                            "review pointer", allow_missing=False)


def _read_manifest(payload_fd):
    return read_flat_record(payload_fd, "manifest.json", "manifest",
                            "review manifest", allow_missing=False)


def cmd_review_bind(args):
    """Bind exactly one request/session identity to an existing review.

    The review must be in the ``created`` state and not yet bound (facts.json
    absent or carrying null session/request).  The caller supplies a single
    --session and --request; ambiguity (extra identity env vars that disagree)
    is rejected.  The provider and model are pinned from the review record and
    the invoking environment; a mismatch fails closed.
    """
    ctx = open_context(args)
    fds, base, git_home, repo, state = (
        ctx["fds"], ctx["base"], ctx["git_home"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)

    # Read the current facts (if any) to check idempotency or pre-bind state.
    existing_facts = _read_facts(payload_fd)

    session = require_match(ID_RE, args.session, "session_invalid", "session id")
    request = require_match(ID_RE, args.request, "request_invalid", "request id")

    # Reject ambiguity: any STITCHPAD_SESSION/REQUEST env that disagrees with
    # the explicit argv is a binding hazard.
    env_session = _bounded_env(_SESSION_ENV)
    env_request = _bounded_env(_REQUEST_ENV)
    if env_session is not None and env_session != session:
        fail("session_ambiguous",
             "the --session disagrees with STITCHPAD_SESSION")
    if env_request is not None and env_request != request:
        fail("request_ambiguous",
             "the --request disagrees with STITCHPAD_REQUEST")

    provider = review["provider"]
    model = _bounded_env(_MODEL_ENV)

    # A model pinned at create (or by an earlier bind) is never silently
    # re-pinned: a raw provider/model mismatch fails closed truthfully
    # instead of overwriting the pinned identity.
    if existing_facts is not None:
        pinned_model = existing_facts.get("provider_model")
        if pinned_model is not None and model != pinned_model:
            fail("provider_model_mismatch",
                 "the invoking model does not match the pinned provider_model")

    # Idempotent re-bind: if facts already carry the same identity, succeed
    # regardless of the review record's state (bound is the expected state
    # after a first successful bind).  This check must run BEFORE the state
    # guard so a re-bind of an already-bound review returns instead of
    # failing with review_not_bindable.
    if existing_facts is not None:
        if existing_facts.get("session_id") == session and \
                existing_facts.get("request_id") == request:
            # Confirm provider/model consistency.
            if existing_facts.get("provider") == provider:
                git_home.release()
                fds.close_all()
                return {
                    "ok": True, "command": "review-bind",
                    "review_id": review["review_id"],
                    "session_id": session, "request_id": request,
                    "provider": provider,
                    "already_bound": True,
                    "generation": existing_facts["generation"],
                }
        # If facts exist but carry a different identity, the review is bound.
        if existing_facts.get("session_id") is not None or \
                existing_facts.get("request_id") is not None:
            fail("review_already_bound",
                 "the review is already bound to a different session/request")

    # The review must still be in the created phase for a first bind.
    if review["state"] != "created":
        fail("review_not_bindable",
             "the review is not in the created state (current: %s)"
             % (review["state"],))

    now = int(time.time())

    mutex = TransitionMutex(state)
    with mutex:
        # Re-read the review record under the lock to confirm state.
        locked_review = _load_review(state, args.id)["record"] \
            if False else _load_review(state, args.id)
        if locked_review["state"] != "created":
            fail("review_not_bindable",
                 "the review transitioned out of created state")

        # Global identity uniqueness: a (session, request) pair authorizes
        # exactly one review.  A per-review check lets two reviews correlate
        # the same provider rows forever; scan every other review's facts
        # under the lock and fail closed on collision.  The scan is bounded;
        # beyond the bound the bind refuses rather than guessing.
        names = list_dir_at(state.reviews, "reviews")
        if len(names) > _MAX_REVIEWS_SCAN:
            fail("review_scan_too_large",
                 "too many reviews to prove global session/request uniqueness")
        for name in names:
            if name == review["review_id"]:
                continue
            other_entry = read_record(state.reviews, name, "review",
                                      "review record", allow_missing=True)
            if other_entry is None:
                continue
            other_facts = _read_payload_facts_scoped(base,
                                                     other_entry["record"])
            if other_facts is None:
                continue
            if other_facts.get("session_id") == session \
                    and other_facts.get("request_id") == request:
                fail("session_request_in_use",
                     "the session/request pair is already bound to "
                     "review %s" % (name,))

        contract = _read_contract() or {}
        facts = new_record("facts", 1, {
            "review_id": review["review_id"],
            "session_id": session,
            "request_id": request,
            "bound_at": now,
            "cancel_requested": False,
            "cancel_requested_at": None,
            "terminal_observed": False,
            "terminal_completion": None,
            "terminal_at": None,
            "report_sealed": False,
            "report_digest": None,
            "report_verdict": None,
            "report_sealed_at": None,
            "artifact_verified": False,
            "verified_at": None,
            "closure": None,
            "closure_reason": None,
            "closed_at": None,
            "conflict": None,
            "contract_commit": contract.get("commit"),
            "contract_report": contract.get("report"),
            "contract_sidecar": contract.get("sidecar"),
            "contract_sidecar_digest": contract.get("sidecar_digest"),
            "false_terminal": False,
            "false_terminal_reason": None,
            "false_terminal_at": None,
            "provider": provider,
            "provider_model": model,
            "session_rotation_required": False,
            "last_activity_at": now,
        })
        publish_flat_record(payload_fd, "facts.json", "facts", facts,
                            "review facts")

        # Advance the review state to bound.
        updated = dict(locked_review)
        updated["generation"] = locked_review["generation"] + 1
        updated["state"] = "bound"
        updated["updated_at"] = now
        publish_record(fds, state.reviews, review["review_id"],
                       "review", updated, "review record")

    git_home.release()
    fds.close_all()
    return {
        "ok": True, "command": "review-bind",
        "review_id": review["review_id"],
        "session_id": session, "request_id": request,
        "provider": provider, "provider_model": model,
        "already_bound": False,
        "generation": updated["generation"],
    }


def _map_state_phase(raw_state):
    """Map a raw provider state to a normalized phase; preserve unknowns."""
    if not isinstance(raw_state, str) or not raw_state:
        return ("unknown", raw_state)
    lower = raw_state.lower()
    phase = _STATE_PHASE.get(lower)
    if phase is not None:
        return (phase, lower)
    return ("unknown", raw_state)


def _is_terminal_state(raw_state):
    if not isinstance(raw_state, str):
        return False
    return raw_state.lower() in _TERMINAL_STATES


def _next_observation_slot(payload_fd, fds):
    """Allocate the next positional observation slot name.

    Observations are stored as ``observations/<n>.json`` where ``<n>`` is a
    zero-based sequential integer.  The slot name is derived from the current
    count of observation files, never from caller input.

    MAX_OBSERVATIONS enforces a hard ceiling: a review that has already
    accumulated the maximum number of observations cannot accept another.
    """
    obs_entry = try_lstat_at(payload_fd, "observations")
    if obs_entry is None:
        obs_fd, _ = ensure_owned_dir(fds, payload_fd, "observations",
                                     "observations directory", mode=DIR_MODE)
        return obs_fd, 0
    if not statmod.S_ISDIR(obs_entry.st_mode) or \
            statmod.S_ISLNK(obs_entry.st_mode):
        fail("observations_invalid",
             "the observations entry is not a real directory")
    if obs_entry.st_uid != os.getuid():
        fail("observations_invalid",
             "the observations directory is not owned by you")
    if statmod.S_IMODE(obs_entry.st_mode) != DIR_MODE:
        fail("observations_invalid", "observations mode is not 0700")
    obs_fd = fds.keep(open_dir_at(payload_fd, "observations",
                                  code="observations_invalid",
                                  what="observations directory"))
    names = list_dir_at(obs_fd, "observations directory")
    max_n = -1
    for name in names:
        if name.endswith(".json") and not name.endswith(".READY") and \
                not name.startswith("."):
            stem = name[:-5]
            if stem.isdigit():
                n = int(stem)
                if n > max_n:
                    max_n = n
    next_slot = max_n + 1
    if next_slot >= MAX_OBSERVATIONS:
        fail("observation_limit",
             "this review has accumulated %d observations; no further "
             "observations can be appended (limit %d)"
             % (max_n + 1, MAX_OBSERVATIONS))
    return obs_fd, next_slot


def cmd_review_refresh(args):
    """Correlate provider rows against the bound review and append an observation.

    The refresh reads a bounded JSON file of provider rows (via
    --provider-rows-fd), correlates the exact request+session, maps the known
    state to a phase, preserves sticky terminal/cancel facts, and appends an
    observation record under the payload with generation CAS.  Missing or
    malformed provider rows never erase evidence.
    """
    ctx = open_context(args)
    fds, base, git_home, repo, state = (
        ctx["fds"], ctx["base"], ctx["git_home"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)
    facts = _read_facts(payload_fd)
    if facts is None:
        fail("review_not_bound",
             "the review must be bound before refresh")
    # A closed review is immutable: no post-closure observation may rewrite
    # the facts, latest diagnostic, or bounded history that audit reads.
    _require_review_open(review, facts)
    pointer = _read_pointer(payload_fd)
    manifest = _read_manifest(payload_fd)

    expected_session = facts["session_id"]
    expected_request = facts["request_id"]
    if expected_session is None or expected_request is None:
        fail("review_not_bound",
             "the review facts carry no bound session/request")

    # Read provider rows from the FD-delivered JSON file.
    raw_data = None
    try:
        with os.fdopen(args.provider_rows_fd, "rb") as fh:
            raw_data = fh.read(MAX_RECORD_BYTES + 1)
    except OSError as exc:
        fail("provider_rows_unreadable",
             "cannot read provider rows: %s" % (exc.strerror,))
    if raw_data is None:
        fail("provider_rows_unreadable", "provider rows FD produced no data")
    if len(raw_data) > MAX_RECORD_BYTES:
        fail("provider_rows_too_large",
             "provider rows exceed %d bytes" % (MAX_RECORD_BYTES,))

    try:
        rows = strict_json_loads(raw_data)
    except CoordError:
        fail("provider_rows_malformed",
             "provider rows are not valid JSON")

    if not isinstance(rows, list):
        fail("provider_rows_malformed",
             "provider rows must be a JSON array")
    if len(rows) > 256:
        fail("provider_rows_too_many",
             "provider rows exceed 256 entries")

    # Correlate: find the row whose request+session match exactly.
    matched = None
    ambiguous = False
    output_correlation = None
    for row in rows:
        if not isinstance(row, dict):
            continue
        row_req = row.get("request")
        row_sess = row.get("session")
        if not isinstance(row_req, str) or not isinstance(row_sess, str):
            continue
        if row_req == expected_request and row_sess == expected_session:
            if matched is not None:
                ambiguous = True
            else:
                matched = row
        # Record output correlation: any row with the same request but a
        # different session is evidence of cross-session leakage.
        if row_req == expected_request and row_sess != expected_session:
            output_correlation = row_sess

    now = int(time.time())
    generation = facts["generation"]

    # Determine the new phase and raw state.
    if matched is None:
        raw_state = None
        phase = "unknown"
        terminal = False
        diagnostic = "no_correlating_provider_row"
    elif ambiguous:
        raw_state = None
        phase = "unknown"
        terminal = False
        diagnostic = "ambiguous_provider_rows"
    else:
        raw_state = matched.get("state")
        phase, normalized = _map_state_phase(raw_state)
        terminal = _is_terminal_state(normalized) if normalized else False
        diagnostic = None
        # Record additional evidence fields if present.
        for evidence_key in ("completion", "exit_code", "error"):
            if evidence_key in matched:
                diagnostic = matched.get(evidence_key)
                break

    # Preserve sticky terminal facts: once terminal_observed is True, it stays.
    cancel_requested = facts["cancel_requested"]
    cancel_requested_at = facts["cancel_requested_at"]
    terminal_observed = facts["terminal_observed"]
    terminal_completion = facts["terminal_completion"]
    terminal_at = facts["terminal_at"]
    # TASK-3: sticky false-terminal audit truth, loaded for every refresh
    # (terminal or not) so the writeback below is always well-defined.
    false_terminal = facts.get("false_terminal", False)
    false_terminal_reason = facts.get("false_terminal_reason")
    false_terminal_at = facts.get("false_terminal_at")

    if terminal and not terminal_observed:
        terminal_observed = True
        terminal_at = now
        # `terminal` is only ever True on the exact-correlation branch above:
        # the no-match and ambiguous branches pin it False, so `matched` is
        # provably the correlating row here. The former `if matched is not
        # None` guard was an audited dead conditional — its else path could
        # never execute, and it implied a terminal fact could be recorded
        # without a completion. Assign from the row directly.
        terminal_completion = matched.get("completion") or \
            matched.get("state")

        # TASK-3: Zero-duration completion detection.  If the provider row
        # carries started_at == finished_at (both non-None and equal), the
        # completion is a kimi2-class zero-run: refuse it as terminal evidence
        # and flag it as false_terminal/zero_duration.
        started = matched.get("started_at")
        finished = matched.get("finished_at")
        if terminal_completion == "completed" \
           and isinstance(started, (int, float)) \
           and isinstance(finished, (int, float)) \
           and started == finished:
            terminal_completion = "false_terminal"

        # TASK-3: Contract satisfaction check.  When a turn reaches terminal
        # state without its contracted artifacts, it is false_terminal —
        # sticky, never erased, same discipline as mismatch conflicts.
        if terminal_completion == "completed" and not false_terminal:
            contract = _facts_contract(facts)
            if contract is not None:
                satisfied, cblockers = _check_contract_satisfaction(
                    contract, repo=repo)
                if not satisfied:
                    false_terminal = True
                    false_terminal_reason = "contract_unsatisfied:" + ",".join(cblockers)
                    false_terminal_at = now
        elif terminal_completion == "false_terminal" and not false_terminal:
            false_terminal = True
            false_terminal_reason = "zero_duration"
            false_terminal_at = now
    mutex = TransitionMutex(state)
    with mutex:
        # Generation CAS: re-read facts under the lock and confirm generation.
        locked_facts = _read_facts(payload_fd)
        if locked_facts is None:
            fail("review_not_bound",
                 "the review facts disappeared under the lock")
        if locked_facts["generation"] != generation:
            fail("generation_conflict",
                 "the review facts changed (generation %d -> %d)"
                 % (generation, locked_facts["generation"]))

        # Re-confirm sticky facts under the lock.
        if locked_facts["terminal_observed"]:
            terminal_observed = True
        if locked_facts["cancel_requested"]:
            cancel_requested = True
            cancel_requested_at = locked_facts["cancel_requested_at"]
        # TASK-3: false_terminal is sticky audit truth — a concurrent
        # detection must never be erased by this refresh's pre-lock snapshot.
        if locked_facts.get("false_terminal"):
            false_terminal = True
            false_terminal_reason = locked_facts.get("false_terminal_reason")
            false_terminal_at = locked_facts.get("false_terminal_at")

        new_generation = generation + 1

        # Append observation record.
        obs_fd, slot = _next_observation_slot(payload_fd, fds)
        obs_name = "%d.json" % (slot,)

        evidence = {"request_matched": matched is not None,
                    "ambiguous": ambiguous}
        if output_correlation is not None:
            evidence["output_correlation_session"] = output_correlation
        evidence_digest = sha256_hex(canonical_json_bytes(evidence))

        raw_model = None
        raw_provider = None
        if isinstance(matched, dict):
            raw_model = matched.get("model")
            raw_provider = matched.get("provider")

        observation = new_record("observation", new_generation, {
            "review_id": review["review_id"],
            "raw_state": raw_state if isinstance(raw_state, str) else None,
            "phase": phase,
            "terminal": terminal,
            "observed_at": now,
            "evidence_digest": evidence_digest,
            "diagnostic": diagnostic if isinstance(diagnostic, str) else None,
            "raw_model": raw_model if isinstance(raw_model, str) else None,
        })
        publish_flat_record(obs_fd, obs_name, "observation", observation,
                            "observation %d" % (slot,))

        # Update latest.json pointer.
        latest = new_record("latest", new_generation, {
            "review_id": review["review_id"],
            "phase": phase,
            "raw_state": raw_state if isinstance(raw_state, str) else None,
            "observed_at": now,
            "diagnostic": diagnostic if isinstance(diagnostic, str) else None,
            "diagnostic_at": now if diagnostic is not None else None,
            "observation_count": slot + 1,
        })
        publish_flat_record(payload_fd, "latest.json", "latest", latest,
                            "review latest")

        # Update facts with generation CAS and sticky preservation.
        updated_facts = dict(locked_facts)
        updated_facts["generation"] = new_generation
        updated_facts["terminal_observed"] = terminal_observed
        updated_facts["terminal_completion"] = terminal_completion
        updated_facts["terminal_at"] = terminal_at
        updated_facts["cancel_requested"] = cancel_requested
        updated_facts["cancel_requested_at"] = cancel_requested_at
        updated_facts["false_terminal"] = false_terminal
        updated_facts["false_terminal_reason"] = false_terminal_reason
        updated_facts["false_terminal_at"] = false_terminal_at
        updated_facts["last_activity_at"] = now
        # Stale-session detection: if the session/request env changed since
        # bind, flag for rotation (consumed by verify/close).
        env_session = _bounded_env(_SESSION_ENV)
        if env_session is not None and env_session != expected_session:
            updated_facts["session_rotation_required"] = True
        # Output correlation evidence (consumed by verify/close).
        if output_correlation is not None:
            updated_facts["conflict"] = "output_correlation"
        # Raw provider/model mismatch: the correlated row's model must agree
        # with the pinned provider_model.  A substitution is recorded as a
        # sticky conflict and surfaced as a status/closure blocker, never
        # silently sealed as evidence; an existing conflict is never erased.
        if updated_facts["conflict"] is None \
                and isinstance(raw_model, str) \
                and isinstance(updated_facts.get("provider_model"), str) \
                and raw_model != updated_facts["provider_model"]:
            updated_facts["conflict"] = "model_mismatch"
        # Raw provider mismatch: same rule, reported truthfully under its
        # own code; an existing conflict is never erased.
        if updated_facts["conflict"] is None \
                and isinstance(raw_provider, str) \
                and isinstance(updated_facts.get("provider"), str) \
                and raw_provider != updated_facts["provider"]:
            updated_facts["conflict"] = "provider_mismatch"
        facts_record = new_record("facts", new_generation, {
            "review_id": updated_facts["review_id"],
            "session_id": updated_facts["session_id"],
            "request_id": updated_facts["request_id"],
            "bound_at": updated_facts["bound_at"],
            "cancel_requested": updated_facts["cancel_requested"],
            "cancel_requested_at": updated_facts["cancel_requested_at"],
            "terminal_observed": updated_facts["terminal_observed"],
            "terminal_completion": updated_facts["terminal_completion"],
            "terminal_at": updated_facts["terminal_at"],
            "report_sealed": updated_facts["report_sealed"],
            "report_digest": updated_facts["report_digest"],
            "report_verdict": updated_facts["report_verdict"],
            "report_sealed_at": updated_facts["report_sealed_at"],
            "artifact_verified": updated_facts["artifact_verified"],
            "verified_at": updated_facts["verified_at"],
            "closure": updated_facts["closure"],
            "closure_reason": updated_facts["closure_reason"],
            "closed_at": updated_facts["closed_at"],
            "conflict": updated_facts["conflict"],
            "contract_commit": updated_facts["contract_commit"],
            "contract_report": updated_facts["contract_report"],
            "contract_sidecar": updated_facts["contract_sidecar"],
            "contract_sidecar_digest": updated_facts["contract_sidecar_digest"],
            "false_terminal": updated_facts["false_terminal"],
            "false_terminal_reason": updated_facts["false_terminal_reason"],
            "false_terminal_at": updated_facts["false_terminal_at"],
            "provider": updated_facts["provider"],
            "provider_model": updated_facts["provider_model"],
            "session_rotation_required":
                updated_facts["session_rotation_required"],
            "last_activity_at": updated_facts["last_activity_at"],
        })
        publish_flat_record(payload_fd, "facts.json", "facts", facts_record,
                            "review facts")

    git_home.release()
    fds.close_all()
    return {
        "ok": True, "command": "review-refresh",
        "review_id": review["review_id"],
        "phase": phase,
        "raw_state": raw_state if isinstance(raw_state, str) else None,
        "terminal": terminal,
        "terminal_observed": terminal_observed,
        "ambiguous": ambiguous,
        "correlated": matched is not None,
        "output_correlation": output_correlation,
        "generation": new_generation,
        "observation_count": slot + 1,
    }


def _format_ts(ts):
    """Format an epoch integer as a human-visible UTC timestamp string."""
    if ts is None:
        return None
    if not isinstance(ts, int) or isinstance(ts, bool):
        return None
    import datetime as _dt
    try:
        return _dt.datetime.fromtimestamp(ts, _dt.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OSError):
        return None


def cmd_review_status(args):
    """Lock-free, double-sampled, read-only status projection.

    Reads the review record, pointer, manifest, facts, and latest observation
    twice (double-sampling) to detect concurrent mutation.  Never writes.
    Projects human-visible timestamps, active state, last activity, current
    request, provider/model, session, worktree, and fail-closed blockers.
    """
    ctx = open_context(args, need_git_home=False)
    fds, base, repo, state = (
        ctx["fds"], ctx["base"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)

    def _sample():
        """Read all payload records in one consistent snapshot."""
        r = _load_review(state, args.id)
        p = read_flat_record(payload_fd, "pointer.json", "pointer",
                             "review pointer", allow_missing=False)
        m = read_flat_record(payload_fd, "manifest.json", "manifest",
                             "review manifest", allow_missing=False)
        f = _read_facts(payload_fd)
        l = read_flat_record(payload_fd, "latest.json", "latest",
                             "review latest", allow_missing=True)
        return {"review": r, "pointer": p, "manifest": m,
                "facts": f, "latest": l}

    # Sufficient double-sampling.  The previous check compared only the
    # review record generation, but refresh/cancel rewrite facts.json and
    # latest.json WITHOUT touching the review record, so a concurrent
    # mutation could produce a torn status reported as stable -- a
    # transient false state.  Sampling is sufficient only when BOTH hold:
    # (a) the transition mutex is absent before, between, and after the
    # two snapshot reads, and (b) the two FULL snapshots (review, pointer,
    # manifest, facts, latest) are byte-identical under canonical JSON.
    # Any divergence is reported as a concurrent-mutation diagnostic
    # (read-only status never fails on it, but never hides it either).
    mutex_before = sample_mutex(state) is not None
    sample1 = _sample()
    mutex_mid = sample_mutex(state) is not None
    sample2 = _sample()
    mutex_after = sample_mutex(state) is not None
    concurrent = mutex_before or mutex_mid or mutex_after or \
        canonical_json_bytes(sample1) != canonical_json_bytes(sample2)

    r = sample2["review"]
    p = sample2["pointer"]
    m = sample2["manifest"]
    f = sample2["facts"]
    l = sample2["latest"]

    now = int(time.time())

    # Determine the display phase.
    if l is not None:
        phase = l.get("phase") or r["state"]
    else:
        phase = r["state"]

    # Build blockers list (fail-closed conditions for verify/close).
    blockers = []
    if f is None:
        blockers.append("not_bound")
    else:
        if f.get("conflict") is not None:
            blockers.append(f["conflict"])
        if f.get("session_rotation_required"):
            blockers.append("session_rotation_required")
        if not f.get("terminal_observed") and \
                r["state"] not in ("closed", "abandoned"):
            blockers.append("not_terminal")
        # Stale-session blocker: if last_activity_at is older than the threshold
        # and the review is not terminal/closed.
        last_act = f.get("last_activity_at")
        if isinstance(last_act, int) and not isinstance(last_act, bool):
            if now - last_act > _stale_threshold_seconds() and \
                    not f.get("terminal_observed") and \
                    r["state"] not in ("closed", "abandoned"):
                blockers.append("stale_session")
    # Closed reviews RETAIN their recorded blockers and bounded history:
    # closure never erases conflict evidence. Only the phase-progress
    # blockers (not_terminal, stale_session) are scoped to open reviews by
    # the state guards above.

    result = {
        "ok": True, "command": "review-status",
        "review_id": r["review_id"],
        "state": r["state"],
        "phase": phase,
        "commit": r["commit"],
        "tree": r["tree"],
        "author_actor": r["author_actor"],
        "reviewer_actor": r["reviewer_actor"],
        "created_at": _format_ts(r["created_at"]),
        "created_at_epoch": r["created_at"],
        "updated_at": _format_ts(r["updated_at"]),
        "updated_at_epoch": r["updated_at"],
        "payload_path": p["payload_path"],
        "ceiling": m.get("ceiling"),
        "entry_count": m.get("entry_count"),
        "blockers": blockers,
        "concurrent_mutation": concurrent,
    }

    if f is not None:
        result["session_id"] = f.get("session_id")
        result["request_id"] = f.get("request_id")
        result["provider"] = f.get("provider") or r.get("provider")
        result["provider_model"] = f.get("provider_model")
        result["bound_at"] = _format_ts(f.get("bound_at"))
        result["bound_at_epoch"] = f.get("bound_at")
        result["last_activity_at"] = _format_ts(f.get("last_activity_at"))
        result["last_activity_at_epoch"] = f.get("last_activity_at")
        result["terminal_observed"] = f.get("terminal_observed", False)
        result["cancel_requested"] = f.get("cancel_requested", False)
        result["report_sealed"] = f.get("report_sealed", False)
        result["artifact_verified"] = f.get("artifact_verified", False)
        result["closure"] = f.get("closure")
        result["closure_reason"] = f.get("closure_reason")
        result["false_terminal"] = f.get("false_terminal", False)
        result["false_terminal_reason"] = f.get("false_terminal_reason")
        result["contract"] = _facts_contract(f)
        if f.get("terminal_completion") is not None:
            result["terminal_completion"] = f.get("terminal_completion")
        if f.get("terminal_at") is not None:
            result["terminal_at"] = _format_ts(f.get("terminal_at"))
            result["terminal_at_epoch"] = f.get("terminal_at")
        if f.get("closed_at") is not None:
            result["closed_at"] = _format_ts(f.get("closed_at"))
            result["closed_at_epoch"] = f.get("closed_at")
        if f.get("false_terminal_at") is not None:
            result["false_terminal_at"] = _format_ts(f.get("false_terminal_at"))
            result["false_terminal_at_epoch"] = f.get("false_terminal_at")
    if l is not None:
        result["latest_phase"] = l.get("phase")
        result["latest_raw_state"] = l.get("raw_state")
        result["latest_observed_at"] = _format_ts(l.get("observed_at"))
        result["latest_observed_at_epoch"] = l.get("observed_at")
        result["observation_count"] = l.get("observation_count", 0)
        if l.get("diagnostic") is not None:
            result["latest_diagnostic"] = l.get("diagnostic")

    # Worktree identity (descriptive, from the review record's repo).
    result["repo_id"] = r["repo_id"]
    result["top"] = r["top"]

    fds.close_all()
    return result


# ---------------------------------------------------------------------------
# Section 13c. Review register-process and cancel-requested
# ---------------------------------------------------------------------------

def _require_role(role):
    """Validate a process role against the strict role regex."""
    return require_match(ROLE_RE, role, "role_invalid", "process role")


def cmd_review_register_process(args):
    """Register exact process evidence for a bound review.

    The review must be bound (facts.json must exist with a non-null
    session/request).  The capability proves registration authority but is
    never treated as process identity: the PID is sampled independently via
    ``sample_process`` and recorded as evidence.  Every identifier is
    validated.  The process record is published under the payload's
    ``processes/`` directory, named by a helper-minted 32-hex ID.
    """
    ctx = open_context(args)
    fds, base, git_home, repo, state = (
        ctx["fds"], ctx["base"], ctx["git_home"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)

    # The review must be bound before a process can be registered.
    facts = _read_facts(payload_fd)
    if facts is None:
        fail("review_not_bound",
             "the review must be bound before registering a process")
    if facts.get("session_id") is None or facts.get("request_id") is None:
        fail("review_not_bound",
             "the review facts carry no bound session/request")
    # A closed review is immutable: registering post-closure process
    # evidence would rewrite the audit state verify/close already read.
    _require_review_open(review, facts)

    # Validate the role against the strict regex.
    role = _require_role(args.role)

    # Validate the PID is a plausible positive integer.
    require_int(args.pid, 2, 2 ** 31 - 1, "pid_invalid", "pid")

    # Read and verify the capability token.  The capability proves the
    # caller has registration authority for this review; it is never
    # process identity.  The PID is sampled independently.
    token = read_capability_fd(args.process_token_fd)
    if not capability_matches(review.get("process_capability"), token):
        fail("capability_rejected",
             "the supplied capability does not authorize this review")

    # Sample the process evidence: this is observation only.  A live process
    # produces a full evidence record; an exited/unknown one still registers
    # (the evidence is the absence, which is itself a sticky fact).  The
    # capability is authority to register; it is never process identity.
    sample = sample_process(args.pid)

    # Generate a helper-minted positional ID for the process record.
    process_record_id = secrets.token_hex(16)
    if not ID_RE.match(process_record_id):
        fail("process_id_invalid", "generated process record id is malformed")

    now = int(time.time())
    generation = facts["generation"]

    mutex = TransitionMutex(state)
    with mutex:
        # Re-read facts under the lock to confirm the review is still bound.
        locked_facts = _read_facts(payload_fd)
        if locked_facts is None:
            fail("review_not_bound",
                 "the review facts disappeared under the lock")
        if locked_facts.get("session_id") is None or \
                locked_facts.get("request_id") is None:
            fail("review_not_bound",
                 "the review is no longer bound under the lock")

        # Build the process evidence record.  Fields with no observed value
        # are recorded as null; they are never fabricated.
        lstart = sample.get("lstart") if sample.get("state") == "alive" else None
        ppid = sample.get("ppid") if sample.get("state") == "alive" else None
        pgid = sample.get("pgid") if sample.get("state") == "alive" else None
        command_digest = sample.get("command_digest") \
            if sample.get("state") == "alive" else None
        command_display = sample.get("command_display") \
            if sample.get("state") == "alive" else None

        process = new_record("process", generation, {
            "review_id": review["review_id"],
            "role": role,
            "pid": args.pid,
            "ppid": ppid,
            "pgid": pgid,
            "lstart": lstart,
            "command_digest": command_digest,
            "command_display": command_display,
            "registered_at": now,
        })

        # Publish under the payload's processes/ directory, named by the
        # helper-minted positional ID.
        processes_fd, _ = ensure_owned_dir(
            fds, payload_fd, "processes", "processes directory", mode=DIR_MODE)
        process_name = process_record_id + ".json"
        if try_lstat_at(processes_fd, process_name) is not None:
            fail("process_conflict", "process record id collision")
        publish_flat_record(processes_fd, process_name, "process", process,
                            "process record")

    git_home.release()
    fds.close_all()
    return {
        "ok": True, "command": "review-register-process",
        "review_id": review["review_id"],
        "process_record_id": process_record_id,
        "role": role,
        "pid": args.pid,
        "process_state": sample.get("state", "unknown"),
        "generation": generation,
    }


def cmd_review_cancel_requested(args):
    """Record a sticky cancel-requested flag on a bound review.

    Before bind, cancel is rejected: the review has no session/request
    identity and nothing to cancel.  After bind, cancel records the sticky
    ``cancel_requested`` fact (and timestamp), advances the facts generation
    via CAS, and performs ZERO HTTP calls and ZERO signals.  The review
    remains nonterminal: cancel is a request, not a terminal state.  It
    never erases terminal truth — if the review is already terminal, the
    cancel flag is still recorded but terminal_observed is preserved.

    Concurrent generations fail closed: the facts generation is re-read
    under the transition mutex and compared (CAS).
    """
    ctx = open_context(args, need_git_home=False)
    fds, base, repo, state = (
        ctx["fds"], ctx["base"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)

    # Cancel before bind: rejected.  The review must have a bound identity.
    facts = _read_facts(payload_fd)
    if facts is None:
        fail("review_not_bound",
             "the review must be bound before cancel can be requested")
    if facts.get("session_id") is None or facts.get("request_id") is None:
        fail("review_not_bound",
             "the review carries no bound session/request; "
             "cancel cannot be requested before bind")
    # A closed review is immutable: a post-closure cancel would advance the
    # facts generation and rewrite the record audit sealed at closure.
    _require_review_open(review, facts)

    generation = facts["generation"]
    now = int(time.time())

    mutex = TransitionMutex(state)
    with mutex:
        # Generation CAS: re-read facts under the lock.
        locked_facts = _read_facts(payload_fd)
        if locked_facts is None:
            fail("review_not_bound",
                 "the review facts disappeared under the lock")
        if locked_facts["generation"] != generation:
            fail("generation_conflict",
                 "the review facts changed (generation %d -> %d)"
                 % (generation, locked_facts["generation"]))

        # The cancel flag is sticky: once True it stays True.  A repeat
        # cancel-requested is idempotent if the generation matches.
        cancel_requested = True
        cancel_requested_at = locked_facts.get("cancel_requested_at")
        if cancel_requested_at is None:
            cancel_requested_at = now
        else:
            # Already requested: preserve the original timestamp.  The flag
            # and its first-request timestamp are immutable once set.
            cancel_requested = True

        new_generation = generation + 1

        # Preserve all sticky terminal truth.  Cancel never erases terminal
        # evidence: terminal_observed, terminal_completion, terminal_at,
        # report_sealed, report_digest, etc. all carry forward unchanged.
        updated_facts = dict(locked_facts)
        updated_facts["generation"] = new_generation
        updated_facts["cancel_requested"] = cancel_requested
        updated_facts["cancel_requested_at"] = cancel_requested_at
        updated_facts["last_activity_at"] = now

        facts_record = new_record("facts", new_generation, {
            "review_id": updated_facts["review_id"],
            "session_id": updated_facts["session_id"],
            "request_id": updated_facts["request_id"],
            "bound_at": updated_facts["bound_at"],
            "cancel_requested": updated_facts["cancel_requested"],
            "cancel_requested_at": updated_facts["cancel_requested_at"],
            "terminal_observed": updated_facts["terminal_observed"],
            "terminal_completion": updated_facts["terminal_completion"],
            "terminal_at": updated_facts["terminal_at"],
            "report_sealed": updated_facts["report_sealed"],
            "report_digest": updated_facts["report_digest"],
            "report_verdict": updated_facts["report_verdict"],
            "report_sealed_at": updated_facts["report_sealed_at"],
            "artifact_verified": updated_facts["artifact_verified"],
            "verified_at": updated_facts["verified_at"],
            "closure": updated_facts["closure"],
            "closure_reason": updated_facts["closure_reason"],
            "closed_at": updated_facts["closed_at"],
            "conflict": updated_facts["conflict"],
            "contract_commit": updated_facts["contract_commit"],
            "contract_report": updated_facts["contract_report"],
            "contract_sidecar": updated_facts["contract_sidecar"],
            "contract_sidecar_digest": updated_facts["contract_sidecar_digest"],
            "false_terminal": updated_facts["false_terminal"],
            "false_terminal_reason": updated_facts["false_terminal_reason"],
            "false_terminal_at": updated_facts["false_terminal_at"],
            "provider": updated_facts["provider"],
            "provider_model": updated_facts["provider_model"],
            "session_rotation_required":
                updated_facts["session_rotation_required"],
            "last_activity_at": updated_facts["last_activity_at"],
        })
        publish_flat_record(payload_fd, "facts.json", "facts", facts_record,
                            "review facts")

    fds.close_all()
    return {
        "ok": True, "command": "review-cancel-requested",
        "review_id": review["review_id"],
        "cancel_requested": True,
        "cancel_requested_at": _format_ts(cancel_requested_at),
        "cancel_requested_at_epoch": cancel_requested_at,
        "already_requested": locked_facts.get("cancel_requested", False),
        "generation": new_generation,
    }


# ---------------------------------------------------------------------------
# Section 13d. Review submit-report (validate and seal write-once)
# ---------------------------------------------------------------------------

def cmd_review_submit_report(args):
    """Validate and seal the review report write-once.

    Reads ``inbox/report.pending`` through a no-follow, stable regular-file
    channel, validates the exact PASS/HOLD/FAIL report headers against the
    pinned commit and bound reviewer actor, then publishes the sealed report
    atomically as ``sealed/report.txt`` via an O_EXCL hard link.  The seal is
    write-once: a second submit, an alias, or crash residue cannot replace or
    auto-repair the sealed bytes.  After sealing, the facts record is advanced
    under the transition mutex with generation CAS to record ``report_sealed``,
    ``report_digest``, ``report_verdict``, and ``report_sealed_at``.

    No deletion, signals, HTTP, scheduler, repair, or cleanup.
    """
    ctx = open_context(args, need_git_home=False)
    fds, base, repo, state = (
        ctx["fds"], ctx["base"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)

    # The review must be bound before a report can be submitted.
    facts = _read_facts(payload_fd)
    if facts is None:
        fail("review_not_bound",
             "the review must be bound before submitting a report")
    if facts.get("session_id") is None or facts.get("request_id") is None:
        fail("review_not_bound",
             "the review facts carry no bound session/request")
    # A closed review is immutable: the seal decision was made at closure;
    # no post-closure submit may advance facts or touch the sealed report.
    _require_review_open(review, facts)

    # Refuse if crash residue from an incomplete prior seal is present.
    # The helper never auto-repairs stale temps or stray hard links.
    incomplete = detect_incomplete_report(fds, payload_fd)
    if incomplete is not None:
        raise CoordError(incomplete,
                         "crash residue from an incomplete report seal "
                         "is present; the operator must intervene")

    # Bind the payload root with expected identities from the pointer record.
    pointer = _read_pointer(payload_fd)
    binding = RootBinding(fds, base, review["payload_name"],
                          expect_payload=pointer["payload_identity"],
                          expect_src=pointer["src_identity"])
    binding.bind()

    generation = facts["generation"]
    now = int(time.time())

    mutex = TransitionMutex(state)
    with mutex:
        # Generation CAS: re-read facts under the lock.
        locked_facts = _read_facts(payload_fd)
        if locked_facts is None:
            fail("review_not_bound",
                 "the review facts disappeared under the lock")
        if locked_facts["generation"] != generation:
            fail("generation_conflict",
                 "the review facts changed (generation %d -> %d)"
                 % (generation, locked_facts["generation"]))

        # Re-check crash residue under the lock ( concurrent cleaner is
        # impossible — no cleanup path exists — but the check is cheap and
        # keeps the refusal exact if state changed between samples).
        locked_incomplete = detect_incomplete_report(fds, payload_fd)
        if locked_incomplete is not None:
            raise CoordError(locked_incomplete,
                             "crash residue from an incomplete report seal "
                             "appeared under the lock")

        # Seal the report write-once: O_EXCL hard link, nlink checks, digest
        # verification.  A second submit, alias, or concurrent attempt fails
        # closed inside seal_report — the sealed bytes cannot be replaced.
        sealed = seal_report(fds, binding, review["commit"],
                             review["reviewer_actor"])

        new_generation = generation + 1

        # Advance the facts record with the sealed report evidence.
        updated_facts = dict(locked_facts)
        updated_facts["generation"] = new_generation
        updated_facts["report_sealed"] = True
        updated_facts["report_digest"] = sealed["digest"]
        updated_facts["report_verdict"] = sealed["verdict"]
        updated_facts["report_sealed_at"] = now
        updated_facts["last_activity_at"] = now

        facts_record = new_record("facts", new_generation, {
            "review_id": updated_facts["review_id"],
            "session_id": updated_facts["session_id"],
            "request_id": updated_facts["request_id"],
            "bound_at": updated_facts["bound_at"],
            "cancel_requested": updated_facts["cancel_requested"],
            "cancel_requested_at": updated_facts["cancel_requested_at"],
            "terminal_observed": updated_facts["terminal_observed"],
            "terminal_completion": updated_facts["terminal_completion"],
            "terminal_at": updated_facts["terminal_at"],
            "report_sealed": updated_facts["report_sealed"],
            "report_digest": updated_facts["report_digest"],
            "report_verdict": updated_facts["report_verdict"],
            "report_sealed_at": updated_facts["report_sealed_at"],
            "artifact_verified": updated_facts["artifact_verified"],
            "verified_at": updated_facts["verified_at"],
            "closure": updated_facts["closure"],
            "closure_reason": updated_facts["closure_reason"],
            "closed_at": updated_facts["closed_at"],
            "conflict": updated_facts["conflict"],
            "contract_commit": updated_facts["contract_commit"],
            "contract_report": updated_facts["contract_report"],
            "contract_sidecar": updated_facts["contract_sidecar"],
            "contract_sidecar_digest": updated_facts["contract_sidecar_digest"],
            "false_terminal": updated_facts["false_terminal"],
            "false_terminal_reason": updated_facts["false_terminal_reason"],
            "false_terminal_at": updated_facts["false_terminal_at"],
            "provider": updated_facts["provider"],
            "provider_model": updated_facts["provider_model"],
            "session_rotation_required":
                updated_facts["session_rotation_required"],
            "last_activity_at": updated_facts["last_activity_at"],
        })
        publish_flat_record(payload_fd, "facts.json", "facts", facts_record,
                            "review facts")

    fds.close_all()
    return {
        "ok": True, "command": "review-submit-report",
        "review_id": review["review_id"],
        "report_sealed": True,
        "report_digest": sealed["digest"],
        "report_verdict": sealed["verdict"],
        "report_bytes": sealed["bytes"],
        "report_sealed_at": _format_ts(now),
        "report_sealed_at_epoch": now,
        "generation": new_generation,
    }


# ---------------------------------------------------------------------------
# Section 13e. Verified closure (closed_verified) and the exact-PASS merge gate
# ---------------------------------------------------------------------------

_CLOSURE_VERIFIED = "closed_verified"


def _require_review_open(review, facts):
    """Closure is explicit and write-once: any recorded closure refuses
    a second transition. Nothing here reopens, repairs, or auto-closes."""
    if review["state"] in ("closed", "abandoned") \
            or review.get("closure") is not None:
        fail("review_already_closed",
             "the review already carries closure %r"
             % (review.get("closure") or review["state"],))
    if facts is not None and facts.get("closure") is not None:
        fail("review_already_closed",
             "the review facts already carry closure %r"
             % (facts.get("closure"),))


def _identity_blockers(review, pointer, manifest):
    """Exact pinned-OID agreement between review, manifest, and pointer."""
    blockers = []
    algo = review["algo"]
    try:
        require_oid(review["commit"], algo, "review commit")
        require_oid(review["tree"], algo, "review tree")
    except CoordError:
        blockers.append("review_oid_invalid")
    if manifest.get("algo") != algo \
            or manifest.get("commit") != review["commit"] \
            or manifest.get("tree") != review["tree"] \
            or manifest.get("review_id") != review["review_id"]:
        blockers.append("manifest_identity_mismatch")
    if pointer.get("review_id") != review["review_id"] \
            or pointer.get("payload_name") != review["payload_name"] \
            or pointer.get("inventory_digest") != manifest.get("inventory_digest"):
        blockers.append("pointer_identity_mismatch")
    return blockers


def _report_blockers(fds, binding, review, facts):
    """Sealed-report agreement: sticky facts and sealed bytes must both be
    present, valid, and identical. Returns (blockers, sealed-or-None)."""
    blockers = []
    if not facts.get("report_sealed") \
            or facts.get("report_digest") is None \
            or facts.get("report_verdict") not in VERDICTS:
        blockers.append("report_not_sealed")
    residue = detect_incomplete_report(fds, binding.payload_fd)
    if residue is not None:
        blockers.append(residue)
    sealed = None
    try:
        sealed = read_sealed_report(fds, binding, review["commit"],
                                    review["reviewer_actor"])
    except CoordError as exc:
        blockers.append(exc.code)
    if sealed is None:
        if "report_not_sealed" not in blockers:
            blockers.append("report_missing")
    else:
        if sealed["digest"] != facts.get("report_digest"):
            blockers.append("report_digest_mismatch")
        if sealed["verdict"] != facts.get("report_verdict"):
            blockers.append("report_verdict_mismatch")
    return blockers, sealed


def _closure_blockers(fds, binding, review, facts, pointer, manifest):
    """Exact blocker projection for verified closure. Read-only.

    ``closed_verified`` requires ALL of: a bound review whose exact terminal
    completion is ``completed``; a valid write-once sealed report agreeing
    with the sticky facts; process evidence with every registered record
    exited (no unknown/alive/unstable/reused/foreign and no unregistered
    discriminator hit); and stable exact final source and payload roots
    whose OIDs still match the pinned manifest. Any conflict or instability
    remains a blocker; nothing here repairs, retries, or erases evidence.
    """
    blockers = []
    if facts.get("session_id") is None or facts.get("request_id") is None:
        blockers.append("not_bound")
    if not facts.get("terminal_observed"):
        blockers.append("not_terminal")
    elif facts.get("terminal_completion") != "completed":
        blockers.append("terminal_not_completed")
    if facts.get("false_terminal"):
        reason = facts.get("false_terminal_reason") or "unspecified"
        blockers.append("false_terminal:" + bounded(reason, 64))
    if facts.get("conflict") is not None:
        blockers.append(bounded(facts["conflict"], 64))
    if facts.get("session_rotation_required"):
        blockers.append("session_rotation_required")
    # TASK-3: Contract satisfaction is re-verified at closure time.  A
    # missing, mismatched, or unreadable contract artifact is a blocker.
    contract = _facts_contract(facts)
    if contract is not None:
        satisfied, cblockers = _check_contract_satisfaction(
            contract, repo={"top": review["top"]})
        if not satisfied:
            blockers.extend(cblockers)

    report_blockers, sealed = _report_blockers(fds, binding, review, facts)
    blockers.extend(report_blockers)

    try:
        evidence = process_evidence(fds, binding.payload_fd,
                                    review["review_id"],
                                    pointer.get("payload_path"))
        blockers.extend(evidence["blockers"])
    except CoordError as exc:
        blockers.append(exc.code)

    blockers.extend(_identity_blockers(review, pointer, manifest))

    # Stable exact final source: the walked inventory must still hash to the
    # pinned manifest digest. Instability inside the walk is itself a blocker.
    try:
        final_records = walk_inventory(fds, binding.src_fd, review["algo"])
        if sha256_hex(encode_inventory(final_records)) \
                != manifest.get("inventory_digest"):
            blockers.append("inventory_mismatch")
    except CoordError as exc:
        blockers.append(exc.code)

    # Stable roots: the published payload/src entries must still name the
    # retained FDs with the exact owner/mode policy.
    try:
        binding.recheck()
    except CoordError as exc:
        blockers.append(exc.code)

    return sorted(set(blockers)), sealed


def _refuse_blocked_closure(blockers):
    raise CoordError(
        "closure_blocked",
        "verified closure requires zero blockers: %s"
        % (",".join(blockers),),
        {"blockers": blockers},
    )


def cmd_review_close(args):
    """Explicit, write-once ``closed_verified`` transition.

    ``--verified`` succeeds only when every requirement holds at decision
    time under the transition mutex: exact bound ``completed`` terminal,
    valid sealed report agreeing with the sticky facts, clean process
    evidence, and stable exact final source and payload roots/OIDs. Any
    blocker refuses closure with the exact projected list; evidence and
    bounded history are never erased. ``--abandoned`` closure is deferred
    and still fails closed. No HTTP, signals, deletion, retry, scheduling,
    repair, cleanup, or auto-close.
    """
    if getattr(args, "abandoned", False):
        fail("not_implemented",
             "review-close --abandoned is deferred to a later increment; "
             "only --verified closure is implemented")

    ctx = open_context(args, need_git_home=False)
    fds, base, repo, state = (
        ctx["fds"], ctx["base"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)
    facts = _read_facts(payload_fd)
    if facts is None:
        fail("review_not_bound",
             "the review must be bound before verified closure")
    _require_review_open(review, facts)

    pointer = _read_pointer(payload_fd)
    manifest = _read_manifest(payload_fd)

    binding = RootBinding(fds, base, review["payload_name"],
                          expect_payload=pointer["payload_identity"],
                          expect_src=pointer["src_identity"])
    binding.bind()

    blockers, _sealed = _closure_blockers(
        fds, binding, review, facts, pointer, manifest)
    if blockers:
        _refuse_blocked_closure(blockers)

    # Bounded history projection for the result (read before the transition;
    # the observation records themselves are never touched).
    latest = read_flat_record(payload_fd, "latest.json", "latest",
                              "review latest", allow_missing=True)
    observation_count = latest.get("observation_count", 0) \
        if latest is not None else 0

    generation = facts["generation"]
    now = int(time.time())

    mutex = TransitionMutex(state)
    with mutex:
        # Re-read both records under the lock: write-once and generation CAS.
        locked_review = _load_review(state, args.id)
        locked_facts = _read_facts(payload_fd)
        if locked_facts is None:
            fail("review_not_bound",
                 "the review facts disappeared under the lock")
        _require_review_open(locked_review, locked_facts)
        if locked_facts["generation"] != generation:
            fail("generation_conflict",
                 "the review facts changed (generation %d -> %d)"
                 % (generation, locked_facts["generation"]))

        # Re-project every blocker at decision time: closure publishes only
        # against a state that is still clean under the lock.
        locked_blockers, sealed = _closure_blockers(
            fds, binding, locked_review, locked_facts, pointer, manifest)
        if locked_blockers:
            _refuse_blocked_closure(locked_blockers)

        new_generation = generation + 1
        updated_facts = dict(locked_facts)
        updated_facts["generation"] = new_generation
        updated_facts["artifact_verified"] = True
        updated_facts["verified_at"] = now
        updated_facts["closure"] = _CLOSURE_VERIFIED
        updated_facts["closure_reason"] = "verified"
        updated_facts["closed_at"] = now
        updated_facts["last_activity_at"] = now

        facts_record = new_record("facts", new_generation, {
            "review_id": updated_facts["review_id"],
            "session_id": updated_facts["session_id"],
            "request_id": updated_facts["request_id"],
            "bound_at": updated_facts["bound_at"],
            "cancel_requested": updated_facts["cancel_requested"],
            "cancel_requested_at": updated_facts["cancel_requested_at"],
            "terminal_observed": updated_facts["terminal_observed"],
            "terminal_completion": updated_facts["terminal_completion"],
            "terminal_at": updated_facts["terminal_at"],
            "report_sealed": updated_facts["report_sealed"],
            "report_digest": updated_facts["report_digest"],
            "report_verdict": updated_facts["report_verdict"],
            "report_sealed_at": updated_facts["report_sealed_at"],
            "artifact_verified": updated_facts["artifact_verified"],
            "verified_at": updated_facts["verified_at"],
            "closure": updated_facts["closure"],
            "closure_reason": updated_facts["closure_reason"],
            "closed_at": updated_facts["closed_at"],
            "conflict": updated_facts["conflict"],
            "contract_commit": updated_facts["contract_commit"],
            "contract_report": updated_facts["contract_report"],
            "contract_sidecar": updated_facts["contract_sidecar"],
            "contract_sidecar_digest": updated_facts["contract_sidecar_digest"],
            "false_terminal": updated_facts["false_terminal"],
            "false_terminal_reason": updated_facts["false_terminal_reason"],
            "false_terminal_at": updated_facts["false_terminal_at"],
            "provider": updated_facts["provider"],
            "provider_model": updated_facts["provider_model"],
            "session_rotation_required":
                updated_facts["session_rotation_required"],
            "last_activity_at": updated_facts["last_activity_at"],
        })
        publish_flat_record(payload_fd, "facts.json", "facts", facts_record,
                            "review facts")

        updated_review = dict(locked_review)
        updated_review["generation"] = locked_review["generation"] + 1
        updated_review["state"] = "closed"
        updated_review["closure"] = _CLOSURE_VERIFIED
        updated_review["closure_reason"] = "verified"
        updated_review["updated_at"] = now
        publish_record(fds, state.reviews, review["review_id"], "review",
                       updated_review, "review record")

    fds.close_all()
    return {
        "ok": True, "command": "review-close",
        "review_id": review["review_id"],
        "closure": _CLOSURE_VERIFIED,
        "closure_reason": "verified",
        "state": "closed",
        "report_verdict": sealed["verdict"] if sealed is not None else None,
        "report_digest": sealed["digest"] if sealed is not None else None,
        "closed_at": _format_ts(now),
        "closed_at_epoch": now,
        "observation_count": observation_count,
        "blockers": [],
        "generation": new_generation,
    }


def cmd_review_verify(args):
    """Exact-PASS merge gate. Read-only; never mutates any record.

    The gate succeeds ONLY for a review whose write-once closure is exactly
    ``closed_verified`` AND whose sealed report verdict is exactly ``PASS``.
    ``HOLD`` and ``FAIL`` never pass. An open, abandoned, or inconsistent
    review fails closed with an exact code. No HTTP, signals, deletion,
    retry, scheduling, repair, cleanup, or auto-close.
    """
    ctx = open_context(args, need_git_home=False)
    fds, base, repo, state = (
        ctx["fds"], ctx["base"], ctx["repo"], ctx["state"])

    review = _load_review(state, args.id)
    if review["repo_id"] != repo["repo_id"] or review["top"] != repo["top"]:
        fail("identity_mismatch",
             "the review does not belong to this repository")

    payload_fd = _open_payload(fds, base, review)
    facts = _read_facts(payload_fd)
    if facts is None:
        fail("merge_gate_not_verified",
             "the merge gate passes only a closed_verified review; "
             "this review has no facts record")
    if review["state"] != "closed" \
            or review.get("closure") != _CLOSURE_VERIFIED \
            or facts.get("closure") != _CLOSURE_VERIFIED:
        fail("merge_gate_not_verified",
             "the merge gate passes only a closed_verified review "
             "(state=%s closure=%s)"
             % (bounded(review["state"], 32),
                bounded(review.get("closure"), 32)))

    # Exact PASS from the sticky facts first: HOLD/FAIL/absent never pass.
    if not facts.get("report_sealed") or facts.get("report_verdict") != "PASS":
        fail("merge_gate_verdict_not_pass",
             "the merge gate passes only an exact PASS verdict, not %r"
             % (bounded(facts.get("report_verdict"), 16),))

    pointer = _read_pointer(payload_fd)
    manifest = _read_manifest(payload_fd)
    identity_blockers = _identity_blockers(review, pointer, manifest)
    if identity_blockers:
        fail("merge_gate_identity_mismatch",
             "pinned identity disagreement: %s"
             % (",".join(identity_blockers),))

    binding = RootBinding(fds, base, review["payload_name"],
                          expect_payload=pointer["payload_identity"],
                          expect_src=pointer["src_identity"])
    binding.bind()

    residue = detect_incomplete_report(fds, binding.payload_fd)
    if residue is not None:
        raise CoordError(residue,
                         "crash residue from an incomplete report seal "
                         "refuses the merge gate")
    sealed = read_sealed_report(fds, binding, review["commit"],
                                review["reviewer_actor"])
    if sealed is None:
        fail("merge_gate_report_missing",
             "the sealed report is absent; the merge gate refuses")
    if sealed["digest"] != facts.get("report_digest"):
        fail("merge_gate_report_mismatch",
             "the sealed report digest disagrees with the sticky facts")
    if sealed["verdict"] != "PASS":
        fail("merge_gate_verdict_not_pass",
             "the sealed report verdict is %r, not exact PASS"
             % (bounded(sealed["verdict"], 16),))
    binding.recheck()

    fds.close_all()
    return {
        "ok": True, "command": "review-verify",
        "merge_gate": "pass",
        "review_id": review["review_id"],
        "closure": _CLOSURE_VERIFIED,
        "verdict": "PASS",
        "commit": review["commit"],
        "tree": review["tree"],
        "algo": review["algo"],
        "report_digest": sealed["digest"],
        "report_bytes": sealed["bytes"],
        "closed_at": _format_ts(facts.get("closed_at")),
        "closed_at_epoch": facts.get("closed_at"),
        "generation": facts["generation"],
    }


# ---------------------------------------------------------------------------
# Section 14. CLI front matter (invoked only by tool/bin/coordination.sh)
# ---------------------------------------------------------------------------


def _fd_number(value):
    try:
        number = int(value, 10)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("fd must be a small non-negative integer")
    if number < 0 or number > 255:
        raise argparse.ArgumentTypeError("fd must be within 0..255")
    return number


def build_parser():
    parser = argparse.ArgumentParser(
        prog="coordination_verify.py",
        description="Stitchpad coordination helper (invoked via coordination.sh)",
    )
    sub = parser.add_subparsers(dest="verb", required=True)

    def common(target):
        target.add_argument("--json", action="store_true",
                            help="emit the redacted result as JSON")
        return target

    acquire = common(sub.add_parser("lease-acquire"))
    acquire.add_argument("--worktree", required=True)
    acquire.add_argument("--actor", required=True)
    acquire.add_argument("--base", required=True)
    acquire.add_argument("--token-out-fd", required=True, type=_fd_number)
    acquire.set_defaults(func=cmd_lease_acquire)

    status = common(sub.add_parser("lease-status"))
    status.add_argument("--worktree", required=True)
    status.set_defaults(func=cmd_lease_status)

    checkpoint = common(sub.add_parser("lease-checkpoint"))
    checkpoint.add_argument("--worktree", required=True)
    checkpoint.add_argument("--token-fd", required=True, type=_fd_number)
    checkpoint.add_argument("--old", required=True)
    checkpoint.add_argument("--new", required=True)
    checkpoint.set_defaults(func=cmd_lease_checkpoint)

    release = common(sub.add_parser("lease-release"))
    release.add_argument("--worktree", required=True)
    release.add_argument("--token-fd", required=True, type=_fd_number)
    release.add_argument("--head", required=True)
    release.set_defaults(func=cmd_lease_release)

    # Review-core verbs. The argument surface is frozen: `review create` takes
    # only flags, and EVERY other review verb takes the review ID as its first
    # POSITIONAL argument (design v5 section 2; audit P2-6). There is no `--id`
    # flag anywhere, so the Bash front controller in tool/bin/coordination.sh
    # and this parser cannot drift apart. Only `review-close --abandoned`
    # remains deferred; it fails closed as not_implemented inside
    # cmd_review_close, so nothing here silently half-runs.
    def with_review_id(target):
        target.add_argument("id", metavar="ID",
                            help="review id: exactly 32 lowercase hex characters")
        return target
    create = common(sub.add_parser("review-create"))
    create.add_argument("--repo", required=True)
    create.add_argument("--commit", required=True)
    create.add_argument("--author-actor", required=True)
    create.add_argument("--reviewer-actor", required=True)
    create.add_argument("--provider", required=True)
    create.add_argument("--process-token-out-fd", required=True, type=_fd_number)
    create.set_defaults(func=cmd_review_create)

    bind = with_review_id(common(sub.add_parser("review-bind")))
    bind.add_argument("--session", required=True)
    bind.add_argument("--request", required=True)
    bind.set_defaults(func=cmd_review_bind)

    register = with_review_id(common(sub.add_parser("review-register-process")))
    register.add_argument("--role", required=True)
    register.add_argument("--pid", required=True, type=int)
    register.add_argument("--process-token-fd", required=True, type=_fd_number)
    register.set_defaults(func=cmd_review_register_process)

    cancel = with_review_id(common(sub.add_parser("review-cancel-requested")))
    cancel.set_defaults(func=cmd_review_cancel_requested)

    refresh = with_review_id(common(sub.add_parser("review-refresh")))
    refresh.add_argument("--provider-rows-fd", required=True, type=_fd_number)
    refresh.set_defaults(func=cmd_review_refresh)

    status = with_review_id(common(sub.add_parser("review-status")))
    status.set_defaults(func=cmd_review_status)

    verify = with_review_id(common(sub.add_parser("review-verify")))
    verify.set_defaults(func=cmd_review_verify)

    submit_report = with_review_id(common(sub.add_parser("review-submit-report")))
    submit_report.set_defaults(func=cmd_review_submit_report)

    close = with_review_id(common(sub.add_parser("review-close")))
    group = close.add_mutually_exclusive_group(required=True)
    group.add_argument("--verified", action="store_true")
    group.add_argument("--abandoned", action="store_true")
    close.set_defaults(func=cmd_review_close)

    return parser


def emit_result(result, want_json):
    if want_json:
        sys.stdout.write(json.dumps(result, sort_keys=True,
                                    separators=(",", ":")) + "\n")
        return
    for key in sorted(result):
        value = result[key]
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("%s: %s\n" % (key, value))


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    want_json = bool(getattr(args, "json", False))
    try:
        try:
            result = args.func(args)
        finally:
            release_owned_scratch_ledger()
    except CoordError as exc:
        if want_json:
            sys.stdout.write(json.dumps({
                "ok": False, "error": exc.code,
                "detail": bounded(exc.detail, 300),
            }, sort_keys=True, separators=(",", ":")) + "\n")
        else:
            sys.stderr.write("coordination refused: %s: %s\n"
                             % (exc.code, bounded(exc.detail, 300)))
        return 2
    except BrokenPipeError:
        return 2
    emit_result(result, want_json)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
