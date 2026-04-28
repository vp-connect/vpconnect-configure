# MTProxy: вспомогательные скрипты (`vpconnect-configure/mt`)

Набор операционных скриптов для управления **секретом MTProxy** на уже настроенном сервере
(после `07_setmtproxy.sh` или эквивалента).

В этой ветке все `mt/*.sh` ожидают `VPCONFIGURE_GIT_BRANCH=debian` и завершаются с ошибкой при других значениях.

## Состав

| Файл | Назначение |
|------|------------|
| `set_secret.sh` | Установить конкретный секрет MTProxy (32 hex или `dd` + 32 hex), обновить существующие файлы и unit MTProxy. |
| `new_secret.sh` | Сгенерировать новый 32-hex секрет и передать в `set_secret.sh`. |
| `mt.sh` | Общая оболочка: `set <secret>` и `new`. |

## Что обновляет `set_secret.sh`

Скрипт **не создаёт** отсутствующие файлы, а обновляет только существующие:

- `VPCONFIGURE_MTPROXY_SECRET_PATH` (или вычисленный путь по умолчанию),
- `VPCONFIGURE_MTPROXY_LINK_PATH` (первая непустая строка `tg://proxy?...secret=dd...`),
- `/etc/systemd/system/mtproxy.service` или `/etc/systemd/system/mtproto-proxy.service` (если найден `-S <secret>`).

После обновления unit-файла выполняется `systemctl daemon-reload` и попытка `systemctl restart mtproxy`/`mtproto-proxy`.

## Переменные окружения

При наличии файла `/root/.vpconnect-configure.env` скрипты подхватывают его автоматически.
Используются (если заданы):

- `VPCONFIGURE_MTPROXY_SECRET_PATH`
- `VPCONFIGURE_MTPROXY_LINK_PATH`
- `VPCONFIGURE_WG_PRIVATE_KEY_PATH` (для вычисления default secret path)
- `VPCONFIGURE_WG_CLIENT_CONFIG_PATH` (для вычисления default link path)

## Примеры

```bash
# Установить конкретный секрет
bash ./mt/set_secret.sh 0123456789abcdef0123456789abcdef

# Сгенерировать и сразу применить новый секрет
bash ./mt/new_secret.sh

# Через оболочку
bash ./mt/mt.sh set dd0123456789abcdef0123456789abcdef
bash ./mt/mt.sh new
```
