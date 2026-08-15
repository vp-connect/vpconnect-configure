#!/usr/bin/env bash
# create_client.sh
#
# Создание VPN-клиента (wireguard | amneziawg): ключи, запись [Peer] в активный серверный
# конфиг, клиентский .conf (+ параметры обфускации для amneziawg), QR, syncconf.
#
# Использование: один аргумент — имя клиента (маркер # Client:).
#
# Параметры из /root/.vpconnect-configure.env и VPCONFIGURE_*:
#   VPCONFIGURE_VPSERVER_TYPE / VPCONFIGURE_VP_* / legacy VPCONFIGURE_WG_*
#
# Зависимости: wg|awg, wg-quick|awg-quick, qrencode; root.
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
vp_require_os_branch centos "create_client.sh"
vp_require_root

VP_BIN="$(vp_bin)"
VP_QUICK="$(vp_quick_bin)"
vp_require_cmd "$VP_BIN"
vp_require_cmd "$VP_QUICK"
vp_require_cmd qrencode

WG_IFACE="$(vp_iface_name)"
WG_CONF="$(vp_conf_path)"
MIRROR_CONF="$(vp_mirror_conf_path || true)"
KEY_DIR="$(vp_client_cert_dir)"
CONFIG_DIR="$(vp_client_config_dir)"
QR_DIR="$CONFIG_DIR/qr"
DNS="${VPCONFIGURE_WIREGUARD_DNS:-8.8.8.8}"
SVC_TYPE="$(vp_service_type)"

if [[ ! -f "$WG_CONF" ]]; then
    echo "Ошибка: файл конфигурации $WG_CONF не найден" >&2
    exit 1
fi

SERVER_PUBLIC_KEY=''
if [[ -n "${VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH:-${VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH:-}}" ]]; then
    _pk="$(vp_expand_tilde "${VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH:-$VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH}")"
    if [[ -f "$_pk" ]]; then
        SERVER_PUBLIC_KEY=$(tr -d '\r\n' <"$_pk")
    fi
fi
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    SERVER_PUBLIC_KEY=$("$VP_BIN" show "$WG_IFACE" public-key 2>/dev/null | tr -d '\r\n' || true)
fi
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    echo "Ошибка: не удалось определить публичный ключ сервера." >&2
    exit 1
fi

SERVER_ENDPOINT=''
if [[ -n "${VPCONFIGURE_WIREGUARD_ENDPOINT:-}" ]]; then
    SERVER_ENDPOINT=$(printf '%s' "$VPCONFIGURE_WIREGUARD_ENDPOINT" | tr -d '\r\n')
else
    _host=$(printf '%s' "${VPCONFIGURE_DOMAIN:-}" | tr -d '\r\n')
    _port=$(printf '%s' "${VPCONFIGURE_VP_PORT:-${VPCONFIGURE_WG_PORT:-}}" | tr -d '\r\n')
    if [[ -n "$_host" && -n "$_port" ]]; then
        SERVER_ENDPOINT="${_host}:${_port}"
    fi
fi
if [[ -z "$SERVER_ENDPOINT" ]]; then
    echo "Ошибка: не удалось определить endpoint (VPCONFIGURE_WIREGUARD_ENDPOINT или DOMAIN+PORT)." >&2
    exit 1
fi

if grep -q "^# Client: $NAME$" "$WG_CONF" 2>/dev/null; then
    echo "Ошибка: клиент с именем $NAME уже существует."
    exit 1
fi

mkdir -p "$KEY_DIR" "$CONFIG_DIR" "$QR_DIR"
chmod 755 "$KEY_DIR" "$CONFIG_DIR" "$QR_DIR" 2>/dev/null || true

PRIVATE_KEY="$KEY_DIR/${NAME}_private.key"
PUBLIC_KEY="$KEY_DIR/${NAME}_public.key"
"$VP_BIN" genkey | tee "$PRIVATE_KEY" | "$VP_BIN" pubkey > "$PUBLIC_KEY"
chmod 600 "$PRIVATE_KEY"
chmod 644 "$PUBLIC_KEY"

SERVER_ADDR_CIDR=$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF")
SERVER_ADDR_IP=${SERVER_ADDR_CIDR%%/*}
SERVER_PREFIX=${SERVER_ADDR_IP%.*}.
if [[ -z "$SERVER_ADDR_IP" || "$SERVER_PREFIX" != *.*.*. ]]; then
    echo "Ошибка: не удалось определить Address из $WG_CONF (ожидается IPv4 Address = A.B.C.D/24)" >&2
    exit 1
fi

declare -A used_ips
while IFS= read -r line; do
    if [[ "$line" =~ AllowedIPs[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)/32 ]]; then
        if [[ "${BASH_REMATCH[1]}." == "$SERVER_PREFIX" ]]; then
            used_ips["${BASH_REMATCH[2]}"]=1
        fi
    fi
done < "$WG_CONF"

CLIENT_IP=""
for ((i=2; i<=254; i++)); do
    if [[ -z "${used_ips[$i]}" ]]; then
        CLIENT_IP="${SERVER_PREFIX}${i}"
        break
    fi
done

if [ -z "$CLIENT_IP" ]; then
    echo "Ошибка: нет свободных IP в подсети ${SERVER_PREFIX}0/24"
    exit 1
fi

PEER_BLOCK=$(cat <<EOF

# Client: $NAME
[Peer]
PublicKey = $(cat "$PUBLIC_KEY")
AllowedIPs = $CLIENT_IP/32
EOF
)

append_peer() {
    local conf=$1
    [[ -f "$conf" ]] || return 0
    if grep -q "^# Client: $NAME$" "$conf" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$PEER_BLOCK" >> "$conf"
}

append_peer "$WG_CONF"
if [[ -n "${MIRROR_CONF:-}" ]]; then
    append_peer "$MIRROR_CONF"
fi

CLIENT_CONF="$CONFIG_DIR/${NAME}.conf"
{
    echo "[Interface]"
    echo "PrivateKey = $(cat "$PRIVATE_KEY")"
    echo "Address = $CLIENT_IP/24"
    echo "DNS = $DNS"
    if [[ "$SVC_TYPE" == "amneziawg" ]]; then
        vp_server_obfuscation_lines "$WG_CONF"
    fi
    echo ""
    echo "[Peer]"
    echo "PublicKey = $SERVER_PUBLIC_KEY"
    echo "Endpoint = $SERVER_ENDPOINT"
    echo "AllowedIPs = 0.0.0.0/0"
    echo "PersistentKeepalive = 25"
} > "$CLIENT_CONF"
chmod 600 "$CLIENT_CONF"

QR_FILE="$QR_DIR/${NAME}.txt"
qrencode -t ansiutf8 < "$CLIENT_CONF" > "$QR_FILE"
chmod 644 "$QR_FILE"

vp_syncconf

echo "✅ Клиент $NAME успешно создан (${SVC_TYPE})."
echo "   IP клиента: $CLIENT_IP"
echo "   Конфигурация: $CLIENT_CONF"
echo "   QR-код: $QR_FILE"
