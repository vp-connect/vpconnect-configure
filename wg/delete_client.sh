#!/usr/bin/env bash
# delete_client.sh
#
# Удаление клиента WireGuard: блок от маркера # Client: <имя> в /etc/wireguard/wg0.conf,
# файлы ключей, клиентский .conf и QR. Резервная копия wg0.conf → wg0.conf.bak.
# Применение: wg syncconf wg0.
#
# Использование: один аргумент — имя клиента (как в маркере # Client:).
#
# Пути/параметры должны совпадать с create_client.sh:
# берутся из VPCONFIGURE_* или автоопределяются; ключи/конфиги по умолчанию в /usr/wireguard/client_cert и /usr/wireguard/client_config.
#
# Зависимости: wg, wg-quick; права root.

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

WG_CONF="$(expand_tilde "$WG_CONF")"
KEY_DIR="$(expand_tilde "$KEY_DIR")"
CONFIG_DIR="$(expand_tilde "$CONFIG_DIR")"
QR_DIR="$(expand_tilde "$QR_DIR")"

# Проверка существования клиента
if ! grep -q "^# Client: $NAME$" "$WG_CONF"; then
    echo "Ошибка: клиент с именем $NAME не найден в $WG_CONF"
    exit 1
fi

START_LINE=$(grep -n "^# Client: $NAME$" "$WG_CONF" | cut -d: -f1)

# Определяем конец блока (последняя строка данных перед пустой строкой или следующим клиентом)
END_LINE=""
CURRENT=$((START_LINE + 1))
while IFS= read -r line; do
    if [[ -z "$line" || "$line" =~ ^#\ Client: ]]; then
        END_LINE=$((CURRENT))
        break
    fi
    ((CURRENT++))
done < <(tail -n +$((START_LINE + 1)) "$WG_CONF")

if [ -z "$END_LINE" ]; then
    END_LINE=$(wc -l < "$WG_CONF")
fi

# Резервное копирование
cp "$WG_CONF" "$WG_CONF.bak"

# Создаём временный файл
TMP_FILE=$(mktemp)

# Удаляем строки с START_LINE по END_LINE
sed "${START_LINE},${END_LINE}d" "$WG_CONF" > "$TMP_FILE"

# Нормализуем пустые строки: одна пустая между блоками, нет пустых в начале и конце
awk '
BEGIN { empty=0; first=1 }
/^$/ { empty++; next }
{
    if (!first && empty>0) print ""
    print
    empty=0
    first=0
}
END { }  # Не добавляем пустую строку в конце
' "$TMP_FILE" > "$WG_CONF.new"

mv "$WG_CONF.new" "$WG_CONF"
rm -f "$TMP_FILE"

# Удаление ключей и конфигов клиента
rm -f "$KEY_DIR/${NAME}_private.key" "$KEY_DIR/${NAME}_public.key"
rm -f "$CONFIG_DIR/${NAME}.conf"
rm -f "$QR_DIR/${NAME}.txt"

# Применяем изменения без перезапуска
wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")

echo "✅ Клиент $NAME успешно удалён."