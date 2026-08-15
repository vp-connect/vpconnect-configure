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
AMNEZIA_APT_KEY_FPR='75C9DD72C799870E310542E24166F2C257290828'

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

ensure_curl_or_wget() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install curl ca-certificates >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum -y install curl ca-certificates >/dev/null 2>&1 || true
  elif command -v pkg >/dev/null 2>&1; then
    pkg install -y curl ca_root_nss >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y -qq curl ca-certificates gnupg >/dev/null 2>&1 || true
  fi
}

# Amnezia PPA (focal) публикует amneziawg / amneziawg-tools для Debian/Ubuntu.
ensure_amnezia_apt_repo() {
  command -v apt-get >/dev/null 2>&1 || return 1
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
  apt-get install -y -qq curl ca-certificates gnupg >/dev/null 2>&1 || true
  ensure_curl_or_wget

  if [[ ! -s /etc/apt/keyrings/amneziawg.gpg ]]; then
    local tmp_asc tmp_keyring fpr
    tmp_asc="$(mktemp /tmp/amneziawg-apt-key.XXXXXX)"
    tmp_keyring="$(mktemp /etc/apt/keyrings/amneziawg.gpg.tmp.XXXXXX)"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${AMNEZIA_APT_KEY_FPR}" -o "$tmp_asc" || true
    else
      wget -qO "$tmp_asc" "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${AMNEZIA_APT_KEY_FPR}" || true
    fi
    if [[ ! -s "$tmp_asc" ]] || ! gpg --dearmor <"$tmp_asc" >"$tmp_keyring" 2>/dev/null; then
      rm -f "$tmp_asc" "$tmp_keyring"
      return 1
    fi
    fpr="$(gpg --show-keys --with-colons "$tmp_keyring" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
    if [[ "${fpr}" != "${AMNEZIA_APT_KEY_FPR}" ]]; then
      rm -f "$tmp_asc" "$tmp_keyring"
      return 1
    fi
    chmod 644 "$tmp_keyring"
    mv -f "$tmp_keyring" /etc/apt/keyrings/amneziawg.gpg
    rm -f "$tmp_asc"
  fi

  cat >/etc/apt/sources.list.d/amneziawg.sources.list <<'EOF'
# Managed by vpconnect-configure 06_setvpservice.sh
deb [signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
deb-src [signed-by=/etc/apt/keyrings/amneziawg.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
EOF
  apt-get update -qq || true
}

amnezia_module_loaded() {
  # Нельзя lsmod|grep -q при set -o pipefail: SIGPIPE у lsmod даёт ложный fail.
  grep -q '^amneziawg ' </proc/modules 2>/dev/null
}

ensure_amnezia_kernel_module() {
  command -v modprobe >/dev/null 2>&1 || return 0
  amnezia_module_loaded && return 0
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    local kr
    kr="$(uname -r)"
    apt-get install -y -qq "linux-headers-${kr}" >/dev/null 2>&1 \
      || apt-get install -y -qq linux-headers-amd64 linux-image-amd64 dkms >/dev/null 2>&1 \
      || true
    if command -v dkms >/dev/null 2>&1; then
      dkms autoinstall >/tmp/amneziawg-dkms.log 2>&1 || true
      depmod -a >/dev/null 2>&1 || true
    fi
  fi
  modprobe amneziawg >/tmp/amneziawg-modprobe.log 2>&1 || true
  amnezia_module_loaded && return 0
  printf '%s\n' \
    "Предупреждение: модуль amneziawg не загружен для ядра $(uname -r)." \
    "Если apt поставил более новый linux-image — перезагрузите сервер и повторите шаг 06." \
    >&2
  return 0
}

generate_amnezia_obfuscation_block() {
  # Диапазоны совместимы с AmneziaWG / wiresock installer.
  local jc jmin jmax s1 s2 s3 s4
  local h1_min h1_max h2_min h2_max h3_min h3_max h4_min h4_max
  jc="$(shuf -i1-128 -n1 2>/dev/null || echo 9)"
  jmin=50
  jmax=1000
  s1="$(shuf -i15-150 -n1 2>/dev/null || echo 50)"
  s2="$(shuf -i15-150 -n1 2>/dev/null || echo 60)"
  s3="$(shuf -i15-150 -n1 2>/dev/null || echo 70)"
  s4="$(shuf -i15-150 -n1 2>/dev/null || echo 80)"
  h1_min="$(shuf -i100000000-900000000 -n1 2>/dev/null || echo 200000000)"
  h1_max=$((h1_min + 100000000 - 1))
  h2_min=$((h1_max + 100000))
  h2_max=$((h2_min + 100000000 - 1))
  h3_min=$((h2_max + 100000))
  h3_max=$((h3_min + 100000000 - 1))
  h4_min=$((h3_max + 100000))
  h4_max=$((h4_min + 100000000 - 1))
  cat <<EOF
Jc = ${jc}
Jmin = ${jmin}
Jmax = ${jmax}
S1 = ${s1}
S2 = ${s2}
S3 = ${s3}
S4 = ${s4}
H1 = ${h1_min}-${h1_max}
H2 = ${h2_min}-${h2_max}
H3 = ${h3_min}-${h3_max}
H4 = ${h4_min}-${h4_max}
EOF
}

# awg-quick читает /etc/amnezia/amneziawg/<iface>.conf (не /etc/wireguard).
publish_amnezia_iface_conf() {
  local iface=$1
  local src="/etc/wireguard/${iface}.conf"
  local dst_dir="/etc/amnezia/amneziawg"
  local dst="${dst_dir}/${iface}.conf"
  [[ -s "$src" ]] || die "Нет конфига WireGuard для переноса в AmneziaWG: ${src}"
  mkdir -p -- "$dst_dir"
  chmod 700 -- "$dst_dir" 2>/dev/null || true
  local tmp obfuscation
  tmp="$(mktemp)"
  obfuscation="$(generate_amnezia_obfuscation_block)"
  awk -v obf="$obfuscation" '
    BEGIN { inserted=0 }
    {
      print
      if (!inserted && $0 ~ /^PrivateKey[[:space:]]*=/) {
        n = split(obf, lines, "\n")
        for (i = 1; i <= n; i++) if (lines[i] != "") print lines[i]
        inserted=1
      }
    }
    END {
      if (!inserted) exit 2
    }
  ' "$src" >"$tmp" || {
    rm -f "$tmp"
    die "Не удалось добавить параметры обфускации AmneziaWG в ${dst}"
  }
  umask 077
  mv -f -- "$tmp" "$dst"
  chmod 600 -- "$dst"
}

ensure_amnezia_tools() {
  local installer_port="${1:-51820}"
  local installer_log='/tmp/amneziawg-installer.log'

  if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
    ensure_amnezia_kernel_module
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    ensure_amnezia_apt_repo || true
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq dkms iptables qrencode amneziawg-tools amneziawg >/tmp/amneziawg-apt.log 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install amneziawg-tools amneziawg >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum -y install amneziawg-tools amneziawg >/dev/null 2>&1 || true
  elif command -v pkg >/dev/null 2>&1; then
    pkg install -y amneziawg-tools amneziawg >/dev/null 2>&1 || true
  fi

  # Fallback: wiresock installer в non-interactive режиме (без stdin-prompts).
  if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
    local installer='/tmp/install_amneziawg.sh'
    local awg_installer='/tmp/amneziawg-install.sh'
    local url_1='https://raw.githubusercontent.com/wiresock/amneziawg-install/main/amneziawg-install.sh'
    local url_2='https://raw.githubusercontent.com/wiresock/amneziawg-install/master/amneziawg-install.sh'

    ensure_curl_or_wget
    if [[ -x "$installer" ]]; then
      bash "$installer" --uninstall >/tmp/amneziawg-uninstall.log 2>&1 || true
    fi
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$awg_installer" "$url_1" || curl -fsSL -o "$awg_installer" "$url_2" || true
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$awg_installer" "$url_1" || wget -qO "$awg_installer" "$url_2" || true
    fi
    [[ -s "$awg_installer" ]] || die "Не удалось скачать AmneziaWG installer"
    chmod +x "$awg_installer" || true
    # AUTO_INSTALL=y обязателен: иначе скрипт зависает на read -rp.
    if command -v timeout >/dev/null 2>&1; then
      timeout 900 env AUTO_INSTALL=y \
        "SERVER_PORT=${installer_port}" \
        ENABLE_IPV6=n \
        CREATE_INITIAL_CLIENT=no \
        "$awg_installer" >"$installer_log" 2>&1 || true
    else
      env AUTO_INSTALL=y \
        "SERVER_PORT=${installer_port}" \
        ENABLE_IPV6=n \
        CREATE_INITIAL_CLIENT=no \
        "$awg_installer" >"$installer_log" 2>&1 || true
    fi
  fi

  command -v awg >/dev/null 2>&1 || die "Выбран amneziawg, но бинарник awg не установлен (см. ${installer_log} и /tmp/amneziawg-apt.log)"
  command -v awg-quick >/dev/null 2>&1 || die "Выбран amneziawg, но бинарник awg-quick не установлен (см. ${installer_log} и /tmp/amneziawg-apt.log)"
  ensure_amnezia_kernel_module
}

awg_quick_unit_available() {
  [[ -f /usr/lib/systemd/system/awg-quick@.service || -f /lib/systemd/system/awg-quick@.service ]] \
    && return 0
  systemctl cat 'awg-quick@.service' >/dev/null 2>&1
}

switch_to_awg_quick_unit() {
  local iface=$1
  command -v systemctl >/dev/null 2>&1 || return 0
  local wg_unit="wg-quick@${iface}.service"
  local awg_unit="awg-quick@${iface}.service"

  publish_amnezia_iface_conf "$iface"
  awg_quick_unit_available \
    || die "Выбран amneziawg, но systemd unit awg-quick@.service не найден"

  # Сначала освобождаем интерфейс у wg-quick (иначе awg-quick: already exists).
  systemctl stop "$wg_unit" >/dev/null 2>&1 || true
  systemctl disable "$wg_unit" >/dev/null 2>&1 || true
  if command -v wg-quick >/dev/null 2>&1; then
    wg-quick down "$iface" >/dev/null 2>&1 || true
  fi
  ip link delete "$iface" >/dev/null 2>&1 || true
  # Легаси awg0 от полного wiresock-installer не должен держать порт.
  systemctl stop 'awg-quick@awg0.service' >/dev/null 2>&1 || true
  ip link delete awg0 >/dev/null 2>&1 || true

  ensure_amnezia_kernel_module
  systemctl enable "$awg_unit" >/dev/null 2>&1 || die "Не удалось enable ${awg_unit}"
  local awg_err=''
  if ! awg_err=$(systemctl restart "$awg_unit" 2>&1); then
    if ! awg_err=$(systemctl start "$awg_unit" 2>&1); then
      printf '%s\n' "Ошибка! Не удалось запустить ${awg_unit}" >&2
      printf '%s\n' "systemctl: ${awg_err}" >&2
      systemctl status "$awg_unit" --no-pager -l >&2 || true
      journalctl -u "$awg_unit" -n 80 --no-pager >&2 || true
      die "Не удалось запустить ${awg_unit}"
    fi
  fi
  systemctl is-active --quiet "$awg_unit" 2>/dev/null \
    || die "Не удалось запустить ${awg_unit} (не active)"
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
