#!/usr/bin/env bash
# 08_setvpmanage
#
# Установка VPManage (ветка debian): клон в /opt/VPManage, venv, settings.env, systemd (gunicorn + Flask).
# Пакет git не ставится здесь — только в 02_gitinstall.sh (цепочка 00–03 обязательна).
# Репозиторий: https://github.com/vp-connect/vpconnect-manage.git
#
# Переменные из 05/06/07 и /root/.vpconnect-configure.env; при отсутствии — умолчания путей WG.
# Экспортируются пути к артефактам MTProxy (как в 07): VPCONFIGURE_MTPROXY_SECRET_PATH,
# VPCONFIGURE_MTPROXY_LINK_PATH (файлы создаёт 07_setmtproxy.sh, здесь только пути для среды и приложения).
#
# CLI: --http-port (по умолчанию 80), --vpm-password (необязательно; иначе 30 символов A-Za-z0-9),
#      --export, --persist [FILE]
#
# Результат: result:success; …; password:<значение> (если пароль сгенерирован или передан).
# settings.env: полный набор ключей как в vpconnect-manage/settings.env (см. manage_site/settings.py).
# Доп. переопределения из окружения перед запуском: VPCONFIGURE_WG_CONF_PATH, VPCONFIGURE_WIREGUARD_*,
# VPCONFIGURE_VPM_LOGIN_MAX_FAILED_ATTEMPTS, VPCONFIGURE_VPM_LOGIN_LOCKOUT_MINUTES.
#
# Нужны VPCONFIGURE_GIT_BRANCH и VPCONFIGURE_DOMAIN (в окружении или в ${DEFAULT_PERSIST_FILE} —
# при запуске bash ./08_… без login-shell файл подхватывается в начале main()).

set -euo pipefail

_VPCONF_SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/vpconfigure_hooks.inc.sh
source "${_VPCONF_SCRIPT_DIR}/lib/vpconfigure_hooks.inc.sh"
# shellcheck source=lib/vpconfigure_firewall.inc.sh
source "${_VPCONF_SCRIPT_DIR}/lib/vpconfigure_firewall.inc.sh"

VPM_INSTALL='/opt/VPManage'
VPM_GIT_URL='https://github.com/vp-connect/vpconnect-manage.git'
VPM_GIT_BRANCH='main'
DEFAULT_HTTP_PORT=80
SYSTEMD_SERVICE='vpconnect-manage'
DEFAULT_PERSIST_FILE='/root/.vpconnect-configure.env'
WG_PRIV_DEFAULT='/etc/wireguard/privatekey'
WG_CLIENT_DIR_DEFAULT='/usr/wireguard/client_config'
WG_CLIENT_CERT_DEFAULT='/usr/wireguard/client_cert'

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
Установка VPManage (ветка debian). Нужен VPCONFIGURE_DOMAIN; пути из env или ${DEFAULT_PERSIST_FILE}.

  --http-port N         HTTP-порт gunicorn (по умолчанию ${DEFAULT_HTTP_PORT})
  --vpm-password PASS   Пароль админки (иначе сгенерируется 30 символов A-Za-z0-9)

  --export              После result — export VPCONFIGURE_VPM_* и связанных переменных
  --persist [FILE]      Записать переменные в env-файл (${DEFAULT_PERSIST_FILE} по умолчанию)

  -h, --help

Каталог: ${VPM_INSTALL}
Репозиторий: ${VPM_GIT_URL} (ветка ${VPM_GIT_BRANCH})
systemd: ${SYSTEMD_SERVICE}.service
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

# head закрывает pipe → tr получает SIGPIPE; при set -o pipefail весь конвейер даёт ненулевой код
# и set -e обрывает скрипт без die(). Подпроцесс отключает pipefail только для этой строки.
gen_vpm_password() (
  set +o pipefail 2>/dev/null || true
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 30
)

# 32 символа: строчные латинские буквы и дефис (для FLASK_SECRET_KEY).
gen_flask_secret_key() (
  set +o pipefail 2>/dev/null || true
  LC_ALL=C tr -dc 'a-z-' </dev/urandom 2>/dev/null | head -c 32
)

open_vpm_http_in_firewall() {
  local port=$1

  if command -v ufw >/dev/null 2>&1; then
    if vp_ufw_has_port "$port" tcp; then
      printf '%s\n' "ufw: правило TCP ${port} уже есть — повторно не добавляю." >&2
    else
    printf '%s\n' "ufw: добавляю TCP ${port} (vpconnect-vpmanage)…" >&2
    local ufw_out
    if ufw_out=$(ufw allow "${port}/tcp" comment 'vpconnect-vpmanage' 2>&1); then
      printf '%s\n' "$ufw_out" >&2
      if ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
        ufw reload >/dev/null 2>&1 || true
      fi
      return 0
    fi
    printf '%s\n' "ufw: не удалось добавить порт: ${ufw_out}" >&2
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    printf '%s\n' "firewalld: TCP ${port}…" >&2
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 \
      && firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1
    return 0
  fi

  printf '%s\n' "Откройте TCP ${port} вручную при необходимости." >&2
}

merge_vpm_into_env_file() {
  local f=$1
  shift
  local d tmp
  d="$(dirname -- "$f")"
  [[ -d "$d" ]] || mkdir -p -- "$d"
  tmp="$(mktemp)"
  umask 077
  if [[ -f "$f" ]]; then
    grep -vE '^export[[:space:]]+VPCONFIGURE_VPM_(HTTP_PORT|PASSWORD|INSTALL_PATH|SYSTEMD_SERVICE)=|^# VPCONFIGURE_VPM \(08_setvpmanage' "$f" >"$tmp" || true
  else
    : >"$tmp"
  fi
  {
    if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" 2>/dev/null || true)" != $'\n' ]]; then
      printf '\n'
    fi
    printf '# VPCONFIGURE_VPM (08_setvpmanage.sh --persist)\n'
    while [[ $# -ge 2 ]]; do
      printf 'export %s=%q\n' "$1" "$2"
      shift 2
    done
  } >>"$tmp"
  mv -f -- "$tmp" "$f"
  chmod 600 -- "$f" 2>/dev/null || true
}

emit_vpm_exports() {
  printf 'export VPCONFIGURE_VPM_HTTP_PORT=%q\n' "$1"
  printf 'export VPCONFIGURE_VPM_PASSWORD=%q\n' "$2"
  printf 'export VPCONFIGURE_VPM_INSTALL_PATH=%q\n' "$3"
  printf 'export VPCONFIGURE_VPM_SYSTEMD_SERVICE=%q\n' "$4"
  printf 'export VPCONFIGURE_MTPROXY_SECRET_PATH=%q\n' "$5"
  printf 'export VPCONFIGURE_MTPROXY_LINK_PATH=%q\n' "$6"
}

run_debian() {
  local opt_http=''
  local opt_pw=''
  local mode_export=0
  local persist=0
  local persist_file=$DEFAULT_PERSIST_FILE

  while [[ $# -gt 0 ]]; do
    case $1 in
      --http-port)
        [[ $# -ge 2 ]] || die "После --http-port нужен номер порта"
        opt_http=$2
        shift 2
        ;;
      --vpm-password)
        [[ $# -ge 2 ]] || die "После --vpm-password нужна строка"
        opt_pw=$2
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

  if [[ -z "${VPCONFIGURE_WG_PRIVATE_KEY_PATH:-}" ]]; then
    export VPCONFIGURE_WG_PRIVATE_KEY_PATH="$WG_PRIV_DEFAULT"
  fi
  if [[ -z "${VPCONFIGURE_WG_CLIENT_CONFIG_PATH:-}" ]]; then
    export VPCONFIGURE_WG_CLIENT_CONFIG_PATH="$WG_CLIENT_DIR_DEFAULT"
  fi
  if [[ -z "${VPCONFIGURE_WG_CLIENT_CERT_PATH:-}" ]]; then
    export VPCONFIGURE_WG_CLIENT_CERT_PATH="$WG_CLIENT_CERT_DEFAULT"
  fi

  [[ -n "${VPCONFIGURE_DOMAIN:-}" ]] \
    || die "Задайте VPCONFIGURE_DOMAIN (05_setdomain.sh) или добавьте export в ${DEFAULT_PERSIST_FILE}"

  printf '%s\n' "VPManage: VPCONFIGURE_DOMAIN=${VPCONFIGURE_DOMAIN}; дальше — пакеты, клон, venv…" >&2

  local wg_priv_exp
  wg_priv_exp="$(expand_tilde "$VPCONFIGURE_WG_PRIVATE_KEY_PATH")"
  local wg_conf_exp
  wg_conf_exp="$(expand_tilde "$VPCONFIGURE_WG_CLIENT_CONFIG_PATH")"

  local derived_secret derived_link
  derived_secret="$(dirname -- "$wg_priv_exp")/mtproxy_secret.txt"
  derived_link="${wg_conf_exp}/mtproxy.link"

  if [[ -z "${VPCONFIGURE_MTPROXY_SECRET_PATH:-}" ]]; then
    export VPCONFIGURE_MTPROXY_SECRET_PATH="$derived_secret"
  fi
  if [[ -z "${VPCONFIGURE_MTPROXY_LINK_PATH:-}" ]]; then
    export VPCONFIGURE_MTPROXY_LINK_PATH="$derived_link"
  fi

  [[ -n "$opt_http" ]] || opt_http=$DEFAULT_HTTP_PORT
  if ! [[ "$opt_http" =~ ^[0-9]+$ ]] || [[ "$opt_http" -lt 1 || "$opt_http" -gt 65535 ]]; then
    die "Некорректный HTTP-порт: ${opt_http}"
  fi

  persist_file="$(expand_tilde "$persist_file")"

  local mtproxy_link_file wg_client_conf_dir wg_keys_dir login_max login_lock wg_conf_path \
    wg_sync_min wg_if_name wg_pub_host wg_listen_port wg_dns

  mtproxy_link_file="$(expand_tilde "$VPCONFIGURE_MTPROXY_LINK_PATH")"
  wg_client_conf_dir="$(expand_tilde "${VPCONFIGURE_WIREGUARD_CLIENT_CONFIG_DIR:-$VPCONFIGURE_WG_CLIENT_CONFIG_PATH}")"
  wg_keys_dir="$(expand_tilde "${VPCONFIGURE_WIREGUARD_CLIENT_KEYS_DIR:-$VPCONFIGURE_WG_CLIENT_CERT_PATH}")"

  login_max="${VPCONFIGURE_VPM_LOGIN_MAX_FAILED_ATTEMPTS:-5}"
  login_lock="${VPCONFIGURE_VPM_LOGIN_LOCKOUT_MINUTES:-60}"
  wg_if_name="${VPCONFIGURE_WIREGUARD_INTERFACE_NAME:-}"
  if [[ -z "$wg_if_name" ]]; then
    local _08s _08r
    _08s=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
    _08r=$(cd "$(dirname "$_08s")" && pwd)
    # shellcheck source=wg/detect_wg_iface.inc.sh
    source "${_08r}/wg/detect_wg_iface.inc.sh"
    wg_if_name=$(detect_wg_interface_name)
  fi
  if [[ -v VPCONFIGURE_WG_CONF_PATH ]]; then
    wg_conf_path="$(expand_tilde "${VPCONFIGURE_WG_CONF_PATH:-}")"
  else
    wg_conf_path="/etc/wireguard/${wg_if_name}.conf"
  fi
  wg_sync_min="${VPCONFIGURE_WIREGUARD_SYNC_INTERVAL_MINUTES:-5}"
  wg_pub_host="${VPCONFIGURE_WIREGUARD_PUBLIC_HOST:-${VPCONFIGURE_DOMAIN}}"
  wg_listen_port="${VPCONFIGURE_WIREGUARD_LISTEN_PORT:-${VPCONFIGURE_WG_PORT:-0}}"
  wg_dns="${VPCONFIGURE_WIREGUARD_DNS:-8.8.8.8}"

  require_root

  if [[ ! -f "$VPCONFIGURE_MTPROXY_SECRET_PATH" ]]; then
    printf '%s\n' "Предупреждение: нет файла ${VPCONFIGURE_MTPROXY_SECRET_PATH} — выполните 07_setmtproxy.sh при необходимости." >&2
  fi
  if [[ ! -f "$VPCONFIGURE_MTPROXY_LINK_PATH" ]]; then
    printf '%s\n' "Предупреждение: нет файла ${VPCONFIGURE_MTPROXY_LINK_PATH} — выполните 07_setmtproxy.sh при необходимости." >&2
  fi

  install -d -m 755 -- "$wg_keys_dir" "$wg_client_conf_dir"

  export DEBIAN_FRONTEND=noninteractive
  printf '%s\n' "VPManage: apt-get update (без вывода пакетов, может занять несколько минут)…" >&2
  apt-get update -qq
  printf '%s\n' "VPManage: установка python3, venv, pip…" >&2
  apt-get install -y -qq python3 python3-venv python3-pip

  command -v git >/dev/null 2>&1 || die "git не найден в PATH, сначала 02_gitinstall.sh"

  if [[ ! -d "${VPM_INSTALL}/.git" ]]; then
    printf '%s\n' "VPManage: git clone ${VPM_GIT_URL} (ветка ${VPM_GIT_BRANCH})…" >&2
    mkdir -p "$(dirname -- "$VPM_INSTALL")"
    git clone -b "$VPM_GIT_BRANCH" "$VPM_GIT_URL" "$VPM_INSTALL" \
      || die "git clone не выполнен: ${VPM_GIT_URL}"
  else
    printf '%s\n' "VPManage: обновление кода в ${VPM_INSTALL}…" >&2
    git -C "$VPM_INSTALL" fetch --all --prune 2>/dev/null || true
    git -C "$VPM_INSTALL" checkout "$VPM_GIT_BRANCH" 2>/dev/null || true
    git -C "$VPM_INSTALL" pull --ff-only 2>/dev/null || true
  fi

  # Пароль и FLASK_SECRET_KEY: при повторном запуске без --vpm-password не затирать существующие.
  local app_pw flask_secret
  local settings_existing="${VPM_INSTALL}/settings.env"
  vp_strip_settings_value() {
    local v=$1
    v="${v%$'\r'}"
    if [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
      v="${v:1:${#v}-2}"
    fi
    printf '%s' "$v"
  }

  if [[ -n "$opt_pw" ]]; then
    app_pw=$opt_pw
  elif [[ -f "$settings_existing" ]]; then
    local _line
    _line=$(grep -m1 -E '^ADMIN_DEFAULT_PASSWORD=' "$settings_existing" 2>/dev/null || true)
    if [[ -n "$_line" ]]; then
      app_pw="${_line#ADMIN_DEFAULT_PASSWORD=}"
      app_pw="$(vp_strip_settings_value "$app_pw")"
    fi
  fi
  if [[ -z "${app_pw:-}" ]]; then
    app_pw="$(gen_vpm_password)"
    [[ ${#app_pw} -eq 30 ]] || die "Не удалось сгенерировать пароль"
    printf '%s\n' "Сгенерирован пароль админки (30 символов)." >&2
  elif [[ -z "$opt_pw" ]]; then
    printf '%s\n' "Сохранён пароль админки из существующего settings.env (повторный запуск)." >&2
  fi

  if [[ -f "$settings_existing" ]]; then
    local _fl
    _fl=$(grep -m1 -E '^FLASK_SECRET_KEY=' "$settings_existing" 2>/dev/null || true)
    if [[ -n "$_fl" ]]; then
      flask_secret="${_fl#FLASK_SECRET_KEY=}"
      flask_secret="$(vp_strip_settings_value "$flask_secret")"
    fi
  fi
  if [[ -z "${flask_secret:-}" ]]; then
    flask_secret="$(gen_flask_secret_key)"
    [[ ${#flask_secret} -eq 32 ]] || die "Не удалось сгенерировать FLASK_SECRET_KEY (нужно 32 символа)"
  else
    [[ ${#flask_secret} -eq 32 ]] || die "В settings.env некорректная длина FLASK_SECRET_KEY (нужно 32 символа)"
    printf '%s\n' "Сохранён FLASK_SECRET_KEY из существующего settings.env (повторный запуск)." >&2
  fi

  export VPCONFIGURE_VPM_HTTP_PORT="$opt_http"
  export VPCONFIGURE_VPM_PASSWORD="$app_pw"
  export VPCONFIGURE_VPM_INSTALL_PATH="$VPM_INSTALL"
  export VPCONFIGURE_VPM_SYSTEMD_SERVICE="$SYSTEMD_SERVICE"

  if [[ ! -d "${VPM_INSTALL}/.venv" ]]; then
    printf '%s\n' "VPManage: создание .venv…" >&2
    python3 -m venv "${VPM_INSTALL}/.venv"
  else
    printf '%s\n' "VPManage: каталог .venv уже есть, пропускаю python3 -m venv…" >&2
  fi
  printf '%s\n' "VPManage: pip install (тихий режим, подождите)…" >&2
  "${VPM_INSTALL}/.venv/bin/pip" install -U pip wheel -q
  if [[ -f "${VPM_INSTALL}/requirements.txt" ]]; then
    "${VPM_INSTALL}/.venv/bin/pip" install -r "${VPM_INSTALL}/requirements.txt" -q \
      || die "pip install -r requirements.txt не выполнен"
  fi
  "${VPM_INSTALL}/.venv/bin/pip" install -q gunicorn \
    || die "pip install gunicorn не выполнен"

  umask 077
  cat >"${VPM_INSTALL}/settings.env" <<EOF
# =============================================================================
# Файл настроек vpconnect-manage (формат KEY=value).
# Сгенерирован 08_setvpmanage.sh; при повторном запуске перезаписывается.
# Смысл параметров — README vpconnect-manage, раздел про settings.env.
# =============================================================================

# --- Веб-приложение Flask ---
# Секрет подписи cookie сессии; в продакшене — длинная случайная строка.
FLASK_SECRET_KEY=${flask_secret}

# Пароль для первичного admin_user.json и сброса из UI (опционально).
ADMIN_DEFAULT_PASSWORD=${app_pw}

# Блокировка входа после неверных попыток с одного IP.
LOGIN_MAX_FAILED_ATTEMPTS=${login_max}
LOGIN_LOCKOUT_MINUTES=${login_lock}

# --- WireGuard (пустой WIREGUARD_CONF_PATH = интеграция выключена, секция клиентов в UI скрыта) ---
# По умолчанию /etc/wireguard/<WIREGUARD_INTERFACE_NAME>.conf; если VPCONFIGURE_WIREGUARD_INTERFACE_NAME пуст — имя как detect_wg_interface_name (wg/detect_wg_iface.inc.sh). Чтобы выключить UI: export VPCONFIGURE_WG_CONF_PATH= перед запуском 08.
WIREGUARD_CONF_PATH=${wg_conf_path}

# Интервал фоновой синхронизации vpn_clients.json с конфигом WG, минуты. 0 — только при старте и при открытии дашборда.
WIREGUARD_SYNC_INTERVAL_MINUTES=${wg_sync_min}

# Имя интерфейса для wg-quick strip / wg syncconf (как в 06 / VPCONFIGURE_WIREGUARD_INTERFACE_NAME).
WIREGUARD_INTERFACE_NAME=${wg_if_name}

# Публичный FQDN или IP для Endpoint, если WIREGUARD_ENDPOINT пуст (по умолчанию VPCONFIGURE_DOMAIN).
WIREGUARD_PUBLIC_HOST=${wg_pub_host}

# Порт UDP для Endpoint при пустом WIREGUARD_ENDPOINT: 0 = ListenPort из конфига WG, иначе при отсутствии — 51820.
WIREGUARD_LISTEN_PORT=${wg_listen_port}

# DNS в клиентском [Interface].
WIREGUARD_DNS=${wg_dns}

# Каталог клиентских *.conf (и qr). Пусто = <родитель WIREGUARD_CLIENT_KEYS_DIR>/client_config.
WIREGUARD_CLIENT_CONFIG_DIR=${wg_client_conf_dir}

# Каталог файлов ключей клиентов на сервере (по умолчанию VPCONFIGURE_WG_CLIENT_CERT_PATH с 06).
WIREGUARD_CLIENT_KEYS_DIR=${wg_keys_dir}

# --- MTProxy ---
# Файл со ссылкой tg:// (первая непустая строка). Пусто — секция MTProxy в UI скрыта.
MTPROXY_LINK_FILE=${mtproxy_link_file}
EOF
  umask 022
  chmod 600 -- "${VPM_INSTALL}/settings.env"

  printf '%s\n' "VPManage: запись unit ${SYSTEMD_SERVICE}.service и перезапуск…" >&2
  cat >/etc/systemd/system/${SYSTEMD_SERVICE}.service <<EOF
[Unit]
Description=VPManage (${SYSTEMD_SERVICE})
After=network.target

[Service]
Type=simple
WorkingDirectory=${VPM_INSTALL}
EnvironmentFile=${VPM_INSTALL}/settings.env
ExecStart=${VPM_INSTALL}/.venv/bin/gunicorn --bind 0.0.0.0:${opt_http} --workers 1 manage_site.selfvpn_app:selfvpn_app
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SYSTEMD_SERVICE}"
  systemctl restart "${SYSTEMD_SERVICE}" 2>/dev/null || systemctl start "${SYSTEMD_SERVICE}" 2>/dev/null \
    || die "Не удалось запустить ${SYSTEMD_SERVICE}.service"

  open_vpm_http_in_firewall "$opt_http"

  vp_result_line success "VPManage установлен и запущен" \
    "vpm_http_port:${opt_http}" \
    "vpm_install_path:${VPM_INSTALL}" \
    "vpm_systemd:${SYSTEMD_SERVICE}" \
    "mtproxy_secret_path:${VPCONFIGURE_MTPROXY_SECRET_PATH}" \
    "mtproxy_link_path:${VPCONFIGURE_MTPROXY_LINK_PATH}" \
    "password:${app_pw}"

  if [[ "$mode_export" -eq 1 ]]; then
    emit_vpm_exports "$opt_http" "$app_pw" "$VPM_INSTALL" "$SYSTEMD_SERVICE" \
      "$VPCONFIGURE_MTPROXY_SECRET_PATH" "$VPCONFIGURE_MTPROXY_LINK_PATH"
  fi

  if [[ "$persist" -eq 1 ]]; then
    merge_vpm_into_env_file "$persist_file" \
      VPCONFIGURE_VPM_HTTP_PORT "$opt_http" \
      VPCONFIGURE_VPM_PASSWORD "$app_pw" \
      VPCONFIGURE_VPM_INSTALL_PATH "$VPM_INSTALL" \
      VPCONFIGURE_VPM_SYSTEMD_SERVICE "$SYSTEMD_SERVICE"
    vp_install_bashrc_hook "$persist_file"
    if vp_install_profile_d_hook "$persist_file"; then
      printf '%s\n' "VPCONFIGURE_VPM_* записаны в ${persist_file}" >&2
    else
      printf '%s\n' "VPCONFIGURE_VPM_* записаны в ${persist_file} (без /etc/profile.d)" >&2
    fi
  fi
}

main() {
  if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    usage
    exit 0
  fi

  # Неинтерактивный bash не подгружает ~/.bashrc — GIT_BRANCH и DOMAIN часто только в env-файле.
  vpconfigure_source_saved_env "$DEFAULT_PERSIST_FILE"

  : "${VPCONFIGURE_GIT_BRANCH:?Сначала 01_getosversion.sh --persist или export VPCONFIGURE_GIT_BRANCH}"

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
      printf '%s\n' "Ветка ${b}: 08_setvpmanage.sh не реализован." >&2
      vp_result_line warning "ветка ${b}, скрипт не реализован" \
        "vpm_http_port:unset" \
        "password:"
      ;;
  esac
}

main "$@"
