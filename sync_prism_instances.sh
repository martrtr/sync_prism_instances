#!/bin/bash

# Настройки
PRISM_INSTANCES_DIR="$HOME/.local/share/PrismLauncher/instances"
TARGET_DIR="${1:-$HOME/.minecraft}"

mkdir -p "$TARGET_DIR"/{saves,resourcepacks,shaderpacks,screenshots}

# список инстансов
instances=()
while IFS= read -r -d $'\0' dir; do
  instances+=("$dir")
done < <(find "$PRISM_INSTANCES_DIR" -maxdepth 2 -type d -name minecraft -print0)

# проверка синхронизации
echo "Доступные инстансы:"
i=1
for instance in "${instances[@]}"; do
  sync_status="❌ Не синхронизирован"
  if [[ -L "$instance/saves" && -L "$instance/resourcepacks" && \
        -L "$instance/shaderpacks" && -L "$instance/screenshots" ]]; then
    sync_status="✅ Синхронизирован"
  fi
  instance_name=$(basename "$(dirname "$instance")")
  printf "%2d. %s (%s)\n" $i "$instance_name" "$sync_status"
  ((i++))
done

# выбор инстанса
echo
read -p "Выберите номер инстанса: " num
selected="${instances[$((num-1))]}"
instance_name=$(basename "$(dirname "$selected")")

# перенос данных и создание симлинков
for folder in saves resourcepacks shaderpacks screenshots; do
  source_dir="$selected/$folder"
  target_dir="$TARGET_DIR/$folder"
  
  if [[ -L "$source_dir" ]]; then
    echo "Пропускаем $folder (уже симлинк)"
    continue
  fi

  if [[ -d "$source_dir" && -n "$(ls -A "$source_dir")" ]]; then
    echo "Переносим $folder из $instance_name"
    cp -r "$source_dir"/* "$target_dir"/ 2>/dev/null
  fi

  rm -rf "$source_dir"
  ln -s "$target_dir" "$source_dir"
  echo "Создан симлинк для $folder"
done

echo "Готово! Данные перенесены в $TARGET_DIR"
