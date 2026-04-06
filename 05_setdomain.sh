#!/usr/bin/env bash
# 05_setdomain
#
# Задаёт используемое имя/адрес сервера в VPCONFIGURE_DOMAIN (для последующих скриптов и установщика).
# Ветка debian: домен из CLI, из REST по ключу, либо внешний IP.
#
# Сначала stdout: строка result:…; message:…; domain:… (при --export вторая строка — export …).
#
# Параметры (все опциональны, порядок неважен):
#   --domain STRING     Явное значение (FQDN или IP), даже если это IP
#   --domain-client-key KEY  Если задано и --domain пуст: GET к REST с key=…; при ошибке — внешний IP и result:warning
#   (если оба не заданы — только внешний IP, result:success)
#
# Как у 01_getosversion.sh:
#   --export   вторая строка stdout: export VPCONFIGURE_DOMAIN=…
#   --persist [FILE]  хуки ~/.bashrc и /etc/profile.d для загрузки FILE при входе
#
# После успеха VPCONFIGURE_DOMAIN всегда дописывается в FILE (по умолчанию /root/.vpconnect-configure.env)
# для следующих скриптов (07_setmtproxy.sh и др.) в новой сессии.
#
# URL сервиса домена (как в vpconnect_install defaults): можно переопределить окружением
#   VPCONFIGURE_DOMAIN_SERVICE_URL (по умолчанию https://example.com/api/vpconnect-domain)
#
# Нужна VPCONFIGURE_GIT_BRANCH из 01_getosversion.sh.

set -euo pipefail

_VPCONF_SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/vpconfigure_hooks.inc.sh
source "${_VPCONF_SCRIPT_DIR}/lib/vpconfigure_hooks.inc.sh"

DEFAULT_DOMAIN_SERVICE_URL='https://example.com/api/vpconnect-domain'
DEFAULT_PERSIST_FILE='/root/.vpconnect-configure.env'

vp_sanitize_msg() {
  local s="$*"
  s="${s//;/,}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

vp_result_line() {
  local status=$1
  shift
  local msg
  msg="$(vp_sanitize_msg "$1")"
  shift
  local out="result:${status}; message:${msg}"
  while [[ $# -gt 0 ]]; do
    out+="; $(vp_sanitize_msg "$1")"
    shift
  done
  printf '%s\n' "$out"
}

die() {
  vp_result_line error "$*"
  exit 1
}

usage() {
  vp_result_line success "Справка выведена в stderr"
  cat >&2 <<EOF
Установка VPCONFIGURE_DOMAIN (ветка debian: домен, сервис по ключу или внешний IP).

  --domain STRING           Явное значение (FQDN или IP)
  --domain-client-key KEY   Запрос FQDN у REST (если --domain не задан); см. VPCONFIGURE_DOMAIN_SERVICE_URL

  --export                  Вторая строка stdout: export VPCONFIGURE_DOMAIN=…
  --persist [FILE]          Только хуки login-shell → FILE (по умолчанию ${DEFAULT_PERSIST_FILE})

  -h, --help

Пример:
  export VPCONFIGURE_GIT_BRANCH=debian
  eval "\$(bash ./05_setdomain.sh --domain srv.example.com --export | sed -n '2p')"
  bash ./05_setdomain.sh --domain srv.example.com --persist
EOF
}

expand_tilde() {
  local p=$1
  if [[ "$p" == '~' || "$p" == ~/* ]]; then
    p="${p/\~/$HOME}"
  fi
  printf '%s' "$p"
}

strip_outer_space() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fetch_public_ip() {
  local ip
  ip=$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
  ip=$(printf '%s' "$ip" | tr -d '\r\n' | head -c 256)
  if [[ -n "$ip" && "$ip" != *' '* ]]; then
    printf '%s' "$ip"
    return 0
  fi
  ip=$(curl -fsS --max-time 10 https://icanhazip.com 2>/dev/null || true)
  ip=$(printf '%s' "$ip" | tr -d '\r\n' | head -c 256)
  if [[ -n "$ip" && "$ip" != *' '* ]]; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

parse_domain_service_body() {
  local raw=$1
  local first raw_trim
  raw_trim=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//')
  first=$(printf '%s' "$raw_trim" | head -n1 | tr -d '\r')
  first=$(strip_outer_space "$first")
  [[ -n "$first" ]] || return 1
  if [[ "${first:0:1}" == '{' ]]; then
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c "
import json, sys
raw = sys.stdin.read()
d = json.loads(raw)
v = (d.get('domain') or d.get('fqdn') or '').strip()
if not v:
    sys.exit(1)
print(v, end='')
" <<<"$raw_trim" 2>/dev/null
    return $?
  fi
  printf '%s' "$first"
  return 0
}

# stdout: FQDN; 0 = успех, 1 = сбой запроса/разбора
resolve_fqdn_via_domain_service() {
  local key=$1
  local base raw
  base="${VPCONFIGURE_DOMAIN_SERVICE_URL:-$DEFAULT_DOMAIN_SERVICE_URL}"
  [[ -n "$key" ]] || return 1
  if ! raw=$(curl -fsS --max-time 30 -G --data-urlencode "key=${key}" "$base" 2>/dev/null); then
    return 1
  fi
  parse_domain_service_body "$raw" || return 1
}

merge_domain_into_env_file() {
  local f=$1
  local val=$2
  local d tmp
  d="$(dirname -- "$f")"
  [[ -d "$d" ]] || mkdir -p -- "$d"
  tmp="$(mktemp)"
  umask 077
  if [[ -f "$f" ]]; then
    grep -vE '^export[[:space:]]+VPCONFIGURE_DOMAIN=|^# VPCONFIGURE_DOMAIN \(05_setdomain' "$f" >"$tmp" || true
  else
    : >"$tmp"
  fi
  {
    if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" 2>/dev/null || true)" != $'\n' ]]; then
      printf '\n'
    fi
    printf '# VPCONFIGURE_DOMAIN (05_setdomain.sh --persist)\n'
    printf 'export VPCONFIGURE_DOMAIN=%q\n' "$val"
  } >>"$tmp"
  mv -f -- "$tmp" "$f"
  chmod 600 -- "$f" 2>/dev/null || true
}

run_debian() {
  local opt_domain=''
  local opt_key=''
  local mode=normal
  local persist=0
  local persist_file=$DEFAULT_PERSIST_FILE

  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain)
        [[ $# -ge 2 ]] || die "После --domain нужна строка"
        opt_domain=$2
        shift 2
        ;;
      --domain-client-key)
        [[ $# -ge 2 ]] || die "После --domain-client-key нужен ключ"
        opt_key=$2
        shift 2
        ;;
      --export)
        mode=export
        shift
        ;;
      --persist)
        persist=1
        shift
        if [[ -n "${1:-}" && "$1" != -* ]]; then
          persist_file=$1
          shift
        fi
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Неизвестный аргумент: $1"
        ;;
    esac
  done

  local explicit
  explicit=$(strip_outer_space "$opt_domain")
  local key_trim
  key_trim=$(strip_outer_space "$opt_key")

  local final=''
  local out_status=success
  local msg_ok='домен установлен'

  if [[ -n "$explicit" ]]; then
    final=$explicit
    msg_ok='использован переданный домен'
  elif [[ -n "$key_trim" ]]; then
    local resolved
    if resolved=$(resolve_fqdn_via_domain_service "$key_trim"); then
      resolved=$(strip_outer_space "$resolved")
      [[ -n "$resolved" ]] || die "Сервис домена вернул пустое имя"
      final=$resolved
      msg_ok='FQDN получен по ключу сервиса'
    else
      printf '%s\n' "Сервис домена недоступен или вернул ошибку, подставляем внешний IP." >&2
      final=$(fetch_public_ip) || die "Не удалось получить FQDN по ключу и не удалось определить внешний IP"
      out_status=warning
      msg_ok='сервис домена не сработал, установлен внешний IP'
    fi
  else
    final=$(fetch_public_ip) || die "Не удалось определить внешний IP сервера"
    msg_ok='установлен внешний IP'
  fi

  final=$(strip_outer_space "$final")
  [[ -n "$final" ]] || die "Итоговое значение домена пусто"

  persist_file="$(expand_tilde "$persist_file")"

  export VPCONFIGURE_DOMAIN="$final"

  if [[ "$mode" == "export" ]]; then
    vp_result_line "$out_status" "$msg_ok" "domain:${final}"
    printf 'export VPCONFIGURE_DOMAIN=%q\n' "$final"
  else
    vp_result_line "$out_status" "$msg_ok" "domain:${final}"
  fi

  merge_domain_into_env_file "$persist_file" "$final" || die "Не удалось записать env-файл: ${persist_file}"
  printf '%s\n' "VPCONFIGURE_DOMAIN сохранён в ${persist_file} (для 07 и др.; в этой сессии уже export)." >&2

  if [[ "$persist" -eq 1 ]]; then
    vp_install_bashrc_hook "$persist_file"
    if vp_install_profile_d_hook "$persist_file"; then
      printf '%s\n' "Хуки login-shell: ~/.bashrc и /etc/profile.d → ${persist_file}" >&2
    else
      printf '%s\n' "Хук ~/.bashrc → ${persist_file} (нет /etc/profile.d)" >&2
    fi
  fi
}

main() {
  : "${VPCONFIGURE_GIT_BRANCH:?Сначала 01_getosversion.sh}"

  local b
  b=$(printf '%s' "$VPCONFIGURE_GIT_BRANCH" | tr '[:upper:]' '[:lower:]')
  case "$b" in
    freebsd|debian|centos) ;;
    *) die "VPCONFIGURE_GIT_BRANCH=${b} недопустимо" ;;
  esac

  case "$b" in
    debian)
      run_debian "$@"
      ;;
    freebsd|centos)
      if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
        usage
        exit 0
      fi
      printf '%s\n' "Ветка ${b}: 05_setdomain.sh для этой ОС не реализован, VPCONFIGURE_DOMAIN не задан." >&2
      vp_result_line warning "ветка ${b}, скрипт не реализован" "domain:unset"
      ;;
  esac
}

main "$@"
