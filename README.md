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

Скрипты **`02`–`08`** должны запускаться **после** `01` и опираться на `VPCONFIGURE_GIT_BRANCH`. **`00`** и **`01`** переменную не требуют.

## Строка результата (для автоматики)

Первая строка **stdout** всегда начинается с `result:success`, `result:warning` или `result:error`, далее `; message:текст` и при необходимости `; ключ:значение` (например `branch:debian`). В `message` символ `;` не использовать. Пояснения и лог — в **stderr** (кроме второй строки `01 … --export`: `export VPCONFIGURE_GIT_BRANCH=…`).

## Скрипты

| Файл | Назначение |
|------|------------|
| `00_installbash.sh` | Установить `bash`, если нет (`sh ./00_installbash.sh`) |
| `01_getosversion.sh` | Семейство ОС → `VPCONFIGURE_GIT_BRANCH`, опции `--export`, `--persist` |
| `02_gitinstall.sh` | Установка `git` по семейству |
| `03_getconfigure.sh` | Клон/обновление репозитория (заготовка) |
| `04_setsystemaccess.sh` | Пароль root, SSH‑порт, ключ (заготовка) |
| `05_setdomain.sh` | Hostname / домен (заготовка) |
| `06_setwireguard.sh` | WireGuard (заготовка) |
| `07_setmtproxy.sh` | MTProxy (заготовка) |
| `08_setvpmanage.sh` | VPManage (заготовка) |

## Порядок запуска (пример)

```sh
sh ./00_installbash.sh
eval "$(bash ./01_getosversion.sh --export | sed -n '2p')"
bash ./01_getosversion.sh --persist   # опционально, лог в stderr после result
bash ./02_gitinstall.sh
# далее 03–08 по мере реализации
```

На FreeBSD сначала нужен **bash** (через `00`), остальные шаги — **`bash ./…`**.

## Формат строк в репозитории

Для `*.sh` задано окончание строк **LF** (`.gitattributes`), чтобы на FreeBSD не было ошибки `set: Illegal option -` из‑за CRLF.
