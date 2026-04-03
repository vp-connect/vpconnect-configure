#!/usr/bin/env bash
# 06_setwireguard
#
# Установка WireGuard (только ветка debian): пакеты, серверные ключи, wg0.conf, systemd wg-quick@wg0.
# После запуска: при наличии ufw или активного firewalld — правило UDP для порта WG и применение.
# Клиентов и клиентские ключи/конфиги не создаём — только сервер.
#
# До настройки выставляются переменные окружения (для последующих скриптов и вызова из vpconnect_install):
#   VPCONFIGURE_WG_PORT
#   VPCONFIGURE_WG_CLIENT_CERT_PATH
#   VPCONFIGURE_WG_CLIENT_CONFIG_PATH
#   VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH — файл с публичным ключом сервера в каталоге сертификатов
#   VPCONFIGURE_WG_PRIVATE_KEY_PATH=/etc/wireguard/privatekey
#
# Используются ранее заданные (по желанию): VPCONFIGURE_DOMAIN — в этой версии не пишется в wg0.conf
# (нет секции Peer), но доступна среде после 05_setdomain.sh.
#
# Сначала stdout: result:…; message:… и поля; при --export далее строки export …; пояснения — stderr.
#
# Опционально:
#   --wg-port N                  UDP-порт (по умолчанию 51820)
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

WG_ETC='/etc/wireguard'
WG_PRIV="${WG_ETC}/privatekey"
WG_CONF="${WG_ETC}/wg0.conf"
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

  --wg-client-cert-path PATH     Каталог для артефиката публичного ключа сервера
                                 (по умолчанию ${DEFAULT_CERT})

  --wg-client-config-path PATH   Каталог для будущих клиентских конфигов (только переменная окружения)
                                 (по умолчанию ${DEFAULT_CONF_DIR})

  --export                       После строки result вывести export VPCONFIGURE_WG_*
  --persist [FILE]             Сохранить переменные в env-файл (${DEFAULT_PERSIST_FILE} по умолчанию)

  -h, --help

Файлы: приватный ключ ${WG_PRIV}, конфиг ${WG_CONF}, публичный ключ сервера — в каталоге cert как ${SERVER_PUB_BASENAME}.

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

# После установки WG: если есть ufw или активный firewalld — открыть UDP-порт и применить.
open_wg_port_in_firewall() {
  local port=$1

  if command -v ufw >/dev/null 2>&1; then
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

merge_wg_into_env_file() {
  local f=$1
  shift
  local d tmp
  d="$(dirname -- "$f")"
  [[ -d "$d" ]] || mkdir -p -- "$d"
  tmp="$(mktemp)"
  umask 077
  if [[ -f "$f" ]]; then
    grep -vE '^export[[:space:]]+VPCONFIGURE_WG_(PORT|CLIENT_CERT_PATH|CLIENT_CONFIG_PATH|SERVER_PUBLIC_KEY_PATH|PRIVATE_KEY_PATH)=|^# VPCONFIGURE_WG \(06_setwireguard' "$f" >"$tmp" || true
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

install_login_profile_hook() {
  local env_file=$1
  local hook=/etc/profile.d/vpconnect-configure.sh
  [[ -d /etc/profile.d ]] || return 1
  umask 022
  {
    printf '# Generated by vpconnect-configure (01/05/06 --persist, login shells)\n'
    printf '[ -r %q ] && . %q\n' "$env_file" "$env_file"
  } >"$hook"
  chmod 644 -- "$hook" 2>/dev/null || true
  return 0
}

install_bashrc_hook() {
  local env_file=$1
  local bashrc="${HOME:-/root}/.bashrc"
  local marker="# vpconnect-configure env (01_getosversion / 05_setdomain / 06_setwireguard --persist)"

  if [[ -f "$bashrc" ]] && grep -qF "$marker" "$bashrc" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n%s\n' "$marker"
    printf '[ -r %q ] && . %q\n' "$env_file" "$env_file"
  } >>"$bashrc"
  return 0
}

emit_exports() {
  printf 'export VPCONFIGURE_WG_PORT=%q\n' "$1"
  printf 'export VPCONFIGURE_WG_CLIENT_CERT_PATH=%q\n' "$2"
  printf 'export VPCONFIGURE_WG_CLIENT_CONFIG_PATH=%q\n' "$3"
  printf 'export VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH=%q\n' "$4"
  printf 'export VPCONFIGURE_WG_PRIVATE_KEY_PATH=%q\n' "$5"
}

run_debian() {
  local opt_port=''
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

  opt_cert="$(expand_tilde "$opt_cert")"
  opt_confdir="$(expand_tilde "$opt_confdir")"
  persist_file="$(expand_tilde "$persist_file")"

  require_root

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard wireguard-tools

  install -d -m 755 -- "$opt_cert" "$opt_confdir"
  install -d -m 700 -- "$WG_ETC"

  local pub_path="${opt_cert}/${SERVER_PUB_BASENAME}"
  umask 077
  wg genkey | tee "$WG_PRIV" | wg pubkey >"$pub_path"
  umask 022
  chmod 600 -- "$WG_PRIV"
  chmod 644 -- "$pub_path"

  local priv_contents
  priv_contents=$(cat -- "$WG_PRIV")

  umask 077
  cat >"$WG_CONF" <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = ${opt_port}
PrivateKey = ${priv_contents}
EOF
  umask 022
  chmod 600 -- "$WG_CONF"

  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0 2>/dev/null || systemctl start wg-quick@wg0 2>/dev/null \
    || die "Не удалось запустить wg-quick@wg0"

  open_wg_port_in_firewall "$opt_port"

  export VPCONFIGURE_WG_PORT="$opt_port"
  export VPCONFIGURE_WG_CLIENT_CERT_PATH="$opt_cert"
  export VPCONFIGURE_WG_CLIENT_CONFIG_PATH="$opt_confdir"
  export VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH="$pub_path"
  export VPCONFIGURE_WG_PRIVATE_KEY_PATH="$WG_PRIV"

  vp_result_line success "WireGuard установлен, интерфейс wg0" \
    "wg_port:${opt_port}" \
    "wg_server_public_key_path:${pub_path}" \
    "wg_private_key_path:${WG_PRIV}"

  if [[ "$mode_export" -eq 1 ]]; then
    emit_exports "$opt_port" "$opt_cert" "$opt_confdir" "$pub_path" "$WG_PRIV"
  fi

  merge_wg_into_env_file "$persist_file" \
    VPCONFIGURE_WG_PORT "$opt_port" \
    VPCONFIGURE_WG_CLIENT_CERT_PATH "$opt_cert" \
    VPCONFIGURE_WG_CLIENT_CONFIG_PATH "$opt_confdir" \
    VPCONFIGURE_WG_SERVER_PUBLIC_KEY_PATH "$pub_path" \
    VPCONFIGURE_WG_PRIVATE_KEY_PATH "$WG_PRIV"
  printf '%s\n' "VPCONFIGURE_WG_* сохранены в ${persist_file} (для 07 и др.; в этой сессии уже export)." >&2

  if [[ "$persist" -eq 1 ]]; then
    install_bashrc_hook "$persist_file"
    if install_login_profile_hook "$persist_file"; then
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
