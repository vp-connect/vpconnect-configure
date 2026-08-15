#!/usr/bin/env bash
# list_users.sh
#
# Чтение списка клиентов из активного VPN-конфига (wireguard|/etc/amnezia/amneziawg) по маркерам «# Client: <имя>» и блокам [Peer].
# Активный клиент — блок, где есть хотя бы одна непустая строка, не начинающаяся с # (раскомментированный [Peer]).
# Отключённый — блок из закомментированных строк (как после toggle_client.sh disable).
#
# Опции (можно комбинировать только осмысленно; по умолчанию без флагов эквивалентно --enabled):
#   --all         — все клиенты (с цветом и статусом enabled/disabled)
#   --enabled     — только активные
#   --disabled    — только отключённые
#   --names-only  — только имена по одной на строку (без цвета и без пометки статуса)
#
# Вывод: stdout; ошибки (нет файла, неизвестная опция) — stderr, код выхода 1.
#
# Используется из wg.sh с флагом --names-only для массовых enable/disable --all.
# В debian-ветке допускается только VPCONFIGURE_GIT_BRANCH=freebsd.

_wg_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_wg_dir=$(cd "$(dirname "$_wg_src")" && pwd)
# shellcheck source=detect_wg_iface.inc.sh
source "${_wg_dir}/detect_wg_iface.inc.sh"
# shellcheck source=vp_runtime.inc.sh
source "${_wg_dir}/vp_runtime.inc.sh"
set -e

vp_source_saved_env "/root/.vpconnect-configure.env"
vp_require_os_branch freebsd "list_users.sh"
WG_IFACE="$(vp_iface_name)"
WG_CONF="$(vp_conf_path)"
COLOR_ENABLE="\e[32m"
COLOR_DISABLE="\e[31m"
COLOR_RESET="\e[0m"

if [ ! -f "$WG_CONF" ]; then
    echo "Файл конфигурации $WG_CONF не найден" >&2
    exit 1
fi

MODE="enabled"      # по умолчанию только активные
NAMES_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            MODE="all"
            shift
            ;;
        --enabled)
            MODE="enabled"
            shift
            ;;
        --disabled)
            MODE="disabled"
            shift
            ;;
        --names-only)
            NAMES_ONLY=true
            shift
            ;;
        *)
            echo "Неизвестная опция: $1" >&2
            exit 1
            ;;
    esac
done

declare -A clients
current_client=""
in_block=false
block_lines=()

check_client_status() {
    local name="$1"
    shift
    local lines=("$@")
    local enabled=false
    for line in "${lines[@]}"; do
        [[ -z "$line" ]] && continue
        if [[ "$line" != \#* ]]; then
            enabled=true
            break
        fi
    done
    if $enabled; then
        clients["$name"]="enabled"
    else
        clients["$name"]="disabled"
    fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^#\ Client:\ (.*)$ ]]; then
        if [ -n "$current_client" ]; then
            check_client_status "$current_client" "${block_lines[@]}"
        fi
        current_client="${BASH_REMATCH[1]}"
        block_lines=()
        in_block=true
    elif $in_block; then
        if [[ -z "$line" ]] || [[ "$line" =~ ^#\ Client: ]]; then
            check_client_status "$current_client" "${block_lines[@]}"
            current_client=""
            in_block=false
            block_lines=()
            if [[ "$line" =~ ^#\ Client: ]]; then
                current_client="${BASH_REMATCH[1]}"
                block_lines=()
                in_block=true
            fi
        else
            block_lines+=("$line")
        fi
    fi
done < "$WG_CONF"

if [ -n "$current_client" ]; then
    check_client_status "$current_client" "${block_lines[@]}"
fi

for client in $(echo "${!clients[@]}" | tr ' ' '\n' | sort); do
    status="${clients[$client]}"
    case "$MODE" in
        all)
            if $NAMES_ONLY; then
                echo "$client"
            else
                if [ "$status" == "enabled" ]; then
                    echo -e "${COLOR_ENABLE}${client} (enabled)${COLOR_RESET}"
                else
                    echo -e "${COLOR_DISABLE}${client} (disabled)${COLOR_RESET}"
                fi
            fi
            ;;
        enabled)
            if [ "$status" == "enabled" ]; then
                if $NAMES_ONLY; then
                    echo "$client"
                else
                    echo -e "${COLOR_ENABLE}${client}${COLOR_RESET}"
                fi
            fi
            ;;
        disabled)
            if [ "$status" == "disabled" ]; then
                if $NAMES_ONLY; then
                    echo "$client"
                else
                    echo -e "${COLOR_DISABLE}${client}${COLOR_RESET}"
                fi
            fi
            ;;
    esac
done
