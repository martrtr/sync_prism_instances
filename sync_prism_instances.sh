#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIGURATION
#######################################

PRISM_INSTANCES_DIR="$HOME/.local/share/PrismLauncher/instances"
TARGET_DIR="${1:-$HOME/.minecraft}"

# folder = директория
# file   = одиночный файл
declare -A SYNC_ITEMS=(
  [saves]="folder"
  [resourcepacks]="folder"
  [shaderpacks]="folder"
  [screenshots]="folder"
  [servers.dat]="file"
)

#######################################
# INITIAL SETUP
#######################################

mkdir -p "$TARGET_DIR"

for item in "${!SYNC_ITEMS[@]}"; do
  [[ "${SYNC_ITEMS[$item]}" == "folder" ]] && mkdir -p "$TARGET_DIR/$item"
done

#######################################
# FIND INSTANCES
#######################################

instances=()
while IFS= read -r -d $'\0' dir; do
  instances+=("$dir")
done < <(find "$PRISM_INSTANCES_DIR" -maxdepth 2 -type d -name minecraft -print0)

#######################################
# FUNCTIONS
#######################################

get_instance_name() {
  basename "$(dirname "$1")"
}

get_sync_status() {
  local instance="$1"
  local synced=()

  for item in "${!SYNC_ITEMS[@]}"; do
    local path="$instance/$item"
    if [[ -L "$path" ]]; then
      synced+=("$item")
    fi
  done

  if [[ ${#synced[@]} -eq 0 ]]; then
    echo "❌ не синхронизирован"
  else
    echo "✅ $(IFS=", "; echo "${synced[*]}")"
  fi
}

toggle_sync() {
  local instance="$1"
  local item="$2"

  local src="$instance/$item"
  local dst="$TARGET_DIR/$item"

  # отключение синхронизации
  if [[ -L "$src" ]]; then
    rm "$src"
    if [[ "${SYNC_ITEMS[$item]}" == "folder" ]]; then
      mkdir -p "$src"
      cp -r "$dst"/* "$src"/ 2>/dev/null || true
    else
      [[ -f "$dst" ]] && cp "$dst" "$src"
    fi
    echo "❌ $item — синхронизация отключена"
    return
  fi

  # включение синхронизации
  if [[ -e "$src" ]]; then
    if [[ "${SYNC_ITEMS[$item]}" == "folder" ]]; then
      cp -r "$src"/* "$dst"/ 2>/dev/null || true
      rm -rf "$src"
    else
      cp "$src" "$dst"
      rm -f "$src"
    fi
  fi

  ln -s "$dst" "$src"
  echo "✅ $item — синхронизация включена"
}

#######################################
# INSTANCE SELECTION MENU
#######################################

echo "Доступные инстансы:"
i=1
for instance in "${instances[@]}"; do
  name=$(get_instance_name "$instance")
  status=$(get_sync_status "$instance")
  printf "%2d. %s (%s)\n" "$i" "$name" "$status"
  ((i++))
done

echo
read -rp "Выберите номер инстанса: " num
instance="${instances[$((num-1))]}"
instance_name=$(get_instance_name "$instance")

#######################################
# SYNC SELECTION MENU
#######################################

while true; do
  echo
  echo "Инстанс: $instance_name"
  echo "Выберите, что синхронизировать (повторный выбор — отключение):"

  idx=1
  keys=()
  for item in "${!SYNC_ITEMS[@]}"; do
    status=" "
    [[ -L "$instance/$item" ]] && status="✔"
    printf " %d. [%s] %s\n" "$idx" "$status" "$item"
    keys+=("$item")
    ((idx++))
  done

  echo " A. [✔] всё / отключить всё"
  echo " Q. выход"

  read -rp "> " choice

  case "$choice" in
    [Qq]) break ;;
    [Aa])
      for item in "${!SYNC_ITEMS[@]}"; do
        toggle_sync "$instance" "$item"
      done
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#keys[@]} )); then
        toggle_sync "$instance" "${keys[$((choice-1))]}"
      else
        echo "Неверный выбор"
      fi
      ;;
  esac
done

echo
echo "Готово. Синхронизация обновлена."
