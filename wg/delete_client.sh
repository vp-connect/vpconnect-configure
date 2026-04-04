#!/usr/bin/env bash
# delete_client.sh
#
# Удаление клиента WireGuard: блок от маркера # Client: <имя> в /etc/wireguard/wg0.conf,
# файлы ключей, клиентский .conf и QR. Резервная копия wg0.conf → wg0.conf.bak.
# Применение: wg syncconf wg0.
#
# Использование: один аргумент — имя клиента (как в маркере # Client:).
#
# Пути должны совпадать с create_client.sh:
#   WG_CONF, KEY_DIR=/usr/wireguard/client_sert, CONFIG_DIR, QR_DIR
#
# Зависимости: wg, wg-quick; права root.

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
wg syncconf wg0 <(wg-quick strip wg0)

echo "✅ Клиент $NAME успешно удалён."