# WireGuard: вспомогательные скрипты (`vpconnect-configure/wg`)

Набор **операционных** сценариев для сервера с уже поднятым WireGuard (после **`06_setwireguard.sh`** или эквивалента): учёт клиентов в **`/etc/wireguard/wg0.conf`**, ключи и клиентские `.conf`, QR в текстовом виде.

Они **не** входят в нумерованную цепочку `00–08` как отдельные шаги, но при успешном **`06_setwireguard.sh`** (ветка debian), если рядом с ним на сервере есть каталог **`wg/`** с этими `*.sh`, скрипт **06** выставляет им **`chmod a+x`** и создаёт **симлинки в `/usr/local/bin/`** (вызов из консоли: `wg.sh help` и т.д.).

## Зависимости

- Утилиты **`wg`**, **`wg-quick`** (пакет `wireguard-tools` / аналог).
- **`qrencode`** — для `create_client.sh` (ANSI QR в `.txt`).
- Права **root** для изменения `wg0.conf` и `wg syncconf`.

## Пути и согласованность с `06_setwireguard.sh`

| Что | В этих скриптах | В `06_setwireguard.sh` (умолчания) |
|-----|-----------------|-------------------------------------|
| Конфиг интерфейса | `/etc/wireguard/wg0.conf` | то же |
| Каталог ключей клиентов | `/usr/wireguard/client_sert` ⚠ | `/usr/wireguard/client_cert` |

Имя каталога **`client_sert`** в коде — опечатка относительно **`client_cert`** в основном скрипте. Перед продакшеном выровняйте **`KEY_DIR`** в `create_client.sh` / `delete_client.sh` под фактический путь на сервере (или наоборот).

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
| **`list_users.sh`** | Разбор `wg0.conf` по маркерам `# Client: …`, фильтры `--all` / `--enabled` / `--disabled`, `--names-only`. |

Подробные параметры и оговорки — в шапке каждого `.sh` (в том же стиле, что и скрипты `vpconnect-configure` в корне каталога).

## Важно для `create_client.sh`

Внутри файла зашиты **`SERVER_PUBLIC_KEY`**, **`SERVER_ENDPOINT`**, **`DNS`**: их нужно **заменить** на реальные публичный ключ сервера, `IP:порт` WG и желаемый DNS для клиентов. Подсеть клиентских адресов зашита как **`10.0.0.0/24`** (поиск свободного хоста с `10.0.0.2` … `10.0.0.254`).

## Формат маркеров в `wg0.conf`

Каждый клиент задаётся блоком, начинающимся со строки:

```ini
# Client: <имя>
[Peer]
...
```

**Отключённый** клиент в `toggle_client.sh` — это тот же блок, но строки **`[Peer]` и полей ниже** временно закомментированы символом `#` в начале строки (не маркер `# Client:`).
