# sync_prism_instances

Минималистичный TUI/CLI для синхронизации данных между инстансами Prism Launcher: миров, ресурспаков, шейдеров, скриншотов и списка серверов.

Папки синхронизируются через симлинки. `servers.dat` синхронизируется отдельно через `PreLaunchCommand`/`PostExitCommand` Prism: перед запуском инстанс получает актуальный список, после выхода его изменения мержатся обратно. Уже существующие серверы не теряются.

Требования: Linux, Bash 4+, Python 3.

## Запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/martrtr/sync_prism_instances/main/sync_prism_instances.sh)
```

Fish:

```fish
bash (curl -fsSL https://raw.githubusercontent.com/martrtr/sync_prism_instances/main/sync_prism_instances.sh | psub)
```

Своя общая папка:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/martrtr/sync_prism_instances/main/sync_prism_instances.sh) --target ~/MinecraftShared
```

## CLI

```text
-t, --target DIR        общая папка
-p, --prism-dir DIR     папка instances Prism Launcher
-i, --instance NAME     выбрать инстанс
    --all-instances     выбрать все инстансы
    --enable ITEMS      включить синхронизацию
    --disable ITEMS     отключить синхронизацию
    --status            показать состояние
-h, --help              помощь
```

`ITEMS`: `saves,resourcepacks,shaderpacks,screenshots,servers` или `all`.

```bash
./sync_prism_instances.sh --instance "Fabric 1.21" --enable saves,servers
```
