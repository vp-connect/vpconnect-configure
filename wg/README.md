# VPN clients (`vpconnect-configure/wg`) — WireGuard и AmneziaWG

Операционные скрипты после шага **`06_setvpservice.sh`** (тип `wireguard` или `amneziawg`).

Общий runtime: **`vp_runtime.inc.sh`** — выбор бинарников (`wg`/`awg`, `wg-quick`/`awg-quick`), активного конфига и каталогов `/usr/vpserver/client_*`.

| Сервис | Серверный конфиг | syncconf |
|--------|------------------|----------|
| wireguard | `/etc/wireguard/<iface>.conf` | `wg` + `wg-quick` |
| amneziawg | `/etc/amnezia/amneziawg/<iface>.conf` | `awg` + `awg-quick` |

Клиентский `.conf` для AmneziaWG включает параметры обфускации сервера (`Jc`…`H4`).

## Команды

```bash
wg.sh create <name>
wg.sh delete <name>
wg.sh enable|disable <name|--all>
wg.sh list [--all]
```

Подробности — в шапках `*.sh`. Env: `/root/.vpconnect-configure.env`.
