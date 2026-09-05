# sync_prism_instances

Минималистичный TUI/CLI для синхронизации данных между инстансами Prism Launcher.

Основное: миры, ресурспаки, шейдеры, скриншоты и список серверов.

В разделе **Additional** доступны популярные пользовательские папки модов: Figura, Litematica/WorldEdit schematics, ReplayMod, Flashback, JourneyMap, Xaero и VoxelMap.

Каталоги синхронизируются через общую папку и симлинки. `servers.dat` синхронизируется отдельно через Prism hooks; если список разошёлся, в главном меню есть **Update server list**, который безопасно объединяет серверы из всех подключённых инстансов и раздаёт единый список обратно.

Требования: Linux, Bash 4+, Python 3.

## Запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/martrtr/sync_prism_instances/main/sync_prism_instances.sh)
```

Для fish:

```fish
bash (curl -fsSL https://raw.githubusercontent.com/martrtr/sync_prism_instances/main/sync_prism_instances.sh | psub)
```

## CLI

```text
-t, --target DIR        общая папка (по умолчанию ~/.minecraft)
-p, --prism-dir DIR     папка instances Prism Launcher
-i, --instance NAME     выбрать инстанс
    --all-instances     выбрать все инстансы
    --enable ITEMS      включить синхронизацию
    --disable ITEMS     отключить синхронизацию
    --update-servers    принудительно объединить списки серверов
    --status            показать состояние
-h, --help              помощь
```

`ITEMS`: `saves`, `resourcepacks`, `shaderpacks`, `screenshots`, `servers`, `figura`, `schematics`, `worldedit`, `replaymod`, `replayvideos`, `flashback`, `journeymap`, `xaero`, `voxelmap` или `all`.

Примеры:

```bash
./sync_prism_instances.sh --instance "Fabric 1.21" --enable saves,servers,figura,schematics
./sync_prism_instances.sh --update-servers
```
