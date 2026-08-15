#!/usr/bin/env bash
# toggle_client.sh
#
# Включение/отключение VPN-клиента (wireguard | amneziawg) комментированием блока [Peer].
# Использование: <имя_клиента> enable|disable
# В debian-ветке допускается только VPCONFIGURE_GIT_BRANCH=freebsd.

set -e

_wg_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_wg_dir=$(cd "$(dirname "$_wg_src")" && pwd)
# shellcheck source=detect_wg_iface.inc.sh
source "${_wg_dir}/detect_wg_iface.inc.sh"
# shellcheck source=vp_runtime.inc.sh
source "${_wg_dir}/vp_runtime.inc.sh"

if [ $# -ne 2 ]; then
    echo "Использование: $0 <имя_клиента> enable|disable"
    exit 1
fi

NAME=$1
ACTION=$2
vp_source_saved_env "/root/.vpconnect-configure.env"
vp_require_os_branch freebsd "toggle_client.sh"
vp_require_root

VP_BIN="$(vp_bin)"
VP_QUICK="$(vp_quick_bin)"
vp_require_cmd "$VP_BIN"
vp_require_cmd "$VP_QUICK"

WG_CONF="$(vp_conf_path)"
MIRROR_CONF="$(vp_mirror_conf_path || true)"

if [ "$ACTION" != "enable" ] && [ "$ACTION" != "disable" ]; then
    echo "Ошибка: второй параметр должен быть enable или disable"
    exit 1
fi

toggle_in_conf() {
    local conf=$1
    [[ -f "$conf" ]] || return 0
    if ! grep -q "^# Client: $NAME$" "$conf"; then
        return 0
    fi
    local START_LINE END_LINE CURRENT
    START_LINE=$(grep -n "^# Client: $NAME$" "$conf" | cut -d: -f1)
    END_LINE=""
    CURRENT=$((START_LINE + 1))
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" =~ ^#\ Client: ]]; then
            END_LINE=$((CURRENT - 1))
            break
        fi
        ((CURRENT++))
    done < <(tail -n +$((START_LINE + 1)) "$conf")
    if [ -z "$END_LINE" ]; then
        END_LINE=$(wc -l < "$conf")
    fi
    cp "$conf" "$conf.bak"
    if [ "$ACTION" = "disable" ]; then
        if [ "$END_LINE" -ge $((START_LINE + 1)) ]; then
            sed -i "$((START_LINE+1)),$END_LINE s/^/#/" "$conf"
        fi
    else
        if [ "$END_LINE" -ge $((START_LINE + 1)) ]; then
            sed -i "$((START_LINE+1)),$END_LINE s/^#//" "$conf"
        fi
    fi
}

if [[ ! -f "$WG_CONF" ]] || ! grep -q "^# Client: $NAME$" "$WG_CONF"; then
    echo "Ошибка: клиент с именем $NAME не найден в $WG_CONF"
    exit 1
fi

toggle_in_conf "$WG_CONF"
if [[ -n "${MIRROR_CONF:-}" ]]; then
    toggle_in_conf "$MIRROR_CONF"
fi

if [ "$ACTION" = "disable" ]; then
    echo "🔒 Клиент $NAME отключён."
else
    echo "🔓 Клиент $NAME включён."
fi

vp_syncconf
echo "✅ Изменения вступили в силу."
