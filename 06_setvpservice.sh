#!/usr/bin/env bash
# 06_setvpservice
#
# Унифицированный шаг установки VPN-сервиса.
# Поддерживаемые типы: wireguard | amneziawg
# Внутри использует реализацию 06_setwireguard.sh как базу.
#
# Новый внешний контракт (vp/vpserver):
#   VPCONFIGURE_VPSERVER_TYPE
#   VPCONFIGURE_VP_PORT
#   VPCONFIGURE_VP_CLIENT_CERT_PATH
#   VPCONFIGURE_VP_CLIENT_CONFIG_PATH
#   VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH
#   VPCONFIGURE_VP_PRIVATE_KEY_PATH
#   VPCONFIGURE_VPSERVER_INTERFACE_NAME
#   VPCONFIGURE_VPSERVER_NETWORK_CIDR
#   VPCONFIGURE_VP_WAN_IFACE
#
# Для совместимости скрипт также оставляет WG-переменные в env-файле.

set -euo pipefail

DEFAULT_VPSERVER_TYPE='wireguard'
DEFAULT_CERT='/usr/vpserver/client_cert'
DEFAULT_CONF_DIR='/usr/vpserver/client_config'
DEFAULT_PERSIST_FILE='/root/.vpconnect-configure.env'

_SELF_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")" && pwd)
_WG_SCRIPT="${_SELF_DIR}/06_setwireguard.sh"

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
Установка VPN-сервиса (wireguard/amneziawg), шаг 06.

  --vpservice-type TYPE         wireguard | amneziawg (по умолчанию ${DEFAULT_VPSERVER_TYPE})
  --vp-service TYPE             алиас к --vpservice-type
  --vp-port N                   UDP-порт (пробрасывается в базовую реализацию)
  --vp-address A.B.C.1/24       Адрес сервера в туннеле
  --vp-wan-interface NAME       WAN интерфейс для NAT
  --vp-client-cert-path PATH    Каталог клиентских сертификатов (по умолчанию ${DEFAULT_CERT})
  --vp-client-config-path PATH  Каталог клиентских конфигов (по умолчанию ${DEFAULT_CONF_DIR})
  --vp-server-private-key-file PATH  Файл приватного ключа сервера
  --export                      Печатать export VPCONFIGURE_VP_*
  --persist [FILE]              Сохранять переменные в env-файл (по умолчанию ${DEFAULT_PERSIST_FILE})
  -h, --help
EOF
}

expand_tilde() {
  local p=$1
  if [[ "$p" == '~' || "$p" == ~/* ]]; then
    p="${p/\~/$HOME}"
  fi
  printf '%s' "$p"
}

_extract_field() {
  local line=$1
  local key=$2
  awk -v k="${key}:" -F';' '
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", $i)
        if (tolower($i) ~ "^" tolower(k)) {
          sub(/^[^:]*:[ \t]*/, "", $i)
          print $i
          exit
        }
      }
    }' <<<"$line"
}

merge_vp_into_env_file() {
  local f=$1
  shift
  local d tmp
  d="$(dirname -- "$f")"
  [[ -d "$d" ]] || mkdir -p -- "$d"
  tmp="$(mktemp)"
  umask 077
  if [[ -f "$f" ]]; then
    grep -vE '^export[[:space:]]+VPCONFIGURE_(VPSERVER_TYPE|VP_(PORT|CLIENT_CERT_PATH|CLIENT_CONFIG_PATH|SERVER_PUBLIC_KEY_PATH|PRIVATE_KEY_PATH|WAN_IFACE|SERVICE_BINARY|SERVICE_QUICK_BINARY)|VPSERVER_(INTERFACE_NAME|NETWORK_CIDR))=|^# VPCONFIGURE_VP \(06_setvpservice' "$f" >"$tmp" || true
  else
    : >"$tmp"
  fi
  {
    if [[ -s "$tmp" ]]; then
      printf '\n'
    fi
    printf '# VPCONFIGURE_VP (06_setvpservice.sh --persist)\n'
    while [[ $# -ge 2 ]]; do
      printf 'export %s=%q\n' "$1" "$2"
      shift 2
    done
  } >>"$tmp"
  mv -f -- "$tmp" "$f"
  chmod 600 -- "$f" 2>/dev/null || true
}

emit_vp_exports() {
  printf 'export VPCONFIGURE_VPSERVER_TYPE=%q\n' "$1"
  printf 'export VPCONFIGURE_VP_PORT=%q\n' "$2"
  printf 'export VPCONFIGURE_VP_CLIENT_CERT_PATH=%q\n' "$3"
  printf 'export VPCONFIGURE_VP_CLIENT_CONFIG_PATH=%q\n' "$4"
  printf 'export VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH=%q\n' "$5"
  printf 'export VPCONFIGURE_VP_PRIVATE_KEY_PATH=%q\n' "$6"
  printf 'export VPCONFIGURE_VPSERVER_INTERFACE_NAME=%q\n' "$7"
  printf 'export VPCONFIGURE_VPSERVER_NETWORK_CIDR=%q\n' "$8"
  if [[ -n "${9:-}" ]]; then
    printf 'export VPCONFIGURE_VP_WAN_IFACE=%q\n' "${9}"
  fi
  printf 'export VPCONFIGURE_VP_SERVICE_BINARY=%q\n' "${10:-}"
  printf 'export VPCONFIGURE_VP_SERVICE_QUICK_BINARY=%q\n' "${11:-}"
}

detect_vp_binaries() {
  local svc=$1
  local vp_bin='wg'
  local vp_quick_bin='wg-quick'
  if [[ "$svc" == "amneziawg" ]]; then
    vp_bin='awg'
    vp_quick_bin='awg-quick'
  fi
  printf '%s;%s\n' "$vp_bin" "$vp_quick_bin"
}

ensure_amnezia_tools() {
  command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1 && return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y -qq amneziawg-tools >/dev/null 2>&1 || true
  if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
    apt-get install -y -qq amneziawg >/dev/null 2>&1 || true
  fi
  # Fallback: рекомендованный установщик AmneziaWG (без docker).
  # Скрипт может быть интерактивным, поэтому подаём порт через stdin.
  if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
    local installer="/tmp/install_amneziawg.sh"
    local installer_url='https://github.com/bivlked/amneziawg-installer/releases/download/v5.7.2/install_amneziawg.sh'
    local installer_port="${1:-51820}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$installer" "$installer_url" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$installer" "$installer_url" >/dev/null 2>&1 || true
    fi
    if [[ -s "$installer" ]]; then
      chmod +x "$installer" || true
      if command -v timeout >/dev/null 2>&1; then
        timeout 900 bash -c "printf '%s\n' '$installer_port' | bash '$installer'" >/tmp/amneziawg-installer.log 2>&1 || true
      else
        bash -c "printf '%s\n' '$installer_port' | bash '$installer'" >/tmp/amneziawg-installer.log 2>&1 || true
      fi
    fi
  fi
  command -v awg >/dev/null 2>&1 || die "Выбран amneziawg, но бинарник awg не установлен"
  command -v awg-quick >/dev/null 2>&1 || die "Выбран amneziawg, но бинарник awg-quick не установлен"
}

switch_to_awg_quick_unit() {
  local iface=$1
  command -v systemctl >/dev/null 2>&1 || return 0
  local wg_unit="wg-quick@${iface}.service"
  local awg_unit="awg-quick@${iface}.service"
  systemctl list-unit-files | grep -q '^awg-quick@\.service' || {
    printf '%s\n' "awg-quick@.service не найден, оставляю текущий wg-quick unit как fallback." >&2
    return 0
  }
  systemctl enable "$awg_unit" >/dev/null 2>&1 || die "Не удалось enable ${awg_unit}"
  systemctl restart "$awg_unit" >/dev/null 2>&1 || systemctl start "$awg_unit" >/dev/null 2>&1 \
    || die "Не удалось запустить ${awg_unit}"
  systemctl stop "$wg_unit" >/dev/null 2>&1 || true
  systemctl disable "$wg_unit" >/dev/null 2>&1 || true
}

main() {
  [[ -f "$_WG_SCRIPT" ]] || die "Не найден базовый скрипт: ${_WG_SCRIPT}"

  local vpservice_type="${VPCONFIGURE_VPSERVER_TYPE:-$DEFAULT_VPSERVER_TYPE}"
  local vp_port=''
  local vp_address=''
  local vp_wan_iface=''
  local vp_cert="${VPCONFIGURE_VP_CLIENT_CERT_PATH:-$DEFAULT_CERT}"
  local vp_conf="${VPCONFIGURE_VP_CLIENT_CONFIG_PATH:-$DEFAULT_CONF_DIR}"
  local vp_priv_file=''
  local mode_export=0
  local persist=0
  local persist_file="$DEFAULT_PERSIST_FILE"

  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --vpservice-type|--vp-service)
        [[ $# -ge 2 ]] || die "После --vpservice-type нужно значение"
        vpservice_type=$2
        shift 2
        ;;
      --vp-port)
        [[ $# -ge 2 ]] || die "После --vp-port нужен порт"
        vp_port=$2
        shift 2
        ;;
      --vp-address)
        [[ $# -ge 2 ]] || die "После --vp-address нужен адрес"
        vp_address=$2
        shift 2
        ;;
      --vp-wan-interface)
        [[ $# -ge 2 ]] || die "После --vp-wan-interface нужно имя интерфейса"
        vp_wan_iface=$2
        shift 2
        ;;
      --vp-client-cert-path)
        [[ $# -ge 2 ]] || die "После --vp-client-cert-path нужен путь"
        vp_cert=$2
        shift 2
        ;;
      --vp-client-config-path)
        [[ $# -ge 2 ]] || die "После --vp-client-config-path нужен путь"
        vp_conf=$2
        shift 2
        ;;
      --vp-server-private-key-file)
        [[ $# -ge 2 ]] || die "После --vp-server-private-key-file нужен путь"
        vp_priv_file=$2
        shift 2
        ;;
      --export)
        mode_export=1
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

  vpservice_type="$(printf '%s' "$vpservice_type" | tr '[:upper:]' '[:lower:]')"
  case "$vpservice_type" in
    wireguard|amneziawg) ;;
    *)
      die "Некорректный --vpservice-type: ${vpservice_type} (ожидается wireguard|amneziawg)"
      ;;
  esac

  vp_cert="$(expand_tilde "$vp_cert")"
  vp_conf="$(expand_tilde "$vp_conf")"
  persist_file="$(expand_tilde "$persist_file")"
  if [[ "$vpservice_type" == "amneziawg" ]]; then
    ensure_amnezia_tools "${vp_port:-51820}"
  fi

  # В текущем шаге используем существующий установщик WG как базу
  # (для amneziawg серверная часть сейчас разворачивается по совместимому пути).
  local -a wg_args=()
  [[ -n "$vp_port" ]] && wg_args+=( --wg-port "$vp_port" )
  [[ -n "$vp_address" ]] && wg_args+=( --wg-address "$vp_address" )
  [[ -n "$vp_wan_iface" ]] && wg_args+=( --wg-wan-interface "$vp_wan_iface" )
  [[ -n "$vp_cert" ]] && wg_args+=( --wg-client-cert-path "$vp_cert" )
  [[ -n "$vp_conf" ]] && wg_args+=( --wg-client-config-path "$vp_conf" )
  [[ -n "$vp_priv_file" ]] && wg_args+=( --wg-server-private-key-file "$vp_priv_file" )
  wg_args+=( --persist "$persist_file" )
  # Забираем export из stdout для нормализации в VP-контракт.
  wg_args+=( --export )

  local out rc
  set +e
  out="$(bash "$_WG_SCRIPT" "${wg_args[@]}" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    die "Не удалось выполнить базовую установку VPN-сервиса (${vpservice_type})"
  fi

  local result_line
  result_line="$(awk '/^result:/{line=$0} END{print line}' <<<"$out")"
  [[ -n "$result_line" ]] || die "Базовый скрипт не вернул result: строку"

  local wg_iface wg_port wg_pub wg_priv wg_wan
  wg_iface="$(_extract_field "$result_line" "wg_interface")"
  wg_port="$(_extract_field "$result_line" "wg_port")"
  wg_pub="$(_extract_field "$result_line" "wg_server_public_key_path")"
  wg_priv="$(_extract_field "$result_line" "wg_private_key_path")"
  wg_wan="$(_extract_field "$result_line" "wg_wan")"
  if [[ "$wg_wan" == auto ]]; then
    wg_wan=''
  fi

  # Определяем подсеть VP из persist/env, где 06_setwireguard хранит network cidr.
  local vp_net="${VPCONFIGURE_WIREGUARD_NETWORK_CIDR:-}"
  if [[ -z "$vp_net" && -r "$persist_file" ]]; then
    vp_net="$(awk -F= '/^export VPCONFIGURE_WIREGUARD_NETWORK_CIDR=/{sub(/^export VPCONFIGURE_WIREGUARD_NETWORK_CIDR=/,""); gsub(/^'\''|'\''$/,""); print; exit}' "$persist_file" 2>/dev/null || true)"
  fi

  export VPCONFIGURE_VPSERVER_TYPE="$vpservice_type"
  export VPCONFIGURE_VP_PORT="${wg_port:-${vp_port:-}}"
  export VPCONFIGURE_VP_CLIENT_CERT_PATH="$vp_cert"
  export VPCONFIGURE_VP_CLIENT_CONFIG_PATH="$vp_conf"
  export VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH="$wg_pub"
  export VPCONFIGURE_VP_PRIVATE_KEY_PATH="$wg_priv"
  export VPCONFIGURE_VPSERVER_INTERFACE_NAME="$wg_iface"
  export VPCONFIGURE_VPSERVER_NETWORK_CIDR="$vp_net"
  if [[ -n "$wg_wan" ]]; then
    export VPCONFIGURE_VP_WAN_IFACE="$wg_wan"
  else
    unset VPCONFIGURE_VP_WAN_IFACE 2>/dev/null || true
  fi
  local vp_bin_pair
  vp_bin_pair="$(detect_vp_binaries "$vpservice_type")"
  export VPCONFIGURE_VP_SERVICE_BINARY="${vp_bin_pair%%;*}"
  export VPCONFIGURE_VP_SERVICE_QUICK_BINARY="${vp_bin_pair#*;}"
  if [[ "$vpservice_type" == "amneziawg" ]]; then
    switch_to_awg_quick_unit "$VPCONFIGURE_VPSERVER_INTERFACE_NAME"
  fi

  local -a vp_kv=(
    VPCONFIGURE_VPSERVER_TYPE "$VPCONFIGURE_VPSERVER_TYPE"
    VPCONFIGURE_VP_PORT "$VPCONFIGURE_VP_PORT"
    VPCONFIGURE_VP_CLIENT_CERT_PATH "$VPCONFIGURE_VP_CLIENT_CERT_PATH"
    VPCONFIGURE_VP_CLIENT_CONFIG_PATH "$VPCONFIGURE_VP_CLIENT_CONFIG_PATH"
    VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH "$VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH"
    VPCONFIGURE_VP_PRIVATE_KEY_PATH "$VPCONFIGURE_VP_PRIVATE_KEY_PATH"
    VPCONFIGURE_VPSERVER_INTERFACE_NAME "$VPCONFIGURE_VPSERVER_INTERFACE_NAME"
    VPCONFIGURE_VPSERVER_NETWORK_CIDR "$VPCONFIGURE_VPSERVER_NETWORK_CIDR"
    VPCONFIGURE_VP_SERVICE_BINARY "$VPCONFIGURE_VP_SERVICE_BINARY"
    VPCONFIGURE_VP_SERVICE_QUICK_BINARY "$VPCONFIGURE_VP_SERVICE_QUICK_BINARY"
  )
  if [[ -n "${VPCONFIGURE_VP_WAN_IFACE:-}" ]]; then
    vp_kv+=( VPCONFIGURE_VP_WAN_IFACE "$VPCONFIGURE_VP_WAN_IFACE" )
  fi
  merge_vp_into_env_file "$persist_file" "${vp_kv[@]}"

  vp_result_line success "VPN-сервис установлен (${vpservice_type})" \
    "vpservice_type:${vpservice_type}" \
    "vp_interface:${VPCONFIGURE_VPSERVER_INTERFACE_NAME}" \
    "vp_port:${VPCONFIGURE_VP_PORT}" \
    "vp_service_binary:${VPCONFIGURE_VP_SERVICE_BINARY}" \
    "vp_service_quick_binary:${VPCONFIGURE_VP_SERVICE_QUICK_BINARY}" \
    "vp_server_public_key_path:${VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH}" \
    "vp_private_key_path:${VPCONFIGURE_VP_PRIVATE_KEY_PATH}" \
    "vp_client_cert_path:${VPCONFIGURE_VP_CLIENT_CERT_PATH}" \
    "vp_client_config_path:${VPCONFIGURE_VP_CLIENT_CONFIG_PATH}"

  if [[ $mode_export -eq 1 ]]; then
    emit_vp_exports \
      "$VPCONFIGURE_VPSERVER_TYPE" \
      "$VPCONFIGURE_VP_PORT" \
      "$VPCONFIGURE_VP_CLIENT_CERT_PATH" \
      "$VPCONFIGURE_VP_CLIENT_CONFIG_PATH" \
      "$VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH" \
      "$VPCONFIGURE_VP_PRIVATE_KEY_PATH" \
      "$VPCONFIGURE_VPSERVER_INTERFACE_NAME" \
      "$VPCONFIGURE_VPSERVER_NETWORK_CIDR" \
      "${VPCONFIGURE_VP_WAN_IFACE:-}" \
      "$VPCONFIGURE_VP_SERVICE_BINARY" \
      "$VPCONFIGURE_VP_SERVICE_QUICK_BINARY"
  fi
}

main "$@"

