# vpconnect-configure

Скрипты подготовки сервера для установки и обслуживания VPConnect.

## Профиль ветки

Ветка `debian` содержит Debian-реализацию шагов `04-08`, runtime-скриптов `lib/` и `wg/`.

## Поддерживаемые ОС (Debian-like)

- **Debian**: 12, 13
- **Ubuntu**: 22.04, 24.04, 26.04
- Производные Debian/Ubuntu: Linux Mint, Pop!_OS, Kali, Raspberry Pi OS, Elementary, Zorin, Devuan

## Политика ветки

- `00-03` — универсальные (`freebsd|debian|centos`).
- `04-08`, `lib/`, `wg/`, `mt/` — только для `VPCONFIGURE_GIT_BRANCH=debian`.
- При других значениях ветки OS-зависимые скрипты возвращают `result:error` и завершаются с ненулевым кодом.

## Debian-специфика

- Пакеты и зависимости: `apt-get`.
- Firewall: `ufw` (опция `--enable-firewall` в `04_setsystemaccess.sh`).
- Типовые пути: `/etc/wireguard`, `/usr/wireguard/client_cert`, `/usr/wireguard/client_config`, `/root/.vpconnect-configure.env`.

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
| `04_setsystemaccess.sh` | Доступ root/SSH/ключ и `ufw` |
| `05_setdomain.sh` | Установка `VPCONFIGURE_DOMAIN` |
| `06_setwireguard.sh` | WireGuard (Debian-реализация) |
| `07_setmtproxy.sh` | MTProxy (Debian-реализация) |
| `08_setvpmanage.sh` | VPManage (Debian-реализация) |

Runtime-утилиты (после установки сервисов):

- `wg/` — управление клиентами WireGuard (`wg.sh`, `create_client.sh` и т.д.).
- `mt/` — управление секретом MTProxy (`mt.sh`, `set_secret.sh`, `new_secret.sh`).

## Порядок запуска

```sh
sh ./00_bashinstall.sh
eval "$(bash ./01_getosversion.sh --export | sed -n '2p')"
bash ./01_getosversion.sh --persist   # optional
bash ./02_gitinstall.sh
bash ./03_getconfigure.sh
# затем 04-08 в ветке debian
```
