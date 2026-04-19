# vpconnect-configure

Скрипты подготовки сервера (WireGuard, MTProxy, VPManage).

## Поддерживаемые ОС

- **FreeBSD** 13, 14  
- **Ubuntu** 22.04, 24.04, 26.04  
- **Debian** 12, 13  
- Производные Debian/Ubuntu: Linux Mint, Pop!_OS, Kali, Raspberry Pi OS, Elementary, Zorin, Devuan (по `ID` / `ID_LIKE`)  
- **AlmaLinux** 9.x, 10.x  
- **Rocky Linux** 8.x, 9.x  
- **VzLinux / Virtuozzo** 8.x  
- **Oracle Linux**, **EuroLinux**, **CloudLinux** 8–10  
- **RHEL** 8–10  
- **Fedora** 39+  
- **Amazon Linux** 2023+ (не AL2)  

Не поддерживаются: CentOS Linux, Scientific Linux, Amazon Linux 2, FreeBSD 12.

## Ветка `VPCONFIGURE_GIT_BRANCH`

Скрипт `01_getosversion.sh` задаёт одно из трёх **семейств** (имя ветки в Git при необходимости совпадает с ним):

| Значение   | ОС |
|------------|----|
| `freebsd`  | FreeBSD |
| `debian`   | Debian, Ubuntu и совместимые (`apt`) |
| `centos`   | RHEL‑семейство: Alma, Rocky, Oracle, Fedora, Amazon Linux 2023+ и т.д. (`dnf`/`yum`) |

Скрипты **`02`–`08`** запускаются **после** `01` и опираются на `VPCONFIGURE_GIT_BRANCH`. **`00`** и **`01`** переменную не требуют.

Для текущей **centos-ветки репозитория** действует политика: скрипты **`04`–`08`**, каталог **`lib/`** и runtime-скрипты **`wg/`** выполняются только при `VPCONFIGURE_GIT_BRANCH=centos` (иначе `result:error`).
Скрипты **`00`–`03`** остаются универсальными для `freebsd|debian|centos`.

## Переменные окружения (`VPCONFIGURE_*`)

Общие правила:

- Префикс **`VPCONFIGURE_`** — единый контракт между скриптами и внешними установщиками.
- Часть переменных выставляется **вручную** (`export`, `eval` из `--export`) или **читается из файла** (по умолчанию **`/root/.vpconnect-configure.env`**). Скрипты **`05`**, **`06`**, **`07`**, **`08`** при успехе **дописывают** свои ключи в этот файл, чтобы новая SSH‑сессия подхватила значения (часто вместе с хуками `~/.bashrc` / `/etc/profile.d` при **`--persist`** у **`01`** / **`05`**).
- Пути могут быть с **`~`**; перед использованием скрипты обычно разворачивают тильду в `$HOME`.

| Переменная | Значение и назначение |
|------------|------------------------|
| **`VPCONFIGURE_GIT_BRANCH`** | Семейство ОС для выбора ветки сценариев и способа установки пакетов: **`freebsd`**, **`debian`** или **`centos`**. Задаётся скриптом **`01_getosversion.sh`** (или вручную). **Обязательна** для **`02`–`08`** (проверка в `main`). |
| **`VPCONFIGURE_REPO_URL`** | URL git‑репозитория с конфигурацией (по умолчанию репозиторий vpconnect-configure). Использует **`03_getconfigure.sh`**, если не заданы флаги `--repo`. |
| **`VPCONFIGURE_INSTALL_DIR`** | Каталог, куда **`03_getconfigure.sh`** клонирует или обновляет файлы (по умолчанию относительный `./vpconnect-configure`). |
| **`VPCONFIGURE_DOMAIN`** | Публичное **имя или IP** сервера (FQDN или адрес), подставляется в **`mtproxy.link`**, в настройки VPManage и т.п. Задаётся **`05_setdomain.sh`** или вручную; **нужна** для **`07`** и **`08`** (в этой ветке — centos-only). |
| **`VPCONFIGURE_DOMAIN_SERVICE_URL`** | Базовый URL **REST** для опции **`05_setdomain.sh --domain-client-key`** (запрос FQDN по ключу). По умолчанию заглушка в коде **`05`**; для реального сервиса задайте до запуска **`05`**. |
| **`VPCONFIGURE_WG_PORT`** | **UDP‑порт** прослушивания WireGuard на сервере. Выставляет **`06_setwireguard.sh`** (CLI: **`--wg-port`**, иначе по умолчанию **51820**). |
| **`VPCONFIGURE_WG_CLIENT_CERT_PATH`** | Каталог **сертификатов/ключей** на сервере: здесь лежит файл **публичного ключа сервера** (базовое имя задаётся в **`06`**). По умолчанию **`/usr/wireguard/client_cert`**. |
| **`VPCONFIGURE_WG_CLIENT_CONFIG_PATH`** | Каталог для **клиентских конфигов** и связанных артефактов (в т.ч. ожидаемый путь к **`mtproxy.link`** рядом с конфигами). По умолчанию **`/usr/wireguard/client_config`**. |
| **`VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH`** | Полный путь к **файлу с публичным ключом сервера** WireGuard. Заполняется **`06_setwireguard.sh`**. |
| **`VPCONFIGURE_WG_PRIVATE_KEY_PATH`** | Полный путь к **приватному ключу сервера** (по умолчанию **`/etc/wireguard/privatekey`**). Задаёт **`06`**; **`07`**/**`08`** могут подставлять умолчания, если переменная пуста. |
| **`VPCONFIGURE_MTPROXY_PORT`** | **TCP‑порт** MTProxy на сервере. Задаёт **`07_setmtproxy.sh`** (CLI: **`--mtproxy-port`**, по умолчанию **443**). |
| **`VPCONFIGURE_MTPROXY_SECRET_PATH`** | Путь к файлу **секрета** для **`mtproto-proxy -S`**: ровно **32** шестнадцатеричных символа (**16** байт). Задаёт **`07`** (файл рядом с каталогом приватного ключа WG). Опционально при запуске **`07`**: **`--mtproxy-secret HEX`** — тот же **32** hex **или** строка как в **`tg://proxy`** (**`dd`** + **32** hex); пробелы обрезаются, регистр не важен. Неверный токен: **`07`** генерирует случайный секрет и пишет предупреждение в **stderr**. Без **`--mtproxy-secret`**: если файл уже есть — используется он, иначе секрет генерируется. |
| **`VPCONFIGURE_MTPROXY_LINK_PATH`** | Путь к файлу **`mtproxy.link`** (строка **`tg://proxy?...`**). Задаёт **`07`**. |
| **`VPCONFIGURE_MTPROXY_INSTALL_DIR`** | Каталог **исходников/сборки** MTProxy (по умолчанию **`/opt/MTProxy`**). Задаёт **`07`**. |
| **`VPCONFIGURE_VPM_HTTP_PORT`** | **TCP‑порт** HTTP панели VPManage (**gunicorn**). Задаёт **`08_setvpmanage.sh`** (по умолчанию **80**). |
| **`VPCONFIGURE_VPM_PASSWORD`** | Пароль админки VPManage (или сгенерированный). Задаёт **`08`**. |
| **`VPCONFIGURE_VPM_INSTALL_PATH`** | Каталог установки приложения (по умолчанию **`/opt/VPManage`**). Задаёт **`08`**. |
| **`VPCONFIGURE_VPM_SYSTEMD_SERVICE`** | Имя unit **systemd** без `.service` (по умолчанию **`vpconnect-manage`**). Задаёт **`08`**. |

**Результат `06_setwireguard.sh`** (имя интерфейса не задаётся флагами; по умолчанию ожидается **`wg0`**, иначе определяется автоматически):

| Переменная | Назначение |
|------------|------------|
| **`VPCONFIGURE_WIREGUARD_INTERFACE_NAME`** | **Записывается `06`:** имя интерфейса WireGuard после установки — файл **`/etc/wireguard/<имя>.conf`**, unit **`wg-quick@<имя>`**. Логика: **`wg/detect_wg_iface.inc.sh`** (`wg show interfaces` с приоритетом **`wg0`**, иначе единственный **`/etc/wireguard/wg*.conf`**, иначе **`wg0`**). Скрипты **`wg/*.sh`** и **`08`** читают эту переменную из окружения/`.vpconnect-configure.env`; если её ещё нет — применяют ту же функцию **`detect_wg_interface_name`**. |
| **`VPCONFIGURE_WG_WAN_IFACE`** | Исходящий интерфейс для **MASQUERADE** в **PostUp**. Не задана — при подъёме туннеля подставляется интерфейс **default route** (`ip -4 route show default`). |

**Опционально для `08_setvpmanage.sh`** (значения уходят в **`settings.env`** vpconnect-manage; если не заданы — берутся умолчания из **`06`** / **`VPCONFIGURE_DOMAIN`**):

| Переменная | Назначение |
|------------|------------|
| **`VPCONFIGURE_WG_CONF_PATH`** | Путь к конфигу WireGuard. Не задана → **`/etc/wireguard/<имя>.conf`**, где **`<имя>`** — **`VPCONFIGURE_WIREGUARD_INTERFACE_NAME`** после **`06`**, либо результат **`detect_wg_interface_name`** (как в **`06`**). Задана **пустой строкой** → интеграция WireGuard в UI панели выключена. |
| **`VPCONFIGURE_WIREGUARD_SYNC_INTERVAL_MINUTES`** | Интервал синхронизации JSON с конфигом WG (минуты); по умолчанию **5**. **0** — только при старте и при открытии дашборда. |
| **`VPCONFIGURE_WIREGUARD_INTERFACE_NAME`** | Если уже выставлена **`06`** — используется она. Если пусто (например, **`08`** без предшествующего **`06`** в той же сессии) — **`08`** подставляет то же автоматическое имя, что и **`detect_wg_interface_name`**. |
| **`VPCONFIGURE_WIREGUARD_ENDPOINT`** | Полный **`host:port`** для клиентских конфигов (если задан, хост/порт ниже для Endpoint не комбинируются). |
| **`VPCONFIGURE_WIREGUARD_PUBLIC_HOST`** | Публичный хост для Endpoint, если **`WIREGUARD_ENDPOINT`** пуст (иначе по умолчанию **`VPCONFIGURE_DOMAIN`**). |
| **`VPCONFIGURE_WIREGUARD_LISTEN_PORT`** | UDP‑порт для Endpoint при пустом **`WIREGUARD_ENDPOINT`**; **0** — взять **`ListenPort`** из конфига WG, иначе при отсутствии — **51820**. По умолчанию подставляется **`VPCONFIGURE_WG_PORT`**, иначе **0**. |
| **`VPCONFIGURE_WIREGUARD_DNS`** | DNS в клиентском **`[Interface]`** (по умолчанию **8.8.8.8**). |
| **`VPCONFIGURE_WIREGUARD_CLIENT_CONFIG_DIR`** | Каталог клиентских **`.conf`**; иначе **`VPCONFIGURE_WG_CLIENT_CONFIG_PATH`**. |
| **`VPCONFIGURE_WIREGUARD_CLIENT_KEYS_DIR`** | Каталог ключей клиентов; иначе **`VPCONFIGURE_WG_CLIENT_CERT_PATH`**. |
| **`VPCONFIGURE_VPM_LOGIN_MAX_FAILED_ATTEMPTS`** | Лимит неверных попыток входа с IP (по умолчанию **5**). |
| **`VPCONFIGURE_VPM_LOGIN_LOCKOUT_MINUTES`** | Блокировка IP (минуты; по умолчанию **60**). |

Служебные переменные (не `VPCONFIGURE_*`, но встречаются в сценариях): **`DEBIAN_FRONTEND=noninteractive`** при вызове **`apt-get`** в Debian-ветке; в **`03`** временно **`GIT_TERMINAL_PROMPT=0`** для неинтерактивного clone/fetch.

## Строка результата (для автоматизации)

Первая строка **stdout** всегда начинается с `result:success`, `result:warning` или `result:error`, далее `; message:текст` и при необходимости `; ключ:значение` (например `branch:debian`). В `message` символ `;` не использовать. Пояснения и лог — в **stderr**

`result:success|warning|error;message:текст;[ключ:значение;]`

## Скрипты

| Файл | Назначение |
|------|------------|
| `00_bashinstall.sh` | Установить `bash`, если нет (`sh ./00_installbash.sh`) |
| `01_getosversion.sh` | Семейство ОС → `VPCONFIGURE_GIT_BRANCH`, опции `--export`, `--persist` |
| `02_gitinstall.sh` | Установка `git` по семейству |
| `03_getconfigure.sh` | Клон/обновление репозитория |
| `04_setsystemaccess.sh` | Пароль root, SSH‑порт, ключ (в этой ветке — только `centos`; опционально **`--enable-firewall`** через `firewalld`) |
| `05_setdomain.sh` | Hostname / домен |
| `06_setwireguard.sh` | WireGuard (в этой ветке — только `centos`; **`--wg-port`**, пути клиентских каталогов, опционально **`--wg-server-private-key-file`**) |
| `07_setmtproxy.sh` | MTProxy (в этой ветке — только `centos`; **`--mtproxy-port`**, опционально **`--mtproxy-secret`**, **`--export`**, **`--persist`**) |
| `08_setvpmanage.sh` | VPManage (в этой ветке — только `centos`) |

## Порядок запуска (пример)

```sh
sh ./00_bashinstall.sh
eval "$(bash ./01_getosversion.sh --export | sed -n '2p')"
bash ./01_getosversion.sh --persist   # опционально
bash ./02_gitinstall.sh
bash ./03_getconfigure.sh
# далее 04–08 по необходимости настройки сервера
```
