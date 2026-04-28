#!/usr/bin/env bash
# mt.sh
#
# Обёртка управления секретом MTProxy:
# - set <secret>   : установить конкретный секрет
# - new            : сгенерировать новый и установить

set -e

_mt_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_mt_dir=$(cd "$(dirname "$_mt_src")" && pwd)

SET_SCRIPT="${_mt_dir}/set_secret.sh"
NEW_SCRIPT="${_mt_dir}/new_secret.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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

require_debian_branch() {
  local b
  b=$(printf '%s' "${VPCONFIGURE_GIT_BRANCH:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$b" != "debian" ]]; then
    echo -e "${RED}Ошибка: mt.sh в ветке debian поддерживает только VPCONFIGURE_GIT_BRANCH=debian (текущее: ${b:-unset}).${NC}" >&2
    exit 1
  fi
}

usage() {
  cat >&2 <<EOF
Использование: mt.sh <команда> [параметры]

Команды:
  help, -h               Показать справку
  set <secret>           Установить конкретный секрет (32 hex или dd+32 hex)
  new                    Сгенерировать новый секрет и установить

Примеры:
  mt.sh set 0123456789abcdef0123456789abcdef
  mt.sh set dd0123456789abcdef0123456789abcdef
  mt.sh new
EOF
}

check_scripts() {
  for script in "$SET_SCRIPT" "$NEW_SCRIPT"; do
    if [[ ! -x "$script" ]]; then
      echo -e "${RED}Ошибка: скрипт $script не найден или не исполняемый${NC}" >&2
      exit 1
    fi
  done
}

main() {
  check_scripts
  vpconfigure_source_saved_env "/root/.vpconnect-configure.env"
  require_debian_branch

  local cmd=${1:-help}
  shift || true

  case "$cmd" in
    help|-h|--help)
      usage
      ;;
    set)
      if [[ $# -ne 1 ]]; then
        echo -e "${RED}Ошибка: для команды set укажите секрет.${NC}" >&2
        usage
        exit 1
      fi
      "$SET_SCRIPT" "$1"
      echo -e "${GREEN}Готово.${NC}" >&2
      ;;
    new)
      if [[ $# -ne 0 ]]; then
        echo -e "${RED}Ошибка: команда new не принимает аргументы.${NC}" >&2
        usage
        exit 1
      fi
      "$NEW_SCRIPT"
      echo -e "${GREEN}Готово.${NC}" >&2
      ;;
    *)
      echo -e "${RED}Неизвестная команда: $cmd${NC}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
