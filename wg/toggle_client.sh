#!/usr/bin/env bash
# toggle_client.sh
#
# Включение или отключение клиента WireGuard без удаления блока: комментирование/раскомментирование
# строк [Peer] и полей внутри блока (см. # Client: <имя>) в /etc/wireguard/wg0.conf.
# Резервная копия wg0.conf.bak; применение wg syncconf wg0.
#
# Использование: <имя_клиента> enable|disable
#
# Статус «disabled» в list_users.sh соответствует закомментированным непустым строкам блока (кроме маркера).
#
# Зависимости: wg, wg-quick; права root.

set -e

_wg_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_wg_dir=$(cd "$(dirname "$_wg_src")" && pwd)
# shellcheck source=detect_wg_iface.inc.sh
source "${_wg_dir}/detect_wg_iface.inc.sh"

if [ $# -ne 2 ]; then
    echo "Использование: $0 <имя_клиента> enable|disable"
    exit 1
fi

NAME=$1
ACTION=$2
WG_IFACE="${VPCONFIGURE_WIREGUARD_INTERFACE_NAME:-$(detect_wg_interface_name)}"
WG_CONF="${VPCONFIGURE_WG_CONF_PATH:-/etc/wireguard/${WG_IFACE}.conf}"

if [ "$ACTION" != "enable" ] && [ "$ACTION" != "disable" ]; then
    echo "Ошибка: второй параметр должен быть enable или disable"
    exit 1
fi

if ! grep -q "^# Client: $NAME$" "$WG_CONF"; then
    echo "Ошибка: клиент с именем $NAME не найден в $WG_CONF"
    exit 1
fi

START_LINE=$(grep -n "^# Client: $NAME$" "$WG_CONF" | cut -d: -f1)
END_LINE=""
CURRENT=$((START_LINE + 1))
while IFS= read -r line; do
    if [[ -z "$line" || "$line" =~ ^#\ Client: ]]; then
        END_LINE=$((CURRENT - 1))
        break
    fi
    ((CURRENT++))
done < <(tail -n +$((START_LINE + 1)) "$WG_CONF")

if [ -z "$END_LINE" ]; then
    END_LINE=$(wc -l < "$WG_CONF")
fi

cp "$WG_CONF" "$WG_CONF.bak"

if [ "$ACTION" = "disable" ]; then
    if [ $END_LINE -ge $((START_LINE + 1)) ]; then
        sed -i "$((START_LINE+1)),$END_LINE s/^/#/" "$WG_CONF"
    fi
    echo "🔒 Клиент $NAME отключён."
else
    if [ $END_LINE -ge $((START_LINE + 1)) ]; then
        sed -i "$((START_LINE+1)),$END_LINE s/^#//" "$WG_CONF"
    fi
    echo "🔓 Клиент $NAME включён."
fi

wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")
echo "✅ Изменения вступили в силу."