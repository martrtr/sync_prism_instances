#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION="4.0.0"
readonly DEFAULT_TARGET="$HOME/.minecraft"
readonly RAW_BASE="https://raw.githubusercontent.com/martrtr/sync_prism_instances/main"
readonly RUNTIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/sync_prism_instances"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
TARGET_DIR="$DEFAULT_TARGET"
PRISM_INSTANCES_DIR="${PRISM_INSTANCES_DIR:-}"
PRISM_CONFIG=""
INSTANCE_QUERY=""
ACTION=""
ACTION_ITEMS=""
ALL_INSTANCES=false
PYTHON_BIN=""

load_module() {
  local name="$1"
  local local_path="${SCRIPT_DIR:+$SCRIPT_DIR/lib/$name}" cache_dir="$RUNTIME_DIR/lib-$VERSION" target
  if [[ -n "$local_path" && -f "$local_path" ]]; then
    # shellcheck source=/dev/null
    source "$local_path"
    return
  fi
  command -v curl >/dev/null 2>&1 || { printf 'Ошибка: для загрузки модулей нужен curl\n' >&2; exit 1; }
  mkdir -p "$cache_dir"
  target="$cache_dir/$name"
  local tmp="$target.tmp.$$"
  curl -fsSL "$RAW_BASE/lib/$name" -o "$tmp" || { rm -f -- "$tmp"; printf 'Ошибка: не удалось загрузить %s\n' "$name" >&2; exit 1; }
  mv -f -- "$tmp" "$target"
  # shellcheck source=/dev/null
  source "$target"
}

load_module common.sh
load_module servers.sh
load_module tui.sh

usage() {
  cat <<'HELP'
sync_prism_instances — синхронизация данных Prism Launcher

Использование:
  sync_prism_instances.sh [папка]
  sync_prism_instances.sh [опции]

Опции:
  -t, --target DIR        общая папка (по умолчанию ~/.minecraft)
  -p, --prism-dir DIR     папка instances Prism Launcher
  -i, --instance NAME     выбрать инстанс для CLI-команды
      --all-instances     применить команду ко всем инстансам
      --enable ITEMS      включить синхронизацию ITEMS
      --disable ITEMS     отключить синхронизацию ITEMS
      --update-servers    принудительно объединить и раздать списки серверов
      --status            показать состояние
  -h, --help              помощь
  -v, --version           версия

ITEMS:
  saves, resourcepacks, shaderpacks, screenshots, servers,
  figura, schematics, worldedit, replaymod, replayvideos,
  flashback, journeymap, xaero, voxelmap или all.

Без CLI-действия запускается TUI.
HELP
}

parse_args() {
  if (($# > 0)) && [[ "$1" != -* ]]; then TARGET_DIR="$1"; shift; fi
  while (($#)); do
    case "$1" in
      -t|--target) (($# >= 2)) || fail "$1 требует путь"; TARGET_DIR="$2"; shift 2 ;;
      -p|--prism-dir) (($# >= 2)) || fail "$1 требует путь"; PRISM_INSTANCES_DIR="$2"; shift 2 ;;
      -i|--instance) (($# >= 2)) || fail "$1 требует имя"; INSTANCE_QUERY="$2"; shift 2 ;;
      --all-instances) ALL_INSTANCES=true; shift ;;
      --enable) (($# >= 2)) || fail "$1 требует список"; [[ -z "$ACTION" ]] || fail "укажите только одно действие"; ACTION=enable; ACTION_ITEMS="$2"; shift 2 ;;
      --disable) (($# >= 2)) || fail "$1 требует список"; [[ -z "$ACTION" ]] || fail "укажите только одно действие"; ACTION=disable; ACTION_ITEMS="$2"; shift 2 ;;
      --update-servers) [[ -z "$ACTION" ]] || fail "укажите только одно действие"; ACTION=update-servers; shift ;;
      --status) [[ -z "$ACTION" ]] || fail "укажите только одно действие"; ACTION=status; shift ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) printf '%s\n' "$VERSION"; exit 0 ;;
      --) shift; break ;;
      *) fail "неизвестный аргумент: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  TARGET_DIR="$(canonical_path "$TARGET_DIR")"
  resolve_prism_dir
  ensure_target
  find_instances
  migrate_legacy_servers

  case "$ACTION" in
    '') run_tui ;;
    status) print_status ;;
    enable|disable) apply_cli_action ;;
    update-servers)
      local result stats instance_count server_count
      result="$(manual_update_servers)"
      stats="${result##*$'\n'}"
      IFS='|' read -r instance_count server_count <<< "$stats"
      printf '✓ список серверов обновлён: %s инстансов, %s серверов\n' "$instance_count" "$server_count"
      ;;
    *) fail "неизвестное действие" ;;
  esac
}

main "$@"
