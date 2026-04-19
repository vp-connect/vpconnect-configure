# vpconnect-configure

Скрипты подготовки сервера для установки и обслуживания VPConnect.

## Профиль ветки

Ветка `centos` содержит RHEL/CentOS-like реализацию шагов `04-08`, runtime-скриптов `lib/` и `wg/`.

## Поддерживаемые ОС (CentOS-like / RHEL-like)

- **AlmaLinux**: 9, 10
- **Rocky Linux**: 8, 9
- **Oracle Linux**, **EuroLinux**, **CloudLinux**: 8-10
- **RHEL**: 8-10
- **Fedora**: 39+
- **Amazon Linux**: 2023+
- **VzLinux / Virtuozzo**: 8

## Политика ветки

- `00-03` — универсальные (`freebsd|debian|centos`).
- `04-08`, `lib/`, `wg/` — только для `VPCONFIGURE_GIT_BRANCH=centos`.
- При других значениях ветки OS-зависимые скрипты возвращают `result:error` и завершаются с ненулевым кодом.

## CentOS-специфика

- Пакеты и зависимости: `dnf`/`yum`.
- Firewall: `firewalld` и `firewall-cmd`.
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
| `04_setsystemaccess.sh` | Доступ root/SSH/ключ и `firewalld` |
| `05_setdomain.sh` | Установка `VPCONFIGURE_DOMAIN` |
| `06_setwireguard.sh` | WireGuard (CentOS-реализация) |
| `07_setmtproxy.sh` | MTProxy (CentOS-реализация) |
| `08_setvpmanage.sh` | VPManage (CentOS-реализация) |

## Порядок запуска

```sh
sh ./00_bashinstall.sh
eval "$(bash ./01_getosversion.sh --export | sed -n '2p')"
bash ./01_getosversion.sh --persist   # optional
bash ./02_gitinstall.sh
bash ./03_getconfigure.sh
# затем 04-08 в ветке centos
```
