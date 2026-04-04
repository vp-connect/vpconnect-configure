#!/usr/bin/env bash
# wg.sh
#
# Удобная обёртка над установленными в /usr/local/bin скриптами управления клиентами WireGuard.
# Не часть нумерованной цепочки 00–08; предполагается уже настроенный wg0 (см. 06_setwireguard.sh).
#
# Вызываемые пути (должны существовать и быть исполняемыми):
#   /usr/local/bin/create_client.sh, delete_client.sh, toggle_client.sh, list_users.sh
#
# Команды (первый аргумент):
#   help, -h          — справка в stderr
#   create, -c NAME  — создать клиента
#   delete NAME      — удалить клиента
#   enable NAME | enable --all | -e …  — включить пира (или всех «отключённых»)
#   disable NAME | disable --all | -d … — отключить пира (или всех «активных»)
#   list, -l [--all] — список (по умолчанию только активные; --all — все с пометкой статуса)
#
# Сообщения об ошибках и цветной вывод — в stderr/stdout; единой строки result:… нет (в отличие от 06–08).

set -e

CREATE_SCRIPT="/usr/local/bin/create_client.sh"
DELETE_SCRIPT="/usr/local/bin/delete_client.sh"
TOGGLE_SCRIPT="/usr/local/bin/toggle_client.sh"
LIST_SCRIPT="/usr/local/bin/list_users.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Использование: wg.sh <команда> [параметры]"
    echo ""
    echo "Команды:"
    echo "  help, -h                          Показать эту справку"
    echo "  create, -c <client_name>          Создать нового клиента"
    echo "  delete <client_name>               Удалить клиента"
    echo "  enable [--all] [client_name]       Включить клиента (или всех отключенных с --all)"
    echo "  disable [--all] [client_name]      Отключить клиента (или всех активных с --all)"
    echo "  list, -l [--all]                   Показать список клиентов (с --all всех, иначе только активных)"
    echo ""
    echo "Примеры:"
    echo "  wg.sh create john"
    echo "  wg.sh disable john"
    echo "  wg.sh enable --all"
    echo "  wg.sh list --all"
}

check_scripts() {
    for script in "$CREATE_SCRIPT" "$DELETE_SCRIPT" "$TOGGLE_SCRIPT" "$LIST_SCRIPT"; do
        if [ ! -x "$script" ]; then
            echo -e "${RED}Ошибка: скрипт $script не найден или не исполняемый${NC}"
            exit 1
        fi
    done
}

toggle_all() {
    local action=$1
    local opt
    if [ "$action" == "enable" ]; then
        opt="--disabled"
    else
        opt="--enabled"
    fi

    mapfile -t clients < <($LIST_SCRIPT "$opt" --names-only)

    if [ ${#clients[@]} -eq 0 ]; then
        echo -e "${YELLOW}Нет клиентов со статусом $( [ "$action" == "enable" ] && echo "отключен" || echo "активен" ).${NC}"
        return
    fi

    for client in "${clients[@]}"; do
        echo -e "${YELLOW}Применяем $action к $client...${NC}"
        $TOGGLE_SCRIPT "$client" "$action"
    done
    echo -e "${GREEN}Готово.${NC}"
}

check_scripts

COMMAND="$1"
shift

case "$COMMAND" in
    help|-h)
        usage
        ;;
    create|-c)
        if [ -z "$1" ]; then
            echo -e "${RED}Ошибка: укажите имя клиента${NC}"
            exit 1
        fi
        $CREATE_SCRIPT "$1"
        ;;
    delete)
        if [ -z "$1" ]; then
            echo -e "${RED}Ошибка: укажите имя клиента${NC}"
            exit 1
        fi
        $DELETE_SCRIPT "$1"
        ;;
    enable|-e)
        if [ "$1" == "--all" ]; then
            toggle_all "enable"
        else
            if [ -z "$1" ]; then
                echo -e "${RED}Ошибка: укажите имя клиента или --all${NC}"
                exit 1
            fi
            $TOGGLE_SCRIPT "$1" "enable"
        fi
        ;;
    disable|-d)
        if [ "$1" == "--all" ]; then
            toggle_all "disable"
        else
            if [ -z "$1" ]; then
                echo -e "${RED}Ошибка: укажите имя клиента или --all${NC}"
                exit 1
            fi
            $TOGGLE_SCRIPT "$1" "disable"
        fi
        ;;
    list|-l)
        if [ "$1" == "--all" ]; then
            $LIST_SCRIPT --all
        else
            $LIST_SCRIPT --enabled
        fi
        ;;
    *)
        echo -e "${RED}Неизвестная команда: $COMMAND${NC}"
        usage
        exit 1
        ;;
esac