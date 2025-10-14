# О скрипте
Этот скрипт создаёт общую папку для ваших миров, ресурс паков, шейдеров и скриншотов `(по умочанию это ~/.minecraft)`, переносит ваши данные в эту папку и создаёт симлинки.
Таким образом миры, ресурс паки, шейдеры и скриншоты синхронизируются между выбранными экземплярами игры в Prism Launcher

# Запуск
- вы можете просто запустить скрипт командой
```bash
bash <(curl -s https://raw.githubusercontent.com/march-taylor/sync_prism_instances/main/sync_prism_instances.sh)
```

- вы можете указать свою папку назначения (в которой будут хранится все ваши данные)
```bash
bash <(curl -s https://raw.githubusercontent.com/march-taylor/sync_prism_instances/main/sync_prism_instances.sh) "/path/to/your/minecraft"
```
