#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION="3.0.0"
readonly DEFAULT_TARGET="$HOME/.minecraft"
readonly RAW_BASE="https://raw.githubusercontent.com/martrtr/sync_prism_instances/main"
readonly RUNTIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/sync_prism_instances"
readonly SERVER_STATE_NAME=".sync_prism_instances.servers.json"
readonly SERVER_MARKER_NAME=".sync_prism_instances.servers"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
SERVER_HELPER="$RUNTIME_DIR/server_sync.py"
PYTHON_BIN=""

SYNC_ITEMS=(saves resourcepacks shaderpacks screenshots servers.dat)
TARGET_DIR="$DEFAULT_TARGET"
PRISM_INSTANCES_DIR="${PRISM_INSTANCES_DIR:-}"
PRISM_CONFIG=""
INSTANCE_QUERY=""
ACTION=""
ACTION_ITEMS=""
ALL_INSTANCES=false

usage() {
  cat <<'HELP'
sync_prism_instances — общие миры, ресурспаки, шейдеры, скриншоты и серверы для Prism Launcher

Использование:
  sync_prism_instances.sh [папка]
  sync_prism_instances.sh [опции]

Опции:
  -t, --target DIR        общая папка (по умолчанию ~/.minecraft)
  -p, --prism-dir DIR     папка instances Prism Launcher
  -i, --instance NAME     инстанс для неинтерактивной команды
      --all-instances     применить команду ко всем инстансам
      --enable ITEMS      включить: saves,resourcepacks,shaderpacks,screenshots,servers или all
      --disable ITEMS     отключить те же элементы
      --status            показать состояние синхронизации
  -h, --help              показать помощь
  -v, --version           показать версию

Без --enable/--disable/--status запускается TUI.
HELP
}

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Предупреждение: %s\n' "$*" >&2; }

canonical_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$1"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -m -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

item_type() {
  case "$1" in
    saves|resourcepacks|shaderpacks|screenshots) printf 'folder\n' ;;
    servers.dat) printf 'servers\n' ;;
    *) return 1 ;;
  esac
}

pretty_item() {
  case "$1" in
    saves) printf 'Миры' ;;
    resourcepacks) printf 'Ресурспаки' ;;
    shaderpacks) printf 'Шейдеры' ;;
    screenshots) printf 'Скриншоты' ;;
    servers.dat) printf 'Серверы' ;;
    *) printf '%s' "$1" ;;
  esac
}

normalize_item() {
  case "${1,,}" in
    saves|worlds|миры) printf 'saves\n' ;;
    resourcepacks|resources|ресурспаки) printf 'resourcepacks\n' ;;
    shaderpacks|shaders|шейдеры) printf 'shaderpacks\n' ;;
    screenshots|скриншоты) printf 'screenshots\n' ;;
    servers|servers.dat|серверы) printf 'servers.dat\n' ;;
    *) return 1 ;;
  esac
}

parse_item_list() {
  local raw="$1" token item
  local -a result=() tokens=()
  if [[ "${raw,,}" == "all" || "${raw,,}" == "всё" ]]; then
    printf '%s\n' "${SYNC_ITEMS[@]}"
    return
  fi
  IFS=',' read -r -a tokens <<< "$raw"
  for token in "${tokens[@]}"; do
    token="${token#${token%%[![:space:]]*}}"
    token="${token%${token##*[![:space:]]}}"
    item="$(normalize_item "$token")" || fail "неизвестный элемент: $token"
    result+=("$item")
  done
  printf '%s\n' "${result[@]}"
}

resolve_prism_dir() {
  if [[ -n "$PRISM_INSTANCES_DIR" ]]; then
    [[ -d "$PRISM_INSTANCES_DIR" ]] || fail "папка Prism Launcher не найдена: $PRISM_INSTANCES_DIR"
    PRISM_INSTANCES_DIR="$(canonical_path "$PRISM_INSTANCES_DIR")"
  else
    local candidates=(
      "$HOME/.local/share/PrismLauncher/instances"
      "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances"
    )
    local dir
    for dir in "${candidates[@]}"; do
      if [[ -d "$dir" ]]; then
        PRISM_INSTANCES_DIR="$(canonical_path "$dir")"
        break
      fi
    done
    [[ -n "$PRISM_INSTANCES_DIR" ]] || fail "не найдена папка Prism Launcher; укажите её через --prism-dir"
  fi

  local candidate="$(dirname "$PRISM_INSTANCES_DIR")/prismlauncher.cfg"
  [[ -f "$candidate" ]] && PRISM_CONFIG="$(canonical_path "$candidate")"
}

find_instances() {
  instances=()
  local base mc
  while IFS= read -r -d '' base; do
    if [[ -d "$base/.minecraft" ]]; then
      mc="$base/.minecraft"
    elif [[ -d "$base/minecraft" ]]; then
      mc="$base/minecraft"
    else
      continue
    fi
    instances+=("$(canonical_path "$mc")")
  done < <(find "$PRISM_INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  ((${#instances[@]} > 0)) || fail "в $PRISM_INSTANCES_DIR не найдено ни одного инстанса"
}

get_instance_name() {
  basename "$(dirname "$1")"
}

instance_cfg() {
  printf '%s/instance.cfg\n' "$(dirname "$1")"
}

ensure_target() {
  mkdir -p "$TARGET_DIR"
  local item
  for item in "${SYNC_ITEMS[@]}"; do
    [[ "$(item_type "$item")" == folder ]] && mkdir -p "$TARGET_DIR/$item"
  done
  return 0
}

copy_dir_contents() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  cp -a -- "$src/." "$dst/"
}

ensure_server_helper() {
  [[ -n "$PYTHON_BIN" ]] || PYTHON_BIN="$(command -v python3 || true)"
  [[ -n "$PYTHON_BIN" ]] || fail "для синхронизации servers.dat нужен python3"
  mkdir -p "$RUNTIME_DIR"

  local sibling="${SCRIPT_DIR:+$SCRIPT_DIR/server_sync.py}"
  if [[ -n "$sibling" && -f "$sibling" ]]; then
    if [[ "$(canonical_path "$sibling")" != "$(canonical_path "$SERVER_HELPER")" ]]; then
      cp -f -- "$sibling" "$SERVER_HELPER"
    fi
  else
    command -v curl >/dev/null 2>&1 || fail "server_sync.py не найден рядом со скриптом, а curl недоступен"
    local tmp="$SERVER_HELPER.tmp.$$"
    curl -fsSL "$RAW_BASE/server_sync.py" -o "$tmp" || {
      rm -f -- "$tmp"
      fail "не удалось загрузить server_sync.py"
    }
    mv -f -- "$tmp" "$SERVER_HELPER"
  fi
  chmod 755 "$SERVER_HELPER"
}

marker_target() {
  local marker="$1/$SERVER_MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  local value
  IFS= read -r value < "$marker" || true
  [[ -n "$value" ]] || return 1
  canonical_path "$value"
}

servers_synced() {
  local instance="$1"
  local state="$instance/$SERVER_STATE_NAME"
  [[ -f "$state" ]] || return 1
  local marked
  marked="$(marker_target "$instance")" || return 1
  [[ "$marked" == "$(canonical_path "$TARGET_DIR/servers.dat")" ]]
}

is_synced() {
  local instance="$1" item="$2"
  if [[ "$item" == servers.dat ]]; then
    servers_synced "$instance"
    return
  fi
  local src="$instance/$item" dst="$TARGET_DIR/$item"
  [[ -L "$src" ]] || return 1
  [[ "$(canonical_path "$src")" == "$(canonical_path "$dst")" ]]
}

install_server_sync() {
  local instance="$1"
  ensure_server_helper
  local cfg
  cfg="$(instance_cfg "$instance")"
  local -a args=(
    "$PYTHON_BIN" "$SERVER_HELPER" install
    --game-dir "$instance"
    --shared "$TARGET_DIR/servers.dat"
    --instance-cfg "$cfg"
  )
  [[ -n "$PRISM_CONFIG" ]] && args+=(--prism-cfg "$PRISM_CONFIG")
  "${args[@]}"
}

uninstall_server_sync() {
  local instance="$1"
  ensure_server_helper
  if [[ -f "$instance/$SERVER_STATE_NAME" ]]; then
    "$PYTHON_BIN" "$SERVER_HELPER" uninstall --game-dir "$instance"
    return
  fi

  # Legacy v1/v2 state: install once to absorb any ordinary servers.dat that
  # Minecraft created after breaking the old symlink, then immediately uninstall.
  if [[ -f "$instance/$SERVER_MARKER_NAME" || -L "$instance/servers.dat" || -L "$instance/servers.dat_old" ]]; then
    install_server_sync "$instance"
    "$PYTHON_BIN" "$SERVER_HELPER" uninstall --game-dir "$instance"
  fi
}

migrate_legacy_servers() {
  local instance marked dst="$TARGET_DIR/servers.dat"
  for instance in "${instances[@]}"; do
    [[ ! -f "$instance/$SERVER_STATE_NAME" ]] || continue
    marked=""
    marked="$(marker_target "$instance" 2>/dev/null || true)"
    if [[ "$marked" == "$(canonical_path "$dst")" ]] \
      || { [[ -L "$instance/servers.dat" ]] && [[ "$(canonical_path "$instance/servers.dat")" == "$(canonical_path "$dst")" ]]; } \
      || { [[ -L "$instance/servers.dat_old" ]] && [[ "$(canonical_path "$instance/servers.dat_old")" == "$(canonical_path "$dst")" ]]; }; then
      install_server_sync "$instance" || warn "не удалось мигрировать серверную синхронизацию для $(get_instance_name "$instance")"
    fi
  done
}

enable_sync() {
  local instance="$1" item="$2"
  local src="$instance/$item" dst="$TARGET_DIR/$item" type
  type="$(item_type "$item")"

  if [[ "$type" == servers ]]; then
    install_server_sync "$instance"
    return
  fi

  is_synced "$instance" "$item" && return 0
  if [[ -L "$src" ]]; then
    warn "$(get_instance_name "$instance")/$item уже является сторонней символьной ссылкой — пропускаю"
    return 1
  fi

  mkdir -p "$dst"
  if [[ -e "$src" && ! -d "$src" ]]; then
    warn "$src существует, но это не каталог — пропускаю"
    return 1
  fi
  if [[ -d "$src" ]]; then
    copy_dir_contents "$src" "$dst"
    rm -rf -- "$src"
  fi
  ln -s -- "$dst" "$src"
}

disable_sync() {
  local instance="$1" item="$2"
  local src="$instance/$item" dst="$TARGET_DIR/$item" type
  type="$(item_type "$item")"

  if [[ "$type" == servers ]]; then
    uninstall_server_sync "$instance"
    return
  fi

  is_synced "$instance" "$item" || return 0
  rm -- "$src"
  mkdir -p "$src"
  [[ -d "$dst" ]] && copy_dir_contents "$dst" "$src"
}

status_line() {
  local instance="$1" item
  local -a enabled=()
  for item in "${SYNC_ITEMS[@]}"; do
    is_synced "$instance" "$item" && enabled+=("$(pretty_item "$item")")
  done
  if ((${#enabled[@]} == 0)); then
    printf '—'
  elif ((${#enabled[@]} == ${#SYNC_ITEMS[@]})); then
    printf 'всё'
  else
    local IFS=', '
    printf '%s' "${enabled[*]}"
  fi
}

select_instances_by_query() {
  selected_instances=()
  if [[ "$ALL_INSTANCES" == true ]]; then
    selected_instances=("${instances[@]}")
    return
  fi
  [[ -n "$INSTANCE_QUERY" ]] || fail "для этой команды укажите --instance NAME или --all-instances"

  local instance name
  for instance in "${instances[@]}"; do
    name="$(get_instance_name "$instance")"
    [[ "$name" == "$INSTANCE_QUERY" ]] && selected_instances+=("$instance")
  done
  if ((${#selected_instances[@]} == 0)); then
    for instance in "${instances[@]}"; do
      name="$(get_instance_name "$instance")"
      [[ "${name,,}" == *"${INSTANCE_QUERY,,}"* ]] && selected_instances+=("$instance")
    done
  fi
  ((${#selected_instances[@]} == 1)) || {
    if ((${#selected_instances[@]} == 0)); then
      fail "инстанс '$INSTANCE_QUERY' не найден"
    else
      fail "'$INSTANCE_QUERY' соответствует нескольким инстансам; укажите точное имя"
    fi
  }
}

print_status() {
  local instance item marker
  for instance in "${instances[@]}"; do
    printf '%s\n' "$(get_instance_name "$instance")"
    for item in "${SYNC_ITEMS[@]}"; do
      marker='·'
      is_synced "$instance" "$item" && marker='✓'
      printf '  %s %s\n' "$marker" "$(pretty_item "$item")"
    done
  done
}

apply_cli_action() {
  select_instances_by_query
  local parsed
  parsed="$(parse_item_list "$ACTION_ITEMS")"
  mapfile -t requested_items <<< "$parsed"
  local instance item
  for instance in "${selected_instances[@]}"; do
    for item in "${requested_items[@]}"; do
      case "$ACTION" in
        enable) enable_sync "$instance" "$item" ;;
        disable) disable_sync "$instance" "$item" ;;
      esac
    done
    printf '✓ %s: %s\n' "$(get_instance_name "$instance")" "$(status_line "$instance")"
  done
}

read_key() {
  local key rest=''
  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\e' ]]; then
    IFS= read -rsn2 -t 0.05 rest || true
    key+="$rest"
  fi
  printf '%s' "$key"
}

tui_enter() {
  [[ -t 0 && -t 1 ]] || fail "TUI требует терминал; используйте --help для неинтерактивного режима"
  printf '\e[?1049h\e[?25l'
  trap 'printf "\e[?25h\e[?1049l"' EXIT INT TERM
}

tui_leave() {
  printf '\e[?25h\e[?1049l'
  trap - EXIT INT TERM
}

render_instance_picker() {
  local selected="$1" i instance prefix
  printf '\e[H\e[2J'
  printf 'Prism Sync  %s\n\n' "$VERSION"
  printf 'Выберите инстанс\n\n'
  for i in "${!instances[@]}"; do
    instance="${instances[$i]}"
    prefix='  '
    ((i == selected)) && prefix='› '
    printf '%s%-28s  %s\n' "$prefix" "$(get_instance_name "$instance")" "$(status_line "$instance")"
  done
  printf '\n↑/↓ выбрать   Enter открыть   q выход\n'
}

tui_pick_instance() {
  local selected=0 key
  TUI_SELECTED=-1
  while true; do
    render_instance_picker "$selected"
    key="$(read_key)" || return 1
    case "$key" in
      $'\e[A'|k) ((selected = (selected - 1 + ${#instances[@]}) % ${#instances[@]})) ;;
      $'\e[B'|j) ((selected = (selected + 1) % ${#instances[@]})) ;;
      ''|$'\n'|$'\r') TUI_SELECTED="$selected"; return 0 ;;
      q|Q) return 1 ;;
    esac
  done
}

render_item_picker() {
  local instance="$1" selected="$2"
  shift 2
  local -a desired=("$@")
  local i item prefix box current note
  printf '\e[H\e[2J'
  printf 'Prism Sync  %s\n\n' "$VERSION"
  printf '%s\n\n' "$(get_instance_name "$instance")"
  for i in "${!SYNC_ITEMS[@]}"; do
    item="${SYNC_ITEMS[$i]}"
    prefix='  '
    ((i == selected)) && prefix='› '
    box='[ ]'
    [[ "${desired[$i]}" == 1 ]] && box='[✓]'
    current=0
    is_synced "$instance" "$item" && current=1
    note=''
    [[ "$current" != "${desired[$i]}" ]] && note='  *'
    printf '%s%s %-16s%s\n' "$prefix" "$box" "$(pretty_item "$item")" "$note"
  done
  printf '\n↑/↓ выбрать   Space изменить   a всё   Enter применить   Esc назад   q выход\n'
  printf '* будет изменено\n'
}

tui_edit_instance() {
  local instance="$1" selected=0 key i item current all_on
  local -a desired=()
  for item in "${SYNC_ITEMS[@]}"; do
    current=0
    is_synced "$instance" "$item" && current=1
    desired+=("$current")
  done

  while true; do
    render_item_picker "$instance" "$selected" "${desired[@]}"
    key="$(read_key)" || return 2
    case "$key" in
      $'\e[A'|k) ((selected = (selected - 1 + ${#SYNC_ITEMS[@]}) % ${#SYNC_ITEMS[@]})) ;;
      $'\e[B'|j) ((selected = (selected + 1) % ${#SYNC_ITEMS[@]})) ;;
      ' ') desired[$selected]=$((1 - desired[$selected])) ;;
      a|A)
        all_on=1
        for i in "${!desired[@]}"; do [[ "${desired[$i]}" == 0 ]] && all_on=0; done
        for i in "${!desired[@]}"; do desired[$i]=$((1 - all_on)); done
        ;;
      $'\e') return 0 ;;
      q|Q) return 2 ;;
      ''|$'\n'|$'\r')
        local error=''
        for i in "${!SYNC_ITEMS[@]}"; do
          item="${SYNC_ITEMS[$i]}"
          current=0
          is_synced "$instance" "$item" && current=1
          if [[ "${desired[$i]}" == 1 && "$current" == 0 ]]; then
            if ! error="$(enable_sync "$instance" "$item" 2>&1)"; then
              printf '\e[H\e[2JОшибка\n\n%s\n\nНажмите любую клавишу…' "$error"
              read_key >/dev/null || true
              return 0
            fi
          elif [[ "${desired[$i]}" == 0 && "$current" == 1 ]]; then
            if ! error="$(disable_sync "$instance" "$item" 2>&1)"; then
              printf '\e[H\e[2JОшибка\n\n%s\n\nНажмите любую клавишу…' "$error"
              read_key >/dev/null || true
              return 0
            fi
          fi
        done
        return 0
        ;;
    esac
  done
}

run_tui() {
  tui_enter
  local rc
  while true; do
    if ! tui_pick_instance; then
      break
    fi
    rc=0
    tui_edit_instance "${instances[$TUI_SELECTED]}" || rc=$?
    ((rc == 2)) && break
  done
  tui_leave
}

parse_args() {
  if (($# > 0)) && [[ "$1" != -* ]]; then
    TARGET_DIR="$1"
    shift
  fi
  while (($#)); do
    case "$1" in
      -t|--target) (($# >= 2)) || fail "$1 требует путь"; TARGET_DIR="$2"; shift 2 ;;
      -p|--prism-dir) (($# >= 2)) || fail "$1 требует путь"; PRISM_INSTANCES_DIR="$2"; shift 2 ;;
      -i|--instance) (($# >= 2)) || fail "$1 требует имя"; INSTANCE_QUERY="$2"; shift 2 ;;
      --all-instances) ALL_INSTANCES=true; shift ;;
      --enable) (($# >= 2)) || fail "$1 требует список"; [[ -z "$ACTION" ]] || fail "укажите только одно действие"; ACTION=enable; ACTION_ITEMS="$2"; shift 2 ;;
      --disable) (($# >= 2)) || fail "$1 требует список"; [[ -z "$ACTION" ]] || fail "укажите только одно действие"; ACTION=disable; ACTION_ITEMS="$2"; shift 2 ;;
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
    *) fail "неизвестное действие" ;;
  esac
}

main "$@"
