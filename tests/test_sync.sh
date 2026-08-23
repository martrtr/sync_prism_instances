#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/sync_prism_instances.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_DATA_HOME="$TMP/data dir"

mkdir -p \
  "$TMP/instances/A/.minecraft/saves/world-A" \
  "$TMP/instances/B/.minecraft/saves/world-B" \
  "$TMP/shared"
printf A > "$TMP/instances/A/.minecraft/saves/world-A/level.dat"
printf B > "$TMP/instances/B/.minecraft/saves/world-B/level.dat"
printf hidden > "$TMP/instances/A/.minecraft/saves/.hidden"

cat > "$TMP/instances/A/instance.cfg" <<'CFG'
InstanceType=OneSix
OverrideCommands=true
PreLaunchCommand=python3 -c \"open('pre.called','w').write('1')\"
PostExitCommand=python3 -c \"open('post.called','w').write('1')\"
name=A
CFG
cat > "$TMP/instances/B/instance.cfg" <<'CFG'
InstanceType=OneSix
name=B
CFG
cat > "$TMP/prismlauncher.cfg" <<'CFG'
PreLaunchCommand=python3 -c \"open('global-pre.called','w').write('1')\"
PostExitCommand=python3 -c \"open('global-post.called','w').write('1')\"
CFG

write_servers() {
  local path="$1"; shift
  PYTHONPATH="$ROOT" python3 - "$path" "$@" <<'PY'
from pathlib import Path
import sys
import server_sync as s

path = Path(sys.argv[1])
entries = []
for spec in sys.argv[2:]:
    name, ip = spec.split('|', 1)
    entries.append({
        'acceptTextures': (s.TAG_BYTE, 1),
        'ip': (s.TAG_STRING, ip),
        'name': (s.TAG_STRING, name),
    })
s.save_nbt(path, s.with_servers(s.empty_document(), entries))
PY
}

assert_ips() {
  local path="$1" expected="$2"
  PYTHONPATH="$ROOT" python3 - "$path" "$expected" <<'PY'
from pathlib import Path
import sys
import server_sync as s

doc = s.load_nbt(Path(sys.argv[1]))
ips = [s.string_tag(x, 'ip') for x in s.entries(doc)]
expected = [x for x in sys.argv[2].split(',') if x]
assert ips == expected, (ips, expected)
PY
}

write_servers "$TMP/instances/A/.minecraft/servers.dat" \
  'Alpha 🚀|alpha.example' 'Общий|same.example'
write_servers "$TMP/instances/B/.minecraft/servers.dat" \
  'Beta|beta.example' 'Дубликат|same.example'

run() {
  HOME="$TMP" XDG_DATA_HOME="$XDG_DATA_HOME" bash "$SCRIPT" \
    --prism-dir "$TMP/instances" --target "$TMP/shared" "$@"
}

run --instance A --enable all >/dev/null
run --instance B --enable all >/dev/null

# Directories still use symlinks and preserve hidden files.
[[ -L "$TMP/instances/A/.minecraft/saves" ]]
[[ -L "$TMP/instances/B/.minecraft/saves" ]]
[[ -f "$TMP/shared/saves/world-A/level.dat" ]]
[[ -f "$TMP/shared/saves/world-B/level.dat" ]]
[[ -f "$TMP/shared/saves/.hidden" ]]

# servers.dat MUST NOT be a symlink anymore.  Prism hooks own its lifecycle.
[[ -f "$TMP/instances/A/.minecraft/servers.dat" && ! -L "$TMP/instances/A/.minecraft/servers.dat" ]]
[[ -f "$TMP/instances/B/.minecraft/servers.dat" && ! -L "$TMP/instances/B/.minecraft/servers.dat" ]]
[[ -f "$TMP/instances/A/.minecraft/.sync_prism_instances.servers.json" ]]
[[ -f "$TMP/instances/B/.minecraft/.sync_prism_instances.servers.json" ]]
grep -q '^OverrideCommands=true$' "$TMP/instances/A/instance.cfg"
grep -q 'server_sync.py.*hook pre' "$TMP/instances/A/instance.cfg"
grep -q 'server_sync.py.*hook post' "$TMP/instances/A/instance.cfg"

RUNTIME="$XDG_DATA_HOME/sync_prism_instances/server_sync.py"
[[ -f "$RUNTIME" ]]

# Parse the command exactly as QSettings + QProcess would conceptually see it.
PYTHONPATH="$ROOT" python3 - "$TMP/instances/A/instance.cfg" "$RUNTIME" <<'PY'
from pathlib import Path
import shlex
import sys
import server_sync as s
_, values = s.read_ini(Path(sys.argv[1]))
command = s.qt_ini_decode(values['PreLaunchCommand'])
argv = shlex.split(command)
assert Path(argv[0]).resolve() == Path(sys.executable).resolve(), argv
assert Path(argv[1]).resolve() == Path(sys.argv[2]).resolve(), argv
assert argv[2:] == ['hook', 'pre'], argv
PY

# User scenario: launch A, add a server, close A. Post-exit must export it.
(
  cd "$TMP/instances/A/.minecraft"
  python3 "$RUNTIME" hook pre
)
[[ -f "$TMP/instances/A/.minecraft/pre.called" ]]
assert_ips "$TMP/instances/A/.minecraft/servers.dat" 'alpha.example,same.example,beta.example'
write_servers "$TMP/instances/A/.minecraft/servers.dat" \
  'Alpha 🚀|alpha.example' 'Общий|same.example' 'Beta|beta.example' 'Новый A|new-a.example'
(
  cd "$TMP/instances/A/.minecraft"
  python3 "$RUNTIME" hook post
)
[[ -f "$TMP/instances/A/.minecraft/post.called" ]]
assert_ips "$TMP/shared/servers.dat" 'alpha.example,same.example,beta.example,new-a.example'

# Launch B afterwards: pre-launch imports A's freshly saved list before Minecraft starts.
(
  cd "$TMP/instances/B/.minecraft"
  python3 "$RUNTIME" hook pre
)
assert_ips "$TMP/instances/B/.minecraft/servers.dat" 'alpha.example,same.example,beta.example,new-a.example'
[[ -f "$TMP/instances/B/.minecraft/global-pre.called" ]]

# B deletes Alpha and adds New B.  This should propagate too (real sync, not union-only).
write_servers "$TMP/instances/B/.minecraft/servers.dat" \
  'Общий|same.example' 'Beta|beta.example' 'Новый A|new-a.example' 'Новый B|new-b.example'
(
  cd "$TMP/instances/B/.minecraft"
  python3 "$RUNTIME" hook post
)
assert_ips "$TMP/shared/servers.dat" 'same.example,beta.example,new-a.example,new-b.example'
[[ -f "$TMP/instances/B/.minecraft/global-post.called" ]]

# Re-open A: it must receive B's final list, not its stale pre-B list.
(
  cd "$TMP/instances/A/.minecraft"
  python3 "$RUNTIME" hook pre
)
assert_ips "$TMP/instances/A/.minecraft/servers.dat" 'same.example,beta.example,new-a.example,new-b.example'

# Disable restores original Prism commands and leaves an ordinary local servers.dat.
run --instance A --disable servers >/dev/null
[[ ! -e "$TMP/instances/A/.minecraft/.sync_prism_instances.servers.json" ]]
[[ -f "$TMP/instances/A/.minecraft/servers.dat" && ! -L "$TMP/instances/A/.minecraft/servers.dat" ]]
python3 - "$TMP/instances/A/instance.cfg" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
assert r"PreLaunchCommand=python3 -c \"open('pre.called','w').write('1')\"" in lines, lines
assert r"PostExitCommand=python3 -c \"open('post.called','w').write('1')\"" in lines, lines
PY

# Legacy v2 migration: old shared symlink may have been moved to servers.dat_old,
# while Minecraft left a new ordinary servers.dat with unsynced changes.
mkdir -p "$TMP/instances/C/.minecraft"
cat > "$TMP/instances/C/instance.cfg" <<'CFG'
InstanceType=OneSix
name=C
CFG
printf '%s\n' "$TMP/shared/servers.dat" > "$TMP/instances/C/.minecraft/.sync_prism_instances.servers"
ln -s "$TMP/shared/servers.dat" "$TMP/instances/C/.minecraft/servers.dat_old"
write_servers "$TMP/instances/C/.minecraft/servers.dat" 'Legacy new|legacy-new.example'
run --status >/dev/null
[[ -f "$TMP/instances/C/.minecraft/.sync_prism_instances.servers.json" ]]
[[ ! -L "$TMP/instances/C/.minecraft/servers.dat" ]]
assert_ips "$TMP/shared/servers.dat" 'same.example,beta.example,new-a.example,new-b.example,legacy-new.example'

# Corrupt NBT must not damage the shared list or leave half-installed hooks/state.
mkdir -p "$TMP/instances/D/.minecraft"
printf 'InstanceType=OneSix\nname=D\n' > "$TMP/instances/D/instance.cfg"
printf 'broken nbt' > "$TMP/instances/D/.minecraft/servers.dat"
before="$(sha256sum "$TMP/shared/servers.dat" | cut -d' ' -f1)"
if run --instance D --enable servers >/dev/null 2>&1; then
  echo "corrupt servers.dat unexpectedly succeeded" >&2
  exit 1
fi
after="$(sha256sum "$TMP/shared/servers.dat" | cut -d' ' -f1)"
[[ "$before" == "$after" ]]
[[ ! -e "$TMP/instances/D/.minecraft/.sync_prism_instances.servers.json" ]]
! grep -q 'server_sync.py' "$TMP/instances/D/instance.cfg"

# Status should show B/C server sync as enabled after all of the above.
status="$(run --status)"
grep -A5 '^B$' <<<"$status" | grep -q '✓ Серверы'
grep -A5 '^C$' <<<"$status" | grep -q '✓ Серверы'

echo OK
