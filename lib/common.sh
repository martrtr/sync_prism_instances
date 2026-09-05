# shellcheck shell=bash

readonly SERVER_STATE_NAME=".sync_prism_instances.servers.json"
readonly SERVER_MARKER_NAME=".sync_prism_instances.servers"

CORE_ITEMS=(saves resourcepacks shaderpacks screenshots servers.dat)
ADDITIONAL_ITEMS=(
  figura
  schematics
  config/worldedit/schematics
  replay_recordings
  replay_videos
  flashback/replays
  journeymap/data
  xaero
  voxelmap
)
SYNC_ITEMS=("${CORE_ITEMS[@]}" "${ADDITIONAL_ITEMS[@]}")

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Предупреждение: %s\n' "$*" >&2; }

canonical_path() {
  if command -v realpath >/dev/null 2>&1; then realpath -m -- "$1"
  elif command -v readlink >/dev/null 2>&1; then readlink -m -- "$1"
  else printf '%s\n' "$1"
  fi
}

pretty_item() {
  case "$1" in
    saves) printf 'Миры' ;;
    resourcepacks) printf 'Ресурспаки' ;;
    shaderpacks) printf 'Шейдеры' ;;
    screenshots) printf 'Скриншоты' ;;
    servers.dat) printf 'Серверы' ;;
    figura) printf 'Figura' ;;
    schematics) printf 'Schematics (Litematica)' ;;
    config/worldedit/schematics) printf 'WorldEdit schematics' ;;
    replay_recordings) printf 'ReplayMod recordings' ;;
    replay_videos) printf 'ReplayMod videos' ;;
    flashback/replays) printf 'Flashback replays' ;;
    journeymap/data) printf 'JourneyMap data' ;;
    xaero) printf 'Xaero maps / waypoints' ;;
    voxelmap) printf 'VoxelMap data' ;;
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
    figura) printf 'figura\n' ;;
    schematics|litematica) printf 'schematics\n' ;;
    worldedit|worldedit-schematics|config/worldedit/schematics) printf 'config/worldedit/schematics\n' ;;
    replaymod|replay|replay_recordings|replay-recordings) printf 'replay_recordings\n' ;;
    replayvideos|replay_videos|replay-videos) printf 'replay_videos\n' ;;
    flashback|flashback/replays) printf 'flashback/replays\n' ;;
    journeymap|journeymap/data) printf 'journeymap/data\n' ;;
    xaero|xaero-maps) printf 'xaero\n' ;;
    voxelmap|voxel-map) printf 'voxelmap\n' ;;
    *) return 1 ;;
  esac
}

parse_item_list() {
  local raw="$1" token item
  local -a tokens=() result=()
  if [[ "${raw,,}" == all || "${raw,,}" == "всё" ]]; then printf '%s\n' "${SYNC_ITEMS[@]}"; return; fi
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
    ) dir
    for dir in "${candidates[@]}"; do
      if [[ -d "$dir" ]]; then PRISM_INSTANCES_DIR="$(canonical_path "$dir")"; break; fi
    done
    [[ -n "$PRISM_INSTANCES_DIR" ]] || fail "не найдена папка Prism Launcher; укажите --prism-dir"
  fi
  local candidate="$(dirname "$PRISM_INSTANCES_DIR")/prismlauncher.cfg"
  [[ -f "$candidate" ]] && PRISM_CONFIG="$(canonical_path "$candidate")"
  return 0
}

find_instances() {
  instances=()
  local base mc
  while IFS= read -r -d '' base; do
    if [[ -d "$base/.minecraft" ]]; then mc="$base/.minecraft"
    elif [[ -d "$base/minecraft" ]]; then mc="$base/minecraft"
    else continue
    fi
    instances+=("$(canonical_path "$mc")")
  done < <(find "$PRISM_INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  ((${#instances[@]} > 0)) || fail "в $PRISM_INSTANCES_DIR не найдено ни одного инстанса"
}

get_instance_name() { basename "$(dirname "$1")"; }
instance_cfg() { printf '%s/instance.cfg\n' "$(dirname "$1")"; }

ensure_target() {
  mkdir -p "$TARGET_DIR"
  local item
  for item in "${SYNC_ITEMS[@]}"; do
    [[ "$item" == servers.dat ]] && continue
    mkdir -p "$TARGET_DIR/$item"
  done
}

copy_dir_contents() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  cp -a -- "$src/." "$dst/"
}

marker_target() {
  local marker="$1/$SERVER_MARKER_NAME" value
  [[ -f "$marker" ]] || return 1
  IFS= read -r value < "$marker" || true
  [[ -n "$value" ]] || return 1
  canonical_path "$value"
}

servers_synced() {
  local instance="$1" marked
  [[ -f "$instance/$SERVER_STATE_NAME" ]] || return 1
  marked="$(marker_target "$instance")" || return 1
  [[ "$marked" == "$(canonical_path "$TARGET_DIR/servers.dat")" ]]
}

is_synced() {
  local instance="$1" item="$2"
  if [[ "$item" == servers.dat ]]; then servers_synced "$instance"; return; fi
  local src="$instance/$item" dst="$TARGET_DIR/$item"
  [[ -L "$src" ]] || return 1
  [[ "$(canonical_path "$src")" == "$(canonical_path "$dst")" ]]
}

enable_sync() {
  local instance="$1" item="$2" src="$1/$2" dst="$TARGET_DIR/$2"
  if [[ "$item" == servers.dat ]]; then install_server_sync "$instance"; return; fi
  is_synced "$instance" "$item" && return 0
  if [[ -L "$src" ]]; then warn "$(get_instance_name "$instance")/$item уже является сторонней символьной ссылкой — пропускаю"; return 1; fi
  if [[ -e "$src" && ! -d "$src" ]]; then warn "$src существует, но это не каталог — пропускаю"; return 1; fi
  mkdir -p "$dst" "$(dirname "$src")"
  if [[ -d "$src" ]]; then copy_dir_contents "$src" "$dst"; rm -rf -- "$src"; fi
  ln -s -- "$dst" "$src"
}

disable_sync() {
  local instance="$1" item="$2" src="$1/$2" dst="$TARGET_DIR/$2"
  if [[ "$item" == servers.dat ]]; then uninstall_server_sync "$instance"; return; fi
  is_synced "$instance" "$item" || return 0
  rm -- "$src"
  mkdir -p "$src"
  [[ -d "$dst" ]] && copy_dir_contents "$dst" "$src"
  return 0
}

status_line() {
  local instance="$1" item additional_count=0
  local -a core=()
  for item in "${CORE_ITEMS[@]}"; do is_synced "$instance" "$item" && core+=("$(pretty_item "$item")"); done
  for item in "${ADDITIONAL_ITEMS[@]}"; do is_synced "$instance" "$item" && ((additional_count += 1)); done
  if ((${#core[@]} == 0 && additional_count == 0)); then printf '—'; return; fi
  if ((${#core[@]} == ${#CORE_ITEMS[@]} && additional_count == ${#ADDITIONAL_ITEMS[@]})); then printf 'всё'; return; fi
  local text='' IFS=', '
  ((${#core[@]} > 0)) && text="${core[*]}"
  if ((additional_count > 0)); then [[ -n "$text" ]] && text+=", "; text+="Additional:$additional_count"; fi
  printf '%s' "$text"
}

select_instances_by_query() {
  selected_instances=()
  if [[ "$ALL_INSTANCES" == true ]]; then selected_instances=("${instances[@]}"); return; fi
  [[ -n "$INSTANCE_QUERY" ]] || fail "укажите --instance NAME или --all-instances"
  local instance name
  for instance in "${instances[@]}"; do name="$(get_instance_name "$instance")"; [[ "$name" == "$INSTANCE_QUERY" ]] && selected_instances+=("$instance"); done
  if ((${#selected_instances[@]} == 0)); then
    for instance in "${instances[@]}"; do name="$(get_instance_name "$instance")"; [[ "${name,,}" == *"${INSTANCE_QUERY,,}"* ]] && selected_instances+=("$instance"); done
  fi
  ((${#selected_instances[@]} == 1)) || { ((${#selected_instances[@]} == 0)) && fail "инстанс '$INSTANCE_QUERY' не найден"; fail "'$INSTANCE_QUERY' соответствует нескольким инстансам; укажите точное имя"; }
}

print_status() {
  local instance item marker
  for instance in "${instances[@]}"; do
    printf '%s\n' "$(get_instance_name "$instance")"
    for item in "${SYNC_ITEMS[@]}"; do marker='·'; is_synced "$instance" "$item" && marker='✓'; printf '  %s %-27s %s\n' "$marker" "$(pretty_item "$item")" "$item"; done
  done
}

apply_cli_action() {
  select_instances_by_query
  local parsed instance item
  parsed="$(parse_item_list "$ACTION_ITEMS")"
  mapfile -t requested_items <<< "$parsed"
  for instance in "${selected_instances[@]}"; do
    for item in "${requested_items[@]}"; do case "$ACTION" in enable) enable_sync "$instance" "$item" ;; disable) disable_sync "$instance" "$item" ;; esac; done
    printf '✓ %s: %s\n' "$(get_instance_name "$instance")" "$(status_line "$instance")"
  done
}
