#!/usr/bin/env bash
# create_client.sh
#
# Создание клиента WireGuard: ключи, запись [Peer] в /etc/wireguard/wg0.conf, клиентский .conf,
# QR (ansiutf8) в каталог qr. Применение без полного перезапуска: wg syncconf wg0.
#
# Использование: один аргумент — имя клиента (латиница/без пробелов в имени маркера # Client:).
#
# Параметры берутся из:
# - переменных окружения `VPCONFIGURE_*` (обычно пишет 06_setwireguard.sh и 05_setdomain.sh)
# - и/или автоопределяются по конфигу `/etc/wireguard/<iface>.conf`.
#
# Ожидаемые переменные (опционально):
#   VPCONFIGURE_WIREGUARD_INTERFACE_NAME  — имя интерфейса (если нет — автоопределение)
#   VPCONFIGURE_WG_CONF_PATH              — путь к конфигу wg (если нет — /etc/wireguard/<iface>.conf)
#   VPCONFIGURE_WG_CLIENT_CERT_PATH       — каталог ключей клиентов (если нет — /usr/wireguard/client_cert)
#   VPCONFIGURE_WG_CLIENT_CONFIG_PATH     — каталог клиентских *.conf (если нет — /usr/wireguard/client_config)
#   VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH — путь к публичному ключу сервера (если нет — извлекаем из wg conf)
#   VPCONFIGURE_WIREGUARD_DNS             — DNS для клиентов (если нет — 8.8.8.8)
#   VPCONFIGURE_WIREGUARD_ENDPOINT        — endpoint host:port (если нет — VPCONFIGURE_DOMAIN + VPCONFIGURE_WG_PORT)
#   VPCONFIGURE_DOMAIN                    — публичный IP/FQDN сервера (для endpoint, если не задан VPCONFIGURE_WIREGUARD_ENDPOINT)
#
# Подсеть клиентов берётся из `Address = ...` в конфиге сервера:
# например `10.8.0.1/24` → клиенты `10.8.0.2..254`.
#
# Зависимости: wg, wg-quick, qrencode; права root.

set -e

_wg_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_wg_dir=$(cd "$(dirname "$_wg_src")" && pwd)
# shellcheck source=detect_wg_iface.inc.sh
source "${_wg_dir}/detect_wg_iface.inc.sh"

expand_tilde() {
    local p=$1
    if [[ "$p" == '~' || "$p" == ~/* ]]; then
        p="${p/\~/$HOME}"
    fi
    printf '%s' "$p"
}

vpconfigure_source_saved_env() {
    local f=${1:-/root/.vpconnect-configure.env}
    f="$(expand_tilde "$f")"
    [[ -r "$f" ]] || return 0
    # shellcheck disable=SC1090
    set -a
    . "$f"
    set +a
}

if [ $# -ne 1 ]; then
    echo "Использование: $0 <имя_клиента>"
    exit 1
fi

NAME=$1
vpconfigure_source_saved_env "/root/.vpconnect-configure.env"
WG_IFACE="${VPCONFIGURE_WIREGUARD_INTERFACE_NAME:-$(detect_wg_interface_name)}"
WG_CONF="${VPCONFIGURE_WG_CONF_PATH:-/etc/wireguard/${WG_IFACE}.conf}"
KEY_DIR="${VPCONFIGURE_WG_CLIENT_CERT_PATH:-/usr/wireguard/client_cert}"
CONFIG_DIR="${VPCONFIGURE_WG_CLIENT_CONFIG_PATH:-/usr/wireguard/client_config}"
QR_DIR="$CONFIG_DIR/qr"
DNS="${VPCONFIGURE_WIREGUARD_DNS:-8.8.8.8}"

WG_CONF="$(expand_tilde "$WG_CONF")"
KEY_DIR="$(expand_tilde "$KEY_DIR")"
CONFIG_DIR="$(expand_tilde "$CONFIG_DIR")"
QR_DIR="$(expand_tilde "$QR_DIR")"

if [[ ! -f "$WG_CONF" ]]; then
    echo "Ошибка: файл конфигурации $WG_CONF не найден" >&2
    exit 1
fi

SERVER_PUBLIC_KEY=''
if [[ -n "${VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH:-}" && -f "$(expand_tilde "$VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH")" ]]; then
    SERVER_PUBLIC_KEY=$(cat "$(expand_tilde "$VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH")" | tr -d '\r\n')
else
    # fallback: вытащить публичный ключ сервера из текущего интерфейса
    if command -v wg >/dev/null 2>&1; then
        SERVER_PUBLIC_KEY=$(wg show "$WG_IFACE" public-key 2>/dev/null | tr -d '\r\n' || true)
    fi
fi
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    echo "Ошибка: не удалось определить публичный ключ сервера (VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH или wg show)." >&2
    exit 1
fi

SERVER_ENDPOINT=''
if [[ -n "${VPCONFIGURE_WIREGUARD_ENDPOINT:-}" ]]; then
    SERVER_ENDPOINT=$(printf '%s' "$VPCONFIGURE_WIREGUARD_ENDPOINT" | tr -d '\r\n')
else
    _host=$(printf '%s' "${VPCONFIGURE_DOMAIN:-}" | tr -d '\r\n')
    _port=$(printf '%s' "${VPCONFIGURE_WG_PORT:-}" | tr -d '\r\n')
    if [[ -n "$_host" && -n "$_port" ]]; then
        SERVER_ENDPOINT="${_host}:${_port}"
    fi
fi
if [[ -z "$SERVER_ENDPOINT" ]]; then
    echo "Ошибка: не удалось определить endpoint (VPCONFIGURE_WIREGUARD_ENDPOINT или VPCONFIGURE_DOMAIN+VPCONFIGURE_WG_PORT)." >&2
    exit 1
fi

# Проверка существования клиента
if grep -q "^# Client: $NAME$" "$WG_CONF" 2>/dev/null; then
    echo "Ошибка: клиент с именем $NAME уже существует."
    exit 1
fi

# Создание директорий
mkdir -p "$KEY_DIR" "$CONFIG_DIR" "$QR_DIR"
chmod 755 "$KEY_DIR" "$CONFIG_DIR" "$QR_DIR" 2>/dev/null || true

# Генерация ключей
PRIVATE_KEY="$KEY_DIR/${NAME}_private.key"
PUBLIC_KEY="$KEY_DIR/${NAME}_public.key"
wg genkey | tee "$PRIVATE_KEY" | wg pubkey > "$PUBLIC_KEY"
chmod 600 "$PRIVATE_KEY"
chmod 644 "$PUBLIC_KEY"

# Определение /24 подсети по Address в конфиге сервера (берём первый Address).
SERVER_ADDR_CIDR=$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF")
SERVER_ADDR_IP=${SERVER_ADDR_CIDR%%/*}
SERVER_PREFIX=${SERVER_ADDR_IP%.*}.   # "10.8.0."
if [[ -z "$SERVER_ADDR_IP" || "$SERVER_PREFIX" != *.*.*. ]]; then
    echo "Ошибка: не удалось определить Address из $WG_CONF (ожидается IPv4 Address = A.B.C.D/24)" >&2
    exit 1
fi

# Поиск свободного IP (от 2 до 254) в этой /24
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

# Добавление пира в конфигурацию сервера
{
    echo ""
    echo "# Client: $NAME"
    echo "[Peer]"
    echo "PublicKey = $(cat "$PUBLIC_KEY")"
    echo "AllowedIPs = $CLIENT_IP/32"
} >> "$WG_CONF"

# Создание конфигурации клиента
CLIENT_CONF="$CONFIG_DIR/${NAME}.conf"
cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $(cat "$PRIVATE_KEY")
Address = $CLIENT_IP/24
DNS = $DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"

# Генерация QR-кода (текстовый файл с ANSI-графикой)
QR_FILE="$QR_DIR/${NAME}.txt"
qrencode -t ansiutf8 < "$CLIENT_CONF" > "$QR_FILE"
chmod 644 "$QR_FILE"

# Применение изменений без перезапуска
wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")

echo "✅ Клиент $NAME успешно создан."
echo "   IP клиента: $CLIENT_IP"
echo "   Конфигурация: $CLIENT_CONF"
echo "   QR-код: $QR_FILE"