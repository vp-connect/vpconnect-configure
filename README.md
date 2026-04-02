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
