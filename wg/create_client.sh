#!/usr/bin/env bash
# create_client.sh
#
# Создание клиента WireGuard: ключи, запись [Peer] в /etc/wireguard/wg0.conf, клиентский .conf,
# QR (ansiutf8) в каталог qr. Применение без полного перезапуска: wg syncconf wg0.
#
# Использование: один аргумент — имя клиента (латиница/без пробелов в имени маркера # Client:).
#
# Пути (при необходимости приведите в соответствие с 06_setwireguard.sh):
#   WG_CONF=/etc/wireguard/wg0.conf
#   KEY_DIR=/usr/wireguard/client_sert  (в коде; на сервере часто client_cert)
#   CONFIG_DIR=/usr/wireguard/client_config, QR_DIR=$CONFIG_DIR/qr
#
# Перед использованием обязательно задайте в теле скрипта:
#   SERVER_PUBLIC_KEY — публичный ключ сервера
#   SERVER_ENDPOINT   — внешний IP или DNS:порт WireGuard
#   DNS               — DNS для клиента в .conf
#
# Подсеть клиентов: 10.0.0.2–10.0.0.254/32 в AllowedIPs пира (поиск свободного адреса по wg0.conf).
#
# Зависимости: wg, wg-quick, qrencode; права root.

set -e

if [ $# -ne 1 ]; then
    echo "Использование: $0 <имя_клиента>"
    exit 1
fi

NAME=$1
WG_CONF="/etc/wireguard/wg0.conf"
KEY_DIR="/usr/wireguard/client_sert"
CONFIG_DIR="/usr/wireguard/client_config"
QR_DIR="$CONFIG_DIR/qr"
SERVER_PUBLIC_KEY="gy4cOIyxRqhkVi4ACdi6hRTe8Kbo3ze1Nn1WXMOSrw0="   # замените на ваш публичный ключ сервера
SERVER_ENDPOINT="193.109.84.22:443"
DNS="8.8.8.8"

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

# Поиск свободного IP (от 2 до 254)
declare -A used_ips
while IFS= read -r line; do
    if [[ "$line" =~ AllowedIPs[[:space:]]*=[[:space:]]*10\.0\.0\.([0-9]+)/32 ]]; then
        used_ips["${BASH_REMATCH[1]}"]=1
    fi
done < "$WG_CONF"

CLIENT_IP=""
for ((i=2; i<=254; i++)); do
    if [[ -z "${used_ips[$i]}" ]]; then
        CLIENT_IP="10.0.0.$i"
        break
    fi
done

if [ -z "$CLIENT_IP" ]; then
    echo "Ошибка: нет свободных IP в подсети 10.0.0.0/24"
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
wg syncconf wg0 <(wg-quick strip wg0)

echo "✅ Клиент $NAME успешно создан."
echo "   IP клиента: $CLIENT_IP"
echo "   Конфигурация: $CLIENT_CONF"
echo "   QR-код: $QR_FILE"