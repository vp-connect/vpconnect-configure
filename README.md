# vpconnect-configure

Скрипты подготовки сервера для установки и обслуживания VPConnect.

## Профиль ветки

Ветка `freebsd` содержит FreeBSD-реализацию шагов `04-08`, runtime-скриптов `lib/` и `wg/`.

## Поддерживаемые ОС (FreeBSD)

- **FreeBSD**: 13, 14

## Политика ветки

- `00-03` — универсальные (`freebsd|debian|centos`).
- `04-08`, `lib/`, `wg/` — только для `VPCONFIGURE_GIT_BRANCH=freebsd`.
- При других значениях ветки OS-зависимые скрипты возвращают `result:error` и завершаются с ненулевым кодом.

## FreeBSD-специфика

- Пакеты и зависимости: `pkg`.
- Firewall/сетевые правила: профиль FreeBSD (например `pf`/`ipfw` в зависимости от конфигурации сервера).
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
| `04_setsystemaccess.sh` | Доступ root/SSH/ключ и firewall-профиль FreeBSD |
| `05_setdomain.sh` | Установка `VPCONFIGURE_DOMAIN` |
| `06_setwireguard.sh` | WireGuard (FreeBSD-реализация) |
| `07_setmtproxy.sh` | MTProxy (FreeBSD-реализация) |
| `08_setvpmanage.sh` | VPManage (FreeBSD-реализация) |

## Порядок запуска

```sh
sh ./00_bashinstall.sh
eval "$(bash ./01_getosversion.sh --export | sed -n '2p')"
bash ./01_getosversion.sh --persist   # optional
bash ./02_gitinstall.sh
bash ./03_getconfigure.sh
# затем 04-08 в ветке freebsd
```
