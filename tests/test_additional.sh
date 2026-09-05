#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/sync_prism_instances.sh"
HELPER="$ROOT/server_sync.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p \
  "$TMP/instances/A/.minecraft/figura/avatars/demo" \
  "$TMP/instances/A/.minecraft/flashback/replays/demo" \
  "$TMP/instances/A/.minecraft/config/worldedit/schematics" \
  "$TMP/instances/B/.minecraft" \
  "$TMP/shared"
printf avatar > "$TMP/instances/A/.minecraft/figura/avatars/demo/avatar.json"
printf replay > "$TMP/instances/A/.minecraft/flashback/replays/demo/replay.zip"
printf schem > "$TMP/instances/A/.minecraft/config/worldedit/schematics/demo.schem"

run() {
  HOME="$TMP" XDG_DATA_HOME="$TMP/data" bash "$SCRIPT" --prism-dir "$TMP/instances" --target "$TMP/shared" "$@"
}

run --instance A --enable figura,flashback,worldedit >/dev/null
run --instance B --enable figura,flashback,worldedit >/dev/null

[[ -L "$TMP/instances/A/.minecraft/figura" ]]
[[ -L "$TMP/instances/A/.minecraft/flashback/replays" ]]
[[ -L "$TMP/instances/A/.minecraft/config/worldedit/schematics" ]]
[[ -f "$TMP/instances/B/.minecraft/figura/avatars/demo/avatar.json" ]]
[[ -f "$TMP/instances/B/.minecraft/flashback/replays/demo/replay.zip" ]]
[[ -f "$TMP/instances/B/.minecraft/config/worldedit/schematics/demo.schem" ]]

# Create two independent server lists, enable server sync, then intentionally
# diverge both local copies. Manual update must union them without losing either.
python3 - "$HELPER" "$TMP" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("server_sync", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = pathlib.Path(sys.argv[2])

def server(name, ip):
    return {
        "name": (mod.TAG_STRING, name),
        "ip": (mod.TAG_STRING, ip),
    }

def write(path, values):
    mod.save_nbt(path, mod.with_servers(mod.empty_document(), [server(*x) for x in values]))

write(root / "instances/A/.minecraft/servers.dat", [("A", "a.example")])
write(root / "instances/B/.minecraft/servers.dat", [("B", "b.example")])
PY

run --instance A --enable servers >/dev/null
run --instance B --enable servers >/dev/null

python3 - "$HELPER" "$TMP" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("server_sync", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = pathlib.Path(sys.argv[2])

def server(name, ip):
    return {"name": (mod.TAG_STRING, name), "ip": (mod.TAG_STRING, ip)}

def current(path):
    return mod.entries(mod.load_nbt(path))

def append(path, name, ip):
    values = current(path)
    values.append(server(name, ip))
    mod.save_nbt(path, mod.with_servers(mod.load_nbt(path), values))

append(root / "instances/A/.minecraft/servers.dat", "A new", "a-new.example")
append(root / "instances/B/.minecraft/servers.dat", "B new", "b-new.example")
PY

run --update-servers >/dev/null

python3 - "$HELPER" "$TMP" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("server_sync", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = pathlib.Path(sys.argv[2])
expected = {"a.example", "b.example", "a-new.example", "b-new.example"}
for path in (
    root / "shared/servers.dat",
    root / "instances/A/.minecraft/servers.dat",
    root / "instances/B/.minecraft/servers.dat",
):
    actual = {mod.string_tag(x, "ip") for x in mod.entries(mod.load_nbt(path))}
    assert actual == expected, (path, actual)
PY

echo OK
