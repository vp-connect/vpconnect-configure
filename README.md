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
| **`VPCONFIGURE_DOMAIN`** | Публичное **имя или IP** сервера (FQDN или адрес), подставляется в **`mtproxy.link`**, в настройки VPManage и т.п. Задаётся **`05_setdomain.sh`** или вручную; **нужна** для **`07`** и **`08`** (ветка debian). |
| **`VPCONFIGURE_DOMAIN_SERVICE_URL`** | Базовый URL **REST** для опции **`05_setdomain.sh --domain-client-key`** (запрос FQDN по ключу). По умолчанию заглушка в коде **`05`**; для реального сервиса задайте до запуска **`05`**. |
| **`VPCONFIGURE_WG_PORT`** | **UDP‑порт** прослушивания WireGuard на сервере. Выставляет **`06_setwireguard.sh`** (CLI: **`--wg-port`**, иначе по умолчанию **51820**). |
| **`VPCONFIGURE_WG_CLIENT_CERT_PATH`** | Каталог **сертификатов/ключей** на сервере: здесь лежит файл **публичного ключа сервера** (базовое имя задаётся в **`06`**). По умолчанию **`/usr/wireguard/client_cert`**. |
| **`VPCONFIGURE_WG_CLIENT_CONFIG_PATH`** | Каталог для **клиентских конфигов** и связанных артефактов (в т.ч. ожидаемый путь к **`mtproxy.link`** рядом с конфигами). По умолчанию **`/usr/wireguard/client_config`**. |
| **`VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH`** | Полный путь к **файлу с публичным ключом сервера** WireGuard. Заполняется **`06_setwireguard.sh`**. |
| **`VPCONFIGURE_WG_PRIVATE_KEY_PATH`** | Полный путь к **приватному ключу сервера** (по умолчанию **`/etc/wireguard/privatekey`**). Задаёт **`06`**; **`07`**/**`08`** могут подставлять умолчания, если переменная пуста. |
| **`VPCONFIGURE_MTPROXY_PORT`** | **UDP‑порт** MTProxy на сервере. Задаёт **`07_setmtproxy.sh`** (по умолчанию **443**). |
| **`VPCONFIGURE_MTPROXY_SECRET_PATH`** | Путь к файлу **секрета** прокси (hex и т.д.). Задаёт **`07`** (рядом с каталогом приватного ключа WG). |
| **`VPCONFIGURE_MTPROXY_LINK_PATH`** | Путь к файлу **`mtproxy.link`** (строка **`tg://proxy?...`**). Задаёт **`07`**. |
| **`VPCONFIGURE_MTPROXY_INSTALL_DIR`** | Каталог **исходников/сборки** MTProxy (по умолчанию **`/opt/MTProxy`**). Задаёт **`07`**. |
| **`VPCONFIGURE_VPM_HTTP_PORT`** | **TCP‑порт** HTTP панели VPManage (**gunicorn**). Задаёт **`08_setvpmanage.sh`** (по умолчанию **80**). |
| **`VPCONFIGURE_VPM_PASSWORD`** | Пароль админки VPManage (или сгенерированный). Задаёт **`08`**. |
| **`VPCONFIGURE_VPM_INSTALL_PATH`** | Каталог установки приложения (по умолчанию **`/opt/VPManage`**). Задаёт **`08`**. |
| **`VPCONFIGURE_VPM_SYSTEMD_SERVICE`** | Имя unit **systemd** без `.service` (по умолчанию **`vpconnect-manage`**). Задаёт **`08`**. |

Служебные переменные (не `VPCONFIGURE_*`, но встречаются в сценариях): **`DEBIAN_FRONTEND=noninteractive`** при вызове **`apt-get`**; в **`03`** временно **`GIT_TERMINAL_PROMPT=0`** для неинтерактивного clone/fetch.

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
| `04_setsystemaccess.sh` | Пароль root, SSH‑порт, ключ |
| `05_setdomain.sh` | Hostname / домен |
| `06_setwireguard.sh` | WireGuard |
| `07_setmtproxy.sh` | MTProxy |
| `08_setvpmanage.sh` | VPManage |

## Порядок запуска (пример)

```sh
sh ./00_bashinstall.sh
eval "$(bash ./01_getosversion.sh --export | sed -n '2p')"
bash ./01_getosversion.sh --persist   # опционально
bash ./02_gitinstall.sh
bash ./03_getconfigure.sh
# далее 04–08 по необходимости настройки сервера
```
