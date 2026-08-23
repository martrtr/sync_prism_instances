#!/usr/bin/env python3
"""Runtime server-list synchronizer for Prism Launcher instances.

Prism runs this file as a pre-launch and post-exit hook.  servers.dat is kept as
an ordinary file inside every instance because Minecraft replaces it atomically
while saving; a symlink therefore cannot be used reliably.
"""

from __future__ import annotations

import argparse
import fcntl
import gzip
import io
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

TAG_END = 0
TAG_BYTE = 1
TAG_SHORT = 2
TAG_INT = 3
TAG_LONG = 4
TAG_FLOAT = 5
TAG_DOUBLE = 6
TAG_BYTE_ARRAY = 7
TAG_STRING = 8
TAG_LIST = 9
TAG_COMPOUND = 10
TAG_INT_ARRAY = 11
TAG_LONG_ARRAY = 12

STATE_NAME = ".sync_prism_instances.servers.json"
MARKER_NAME = ".sync_prism_instances.servers"
BASELINE_NAME = ".sync_prism_instances.servers.baseline.dat"


class SyncError(Exception):
    pass


class NBTError(SyncError):
    pass


def mutf8_decode(data: bytes) -> str:
    units: list[int] = []
    i = 0
    while i < len(data):
        b0 = data[i]
        if b0 & 0x80 == 0:
            units.append(b0)
            i += 1
        elif b0 & 0xE0 == 0xC0:
            if i + 1 >= len(data):
                raise NBTError("обрезанная modified UTF-8 строка")
            b1 = data[i + 1]
            if b1 & 0xC0 != 0x80:
                raise NBTError("некорректная modified UTF-8 строка")
            units.append(((b0 & 0x1F) << 6) | (b1 & 0x3F))
            i += 2
        elif b0 & 0xF0 == 0xE0:
            if i + 2 >= len(data):
                raise NBTError("обрезанная modified UTF-8 строка")
            b1, b2 = data[i + 1], data[i + 2]
            if b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80:
                raise NBTError("некорректная modified UTF-8 строка")
            units.append(((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F))
            i += 3
        else:
            raise NBTError("4-байтная последовательность недопустима в Java modified UTF-8")

    raw = bytearray()
    for unit in units:
        raw.extend(struct.pack(">H", unit))
    return bytes(raw).decode("utf-16-be", errors="surrogatepass")


def mutf8_encode(value: str) -> bytes:
    raw = value.encode("utf-16-be", errors="surrogatepass")
    out = bytearray()
    for i in range(0, len(raw), 2):
        unit = (raw[i] << 8) | raw[i + 1]
        if 0x0001 <= unit <= 0x007F:
            out.append(unit)
        elif unit <= 0x07FF:
            out.extend((0xC0 | (unit >> 6), 0x80 | (unit & 0x3F)))
        else:
            out.extend(
                (
                    0xE0 | (unit >> 12),
                    0x80 | ((unit >> 6) & 0x3F),
                    0x80 | (unit & 0x3F),
                )
            )
    return bytes(out)


class Reader:
    def __init__(self, data: bytes):
        self.f = io.BytesIO(data)

    def read(self, n: int) -> bytes:
        value = self.f.read(n)
        if len(value) != n:
            raise NBTError("неожиданный конец NBT")
        return value

    def unpack(self, fmt: str) -> Any:
        return struct.unpack(fmt, self.read(struct.calcsize(fmt)))[0]

    def string(self) -> str:
        length = self.unpack(">H")
        return mutf8_decode(self.read(length))

    def payload(self, tag: int) -> Any:
        if tag == TAG_BYTE:
            return self.unpack(">b")
        if tag == TAG_SHORT:
            return self.unpack(">h")
        if tag == TAG_INT:
            return self.unpack(">i")
        if tag == TAG_LONG:
            return self.unpack(">q")
        if tag == TAG_FLOAT:
            return self.unpack(">f")
        if tag == TAG_DOUBLE:
            return self.unpack(">d")
        if tag == TAG_BYTE_ARRAY:
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина byte array")
            return self.read(n)
        if tag == TAG_STRING:
            return self.string()
        if tag == TAG_LIST:
            child = self.unpack(">B")
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина list")
            return child, [self.payload(child) for _ in range(n)]
        if tag == TAG_COMPOUND:
            out: dict[str, tuple[int, Any]] = {}
            while True:
                child = self.unpack(">B")
                if child == TAG_END:
                    break
                name = self.string()
                out[name] = child, self.payload(child)
            return out
        if tag == TAG_INT_ARRAY:
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина int array")
            return [self.unpack(">i") for _ in range(n)]
        if tag == TAG_LONG_ARRAY:
            n = self.unpack(">i")
            if n < 0:
                raise NBTError("отрицательная длина long array")
            return [self.unpack(">q") for _ in range(n)]
        raise NBTError(f"неизвестный NBT tag: {tag}")


class Writer:
    def __init__(self):
        self.f = io.BytesIO()

    def write(self, data: bytes) -> None:
        self.f.write(data)

    def pack(self, fmt: str, value: Any) -> None:
        self.write(struct.pack(fmt, value))

    def string(self, value: str) -> None:
        data = mutf8_encode(value)
        if len(data) > 65535:
            raise NBTError("слишком длинная NBT строка")
        self.pack(">H", len(data))
        self.write(data)

    def payload(self, tag: int, value: Any) -> None:
        if tag == TAG_BYTE:
            self.pack(">b", value)
        elif tag == TAG_SHORT:
            self.pack(">h", value)
        elif tag == TAG_INT:
            self.pack(">i", value)
        elif tag == TAG_LONG:
            self.pack(">q", value)
        elif tag == TAG_FLOAT:
            self.pack(">f", value)
        elif tag == TAG_DOUBLE:
            self.pack(">d", value)
        elif tag == TAG_BYTE_ARRAY:
            self.pack(">i", len(value))
            self.write(value)
        elif tag == TAG_STRING:
            self.string(value)
        elif tag == TAG_LIST:
            child, values = value
            self.pack(">B", child)
            self.pack(">i", len(values))
            for entry in values:
                self.payload(child, entry)
        elif tag == TAG_COMPOUND:
            for name, (child, entry) in value.items():
                self.pack(">B", child)
                self.string(name)
                self.payload(child, entry)
            self.pack(">B", TAG_END)
        elif tag == TAG_INT_ARRAY:
            self.pack(">i", len(value))
            for entry in value:
                self.pack(">i", entry)
        elif tag == TAG_LONG_ARRAY:
            self.pack(">i", len(value))
            for entry in value:
                self.pack(">q", entry)
        else:
            raise NBTError(f"неизвестный NBT tag: {tag}")

    def value(self) -> bytes:
        return self.f.getvalue()


Document = tuple[str, dict[str, tuple[int, Any]], bool]


def empty_document() -> Document:
    return "", {"servers": (TAG_LIST, (TAG_COMPOUND, []))}, False


def load_nbt(path: Path) -> Document | None:
    if not path.exists() or not path.is_file() or path.stat().st_size == 0:
        return None
    raw = path.read_bytes()
    compressed = raw.startswith(b"\x1f\x8b")
    if compressed:
        raw = gzip.decompress(raw)
    reader = Reader(raw)
    root_type = reader.unpack(">B")
    if root_type != TAG_COMPOUND:
        raise NBTError(f"корневой tag servers.dat должен быть compound, получен {root_type}")
    root_name = reader.string()
    root = reader.payload(TAG_COMPOUND)
    if reader.f.read(1):
        raise NBTError("лишние данные после корневого NBT")
    server_list(root)  # validate the list while the original file is still untouched
    return root_name, root, compressed


def dump_nbt(document: Document) -> bytes:
    root_name, root, compressed = document
    writer = Writer()
    writer.pack(">B", TAG_COMPOUND)
    writer.string(root_name)
    writer.payload(TAG_COMPOUND, root)
    raw = writer.value()
    return gzip.compress(raw) if compressed else raw


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def save_nbt(path: Path, document: Document) -> None:
    atomic_write(path, dump_nbt(document))


def string_tag(compound: dict[str, tuple[int, Any]], key: str) -> str:
    value = compound.get(key)
    if not value or value[0] != TAG_STRING:
        return ""
    return value[1]


def server_key(compound: dict[str, tuple[int, Any]]) -> tuple[str, str]:
    ip = string_tag(compound, "ip").strip().casefold()
    if ip:
        return "ip", ip
    name = string_tag(compound, "name").strip().casefold()
    if name:
        return "name", name
    return "raw", repr(compound)


def server_list(root: dict[str, tuple[int, Any]]) -> list[dict[str, tuple[int, Any]]]:
    entry = root.get("servers")
    if entry is None:
        return []
    if entry[0] != TAG_LIST or entry[1][0] != TAG_COMPOUND:
        raise NBTError("tag 'servers' имеет неожиданный тип")
    return entry[1][1]


def with_servers(base: Document | None, servers: list[dict[str, tuple[int, Any]]]) -> Document:
    if base is None:
        base = empty_document()
    root_name, root, compressed = base
    root = dict(root)
    root["servers"] = TAG_LIST, (TAG_COMPOUND, servers)
    return root_name, root, compressed


def entries(document: Document | None) -> list[dict[str, tuple[int, Any]]]:
    return [] if document is None else list(server_list(document[1]))


def entry_equal(a: dict[str, tuple[int, Any]], b: dict[str, tuple[int, Any]]) -> bool:
    return a == b


def initial_union(*documents: Document | None) -> Document:
    base = next((doc for doc in documents if doc is not None), None)
    merged: list[dict[str, tuple[int, Any]]] = []
    seen: set[tuple[str, str]] = set()
    for doc in documents:
        for server in entries(doc):
            key = server_key(server)
            if key in seen:
                continue
            merged.append(server)
            seen.add(key)
    return with_servers(base, merged)


def reconcile(shared: Document | None, baseline: Document | None, local: Document | None) -> Document:
    """Apply this instance's changes since baseline to the current shared list.

    This is a small three-way merge.  Additions and edits from the instance are
    applied to the latest shared list.  A deletion is applied only when the
    corresponding shared entry has not changed since this instance started,
    which avoids deleting a concurrent edit from another running instance.
    """
    if baseline is None:
        return initial_union(shared, local)
    if local is None:
        # Missing file is treated as an abnormal/partial write, not "delete all".
        return shared or baseline or empty_document()

    base_entries = entries(baseline)
    local_entries = entries(local)
    shared_entries = entries(shared)

    base_map = {server_key(x): x for x in base_entries}
    local_map = {server_key(x): x for x in local_entries}
    shared_map = {server_key(x): x for x in shared_entries}
    order = [server_key(x) for x in shared_entries]

    # Deletions and edits of entries that existed at launch.
    for key, base_entry in base_map.items():
        local_entry = local_map.get(key)
        if local_entry is None:
            current = shared_map.get(key)
            if current is not None and entry_equal(current, base_entry):
                shared_map.pop(key, None)
                order = [k for k in order if k != key]
        elif not entry_equal(local_entry, base_entry):
            if key not in shared_map:
                order.append(key)
            shared_map[key] = local_entry

    # New entries created while the instance was running.
    for local_entry in local_entries:
        key = server_key(local_entry)
        if key not in base_map:
            if key not in shared_map:
                order.append(key)
            shared_map[key] = local_entry

    merged = [shared_map[key] for key in order if key in shared_map]
    return with_servers(shared or local or baseline, merged)


class LockedShared:
    def __init__(self, shared: Path):
        self.lock_path = shared.with_name(shared.name + ".sync-prism.lock")
        self.handle: io.TextIOWrapper | None = None

    def __enter__(self) -> None:
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = self.lock_path.open("a+")
        fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        assert self.handle is not None
        fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        self.handle.close()


def state_path(game_dir: Path) -> Path:
    return game_dir / STATE_NAME


def marker_path(game_dir: Path) -> Path:
    return game_dir / MARKER_NAME


def baseline_path(game_dir: Path) -> Path:
    return game_dir / BASELINE_NAME


def read_state(game_dir: Path) -> dict[str, Any]:
    path = state_path(game_dir)
    if not path.is_file():
        raise SyncError(f"не найдено состояние синхронизации: {path}")
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        raise SyncError(f"не удалось прочитать {path}: {exc}") from exc
    if state.get("version") != 3 or not state.get("shared"):
        raise SyncError(f"неподдерживаемое состояние синхронизации: {path}")
    return state


def write_state(game_dir: Path, state: dict[str, Any]) -> None:
    atomic_write(state_path(game_dir), (json.dumps(state, ensure_ascii=False, indent=2) + "\n").encode())
    atomic_write(marker_path(game_dir), (str(state["shared"]) + "\n").encode())


def sync_game(game_dir: Path, state: dict[str, Any], include_old_on_first: bool = False) -> None:
    shared = Path(state["shared"])
    local = game_dir / "servers.dat"
    baseline = baseline_path(game_dir)

    with LockedShared(shared):
        shared_doc = load_nbt(shared)
        local_doc = load_nbt(local)
        baseline_doc = load_nbt(baseline)

        if baseline_doc is None and include_old_on_first:
            old_doc = None
            old = game_dir / "servers.dat_old"
            try:
                # During migration Minecraft may have moved the old shared symlink
                # to servers.dat_old.  Loading it is safe and prevents data loss.
                old_doc = load_nbt(old)
            except NBTError:
                old_doc = None
            merged = initial_union(shared_doc, local_doc, old_doc)
        else:
            merged = reconcile(shared_doc, baseline_doc, local_doc)

        data = dump_nbt(merged)
        atomic_write(shared, data)
        # os.replace intentionally replaces a legacy symlink with a normal file.
        atomic_write(local, data)
        atomic_write(baseline, data)


def qt_ini_decode(value: str) -> str:
    # QSettings stores quotes/backslashes escaped in INI files.  Custom command
    # values are strings, so the small escape subset below is sufficient and
    # keeps unknown escapes intact instead of guessing.
    out: list[str] = []
    i = 0
    escapes = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"'}
    while i < len(value):
        if value[i] == "\\" and i + 1 < len(value):
            nxt = value[i + 1]
            if nxt in escapes:
                out.append(escapes[nxt])
                i += 2
                continue
        out.append(value[i])
        i += 1
    return "".join(out)


def qt_ini_encode(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def read_ini(path: Path) -> tuple[list[str], dict[str, str]]:
    if not path.exists():
        return [], {}
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    lines = text.splitlines()
    values: dict[str, str] = {}
    for line in lines:
        if not line or line.lstrip().startswith(("#", ";")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value
    return lines, values


def write_ini_values(path: Path, changes: dict[str, str | None]) -> None:
    lines, _ = read_ini(path)
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if "=" not in line or line.lstrip().startswith(("#", ";")):
            out.append(line)
            continue
        key = line.split("=", 1)[0].strip()
        if key not in changes:
            out.append(line)
            continue
        if key in seen:
            continue
        seen.add(key)
        value = changes[key]
        if value is not None:
            out.append(f"{key}={value}")
    for key, value in changes.items():
        if key not in seen and value is not None:
            out.append(f"{key}={value}")
    atomic_write(path, (("\n".join(out) + "\n") if out else "").encode("utf-8", errors="surrogateescape"))


def snapshot_keys(values: dict[str, str], keys: list[str]) -> dict[str, dict[str, Any]]:
    return {key: {"present": key in values, "value": values.get(key, "")} for key in keys}


def bool_value(value: str | None) -> bool:
    return (value or "").strip().casefold() in {"1", "true", "yes", "on"}


def get_override(values: dict[str, str]) -> bool:
    if "OverrideCommands" in values:
        return bool_value(values["OverrideCommands"])
    return bool_value(values.get("OverrideLaunchCmd"))


def effective_command(instance_values: dict[str, str], global_values: dict[str, str], key: str) -> str:
    raw = instance_values.get(key, "") if get_override(instance_values) else global_values.get(key, "")
    return qt_ini_decode(raw)


def qprocess_quote(value: str) -> str:
    if '"' in value:
        # QProcess uses double quotes.  Quotes in a filesystem path are legal on
        # Linux, but supporting them here is not worth producing a broken hook.
        raise SyncError(f"путь содержит двойную кавычку и не может быть безопасно записан в Prism command: {value}")
    if not value or any(ch.isspace() for ch in value):
        return f'"{value}"'
    return value


def make_hook_command(action: str) -> str:
    return " ".join((qprocess_quote(sys.executable), qprocess_quote(str(Path(__file__).resolve())), "hook", action))


def is_our_hook(command: str) -> bool:
    return "server_sync.py" in command and " hook " in f" {command} "


def install_hooks(instance_cfg: Path, state: dict[str, Any]) -> None:
    write_ini_values(
        instance_cfg,
        {
            "OverrideCommands": "true",
            "OverrideLaunchCmd": None,
            "PreLaunchCommand": qt_ini_encode(make_hook_command("pre")),
            "PostExitCommand": qt_ini_encode(make_hook_command("post")),
        },
    )


def restore_hooks(instance_cfg: Path, state: dict[str, Any]) -> None:
    backup = state.get("config_backup", {})
    changes: dict[str, str | None] = {}
    for key in ("OverrideCommands", "OverrideLaunchCmd", "PreLaunchCommand", "PostExitCommand"):
        item = backup.get(key, {"present": False, "value": ""})
        changes[key] = item.get("value", "") if item.get("present") else None
    write_ini_values(instance_cfg, changes)


_VAR = re.compile(r"\$(?:\{([A-Za-z0-9_]+)\}|([A-Za-z0-9_]+))")


def expand_prism_vars(command: str) -> str:
    def repl(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2)
        value = os.environ.get(name, "")
        return value if value else match.group(0)

    return _VAR.sub(repl, command)


def run_original(command: str) -> int:
    command = command.strip()
    if not command or is_our_hook(command):
        return 0
    expanded = expand_prism_vars(command)
    try:
        argv = shlex.split(expanded, posix=True)
    except ValueError as exc:
        print(f"sync_prism_instances: не удалось разобрать исходную Prism-команду: {exc}", file=sys.stderr)
        return 127
    if not argv:
        return 0
    try:
        return subprocess.run(argv, check=False).returncode
    except OSError as exc:
        print(f"sync_prism_instances: исходная Prism-команда не запустилась: {exc}", file=sys.stderr)
        return 127


def cmd_install(args: argparse.Namespace) -> int:
    game_dir = Path(args.game_dir).resolve()
    shared = Path(args.shared).resolve()
    instance_cfg = Path(args.instance_cfg).resolve()
    prism_cfg = Path(args.prism_cfg).resolve() if args.prism_cfg else None
    game_dir.mkdir(parents=True, exist_ok=True)

    existing_state = None
    try:
        existing_state = read_state(game_dir)
    except SyncError:
        pass

    if existing_state is not None:
        if Path(existing_state["shared"]).resolve() != shared:
            raise SyncError(
                f"инстанс уже синхронизирует серверы с {existing_state['shared']}; сначала отключите эту синхронизацию"
            )
        install_hooks(instance_cfg, existing_state)
        # Do not touch servers.dat here: the instance may currently be running.
        # The next Prism pre/post hook performs the actual reconciliation safely.
        return 0

    _, instance_values = read_ini(instance_cfg)
    _, global_values = read_ini(prism_cfg) if prism_cfg else ([], {})
    keys = ["OverrideCommands", "OverrideLaunchCmd", "PreLaunchCommand", "PostExitCommand"]
    pre = effective_command(instance_values, global_values, "PreLaunchCommand")
    post = effective_command(instance_values, global_values, "PostExitCommand")
    if is_our_hook(pre):
        pre = ""
    if is_our_hook(post):
        post = ""

    state = {
        "version": 3,
        "shared": str(shared),
        "instance_cfg": str(instance_cfg),
        "effective_pre": pre,
        "effective_post": post,
        "config_backup": snapshot_keys(instance_values, keys),
    }

    # State first: if Prism notices instance.cfg immediately, the hook already has
    # everything it needs.  If hook installation fails, restore/remove below.
    write_state(game_dir, state)
    try:
        sync_game(game_dir, state, include_old_on_first=True)
        install_hooks(instance_cfg, state)
    except Exception:
        try:
            restore_hooks(instance_cfg, state)
        finally:
            state_path(game_dir).unlink(missing_ok=True)
            marker_path(game_dir).unlink(missing_ok=True)
            baseline_path(game_dir).unlink(missing_ok=True)
        raise
    return 0


def cmd_uninstall(args: argparse.Namespace) -> int:
    game_dir = Path(args.game_dir).resolve()
    state = read_state(game_dir)
    sync_game(game_dir, state)
    restore_hooks(Path(state["instance_cfg"]), state)
    state_path(game_dir).unlink(missing_ok=True)
    marker_path(game_dir).unlink(missing_ok=True)
    baseline_path(game_dir).unlink(missing_ok=True)
    return 0


def cmd_hook(args: argparse.Namespace) -> int:
    game_dir = Path.cwd().resolve()
    state = read_state(game_dir)
    command = state.get("effective_pre" if args.action == "pre" else "effective_post", "")

    if args.action == "pre":
        rc = run_original(command)
        if rc != 0:
            return rc
        sync_game(game_dir, state)
        return 0

    # Let an existing post-exit command finish first, then export every change it
    # may have made to servers.dat as well.
    rc = run_original(command)
    sync_error = None
    try:
        sync_game(game_dir, state)
    except Exception as exc:  # still preserve the original command's exit status
        sync_error = exc
    if sync_error is not None:
        print(f"sync_prism_instances: post-exit sync failed: {sync_error}", file=sys.stderr)
        return rc if rc != 0 else 1
    return rc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    install = sub.add_parser("install")
    install.add_argument("--game-dir", required=True)
    install.add_argument("--shared", required=True)
    install.add_argument("--instance-cfg", required=True)
    install.add_argument("--prism-cfg")
    install.set_defaults(func=cmd_install)

    uninstall = sub.add_parser("uninstall")
    uninstall.add_argument("--game-dir", required=True)
    uninstall.set_defaults(func=cmd_uninstall)

    hook = sub.add_parser("hook")
    hook.add_argument("action", choices=("pre", "post"))
    hook.set_defaults(func=cmd_hook)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return int(args.func(args))
    except (SyncError, OSError, gzip.BadGzipFile, struct.error) as exc:
        print(f"sync_prism_instances: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
