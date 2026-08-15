#!/usr/bin/env bash
# delete_client.sh
#
# Удаление VPN-клиента (wireguard | amneziawg): блок # Client: из активного конфига
# (+ зеркало), ключи/конфиг/QR, syncconf.
#
# Использование: один аргумент — имя клиента.
# В debian-ветке допускается только VPCONFIGURE_GIT_BRANCH=centos.

set -e

_wg_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_wg_dir=$(cd "$(dirname "$_wg_src")" && pwd)
# shellcheck source=detect_wg_iface.inc.sh
source "${_wg_dir}/detect_wg_iface.inc.sh"
# shellcheck source=vp_runtime.inc.sh
source "${_wg_dir}/vp_runtime.inc.sh"

if [ $# -ne 1 ]; then
    echo "Использование: $0 <имя_клиента>"
    exit 1
fi

NAME=$1
vp_source_saved_env "/root/.vpconnect-configure.env"
vp_require_os_branch centos "delete_client.sh"
vp_require_root

VP_BIN="$(vp_bin)"
VP_QUICK="$(vp_quick_bin)"
vp_require_cmd "$VP_BIN"
vp_require_cmd "$VP_QUICK"

WG_CONF="$(vp_conf_path)"
MIRROR_CONF="$(vp_mirror_conf_path || true)"
KEY_DIR="$(vp_client_cert_dir)"
CONFIG_DIR="$(vp_client_config_dir)"
QR_DIR="$CONFIG_DIR/qr"

remove_client_from_conf() {
    local conf=$1
    [[ -f "$conf" ]] || return 0
    if ! grep -q "^# Client: $NAME$" "$conf"; then
        return 0
    fi
    local START_LINE END_LINE CURRENT TMP_FILE
    START_LINE=$(grep -n "^# Client: $NAME$" "$conf" | cut -d: -f1)
    END_LINE=""
    CURRENT=$((START_LINE + 1))
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" =~ ^#\ Client: ]]; then
            END_LINE=$((CURRENT))
            break
        fi
        ((CURRENT++))
    done < <(tail -n +$((START_LINE + 1)) "$conf")
    if [ -z "$END_LINE" ]; then
        END_LINE=$(wc -l < "$conf")
    fi
    cp "$conf" "$conf.bak"
    TMP_FILE=$(mktemp)
    sed "${START_LINE},${END_LINE}d" "$conf" > "$TMP_FILE"
    awk '
BEGIN { empty=0; first=1 }
/^$/ { empty++; next }
{
    if (!first && empty>0) print ""
    print
    empty=0
    first=0
}
' "$TMP_FILE" > "$conf.new"
    mv "$conf.new" "$conf"
    rm -f "$TMP_FILE"
}

if [[ ! -f "$WG_CONF" ]] || ! grep -q "^# Client: $NAME$" "$WG_CONF"; then
    echo "Ошибка: клиент с именем $NAME не найден в $WG_CONF"
    exit 1
fi

remove_client_from_conf "$WG_CONF"
if [[ -n "${MIRROR_CONF:-}" ]]; then
    remove_client_from_conf "$MIRROR_CONF"
fi

rm -f "$KEY_DIR/${NAME}_private.key" "$KEY_DIR/${NAME}_public.key"
rm -f "$CONFIG_DIR/${NAME}.conf"
rm -f "$QR_DIR/${NAME}.txt"

vp_syncconf

echo "✅ Клиент $NAME успешно удалён."
