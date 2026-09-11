"""Linux env-file reconciliation primitives for trusted, release-owned adapters.

No CLI or service execution. Remote requests must never select paths or rules.
Plans contain secrets and must remain in a private local journal directory.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import stat
import uuid
from dataclasses import dataclass

MAX_BYTES = 1024 * 1024
KEY = re.compile(r"[A-Z][A-Z0-9_]{0,127}\Z")
# Deliberately only the common literal subset of systemd/Compose env syntax.
VALUE = re.compile(r"[A-Za-z0-9_.,:/+@=-]*\Z")


class ReconcileError(Exception):
    """Messages are constant codes: never include file contents or supplied values."""


@dataclass(frozen=True)
class Rule:
    key: str
    mode: str  # initialize, managed, or add-set


def candidate(source: bytes, rules: tuple[Rule, ...], desired: dict[str, str],
              baseline: dict[str, str] | None = None) -> bytes:
    """Preserve unrelated lines; reject ambiguous managed fields and local drift."""
    if len(source) > MAX_BYTES:
        raise ReconcileError("FILE_TOO_LARGE")
    try:
        content = source.decode("utf-8")
    except UnicodeDecodeError:
        raise ReconcileError("INVALID_ENCODING") from None
    if "\x00" in content or "\r" in content:
        raise ReconcileError("UNSUPPORTED_ENV_FORMAT")
    allowed = {rule.key: rule.mode for rule in rules}
    if len(allowed) != len(rules) or any(not KEY.fullmatch(k) for k in allowed):
        raise ReconcileError("INVALID_ADAPTER_RULES")
    if any(mode not in ("initialize", "managed", "add-set") for mode in allowed.values()):
        raise ReconcileError("INVALID_ADAPTER_RULES")
    if not isinstance(desired, dict) or not desired or set(desired) - allowed.keys():
        raise ReconcileError("UNKNOWN_MANAGED_FIELD")
    if any(not isinstance(v, str) or not v or not VALUE.fullmatch(v) for v in desired.values()):
        raise ReconcileError("UNSUPPORTED_DESIRED_VALUE")
    lines = content.splitlines(keepends=True)
    current: dict[str, tuple[int, str]] = {}
    for index, line in enumerate(lines):
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#"):
            continue
        match = re.match(r"(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=", trimmed)
        if not match:
            raise ReconcileError("UNSUPPORTED_ENV_FORMAT")
        raw = trimmed[match.end():].strip()
        if raw.startswith(('"', "'")):
            if len(raw) < 2 or raw[-1] != raw[0] or "\\" in raw:
                raise ReconcileError("UNSUPPORTED_ENV_FORMAT")
        elif any(char in raw for char in ('"', "'", "\\")):
            raise ReconcileError("UNSUPPORTED_ENV_FORMAT")
        if match[1] not in desired:
            continue
        key = match[1]
        if key in current:
            raise ReconcileError("DUPLICATE_MANAGED_FIELD")
        # Accept simple quoted literals, never expansion or escaped values.
        value = trimmed[match.end():].strip()
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            value = value[1:-1]
        if not VALUE.fullmatch(value):
            raise ReconcileError("UNSUPPORTED_CURRENT_VALUE")
        current[key] = (index, value)
    for key, wanted in desired.items():
        old = current.get(key, (-1, ""))[1]
        mode = allowed[key]
        if mode == "add-set":
            before = old.split(",") if old else []
            added = wanted.split(",")
            if any(not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", x) for x in before + added):
                raise ReconcileError("INVALID_SET_MEMBER")
            wanted = ",".join(dict.fromkeys(before + added))
        if old == wanted:
            continue
        if mode == "initialize" and old:
            raise ReconcileError("EXISTING_VALUE_CONFLICT")
        if mode == "managed" and old and (baseline is None or baseline.get(key) != old):
            raise ReconcileError("LOCAL_DRIFT_CONFLICT")
        replacement = key + "=" + wanted + "\n"
        if key in current:
            lines[current[key][0]] = replacement
        else:
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(replacement)
    result = "".join(lines).encode()
    if len(result) > MAX_BYTES:
        raise ReconcileError("FILE_TOO_LARGE")
    return result


@contextlib.contextmanager
def secure_directory(path: str, *, private: bool = False):
    """Walk absolute paths using directory FDs; reject symlinks/writable ancestors."""
    if not os.path.isabs(path) or any(p in (".", "..") for p in path.split("/")):
        raise ReconcileError("INVALID_LOCAL_PATH")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in filter(None, path.split("/")):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            if info.st_uid not in (0, os.geteuid()) or info.st_mode & 0o022:
                raise ReconcileError("UNTRUSTED_DIRECTORY")
        if private and (os.fstat(fd).st_mode & 0o077 or os.fstat(fd).st_uid != os.geteuid()):
            raise ReconcileError("JOURNAL_NOT_PRIVATE")
        yield fd
    finally:
        os.close(fd)


def read_file(parent: int, name: str) -> tuple[bytes, os.stat_result]:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
            raise ReconcileError("UNSAFE_FILE")
        if info.st_mode & 0o022:
            raise ReconcileError("WRITABLE_CONFIG")
        data = bytearray()
        while len(data) <= MAX_BYTES:
            block = os.read(fd, min(65536, MAX_BYTES + 1 - len(data)))
            if not block:
                return bytes(data), info
            data.extend(block)
        raise ReconcileError("FILE_TOO_LARGE")
    finally:
        os.close(fd)


def atomic_write(parent: int, name: str, data: bytes, mode: int, uid: int, gid: int):
    temporary = ".reconcile-" + uuid.uuid4().hex
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=parent)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fchown(fd, uid, gid)
            os.fchmod(fd, mode)
            os.fsync(fd)
        os.replace(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        os.close(fd)
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass


class EnvJournal:
    """One private journal per adapter, held under an exclusive process lock.

    The caller verifies remote assignment/lease before calling apply. Only root-owned
    cooperating adapters may write this config during apply; another privileged process
    cannot be fenced by filesystem permissions. This object never restarts a service.
    """

    def __init__(self, path: str, journal: str, rules: tuple[Rule, ...]):
        self.path, self.journal, self.rules = path, journal, rules

    @contextlib.contextmanager
    def locked(self):
        with secure_directory(os.path.dirname(self.path)) as target:
            with secure_directory(self.journal, private=True) as journal:
                lock = os.open("lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                               0o600, dir_fd=journal)
                try:
                    info = os.fstat(lock)
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                        raise ReconcileError("UNSAFE_LOCK")
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    yield target, journal
                finally:
                    os.close(lock)

    @staticmethod
    def save(journal: int, name: str, plan: dict):
        data = json.dumps(plan, sort_keys=True).encode()
        if len(data) > MAX_BYTES:
            raise ReconcileError("JOURNAL_TOO_LARGE")
        atomic_write(journal, name, data, 0o600, os.geteuid(), os.getegid())

    @staticmethod
    def name(operation: str) -> str:
        try:
            return str(uuid.UUID(operation)) + ".json"
        except (ValueError, AttributeError):
            raise ReconcileError("INVALID_OPERATION") from None

    def stage(self, operation: str, desired: dict[str, str], baseline=None) -> dict:
        name = self.name(operation)
        with self.locked() as (target, journal):
            source, info = read_file(target, os.path.basename(self.path))
            proposed = candidate(source, self.rules, desired, baseline)
            plan = dict(version=1, path=self.path, phase="staged", before=source.decode(),
                        after=proposed.decode(), mode=stat.S_IMODE(info.st_mode), uid=info.st_uid,
                        gid=info.st_gid)
            try:
                saved, _ = read_file(journal, name)
            except FileNotFoundError:
                self.save(journal, name, plan)
            else:
                # Never replace the before-image or reinterpret an operation ID.
                previous = json.loads(saved)
                if previous["path"] != self.path or previous["after"] != proposed.decode():
                    raise ReconcileError("OPERATION_CONFLICT")
                plan = previous
            return {"phase": plan["phase"], "changed": plan["before"] != plan["after"]}

    def apply(self, operation: str) -> dict:
        with self.locked() as (target, journal):
            name = self.name(operation)
            saved, _ = read_file(journal, name)
            plan = json.loads(saved)
            if plan["version"] != 1 or plan["path"] != self.path:
                raise ReconcileError("PLAN_MISMATCH")
            current, info = read_file(target, os.path.basename(self.path))
            if (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid) != (plan["mode"], plan["uid"], plan["gid"]):
                raise ReconcileError("METADATA_CHANGED")
            before, after = plan["before"].encode(), plan["after"].encode()
            changed = current != after
            if current != after:
                if current != before or plan["phase"] not in ("staged", "applying"):
                    raise ReconcileError("STALE_PLAN")
                plan["phase"] = "applying"
                self.save(journal, name, plan)
                # Repeat read after journaling, before replacement; operator writers must
                # share the adapter lock. Root can bypass any filesystem-level lock.
                check, latest = read_file(target, os.path.basename(self.path))
                if check != current or (latest.st_ino, latest.st_mtime_ns) != (info.st_ino, info.st_mtime_ns):
                    raise ReconcileError("CONCURRENT_EDIT")
                atomic_write(target, os.path.basename(self.path), after, plan["mode"], plan["uid"], plan["gid"])
            verified, _ = read_file(target, os.path.basename(self.path))
            if verified != after:
                raise ReconcileError("VERIFY_FAILED")
            if plan["phase"] != "applied":
                plan["phase"] = "applied"
                self.save(journal, name, plan)
            return {"phase": "applied", "changed": changed}
