#!/usr/bin/env bash
# set_secret.sh
#
# Установка конкретного секрета MTProxy:
# - принимает секрет в формате 32 hex или dd+32 hex;
# - обновляет существующие файлы (без создания новых):
#   * VPCONFIGURE_MTPROXY_SECRET_PATH
#   * VPCONFIGURE_MTPROXY_LINK_PATH
#   * /etc/systemd/system/mtproxy.service (или mtproto-proxy.service), если есть.
# - перезапускает сервис после изменения unit-файла.
#
# Ветка centos: допускается только VPCONFIGURE_GIT_BRANCH=centos.

set -euo pipefail

_mt_src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_mt_dir=$(cd "$(dirname "$_mt_src")" && pwd)

DEFAULT_ENV_FILE="/root/.vpconnect-configure.env"
DEFAULT_WG_PRIV="/etc/wireguard/privatekey"
DEFAULT_WG_CLIENT_CONFIG="/usr/wireguard/client_config"

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

require_root() {
  [[ "${EUID:-0}" -eq 0 ]] || {
    echo "Ошибка: запускайте от root." >&2
    exit 1
  }
}

require_centos_branch() {
  local b
  b=$(printf '%s' "${VPCONFIGURE_GIT_BRANCH:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$b" != "centos" ]]; then
    echo "Ошибка: mt/set_secret.sh в ветке centos поддерживает только VPCONFIGURE_GIT_BRANCH=centos (текущее: ${b:-unset})." >&2
    exit 1
  fi
}

normalize_secret_or_fail() {
  local raw=$1
  raw=$(printf '%s' "$raw" | tr -d ' \t\r\n' | tr '[:upper:]' '[:lower:]')
  if [[ "$raw" =~ ^dd[0-9a-f]{32}$ ]]; then
    printf '%s' "${raw:2}"
    return 0
  fi
  if [[ "$raw" =~ ^[0-9a-f]{32}$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  return 1
}

usage() {
  cat >&2 <<EOF
Использование:
  set_secret.sh <secret>

Где <secret>:
  - 32 hex символа (без префикса), или
  - dd + 32 hex (как в tg://proxy).
EOF
}

replace_secret_in_link_line() {
  local line=$1
  local secret_hex=$2
  local updated
  updated=$(printf '%s' "$line" | sed -E "s/(secret=)(dd)?[0-9a-fA-F]{32}/\\1dd${secret_hex}/")
  printf '%s' "$updated"
}

update_secret_file_if_exists() {
  local secret_path=$1
  local secret_hex=$2
  if [[ ! -f "$secret_path" ]]; then
    echo "[set_secret] skip: файл секрета не найден: $secret_path" >&2
    return 1
  fi
  umask 077
  printf '%s' "$secret_hex" >"$secret_path"
  umask 022
  chmod 600 -- "$secret_path" 2>/dev/null || true
  echo "[set_secret] updated: $secret_path" >&2
  return 0
}

update_link_file_if_exists() {
  local link_path=$1
  local secret_hex=$2
  if [[ ! -f "$link_path" ]]; then
    echo "[set_secret] skip: файл ссылки не найден: $link_path" >&2
    return 1
  fi

  local first_line
  first_line=$(awk 'NF{print; exit}' "$link_path")
  if [[ -z "$first_line" ]]; then
    echo "[set_secret] skip: файл ссылки пуст: $link_path" >&2
    return 1
  fi

  local new_line
  new_line=$(replace_secret_in_link_line "$first_line" "$secret_hex")
  if [[ "$new_line" == "$first_line" ]]; then
    echo "[set_secret] skip: в ссылке не найден параметр secret=...: $link_path" >&2
    return 1
  fi

  umask 022
  printf '%s\n' "$new_line" >"$link_path"
  chmod 644 -- "$link_path" 2>/dev/null || true
  echo "[set_secret] updated: $link_path" >&2
  return 0
}

update_unit_file_if_exists() {
  local unit_file=$1
  local secret_hex=$2
  [[ -f "$unit_file" ]] || return 1

  local tmp changed
  tmp=$(mktemp)
  changed=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    local new_line
    new_line=$(printf '%s' "$line" | sed -E "s/(^|[[:space:]])-S[[:space:]]+(dd)?[0-9a-fA-F]{32}/\\1-S ${secret_hex}/")
    if [[ "$new_line" != "$line" ]]; then
      changed=1
    fi
    printf '%s\n' "$new_line" >>"$tmp"
  done <"$unit_file"

  if [[ "$changed" -eq 1 ]]; then
    mv -f -- "$tmp" "$unit_file"
    echo "[set_secret] updated: $unit_file" >&2
    return 0
  fi

  rm -f -- "$tmp"
  echo "[set_secret] skip: в unit не найден аргумент -S <secret>: $unit_file" >&2
  return 1
}

restart_mtproxy_if_possible() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[set_secret] skip: systemctl не найден, перезапуск выполните вручную." >&2
    return 0
  fi

  systemctl daemon-reload || true
  if systemctl restart mtproxy >/dev/null 2>&1; then
    echo "[set_secret] service restarted: mtproxy" >&2
    return 0
  fi
  if systemctl restart mtproto-proxy >/dev/null 2>&1; then
    echo "[set_secret] service restarted: mtproto-proxy" >&2
    return 0
  fi

  echo "[set_secret] warning: не удалось перезапустить mtproxy/mtproto-proxy, проверьте вручную." >&2
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  vpconfigure_source_saved_env "$DEFAULT_ENV_FILE"
  require_centos_branch
  require_root

  local secret_hex
  if ! secret_hex=$(normalize_secret_or_fail "$1"); then
    echo "Ошибка: секрет должен быть 32 hex или dd+32 hex." >&2
    exit 1
  fi

  local wg_priv client_cfg secret_path link_path
  wg_priv="$(expand_tilde "${VPCONFIGURE_WG_PRIVATE_KEY_PATH:-$DEFAULT_WG_PRIV}")"
  client_cfg="$(expand_tilde "${VPCONFIGURE_WG_CLIENT_CONFIG_PATH:-$DEFAULT_WG_CLIENT_CONFIG}")"
  secret_path="$(expand_tilde "${VPCONFIGURE_MTPROXY_SECRET_PATH:-$(dirname -- "$wg_priv")/mtproxy_secret.txt}")"
  link_path="$(expand_tilde "${VPCONFIGURE_MTPROXY_LINK_PATH:-$client_cfg/mtproxy.link}")"

  echo "[set_secret] using: VPCONFIGURE_MTPROXY_SECRET_PATH=$secret_path" >&2
  echo "[set_secret] using: VPCONFIGURE_MTPROXY_LINK_PATH=$link_path" >&2

  local updated_any=0 unit_updated=0
  update_secret_file_if_exists "$secret_path" "$secret_hex" && updated_any=1 || true
  update_link_file_if_exists "$link_path" "$secret_hex" && updated_any=1 || true

  update_unit_file_if_exists "/etc/systemd/system/mtproxy.service" "$secret_hex" && unit_updated=1 || true
  update_unit_file_if_exists "/etc/systemd/system/mtproto-proxy.service" "$secret_hex" && unit_updated=1 || true
  if [[ "$unit_updated" -eq 1 ]]; then
    updated_any=1
    restart_mtproxy_if_possible
  fi

  if [[ "$updated_any" -eq 0 ]]; then
    echo "Ошибка: не найдено подходящих файлов для обновления секрета (ничего не изменено)." >&2
    exit 1
  fi

  echo "Готово: секрет MTProxy обновлён (для ссылки используется префикс dd)." >&2
}

main "$@"
