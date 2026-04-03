#!/usr/bin/env bash
# 07_setmtproxy
#
# Установка Telegram MTProxy (ветка debian): сборка в /opt/MTProxy, systemd mtproxy.service,
# секрет и ссылка tg:// в каталогах рядом с артефактами WireGuard.
#
# Переменные окружения (export, 05_setdomain.sh и 06_setwireguard.sh) или из файла
# /root/.vpconnect-configure.env (06 записывает VPCONFIGURE_WG_* после каждого успешного запуска).
#   VPCONFIGURE_DOMAIN — хост в mtproxy.link
#   VPCONFIGURE_WG_PRIVATE_KEY_PATH — dirname → mtproxy_secret.txt
#   VPCONFIGURE_WG_CLIENT_CONFIG_PATH — каталог для mtproxy.link
# Если WG-переменные пусты: /etc/wireguard/privatekey и /usr/wireguard/client_config — каталоги создаются,
# при отсутствии файла privatekey (и наличии wg) генерируется ключ.
#
# Перед настройкой выставляются (и экспортируются):
#   VPCONFIGURE_MTPROXY_PORT (по умолчанию 443)
#   VPCONFIGURE_MTPROXY_SECRET_PATH
#   VPCONFIGURE_MTPROXY_LINK_PATH
#   VPCONFIGURE_MTPROXY_INSTALL_DIR=/opt/MTProxy
#
# Сначала stdout: result:…; message:… и поля; при --export — строки export …; пояснения — stderr.
#
#   --mtproxy-port N   UDP-порт прокси (по умолчанию 443)
#   --export           после result вывести export VPCONFIGURE_MTPROXY_*
#   --persist [FILE]   записать переменные в /root/.vpconnect-configure.env (или FILE)
#
# Нужна VPCONFIGURE_GIT_BRANCH из 01_getosversion.sh.
# Пакет git не ставится здесь — только в 02_gitinstall.sh (цепочка 00–03 обязательна).

set -euo pipefail

MTP_ROOT='/opt/MTProxy'
DEFAULT_MTPROXY_PORT=443
DEFAULT_PERSIST_FILE='/root/.vpconnect-configure.env'
SYSTEMD_NAME='mtproxy'
WG_PRIV_DEFAULT='/etc/wireguard/privatekey'
WG_CLIENT_DIR_DEFAULT='/usr/wireguard/client_config'

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
Установка MTProxy (ветка debian). Нужны VPCONFIGURE_DOMAIN; пути WG из export, из
${DEFAULT_PERSIST_FILE} или умолчания ${WG_PRIV_DEFAULT} и ${WG_CLIENT_DIR_DEFAULT} (каталоги/ключ создаются при необходимости).

  --mtproxy-port N   Порт UDP (по умолчанию ${DEFAULT_MTPROXY_PORT})

  --export           Строки export VPCONFIGURE_MTPROXY_* после result
  --persist [FILE]   Сохранить переменные в env-файл (${DEFAULT_PERSIST_FILE} по умолчанию)

  -h, --help

Каталог сборки: ${MTP_ROOT}
Файлы: mtproxy_secret.txt рядом с WG private key; mtproxy.link в WG client config.
EOF
}

expand_tilde() {
  local p=$1
  if [[ "$p" == '~' || "$p" == ~/* ]]; then
    p="${p/\~/$HOME}"
  fi
  printf '%s' "$p"
}

vpconfigure_source_saved_env() {
  local f
  f="$(expand_tilde "${1:-$DEFAULT_PERSIST_FILE}")"
  [[ -r "$f" ]] || return 0
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  . "$f"
  set +a
  printf '%s\n' "Загружены переменные из ${f}" >&2
}

require_root() {
  [[ "${EUID:-0}" -eq 0 ]] || die "Запускайте от root"
}

# Каталог для privatekey (700), при отсутствии файла — wg genkey; каталог client_config (755).
ensure_wg_private_and_client_paths() {
  local priv=$1
  local cdir=$2
  local pdir
  pdir="$(dirname -- "$priv")"
  install -d -m 700 -- "$pdir"
  if [[ ! -f "$priv" ]]; then
    command -v wg >/dev/null 2>&1 || die "Нет файла ${priv} и команды wg (нужен пакет wireguard-tools)"
    umask 077
    wg genkey >"$priv"
    umask 022
    chmod 600 -- "$priv"
    printf '%s\n' "Создан файл ключа WireGuard: ${priv}" >&2
  fi
  install -d -m 755 -- "$cdir"
}

open_mtproxy_udp_in_firewall() {
  local port=$1

  if command -v ufw >/dev/null 2>&1; then
    printf '%s\n' "Обнаружен ufw: добавляю UDP ${port} (vpconnect-mtproxy)…" >&2
    local ufw_out
    if ufw_out=$(ufw allow "${port}/udp" comment 'vpconnect-mtproxy' 2>&1); then
      printf '%s\n' "$ufw_out" >&2
      if ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
        ufw reload >/dev/null 2>&1 || printf '%s\n' "ufw: reload не выполнен." >&2
      fi
      return 0
    fi
    printf '%s\n' "ufw: не удалось добавить порт: ${ufw_out}" >&2
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    printf '%s\n' "firewalld: добавляю ${port}/udp…" >&2
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 \
      && firewall-cmd --add-port="${port}/udp" >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1 \
      && printf '%s\n' "firewalld: ${port}/udp добавлен." >&2
    return 0
  fi

  printf '%s\n' "Откройте UDP ${port} вручную, если используется другой файрвол." >&2
}

merge_mtproxy_into_env_file() {
  local f=$1
  shift
  local d tmp
  d="$(dirname -- "$f")"
  [[ -d "$d" ]] || mkdir -p -- "$d"
  tmp="$(mktemp)"
  umask 077
  if [[ -f "$f" ]]; then
    grep -vE '^export[[:space:]]+VPCONFIGURE_MTPROXY_(PORT|SECRET_PATH|LINK_PATH|INSTALL_DIR)=|^# VPCONFIGURE_MTPROXY \(07_setmtproxy' "$f" >"$tmp" || true
  else
    : >"$tmp"
  fi
  {
    if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" 2>/dev/null || true)" != $'\n' ]]; then
      printf '\n'
    fi
    printf '# VPCONFIGURE_MTPROXY (07_setmtproxy.sh --persist)\n'
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
    printf '# Generated by vpconnect-configure (--persist, login shells)\n'
    printf '[ -r %q ] && . %q\n' "$env_file" "$env_file"
  } >"$hook"
  chmod 644 -- "$hook" 2>/dev/null || true
  return 0
}

install_bashrc_hook() {
  local env_file=$1
  local bashrc="${HOME:-/root}/.bashrc"
  local marker="# vpconnect-configure env (01/05/06/07 --persist)"

  if [[ -f "$bashrc" ]] && grep -qF "$marker" "$bashrc" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n%s\n' "$marker"
    printf '[ -r %q ] && . %q\n' "$env_file" "$env_file"
  } >>"$bashrc"
  return 0
}

emit_mtproxy_exports() {
  printf 'export VPCONFIGURE_MTPROXY_PORT=%q\n' "$1"
  printf 'export VPCONFIGURE_MTPROXY_SECRET_PATH=%q\n' "$2"
  printf 'export VPCONFIGURE_MTPROXY_LINK_PATH=%q\n' "$3"
  printf 'export VPCONFIGURE_MTPROXY_INSTALL_DIR=%q\n' "$4"
}

run_debian() {
  local opt_port=''
  local mode_export=0
  local persist=0
  local persist_file=$DEFAULT_PERSIST_FILE

  while [[ $# -gt 0 ]]; do
    case $1 in
      --mtproxy-port)
        [[ $# -ge 2 ]] || die "После --mtproxy-port нужен номер порта"
        opt_port=$2
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

  vpconfigure_source_saved_env "$DEFAULT_PERSIST_FILE"

  if [[ -z "${VPCONFIGURE_WG_PRIVATE_KEY_PATH:-}" ]]; then
    export VPCONFIGURE_WG_PRIVATE_KEY_PATH="$WG_PRIV_DEFAULT"
    printf '%s\n' "VPCONFIGURE_WG_PRIVATE_KEY_PATH не задан — использую ${WG_PRIV_DEFAULT}" >&2
  fi
  if [[ -z "${VPCONFIGURE_WG_CLIENT_CONFIG_PATH:-}" ]]; then
    export VPCONFIGURE_WG_CLIENT_CONFIG_PATH="$WG_CLIENT_DIR_DEFAULT"
    printf '%s\n' "VPCONFIGURE_WG_CLIENT_CONFIG_PATH не задан — использую ${WG_CLIENT_DIR_DEFAULT}" >&2
  fi

  : "${VPCONFIGURE_DOMAIN:?Задайте VPCONFIGURE_DOMAIN (05_setdomain.sh) или добавьте в ${DEFAULT_PERSIST_FILE}}"
  : "${VPCONFIGURE_WG_PRIVATE_KEY_PATH:?}"
  : "${VPCONFIGURE_WG_CLIENT_CONFIG_PATH:?}"

  [[ -n "$opt_port" ]] || opt_port=$DEFAULT_MTPROXY_PORT
  if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [[ "$opt_port" -lt 1 || "$opt_port" -gt 65535 ]]; then
    die "Некорректный порт MTProxy: ${opt_port} (нужно 1–65535)"
  fi

  persist_file="$(expand_tilde "$persist_file")"

  local wg_priv
  wg_priv="$(expand_tilde "$VPCONFIGURE_WG_PRIVATE_KEY_PATH")"
  local wg_conf_dir
  wg_conf_dir="$(expand_tilde "$VPCONFIGURE_WG_CLIENT_CONFIG_PATH")"

  local secret_dir
  secret_dir="$(dirname -- "$wg_priv")"
  local secret_path="${secret_dir}/mtproxy_secret.txt"
  local link_path="${wg_conf_dir}/mtproxy.link"
  local effective_host
  effective_host=$(printf '%s' "$VPCONFIGURE_DOMAIN" | tr -d '\r\n')

  export VPCONFIGURE_MTPROXY_PORT="$opt_port"
  export VPCONFIGURE_MTPROXY_SECRET_PATH="$secret_path"
  export VPCONFIGURE_MTPROXY_LINK_PATH="$link_path"
  export VPCONFIGURE_MTPROXY_INSTALL_DIR="$MTP_ROOT"

  require_root

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl build-essential libssl-dev zlib1g-dev xxd wireguard-tools

  command -v git >/dev/null 2>&1 || die "git не найден в PATH, сначала 02_gitinstall.sh"

  ensure_wg_private_and_client_paths "$wg_priv" "$wg_conf_dir"

  local SECRET
  if [[ -f "$secret_path" && -s "$secret_path" ]]; then
    SECRET=$(tr -d ' \t\r\n' <"$secret_path")
    [[ -n "$SECRET" ]] || die "Файл секрета пуст: ${secret_path}"
    printf '%s\n' "Использую существующий секрет из ${secret_path}" >&2
  else
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    umask 077
    printf '%s' "$SECRET" >"$secret_path"
    umask 022
    chmod 600 -- "$secret_path"
    printf '%s\n' "Записан новый секрет: ${secret_path}" >&2
  fi

  if [[ ! -d "${MTP_ROOT}/.git" ]]; then
    rm -rf -- "$MTP_ROOT"
    git clone --depth 1 https://github.com/TelegramMessenger/MTProxy.git "$MTP_ROOT" \
      || die "git clone MTProxy не выполнен"
  fi

  local nj
  nj=$(nproc 2>/dev/null || printf '2')
  make -C "$MTP_ROOT" -j"$nj" || die "Сборка MTProxy в ${MTP_ROOT} не удалась"

  local BIN_DIR="${MTP_ROOT}/objs/bin"
  cd "$BIN_DIR"
  curl -fsSL -o proxy-multi.conf https://core.telegram.org/getProxyConfig \
    || die "Не удалось скачать proxy-multi.conf"
  curl -fsSL -o proxy-secret https://core.telegram.org/getProxySecret \
    || die "Не удалось скачать proxy-secret"

  umask 022
  printf 'tg://proxy?server=%s&port=%s&secret=dd%s\n' "$effective_host" "$opt_port" "$SECRET" >"$link_path"
  chmod 644 -- "$link_path"
  printf '%s\n' "Ссылка: ${link_path}" >&2

  cat >/etc/systemd/system/${SYSTEMD_NAME}.service <<EOF
[Unit]
Description=Telegram MTProxy
After=network.target

[Service]
Type=simple
WorkingDirectory=${BIN_DIR}
ExecStart=${BIN_DIR}/mtproto-proxy -u nobody -p ${opt_port} -H 8888 -S ${SECRET} --aes-pwd ${BIN_DIR}/proxy-secret ${BIN_DIR}/proxy-multi.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl disable mtproto-proxy 2>/dev/null || true
  rm -f /etc/systemd/system/mtproto-proxy.service

  systemctl daemon-reload
  systemctl enable "${SYSTEMD_NAME}"
  systemctl restart "${SYSTEMD_NAME}" 2>/dev/null || systemctl start "${SYSTEMD_NAME}" 2>/dev/null \
    || die "Не удалось запустить ${SYSTEMD_NAME}.service"

  open_mtproxy_udp_in_firewall "$opt_port"

  vp_result_line success "MTProxy установлен и запущен" \
    "mtproxy_port:${opt_port}" \
    "mtproxy_secret_path:${secret_path}" \
    "mtproxy_link_path:${link_path}" \
    "mtproxy_install_dir:${MTP_ROOT}"

  if [[ "$mode_export" -eq 1 ]]; then
    emit_mtproxy_exports "$opt_port" "$secret_path" "$link_path" "$MTP_ROOT"
  fi

  if [[ "$persist" -eq 1 ]]; then
    merge_mtproxy_into_env_file "$persist_file" \
      VPCONFIGURE_MTPROXY_PORT "$opt_port" \
      VPCONFIGURE_MTPROXY_SECRET_PATH "$secret_path" \
      VPCONFIGURE_MTPROXY_LINK_PATH "$link_path" \
      VPCONFIGURE_MTPROXY_INSTALL_DIR "$MTP_ROOT"
    install_bashrc_hook "$persist_file"
    if install_login_profile_hook "$persist_file"; then
      printf '%s\n' "Переменные VPCONFIGURE_MTPROXY_* записаны в ${persist_file}" >&2
    else
      printf '%s\n' "Переменные записаны в ${persist_file} (без /etc/profile.d)" >&2
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
      printf '%s\n' "Ветка ${b}: 07_setmtproxy.sh не реализован." >&2
      vp_result_line warning "ветка ${b}, скрипт не реализован" \
        "mtproxy_port:unset" \
        "mtproxy_secret_path:unset" \
        "mtproxy_link_path:unset"
      ;;
  esac
}

main "$@"
