#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION="2.1.0"
readonly DEFAULT_TARGET="$HOME/.minecraft"
readonly RAW_BASE="https://raw.githubusercontent.com/martrtr/sync_prism_instances/main"
readonly SERVER_MARKER_NAME=".sync_prism_instances.servers"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"

SYNC_ITEMS=(saves resourcepacks shaderpacks screenshots servers.dat)
TARGET_DIR="$DEFAULT_TARGET"
PRISM_INSTANCES_DIR="${PRISM_INSTANCES_DIR:-}"
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
    return
  fi

  local candidates=(
    "$HOME/.local/share/PrismLauncher/instances"
    "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances"
  )
  local dir
  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      PRISM_INSTANCES_DIR="$(canonical_path "$dir")"
      return
    fi
  done
  fail "не найдена папка Prism Launcher; укажите её через --prism-dir"
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

link_points_to() {
  local src="$1" dst="$2"
  [[ -L "$src" ]] || return 1
  [[ "$(canonical_path "$src")" == "$(canonical_path "$dst")" ]]
}

server_marker() {
  printf '%s/%s\n' "$1" "$SERVER_MARKER_NAME"
}

servers_managed() {
  local instance="$1" marker saved_target
  marker="$(server_marker "$instance")"
  [[ -f "$marker" ]] || return 1
  IFS= read -r saved_target < "$marker" || return 1
  [[ -n "$saved_target" ]] || return 1
  [[ "$(canonical_path "$saved_target")" == "$TARGET_DIR" ]]
}

write_server_marker() {
  local instance="$1" marker tmp
  marker="$(server_marker "$instance")"
  tmp="$(mktemp "$instance/.sync_prism_instances.servers.tmp.XXXXXX")"
  printf '%s\n' "$TARGET_DIR" > "$tmp"
  mv -f -- "$tmp" "$marker"
}

is_synced() {
  local instance="$1" item="$2"
  if [[ "$item" == servers.dat ]]; then
    servers_managed "$instance"
  else
    link_points_to "$instance/$item" "$TARGET_DIR/$item"
  fi
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

resolve_merge_helper() {
  local sibling="${SCRIPT_DIR:+$SCRIPT_DIR/merge_servers.py}"
  if [[ -n "$sibling" && -f "$sibling" ]]; then
    printf '%s\n' "$sibling"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || fail "merge_servers.py не найден рядом со скриптом, а curl недоступен"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sync_prism_instances"
  local helper="$cache_dir/merge_servers-$VERSION.py"
  if [[ ! -s "$helper" ]]; then
    mkdir -p "$cache_dir"
    local tmp="$helper.tmp.$$"
    curl -fsSL "$RAW_BASE/merge_servers.py" -o "$tmp" || {
      rm -f -- "$tmp"
      fail "не удалось загрузить merge_servers.py"
    }
    mv -f -- "$tmp" "$helper"
  fi
  printf '%s\n' "$helper"
}

merge_servers_dat() {
  local shared="$1" local_file="$2"
  command -v python3 >/dev/null 2>&1 || fail "для безопасного объединения servers.dat нужен python3"

  local helper tmp
  helper="$(resolve_merge_helper)"
  tmp="$(mktemp "${shared}.tmp.XXXXXX")"
  if ! python3 "$helper" "$shared" "$local_file" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$shared"
}

migrate_legacy_server_state() {
  local instance src old dst
  dst="$TARGET_DIR/servers.dat"
  for instance in "${instances[@]}"; do
    servers_managed "$instance" && continue
    src="$instance/servers.dat"
    old="$instance/servers.dat_old"
    # v2.0 хранил состояние только в самом симлинке. После atomic replace
    # Minecraft часто оставляет прежний линк в servers.dat_old.
    if link_points_to "$src" "$dst" || link_points_to "$old" "$dst"; then
      write_server_marker "$instance"
    fi
  done
}

reconcile_server_instance() {
  local instance="$1" src dst
  servers_managed "$instance" || return 0
  src="$instance/servers.dat"
  dst="$TARGET_DIR/servers.dat"

  if link_points_to "$src" "$dst"; then
    return 0
  fi

  if [[ -L "$src" ]]; then
    warn "$(get_instance_name "$instance")/servers.dat — сторонняя символьная ссылка; не перезаписываю"
    return 1
  fi
  if [[ -e "$src" && ! -f "$src" ]]; then
    warn "$src существует, но это не файл; не перезаписываю"
    return 1
  fi

  # Если игра заменила симлинк обычным servers.dat, сначала забираем все
  # изменения из него в общий файл. Локальный файл удаляется только после
  # успешного NBT merge.
  if [[ -f "$src" ]]; then
    merge_servers_dat "$dst" "$src" || {
      warn "не удалось объединить servers.dat инстанса $(get_instance_name "$instance"); локальный файл сохранён"
      return 1
    }
    rm -f -- "$src"
  elif [[ ! -f "$dst" ]]; then
    merge_servers_dat "$dst" "" || return 1
  fi

  ln -s -- "$dst" "$src"
}

reconcile_managed_servers() {
  local instance
  for instance in "${instances[@]}"; do
    if servers_managed "$instance"; then
      reconcile_server_instance "$instance" || true
    fi
  done
}

enable_sync() {
  local instance="$1" item="$2"
  local src="$instance/$item" dst="$TARGET_DIR/$item" type
  type="$(item_type "$item")"

  if is_synced "$instance" "$item"; then
    [[ "$item" == servers.dat ]] && reconcile_server_instance "$instance"
    return 0
  fi
  if [[ -L "$src" ]]; then
    warn "$(get_instance_name "$instance")/$item уже является сторонней символьной ссылкой — пропускаю"
    return 1
  fi

  case "$type" in
    folder)
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
      ;;
    servers)
      if [[ -e "$src" && ! -f "$src" ]]; then
        warn "$src существует, но это не файл — пропускаю"
        return 1
      fi
      merge_servers_dat "$dst" "$src" || return 1
      [[ -e "$src" ]] && rm -f -- "$src"
      ln -s -- "$dst" "$src"
      write_server_marker "$instance"
      ;;
  esac
}

disable_sync() {
  local instance="$1" item="$2"
  local src="$instance/$item" dst="$TARGET_DIR/$item" type marker
  type="$(item_type "$item")"

  is_synced "$instance" "$item" || return 0
  case "$type" in
    folder)
      rm -- "$src"
      mkdir -p "$src"
      [[ -d "$dst" ]] && copy_dir_contents "$dst" "$src"
      ;;
    servers)
      # Сначала забираем возможные изменения, сделанные Minecraft после
      # разрушения симлинка, и только потом отключаем управление.
      reconcile_server_instance "$instance" || return 1
      rm -f -- "$src"
      [[ -f "$dst" ]] && cp -a -- "$dst" "$src"
      marker="$(server_marker "$instance")"
      rm -f -- "$marker"
      ;;
  esac
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

  # v2.0 определял серверную синхронизацию по симлинку. Мигрируем такие
  # инстансы и каждый запуск восстанавливаем servers.dat, если игра его заменила.
  migrate_legacy_server_state
  reconcile_managed_servers

  case "$ACTION" in
    '') run_tui ;;
    status) print_status ;;
    enable|disable) apply_cli_action ;;
    *) fail "неизвестное действие" ;;
  esac
}

main "$@"
