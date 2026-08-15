#!/usr/bin/env bash
# vp_runtime.inc.sh — общий runtime для wg/*.sh (wireguard | amneziawg).
# Source из соседних скриптов после detect_wg_iface.inc.sh (необязательно).

vp_expand_tilde() {
  local p=$1
  if [[ "$p" == '~' || "$p" == ~/* ]]; then
    p="${p/\~/$HOME}"
  fi
  printf '%s' "$p"
}

vp_source_saved_env() {
  local f=${1:-/root/.vpconnect-configure.env}
  f="$(vp_expand_tilde "$f")"
  [[ -r "$f" ]] || return 0
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

vp_require_os_branch() {
  local expected=$1
  local script_name=${2:-script}
  local b
  b=$(printf '%s' "${VPCONFIGURE_GIT_BRANCH:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$b" != "$expected" ]]; then
    echo "Ошибка: ${script_name} в ветке ${expected} поддерживает только VPCONFIGURE_GIT_BRANCH=${expected} (текущее: ${b:-unset})." >&2
    exit 1
  fi
}

vp_require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Ошибка: запускайте от root." >&2
    exit 1
  fi
}

vp_require_cmd() {
  local c=$1
  command -v "$c" >/dev/null 2>&1 || {
    echo "Ошибка: не найдена команда '$c' в PATH." >&2
    exit 1
  }
}

vp_service_type() {
  local t
  t=$(printf '%s' "${VPCONFIGURE_VPSERVER_TYPE:-${VPCONFIGURE_VP_SERVICE_TYPE:-}}" | tr '[:upper:]' '[:lower:]')
  if [[ "$t" == "amneziawg" || "$t" == "wireguard" ]]; then
    printf '%s' "$t"
    return 0
  fi
  local iface conf
  iface="${VPCONFIGURE_VPSERVER_INTERFACE_NAME:-${VPCONFIGURE_WIREGUARD_INTERFACE_NAME:-}}"
  if [[ -z "$iface" ]] && declare -F detect_wg_interface_name >/dev/null 2>&1; then
    iface="$(detect_wg_interface_name)"
  fi
  iface="${iface:-wg0}"
  conf="/etc/amnezia/amneziawg/${iface}.conf"
  if [[ -f "$conf" ]] && grep -Eq '^[[:space:]]*(Jc|Jmin|Jmax|S1|H1)[[:space:]]*=' "$conf" 2>/dev/null; then
    printf '%s' "amneziawg"
    return 0
  fi
  printf '%s' "wireguard"
}

vp_iface_name() {
  local iface
  iface="${VPCONFIGURE_VPSERVER_INTERFACE_NAME:-${VPCONFIGURE_WIREGUARD_INTERFACE_NAME:-}}"
  if [[ -z "$iface" ]] && declare -F detect_wg_interface_name >/dev/null 2>&1; then
    iface="$(detect_wg_interface_name)"
  fi
  printf '%s' "${iface:-wg0}"
}

vp_bin() {
  local explicit svc
  explicit="${VPCONFIGURE_VP_SERVICE_BINARY:-}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  svc="$(vp_service_type)"
  if [[ "$svc" == "amneziawg" ]]; then
    printf '%s' "awg"
  else
    printf '%s' "wg"
  fi
}

vp_quick_bin() {
  local explicit svc
  explicit="${VPCONFIGURE_VP_SERVICE_QUICK_BINARY:-}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  svc="$(vp_service_type)"
  if [[ "$svc" == "amneziawg" ]]; then
    printf '%s' "awg-quick"
  else
    printf '%s' "wg-quick"
  fi
}

vp_conf_path() {
  local iface svc explicit
  explicit="${VPCONFIGURE_VP_CONF_PATH:-${VPCONFIGURE_WG_CONF_PATH:-}}"
  if [[ -n "$explicit" ]]; then
    vp_expand_tilde "$explicit"
    return 0
  fi
  iface="$(vp_iface_name)"
  svc="$(vp_service_type)"
  if [[ "$svc" == "amneziawg" ]]; then
    printf '%s' "/etc/amnezia/amneziawg/${iface}.conf"
  else
    printf '%s' "/etc/wireguard/${iface}.conf"
  fi
}

# Дополнительный путь для зеркалирования пиров (если файл существует).
vp_mirror_conf_path() {
  local iface svc primary mirror
  iface="$(vp_iface_name)"
  svc="$(vp_service_type)"
  primary="$(vp_conf_path)"
  if [[ "$svc" == "amneziawg" ]]; then
    mirror="/etc/wireguard/${iface}.conf"
  else
    mirror="/etc/amnezia/amneziawg/${iface}.conf"
  fi
  if [[ "$mirror" != "$primary" && -f "$mirror" ]]; then
    printf '%s' "$mirror"
  fi
}

vp_client_cert_dir() {
  local d
  d="${VPCONFIGURE_VP_CLIENT_CERT_PATH:-${VPCONFIGURE_WG_CLIENT_CERT_PATH:-/usr/vpserver/client_cert}}"
  vp_expand_tilde "$d"
}

vp_client_config_dir() {
  local d
  d="${VPCONFIGURE_VP_CLIENT_CONFIG_PATH:-${VPCONFIGURE_WG_CLIENT_CONFIG_PATH:-/usr/vpserver/client_config}}"
  vp_expand_tilde "$d"
}

vp_syncconf() {
  local iface bin quick
  iface="$(vp_iface_name)"
  bin="$(vp_bin)"
  quick="$(vp_quick_bin)"
  vp_require_cmd "$bin"
  vp_require_cmd "$quick"
  "$bin" syncconf "$iface" <("$quick" strip "$iface")
}

# Строки Jc/Jmin/Jmax/S1-S4/H1-H4 из серверного [Interface] (для клиентского .conf AmneziaWG).
vp_server_obfuscation_lines() {
  local conf=${1:-}
  [[ -n "$conf" && -f "$conf" ]] || return 0
  awk '
    BEGIN { in_iface=0 }
    /^[[:space:]]*\[Interface\]/ { in_iface=1; next }
    /^[[:space:]]*\[/ { in_iface=0 }
    in_iface && $0 ~ /^[[:space:]]*(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4)[[:space:]]*=/ { print }
  ' "$conf"
}
