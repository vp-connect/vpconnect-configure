# WireGuard: вспомогательные скрипты (`vpconnect-configure/wg`)

Набор **операционных** сценариев для сервера с уже поднятым WireGuard (после **`06_setwireguard.sh`** или эквивалента): учёт клиентов в **`/etc/wireguard/<имя>.conf`** (имя — **`VPCONFIGURE_WIREGUARD_INTERFACE_NAME`** из env после **`06`**, иначе **`detect_wg_interface_name`** из **`detect_wg_iface.inc.sh`**, обычно **`wg0`**), ключи и клиентские `.conf`, QR в текстовом виде.

Они **не** входят в нумерованную цепочку `00–08` как отдельные шаги, но при успешном **`06_setwireguard.sh`** (ветка debian), если рядом с ним на сервере есть каталог **`wg/`** с этими `*.sh`, скрипт **06** выставляет им **`chmod a+x`** и создаёт **симлинки в `/usr/local/bin/`** (вызов из консоли: `wg.sh help` и т.д.).

## Зависимости

- Утилиты **`wg`**, **`wg-quick`** (пакет `wireguard-tools` / аналог).
- **`qrencode`** — для `create_client.sh` (ANSI QR в `.txt`).
- Права **root** для изменения `wg0.conf` и `wg syncconf`.

## Пути и согласованность с `06_setwireguard.sh`

| Что | В этих скриптах | В `06_setwireguard.sh` (умолчания) |
|-----|-----------------|-------------------------------------|
| Конфиг интерфейса | `VPCONFIGURE_WG_CONF_PATH` или `/etc/wireguard/<имя>.conf` | `/etc/wireguard/<имя>.conf` |
| Каталог ключей клиентов | `VPCONFIGURE_WG_CLIENT_CERT_PATH` или `/usr/wireguard/client_cert` | `/usr/wireguard/client_cert` |
| Каталог клиентских конфигов | `VPCONFIGURE_WG_CLIENT_CONFIG_PATH` или `/usr/wireguard/client_config` | `/usr/wireguard/client_config` |

## Установка на сервер

- **Автоматически:** положите дерево `vpconnect-configure` на сервер (как после `03_getconfigure.sh`), затем выполните **`06_setwireguard.sh`** — см. выше.
- **Вручную (пример),** если 06 не запускали:

```bash
sudo chmod a+x /path/to/vpconnect-configure/wg/*.sh
for f in /path/to/vpconnect-configure/wg/*.sh; do sudo ln -sf "$f" /usr/local/bin/; done
# wg.sh ожидает create_client.sh, delete_client.sh, toggle_client.sh, list_users.sh в /usr/local/bin/
```

## Состав

| Файл | Назначение |
|------|------------|
| **`wg.sh`** | Обёртка: `create`, `delete`, `enable`/`disable`, `list` → вызывает остальные скрипты из фиксированных путей. |
| **`create_client.sh`** | Новый клиент: ключи, запись `[Peer]` в `wg0.conf`, `.conf`, QR; `wg syncconf`. |
| **`delete_client.sh`** | Удаление блока клиента, файлов ключей/конфига/QR; `wg syncconf`. |
| **`toggle_client.sh`** | Включение/отключение пира комментированием строк блока `[Peer]`; `wg syncconf`. |
| **`list_users.sh`** | Разбор конфига WG по маркерам `# Client: …`, фильтры `--all` / `--enabled` / `--disabled`, `--names-only`. |

Подробные параметры и оговорки — в шапке каждого `.sh` (в том же стиле, что и скрипты `vpconnect-configure` в корне каталога).

## Важно для `create_client.sh`

`create_client.sh` не требует ручного редактирования:

- Публичный ключ сервера берётся из `VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH`, а при отсутствии — через `wg show <iface> public-key`.
- Endpoint берётся из `VPCONFIGURE_WIREGUARD_ENDPOINT`, а при отсутствии — из `VPCONFIGURE_DOMAIN:VPCONFIGURE_WG_PORT`.
- DNS берётся из `VPCONFIGURE_WIREGUARD_DNS` (по умолчанию `8.8.8.8`).
- Подсеть для клиентских адресов выводится из `Address = ...` в конфиге сервера (например `10.8.0.1/24` → клиенты `10.8.0.2..254`).

## Формат маркеров в конфиге интерфейса

Каждый клиент задаётся блоком, начинающимся со строки:

```ini
# Client: <имя>
[Peer]
...
```

**Отключённый** клиент в `toggle_client.sh` — это тот же блок, но строки **`[Peer]` и полей ниже** временно закомментированы символом `#` в начале строки (не маркер `# Client:`).
