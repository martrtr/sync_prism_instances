#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/sync_prism_instances.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p \
  "$TMP/instances/A/.minecraft/saves/world-A" \
  "$TMP/instances/B/.minecraft/saves/world-B" \
  "$TMP/shared"
printf A > "$TMP/instances/A/.minecraft/saves/world-A/level.dat"
printf B > "$TMP/instances/B/.minecraft/saves/world-B/level.dat"
printf hidden > "$TMP/instances/A/.minecraft/saves/.hidden"

python3 - "$TMP" <<'PY'
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])

def mutf8(value):
    raw = value.encode("utf-16-be", errors="surrogatepass")
    out = bytearray()
    for i in range(0, len(raw), 2):
        unit = (raw[i] << 8) | raw[i + 1]
        if 1 <= unit <= 0x7F:
            out.append(unit)
        elif unit <= 0x7FF:
            out.extend((0xC0 | (unit >> 6), 0x80 | (unit & 0x3F)))
        else:
            out.extend((0xE0 | (unit >> 12), 0x80 | ((unit >> 6) & 0x3F), 0x80 | (unit & 0x3F)))
    return bytes(out)

def string(value):
    data = mutf8(value)
    return struct.pack(">H", len(data)) + data

def server(name, ip, accept=0):
    return (
        b"\x01" + string("acceptTextures") + struct.pack(">b", accept)
        + b"\x08" + string("ip") + string(ip)
        + b"\x08" + string("name") + string(name)
        + b"\x00"
    )

def write(path, entries):
    data = (
        b"\x0a" + string("")
        + b"\x09" + string("servers") + b"\x0a" + struct.pack(">i", len(entries))
        + b"".join(entries)
        + b"\x00"
    )
    path.write_bytes(data)

write(root / "instances/A/.minecraft/servers.dat", [
    server("Alpha 🚀", "alpha.example", 1),
    server("Общий", "same.example"),
])
write(root / "instances/B/.minecraft/servers.dat", [
    server("Beta", "beta.example"),
    server("Дубликат", "same.example", 1),
])
PY

run() {
  HOME="$TMP" bash "$SCRIPT" --prism-dir "$TMP/instances" --target "$TMP/shared" "$@"
}

assert_ips() {
  local file="$1" expected="$2"
  python3 - "$file" "$expected" <<'PY'
import io
import struct
import sys

f = io.BytesIO(open(sys.argv[1], "rb").read())
expected = sys.argv[2].split(",") if sys.argv[2] else []

def read(n): return f.read(n)
def u8(): return struct.unpack(">B", read(1))[0]
def i32(): return struct.unpack(">i", read(4))[0]
def string_bytes():
    n = struct.unpack(">H", read(2))[0]
    return read(n)
def ascii_string(): return string_bytes().decode("ascii")

assert u8() == 10
assert ascii_string() == ""
assert u8() == 9 and ascii_string() == "servers" and u8() == 10
ips = []
for _ in range(i32()):
    ip = None
    while True:
        tag = u8()
        if tag == 0:
            break
        name = ascii_string()
        if tag == 1:
            read(1)
        elif tag == 8:
            value = string_bytes()
            if name == "ip":
                ip = value.decode("ascii")
        else:
            raise AssertionError(f"unexpected tag {tag}")
    ips.append(ip)
assert ips == expected, (ips, expected)
PY
}

run --instance A --enable all >/dev/null
run --instance B --enable all >/dev/null

[[ -L "$TMP/instances/A/.minecraft/servers.dat" ]]
[[ -L "$TMP/instances/B/.minecraft/servers.dat" ]]
[[ -f "$TMP/instances/A/.minecraft/.sync_prism_instances.servers" ]]
[[ -f "$TMP/instances/B/.minecraft/.sync_prism_instances.servers" ]]
[[ -f "$TMP/shared/saves/world-A/level.dat" ]]
[[ -f "$TMP/shared/saves/world-B/level.dat" ]]
[[ -f "$TMP/shared/saves/.hidden" ]]
assert_ips "$TMP/shared/servers.dat" "alpha.example,same.example,beta.example"

# Minecraft может сохранить servers.dat через atomic replace: симлинк исчезает,
# а на его месте появляется обычный файл. Следующий запуск должен забрать
# изменения, восстановить ссылку и не потерять состояние синхронизации.
python3 - "$TMP" <<'PY'
import os
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
mc = root / "instances/A/.minecraft"

def string(value):
    data = value.encode("ascii")
    return struct.pack(">H", len(data)) + data

def server(name, ip):
    return b"\x08" + string("ip") + string(ip) + b"\x08" + string("name") + string(name) + b"\x00"

data = (
    b"\x0a" + string("")
    + b"\x09" + string("servers") + b"\x0a" + struct.pack(">i", 2)
    + server("Alpha", "alpha.example")
    + server("Gamma", "gamma.example")
    + b"\x00"
)
tmp = mc / "servers.dat.tmp"
tmp.write_bytes(data)
os.replace(tmp, mc / "servers.dat")
PY

[[ ! -L "$TMP/instances/A/.minecraft/servers.dat" ]]
run --status >/dev/null
[[ -L "$TMP/instances/A/.minecraft/servers.dat" ]]
[[ -f "$TMP/instances/A/.minecraft/.sync_prism_instances.servers" ]]
assert_ips "$TMP/shared/servers.dat" "alpha.example,same.example,beta.example,gamma.example"

# Миграция v2.0: после safe replace старый симлинк может оказаться в
# servers.dat_old. Новый скрипт должен распознать это без ручного включения.
mkdir -p "$TMP/instances/Legacy/.minecraft"
ln -s "$TMP/shared/servers.dat" "$TMP/instances/Legacy/.minecraft/servers.dat_old"
python3 - "$TMP/instances/Legacy/.minecraft/servers.dat" <<'PY'
import pathlib, struct, sys
p = pathlib.Path(sys.argv[1])
def s(v):
    b=v.encode("ascii"); return struct.pack(">H",len(b))+b
def srv(name, ip):
    return b"\x08"+s("ip")+s(ip)+b"\x08"+s("name")+s(name)+b"\x00"
p.write_bytes(b"\x0a"+s("")+b"\x09"+s("servers")+b"\x0a"+struct.pack(">i",1)+srv("Legacy","legacy.example")+b"\x00")
PY
run --status >/dev/null
[[ -f "$TMP/instances/Legacy/.minecraft/.sync_prism_instances.servers" ]]
[[ -L "$TMP/instances/Legacy/.minecraft/servers.dat" ]]
assert_ips "$TMP/shared/servers.dat" "alpha.example,same.example,beta.example,gamma.example,legacy.example"

# Отключение должно вернуть обычную локальную копию, а не удалить данные.
run --instance B --disable all >/dev/null
[[ ! -L "$TMP/instances/B/.minecraft/servers.dat" ]]
[[ ! -e "$TMP/instances/B/.minecraft/.sync_prism_instances.servers" ]]
[[ -f "$TMP/instances/B/.minecraft/saves/world-A/level.dat" ]]
[[ -f "$TMP/instances/B/.minecraft/saves/world-B/level.dat" ]]

# Битый NBT не должен уничтожить ни локальный, ни общий servers.dat.
mkdir -p "$TMP/instances/C/.minecraft"
printf 'broken nbt' > "$TMP/instances/C/.minecraft/servers.dat"
before="$(sha256sum "$TMP/shared/servers.dat" | cut -d' ' -f1)"
if run --instance C --enable servers >/dev/null 2>&1; then
  echo "corrupt servers.dat unexpectedly succeeded" >&2
  exit 1
fi
[[ -f "$TMP/instances/C/.minecraft/servers.dat" ]]
[[ ! -L "$TMP/instances/C/.minecraft/servers.dat" ]]
after="$(sha256sum "$TMP/shared/servers.dat" | cut -d' ' -f1)"
[[ "$before" == "$after" ]]

echo "OK"
