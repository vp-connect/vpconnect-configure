# vpconnect-configure

Скрипты подготовки сервера для установки и обслуживания VPConnect.

## Профиль ветки

Ветка `main` содержит общий формат документации и полное описание поддерживаемых платформ без привязки к конкретной реализации ОС.

## Поддерживаемые ОС

- **FreeBSD**: 13, 14
- **Debian family**: Debian 12-13, Ubuntu 22.04/24.04/26.04, Linux Mint, Pop!_OS, Kali, Raspberry Pi OS, Elementary, Zorin, Devuan
- **RHEL family**: AlmaLinux 9-10, Rocky Linux 8-9, Oracle Linux 8-10, EuroLinux 8-10, CloudLinux 8-10, RHEL 8-10, Fedora 39+, Amazon Linux 2023+, VzLinux/Virtuozzo 8

Неподдерживаемые примеры: CentOS Linux, Scientific Linux, Amazon Linux 2, FreeBSD 12.

## Модель веток и запуск

- `00-03` — универсальные, мульти-OS.
- `04-08`, `lib/`, `wg/` — OS-зависимые и используются в профильных ветках.
- `01_getosversion.sh` задает `VPCONFIGURE_GIT_BRANCH` (`freebsd|debian|centos`) для выбора целевого профиля.

## Контракт результата

Первая строка stdout:

`result:success|warning|error;message:текст;[ключ:значение;]`

- Логи и пояснения печатаются в stderr.
- `message` не должен содержать `;`.

## Скрипты

| Файл | Назначение |
|------|------------|
| `00_bashinstall.sh` | Проверка/установка оболочки `bash` |
| `01_getosversion.sh` | Определение семейства ОС и `VPCONFIGURE_GIT_BRANCH` |
| `02_gitinstall.sh` | Установка `git` средствами текущей ОС |
| `03_getconfigure.sh` | Клон/обновление репозитория конфигурации |
| `04_setsystemaccess.sh` | Базовый системный доступ (root/SSH/ключ/опц. firewall) |
| `05_setdomain.sh` | Установка `VPCONFIGURE_DOMAIN` |
| `06_setwireguard.sh` | Установка и базовая настройка WireGuard |
| `07_setmtproxy.sh` | Установка и настройка MTProxy |
| `08_setvpmanage.sh` | Установка и настройка VPManage |

## Порядок запуска

```sh
sh ./00_bashinstall.sh
eval "$(bash ./01_getosversion.sh --export | sed -n '2p')"
bash ./01_getosversion.sh --persist   # optional
bash ./02_gitinstall.sh
bash ./03_getconfigure.sh
# затем 04-08 по задачам окружения
```
