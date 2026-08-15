#!/usr/bin/env bash
# 10_uninstall
#
# Удаляет артефакты и сервисы, созданные шагами 05–08.
# Поддерживает оба сценария VP service: wireguard и amneziawg.
# Имена/пути очищаются и в legacy WG-формате, и в новом VP-формате.
#
# Опции:
#   --purge-packages   попытаться удалить пакеты VPN/MTProxy/VPManage (best effort)
#   -h, --help
#
# Формат stdout: result:success|warning|error; message:...

set -euo pipefail

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
  shift || true
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
  cat >&2 <<'EOF'
Удаление компонентов vpconnect-configure 05–08.

  --purge-packages   Пытаться удалить системные пакеты (best effort).
  -h, --help
EOF
}

require_root() {
  [[ "${EUID:-0}" -eq 0 ]] || die "Запускайте от root"
}

rm_if_exists() {
  local p=$1
  [[ -e "$p" ]] && rm -rf -- "$p" || true
}

remove_bashrc_hook_lines() {
  local f=${1:-/root/.bashrc}
  [[ -f "$f" ]] || return 0
  sed -i '/vpconnect-configure\.env/d' "$f" 2>/dev/null || true
}

stop_disable_unit() {
  local svc=$1
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
}

remove_unit_everywhere() {
  local unit=$1
  stop_disable_unit "$unit"
  rm_if_exists "/etc/systemd/system/${unit}"
  rm_if_exists "/etc/systemd/system/multi-user.target.wants/${unit}"
  rm_if_exists "/etc/systemd/system/default.target.wants/${unit}"
  rm_if_exists "/etc/systemd/system/network-online.target.wants/${unit}"
}

remove_units_like() {
  local patt=$1
  local -a units=()
  mapfile -t units < <(systemctl list-units --type=service --all 2>/dev/null | awk -v p="$patt" '$1 ~ p {print $1}')
  if [[ ${#units[@]} -gt 0 ]]; then
    local u
    for u in "${units[@]}"; do
      remove_unit_everywhere "$u"
    done
  fi
}

purge_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y -qq wireguard wireguard-tools amneziawg amneziawg-tools 2>/dev/null || true
  apt-get remove -y -qq python3-venv python3-pip 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true
}

purge_rhel() {
  local pm=''
  if command -v dnf >/dev/null 2>&1; then
    pm='dnf'
  elif command -v yum >/dev/null 2>&1; then
    pm='yum'
  fi
  [[ -n "$pm" ]] || return 0
  "$pm" -y remove wireguard-tools amneziawg-tools python3-pip >/dev/null 2>&1 || true
  "$pm" -y autoremove >/dev/null 2>&1 || true
}

purge_freebsd() {
  command -v pkg >/dev/null 2>&1 || return 0
  pkg delete -y wireguard-tools amneziawg-tools py311-pip py310-pip py39-pip >/dev/null 2>&1 || true
}

main() {
  local purge_pkgs=0
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --purge-packages)
        purge_pkgs=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Неизвестный аргумент: ${1}"
        ;;
    esac
  done

  require_root

  # --- VPManage (08) ---
  remove_unit_everywhere "vpconnect-manage.service"
  remove_unit_everywhere "selfvpn.service"
  rm_if_exists "/opt/VPManage"
  rm_if_exists "/opt/selfvpn"

  # --- MTProxy (07) ---
  remove_unit_everywhere "mtproxy.service"
  remove_unit_everywhere "mtproto-proxy.service"
  rm_if_exists "/opt/MTProxy"
  rm_if_exists "/etc/wireguard/mtproxy_secret.txt"
  rm_if_exists "/etc/vpserver/mtproxy_secret.txt"
  rm_if_exists "/usr/wireguard/client_config/mtproxy.link"
  rm_if_exists "/usr/vpserver/client_config/mtproxy.link"

  # --- VP service (06) ---
  remove_units_like "wg-quick@"
  remove_units_like "awg-quick@"
  rm_if_exists "/etc/wireguard"
  rm_if_exists "/etc/amnezia"
  rm_if_exists "/etc/amneziawg"
  rm_if_exists "/usr/wireguard"
  rm_if_exists "/usr/vpserver"
  rm_if_exists "/etc/sysctl.d/99-vpconnect-wireguard-forward.conf"
  rm_if_exists "/etc/sysctl.d/99-vpconnect-vpservice-forward.conf"
  sysctl -p >/dev/null 2>&1 || true

  # --- env + hooks (05/06/07/08 --persist) ---
  rm_if_exists "/root/.vpconnect-configure.env"
  rm_if_exists "/etc/profile.d/vpconnect-configure.sh"
  remove_bashrc_hook_lines "/root/.bashrc"

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  if [[ "$purge_pkgs" -eq 1 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      purge_debian
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      purge_rhel
    elif command -v pkg >/dev/null 2>&1; then
      purge_freebsd
    fi
  fi

  vp_result_line success "uninstalled"
}

main "$@"

