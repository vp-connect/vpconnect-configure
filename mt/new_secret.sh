#!/usr/bin/env bash
# new_secret.sh
#
# Генерация нового секрета MTProxy (32 hex) и передача в set_secret.sh.
# В tg://proxy используется dd<secret>.

set -euo pipefail

_mt_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_mt_dir=$(cd "$(dirname "$_mt_src")" && pwd)
_set_secret="${_mt_dir}/set_secret.sh"
DEFAULT_ENV_FILE="/root/.vpconnect-configure.env"

expand_tilde() {
  local p=$1
  if [[ "$p" == "~" || "$p" == ~/* ]]; then
    p="${p/\~/$HOME}"
  fi
  printf '%s' "$p"
}

vpconfigure_source_saved_env() {
  local f=${1:-$DEFAULT_ENV_FILE}
  f="$(expand_tilde "$f")"
  [[ -r "$f" ]] || return 0
  # shellcheck disable=SC1090
  set -a
  . "$f"
  set +a
}

require_freebsd_branch() {
  local b
  b=$(printf '%s' "${VPCONFIGURE_GIT_BRANCH:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$b" != "freebsd" ]]; then
    echo "Ошибка: mt/new_secret.sh в ветке freebsd поддерживает только VPCONFIGURE_GIT_BRANCH=freebsd (текущее: ${b:-unset})." >&2
    exit 1
  fi
}

usage() {
  cat >&2 <<EOF
Использование:
  new_secret.sh

Генерирует новый 32-hex секрет и вызывает set_secret.sh.
EOF
}

require_cmd() {
  local c=$1
  command -v "$c" >/dev/null 2>&1 || {
    echo "Ошибка: не найдена команда '$c' в PATH." >&2
    exit 1
  }
}

gen_secret_hex() (
  set +o pipefail 2>/dev/null || true
  head -c 16 /dev/urandom | xxd -ps
)

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ $# -ne 0 ]]; then
    usage
    exit 1
  fi

  [[ -x "$_set_secret" ]] || {
    echo "Ошибка: не найден исполняемый $_set_secret" >&2
    exit 1
  }

  vpconfigure_source_saved_env "$DEFAULT_ENV_FILE"
  require_freebsd_branch

  require_cmd head
  require_cmd xxd

  local secret
  secret=$(gen_secret_hex | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')
  [[ "$secret" =~ ^[0-9a-f]{32}$ ]] || {
    echo "Ошибка: не удалось сгенерировать корректный секрет MTProxy." >&2
    exit 1
  }

  echo "[new_secret] generated: ${secret}" >&2
  "$_set_secret" "$secret"
}

main "$@"
