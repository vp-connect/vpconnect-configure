#!/usr/bin/env bash
# 06_setwireguard
#
# Установка WireGuard (только ветка debian): пакеты, серверные ключи, <iface>.conf, systemd wg-quick@<iface>.
# Имя интерфейса WG: только автоопределение (wg/detect_wg_iface.inc.sh) — по умолчанию wg0; если уже есть
# другой WG из «wg show» или ровно один /etc/wireguard/wg*.conf — берётся он; в env записывается VPCONFIGURE_WIREGUARD_INTERFACE_NAME.
# Внешний (WAN) интерфейс для NAT: VPCONFIGURE_WG_WAN_IFACE или --wg-wan-interface; иначе при PostUp
# определяется через «ip -4 route show default» (не хардкод eth0).
# Шлюз для клиентов: net.ipv4.ip_forward=1 (sysctl.d) и PostUp/PostDown — FORWARD для %i и MASQUERADE на WAN.
# После запуска: при наличии ufw или активного firewalld — правило UDP для порта WG и применение.
# Клиентов и клиентские ключи/конфиги не создаём — только сервер.
# Управление клиентами на уже настроенном сервере — отдельные скрипты в vpconnect-configure/wg/ (см. wg/README.md).
# После успешной настройки интерфейса WG: все *.sh в каталоге wg/ получают chmod +x и симлинки в /usr/local/bin.
#
# До настройки выставляются переменные окружения (для последующих скриптов и вызова из vpconnect_install):
#   VPCONFIGURE_WG_PORT
#   VPCONFIGURE_WG_CLIENT_CERT_PATH
#   VPCONFIGURE_WG_CLIENT_CONFIG_PATH
#   VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH — файл с публичным ключом сервера в каталоге сертификатов
#   VPCONFIGURE_WG_PRIVATE_KEY_PATH=/etc/wireguard/privatekey
#
# Используются ранее заданные (по желанию): VPCONFIGURE_DOMAIN — в эту версию <iface>.conf не пишется
# (нет секции Peer), но доступна среде после 05_setdomain.sh.
#
# Сначала stdout: result:…; message:… и поля; при --export далее строки export …; пояснения — stderr.
#
# Опционально:
#   --wg-port N                  UDP-порт (по умолчанию 51820)
#   --wg-wan-interface NAME      внешний интерфейс для MASQUERADE (env: VPCONFIGURE_WG_WAN_IFACE); иначе авто
#   --wg-client-cert-path PATH   (по умолчанию /usr/wireguard/client_cert)
#   --wg-client-config-path PATH (по умолчанию /usr/wireguard/client_config)
#   --export                     после result печатать export VPCONFIGURE_WG_* (для eval)
#   --persist [FILE]             хуки ~/.bashrc и /etc/profile.d для загрузки FILE при входе
#
# После успеха VPCONFIGURE_WG_* всегда дописываются в FILE (по умолчанию /root/.vpconnect-configure.env),
# чтобы 07_setmtproxy.sh и др. могли подхватить их в новой сессии без ручного export.
#
# Нужна VPCONFIGURE_GIT_BRANCH из 01_getosversion.sh.

set -euo pipefail

_VPCONF_SCRIPT_06=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
_VPCONF_ROOT=$(cd "$(dirname "$_VPCONF_SCRIPT_06")" && pwd)
# shellcheck source=wg/detect_wg_iface.inc.sh
source "${_VPCONF_ROOT}/wg/detect_wg_iface.inc.sh"
# shellcheck source=lib/vpconfigure_hooks.inc.sh
source "${_VPCONF_ROOT}/lib/vpconfigure_hooks.inc.sh"
# shellcheck source=lib/vpconfigure_firewall.inc.sh
source "${_VPCONF_ROOT}/lib/vpconfigure_firewall.inc.sh"

WG_ETC='/etc/wireguard'
WG_PRIV="${WG_ETC}/privatekey"
SERVER_PUB_BASENAME='wg_server_public.key'

DEFAULT_WG_PORT=51820
DEFAULT_CERT='/usr/wireguard/client_cert'
DEFAULT_CONF_DIR='/usr/wireguard/client_config'
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
Установка WireGuard (сервер, ветка debian). Клиенты не создаются.

  --wg-port N                    UDP-порт прослушивания (по умолчанию ${DEFAULT_WG_PORT})

  --wg-wan-interface NAME        Исходящий интерфейс для NAT (MASQUERADE). Без опции — определяется при подъёме
                                 туннеля через default route (env: VPCONFIGURE_WG_WAN_IFACE)

  --wg-client-cert-path PATH     Каталог для артефиката публичного ключа сервера
                                 (по умолчанию ${DEFAULT_CERT})

  --wg-client-config-path PATH   Каталог для будущих клиентских конфигов (только переменная окружения)
                                 (по умолчанию ${DEFAULT_CONF_DIR})

  --export                       После строки result вывести export VPCONFIGURE_WG_*
  --persist [FILE]             Сохранить переменные в env-файл (${DEFAULT_PERSIST_FILE} по умолчанию)

  -h, --help

Файлы: приватный ключ ${WG_PRIV}; конфиг \${WG_ETC}/<iface>.conf; публичный ключ в каталоге cert (${SERVER_PUB_BASENAME}).

Пример:
  export VPCONFIGURE_GIT_BRANCH=debian
  bash ./06_setwireguard.sh --export
  bash ./06_setwireguard.sh --wg-port 51830 --persist
EOF
}

expand_tilde() {
  local p=$1
  if [[ "$p" == '~' || "$p" == ~/* ]]; then
    p="${p/\~/$HOME}"
  fi
  printf '%s' "$p"
}

require_root() {
  [[ "${EUID:-0}" -eq 0 ]] || die "Запускайте от root"
}

# Постоянное включение IPv4 forwarding (клиенты WG выходят в интернет через сервер).
ensure_ipv4_forward_sysctl() {
  local dropin=/etc/sysctl.d/99-vpconnect-wireguard-forward.conf
  umask 022
  printf '%s\n' 'net.ipv4.ip_forward=1' >"$dropin"
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -q -p "$dropin" 2>/dev/null || sysctl -q -w net.ipv4.ip_forward=1 || true
  fi
  # Дублируем в /etc/sysctl.conf, если строки ещё нет (как в типовых инструкциях).
  if [[ -f /etc/sysctl.conf ]] && ! grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf; then
    printf '\n# vpconnect-configure 06_setwireguard: forwarding for WireGuard NAT\nnet.ipv4.ip_forward=1\n' >>/etc/sysctl.conf
  fi
  printf '%s\n' "IPv4 forwarding: ${dropin} и проверка /etc/sysctl.conf" >&2
}

# После установки WG: если есть ufw или активный firewalld — открыть UDP-порт и применить.
open_wg_port_in_firewall() {
  local port=$1

  if command -v ufw >/dev/null 2>&1; then
    if vp_ufw_has_port "$port" udp; then
      printf '%s\n' "ufw: правило UDP ${port} уже есть — повторно не добавляю." >&2
    else
    printf '%s\n' "Обнаружен ufw: добавляю UDP ${port}/udp (vpconnect-wireguard)…" >&2
    local ufw_out
    if ufw_out=$(ufw allow "${port}/udp" comment 'vpconnect-wireguard' 2>&1); then
      printf '%s\n' "$ufw_out" >&2
      if ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
        if ufw reload >/dev/null 2>&1; then
          printf '%s\n' "ufw: правило применено (reload)." >&2
        else
          printf '%s\n' "ufw: правило добавлено, reload не выполнен (проверьте ufw)." >&2
        fi
      else
        printf '%s\n' "ufw: правило добавлено (сейчас неактивен — после ufw enable подхватится)." >&2
      fi
      return 0
    fi
    printf '%s\n' "ufw: не удалось добавить порт: ${ufw_out}" >&2
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      printf '%s\n' "Обнаружен активный firewalld: добавляю ${port}/udp…" >&2
      if firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 \
        && firewall-cmd --add-port="${port}/udp" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1; then
        printf '%s\n' "firewalld: порт ${port}/udp добавлен (permanent + runtime), reload выполнен." >&2
        return 0
      fi
      printf '%s\n' "firewalld: не удалось добавить порт ${port}/udp." >&2
      return 0
    fi
    printf '%s\n' "firewalld установлен, но служба не активна — откройте UDP ${port} после запуска firewalld." >&2
    return 0
  fi

  printf '%s\n' "ufw и firewalld не найдены: откройте UDP ${port} вручную, если используется другой файрвол." >&2
}

# Каталог vpconnect-configure/wg рядом с 06_setwireguard.sh: исполняемые права и имена в PATH (/usr/local/bin).
wireguard_publish_wg_scripts() {
  local configure_root wgdir
  configure_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  wgdir="${configure_root}/wg"
  if [[ ! -d "$wgdir" ]]; then
    printf '%s\n' "Предупреждение: каталог ${wgdir} не найден — публикация wg-скриптов пропущена." >&2
    return 0
  fi
  local -a scripts=()
  shopt -s nullglob
  scripts=( "${wgdir}"/*.sh )
  shopt -u nullglob
  if [[ ${#scripts[@]} -eq 0 ]]; then
    printf '%s\n' "Предупреждение: в ${wgdir} нет файлов *.sh — нечего публиковать." >&2
    return 0
  fi
  chmod a+x -- "${scripts[@]}"
  install -d -m 755 /usr/local/bin
  local f base
  for f in "${scripts[@]}"; do
    base="$(basename -- "$f")"
    ln -sf -- "$f" "/usr/local/bin/${base}"
  done
  printf '%s\n' "wg: ${#scripts[@]} скрипт(ов) в ${wgdir} — режим исполнения установлен, ссылки в /usr/local/bin (например: wg.sh help)." >&2
}

merge_wg_into_env_file() {
  local f=$1
  shift
  local d tmp
  d="$(dirname -- "$f")"
  [[ -d "$d" ]] || mkdir -p -- "$d"
  tmp="$(mktemp)"
  umask 077
  if [[ -f "$f" ]]; then
    grep -vE '^export[[:space:]]+VPCONFIGURE_(WG_(PORT|CLIENT_CERT_PATH|CLIENT_CONFIG_PATH|SERVER_PUBLIC_KEY_PATH|PRIVATE_KEY_PATH|WAN_IFACE)|WIREGUARD_INTERFACE_NAME)=|^# VPCONFIGURE_WG \(06_setwireguard' "$f" >"$tmp" || true
  else
    : >"$tmp"
  fi
  {
    if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" 2>/dev/null || true)" != $'\n' ]]; then
      printf '\n'
    fi
    printf '# VPCONFIGURE_WG (06_setwireguard.sh --persist)\n'
    while [[ $# -ge 2 ]]; do
      printf 'export %s=%q\n' "$1" "$2"
      shift 2
    done
  } >>"$tmp"
  mv -f -- "$tmp" "$f"
  chmod 600 -- "$f" 2>/dev/null || true
}

emit_exports() {
  printf 'export VPCONFIGURE_WG_PORT=%q\n' "$1"
  printf 'export VPCONFIGURE_WG_CLIENT_CERT_PATH=%q\n' "$2"
  printf 'export VPCONFIGURE_WG_CLIENT_CONFIG_PATH=%q\n' "$3"
  printf 'export VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH=%q\n' "$4"
  printf 'export VPCONFIGURE_WG_PRIVATE_KEY_PATH=%q\n' "$5"
  printf 'export VPCONFIGURE_WIREGUARD_INTERFACE_NAME=%q\n' "$6"
  if [[ -n "${7:-}" ]]; then
    printf 'export VPCONFIGURE_WG_WAN_IFACE=%q\n' "$7"
  fi
}

run_debian() {
  local opt_port=''
  local opt_wan_iface=''
  local opt_cert=$DEFAULT_CERT
  local opt_confdir=$DEFAULT_CONF_DIR
  local mode_export=0
  local persist=0
  local persist_file=$DEFAULT_PERSIST_FILE

  while [[ $# -gt 0 ]]; do
    case $1 in
      --wg-port)
        [[ $# -ge 2 ]] || die "После --wg-port нужен номер UDP-порта"
        opt_port=$2
        shift 2
        ;;
      --wg-wan-interface)
        [[ $# -ge 2 ]] || die "После --wg-wan-interface нужно имя внешнего интерфейса"
        opt_wan_iface=$2
        shift 2
        ;;
      --wg-client-cert-path)
        [[ $# -ge 2 ]] || die "После --wg-client-cert-path нужен путь"
        opt_cert=$2
        shift 2
        ;;
      --wg-client-config-path)
        [[ $# -ge 2 ]] || die "После --wg-client-config-path нужен путь"
        opt_confdir=$2
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

  [[ -n "$opt_port" ]] || opt_port=$DEFAULT_WG_PORT

  if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [[ "$opt_port" -lt 1 || "$opt_port" -gt 65535 ]]; then
    die "Некорректный UDP-порт: ${opt_port} (нужно 1–65535)"
  fi

  wan_iface="${opt_wan_iface:-${VPCONFIGURE_WG_WAN_IFACE:-}}"
  if [[ -n "$wan_iface" ]] && ! [[ "$wan_iface" =~ ^[a-zA-Z0-9._:@-]{1,32}$ ]]; then
    die "Некорректное имя внешнего интерфейса (WAN): ${wan_iface}"
  fi

  opt_cert="$(expand_tilde "$opt_cert")"
  opt_confdir="$(expand_tilde "$opt_confdir")"
  persist_file="$(expand_tilde "$persist_file")"

  require_root

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard wireguard-tools

  local wg_iface WG_CONF
  wg_iface=$(detect_wg_interface_name)
  if ! [[ "$wg_iface" =~ ^[a-zA-Z0-9._-]{1,15}$ ]]; then
    die "Некорректное автоопределённое имя интерфейса WireGuard: ${wg_iface}"
  fi
  WG_CONF="${WG_ETC}/${wg_iface}.conf"
  printf '%s\n' "WireGuard: интерфейс «${wg_iface}» (автоопределение; см. wg/detect_wg_iface.inc.sh)." >&2

  install -d -m 755 -- "$opt_cert" "$opt_confdir"
  install -d -m 700 -- "$WG_ETC"

  ensure_ipv4_forward_sysctl

  local pub_path="${opt_cert}/${SERVER_PUB_BASENAME}"
  local priv_contents
  if [[ -f "$WG_PRIV" && -s "$WG_PRIV" ]]; then
    priv_contents=$(cat -- "$WG_PRIV")
    printf '%s\n' "Сохранён существующий приватный ключ ${WG_PRIV} (повторный запуск 06)." >&2
    umask 077
    printf '%s\n' "$priv_contents" | wg pubkey >"$pub_path"
    umask 022
    chmod 600 -- "$WG_PRIV"
    chmod 644 -- "$pub_path"
  else
    umask 077
    wg genkey | tee "$WG_PRIV" | wg pubkey >"$pub_path"
    umask 022
    chmod 600 -- "$WG_PRIV"
    chmod 644 -- "$pub_path"
    priv_contents=$(cat -- "$WG_PRIV")
  fi

  umask 077
  if [[ -n "$wan_iface" ]]; then
    cat >"$WG_CONF" <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = ${opt_port}
PrivateKey = ${priv_contents}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${wan_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${wan_iface} -j MASQUERADE
EOF
  else
    # WAN при каждом up: default route (не хардкод eth0). \$(...) и \$5 — буквально в файле для wg-quick.
    cat >"$WG_CONF" <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = ${opt_port}
PrivateKey = ${priv_contents}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o \$(ip -4 route show default | awk '/default/{print \$5; exit}') -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o \$(ip -4 route show default | awk '/default/{print \$5; exit}') -j MASQUERADE
EOF
  fi
  umask 022
  chmod 600 -- "$WG_CONF"

  systemctl enable "wg-quick@${wg_iface}"
  systemctl restart "wg-quick@${wg_iface}" 2>/dev/null || systemctl start "wg-quick@${wg_iface}" 2>/dev/null \
    || die "Не удалось запустить wg-quick@${wg_iface}"

  open_wg_port_in_firewall "$opt_port"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
    printf '%s\n' \
      "Если клиенты WG не выходят в интернет: при активном ufw часто нужен ACCEPT для forward (см. /etc/default/ufw, ufw route allow)." \
      >&2
  fi

  wireguard_publish_wg_scripts

  export VPCONFIGURE_WG_PORT="$opt_port"
  export VPCONFIGURE_WG_CLIENT_CERT_PATH="$opt_cert"
  export VPCONFIGURE_WG_CLIENT_CONFIG_PATH="$opt_confdir"
  export VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH="$pub_path"
  export VPCONFIGURE_WG_PRIVATE_KEY_PATH="$WG_PRIV"
  export VPCONFIGURE_WIREGUARD_INTERFACE_NAME="$wg_iface"
  if [[ -n "$wan_iface" ]]; then
    export VPCONFIGURE_WG_WAN_IFACE="$wan_iface"
  else
    unset VPCONFIGURE_WG_WAN_IFACE 2>/dev/null || true
  fi

  local wan_field='wg_wan:auto'
  [[ -n "$wan_iface" ]] && wan_field="wg_wan:${wan_iface}"

  vp_result_line success "WireGuard установлен, интерфейс ${wg_iface} (NAT/forward для клиентов)" \
    "wg_interface:${wg_iface}" \
    "${wan_field}" \
    "wg_port:${opt_port}" \
    "wg_server_public_key_path:${pub_path}" \
    "wg_private_key_path:${WG_PRIV}" \
    "wg_ipv4_forward:1"

  if [[ "$mode_export" -eq 1 ]]; then
    emit_exports "$opt_port" "$opt_cert" "$opt_confdir" "$pub_path" "$WG_PRIV" "$wg_iface" "${wan_iface}"
  fi

  local -a merge_kv=(
    VPCONFIGURE_WG_PORT "$opt_port"
    VPCONFIGURE_WG_CLIENT_CERT_PATH "$opt_cert"
    VPCONFIGURE_WG_CLIENT_CONFIG_PATH "$opt_confdir"
    VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH "$pub_path"
    VPCONFIGURE_WG_PRIVATE_KEY_PATH "$WG_PRIV"
    VPCONFIGURE_WIREGUARD_INTERFACE_NAME "$wg_iface"
  )
  [[ -n "$wan_iface" ]] && merge_kv+=( VPCONFIGURE_WG_WAN_IFACE "$wan_iface" )
  merge_wg_into_env_file "$persist_file" "${merge_kv[@]}"
  printf '%s\n' "VPCONFIGURE_WG_* сохранены в ${persist_file} (для 07 и др.; в этой сессии уже export)." >&2

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
      printf '%s\n' "Ветка ${b}: 06_setwireguard.sh не реализован." >&2
      vp_result_line warning "ветка ${b}, скрипт не реализован" \
        "wg_port:unset" \
        "wg_server_public_key_path:unset"
      ;;
  esac
}

main "$@"
