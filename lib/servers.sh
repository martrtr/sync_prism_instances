# shellcheck shell=bash

SERVER_HELPER="$RUNTIME_DIR/server_sync.py"

ensure_server_helper() {
  [[ -n "$PYTHON_BIN" ]] || PYTHON_BIN="$(command -v python3 || true)"
  [[ -n "$PYTHON_BIN" ]] || fail "для синхронизации servers.dat нужен python3"
  mkdir -p "$RUNTIME_DIR"
  local sibling="${SCRIPT_DIR:+$SCRIPT_DIR/server_sync.py}"
  if [[ -n "$sibling" && -f "$sibling" ]]; then
    [[ "$(canonical_path "$sibling")" == "$(canonical_path "$SERVER_HELPER")" ]] || cp -f -- "$sibling" "$SERVER_HELPER"
  else
    command -v curl >/dev/null 2>&1 || fail "server_sync.py не найден рядом со скриптом, а curl недоступен"
    local tmp="$SERVER_HELPER.tmp.$$"
    curl -fsSL "$RAW_BASE/server_sync.py" -o "$tmp" || { rm -f -- "$tmp"; fail "не удалось загрузить server_sync.py"; }
    mv -f -- "$tmp" "$SERVER_HELPER"
  fi
  chmod 755 "$SERVER_HELPER"
}

install_server_sync() {
  local instance="$1" cfg
  ensure_server_helper
  cfg="$(instance_cfg "$instance")"
  local -a args=("$PYTHON_BIN" "$SERVER_HELPER" install --game-dir "$instance" --shared "$TARGET_DIR/servers.dat" --instance-cfg "$cfg")
  [[ -n "$PRISM_CONFIG" ]] && args+=(--prism-cfg "$PRISM_CONFIG")
  "${args[@]}"
}

uninstall_server_sync() {
  local instance="$1"
  ensure_server_helper
  if [[ -f "$instance/$SERVER_STATE_NAME" ]]; then "$PYTHON_BIN" "$SERVER_HELPER" uninstall --game-dir "$instance"; return; fi
  if [[ -f "$instance/$SERVER_MARKER_NAME" || -L "$instance/servers.dat" || -L "$instance/servers.dat_old" ]]; then
    install_server_sync "$instance"
    "$PYTHON_BIN" "$SERVER_HELPER" uninstall --game-dir "$instance"
  fi
}

migrate_legacy_servers() {
  local instance marked dst="$TARGET_DIR/servers.dat"
  for instance in "${instances[@]}"; do
    [[ ! -f "$instance/$SERVER_STATE_NAME" ]] || continue
    marked="$(marker_target "$instance" 2>/dev/null || true)"
    if [[ "$marked" == "$(canonical_path "$dst")" ]] \
      || { [[ -L "$instance/servers.dat" ]] && [[ "$(canonical_path "$instance/servers.dat")" == "$(canonical_path "$dst")" ]]; } \
      || { [[ -L "$instance/servers.dat_old" ]] && [[ "$(canonical_path "$instance/servers.dat_old")" == "$(canonical_path "$dst")" ]]; }; then
      install_server_sync "$instance" || warn "не удалось мигрировать серверы для $(get_instance_name "$instance")"
    fi
  done
  return 0
}

has_managed_servers() {
  local instance
  for instance in "${instances[@]}"; do servers_synced "$instance" && return 0; done
  return 1
}

manual_update_servers() {
  ensure_server_helper
  local -a managed=()
  local instance
  for instance in "${instances[@]}"; do servers_synced "$instance" && managed+=("$instance"); done
  ((${#managed[@]} > 0)) || { warn "ни в одном инстансе не включена синхронизация серверов"; return 1; }

  "$PYTHON_BIN" - "$SERVER_HELPER" "$TARGET_DIR/servers.dat" "${managed[@]}" <<'PY'
import importlib.util
import pathlib
import sys

helper = pathlib.Path(sys.argv[1]).resolve()
shared = pathlib.Path(sys.argv[2]).resolve()
game_dirs = [pathlib.Path(x).resolve() for x in sys.argv[3:]]
spec = importlib.util.spec_from_file_location("sync_prism_server_runtime", helper)
if spec is None or spec.loader is None:
    raise SystemExit("не удалось загрузить server_sync.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

states = []
try:
    with mod.LockedShared(shared):
        documents = [mod.load_nbt(shared)]
        for game_dir in game_dirs:
            state = mod.read_state(game_dir)
            if pathlib.Path(state["shared"]).resolve() != shared:
                continue
            states.append((game_dir, state))
            try:
                documents.append(mod.load_nbt(game_dir / "servers.dat"))
            except Exception as exc:
                raise RuntimeError(f"{game_dir.name}/servers.dat: {exc}") from exc
        merged = mod.initial_union(*documents)
        data = mod.dump_nbt(merged)
        mod.atomic_write(shared, data)
        for game_dir, _state in states:
            mod.atomic_write(game_dir / "servers.dat", data)
            mod.atomic_write(game_dir / mod.BASELINE_NAME, data)
    print(f"{len(states)}|{len(mod.entries(merged))}")
except Exception as exc:
    print(f"sync_prism_instances: ручное обновление серверов не выполнено: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}
