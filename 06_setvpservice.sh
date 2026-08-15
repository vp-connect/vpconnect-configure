#!/usr/bin/env bash
set -euo pipefail

DEFAULT_VPSERVER_TYPE='wireguard'
DEFAULT_CERT='/usr/vpserver/client_cert'
DEFAULT_CONF_DIR='/usr/vpserver/client_config'
DEFAULT_PERSIST_FILE='/root/.vpconnect-configure.env'

die() {
  printf 'result:error; message:%s\n' "${1//;/,}"
  exit 1
}

vpservice_type="$DEFAULT_VPSERVER_TYPE"
vp_port=''
vp_address=''
vp_wan_iface=''
vp_cert="$DEFAULT_CERT"
vp_conf="$DEFAULT_CONF_DIR"
vp_priv=''
persist_file="$DEFAULT_PERSIST_FILE"
mode_export=0

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --vpservice-type) vpservice_type="$2"; shift 2 ;;
    --vp-port) vp_port="$2"; shift 2 ;;
    --vp-address) vp_address="$2"; shift 2 ;;
    --vp-wan-interface) vp_wan_iface="$2"; shift 2 ;;
    --vp-client-cert-path) vp_cert="$2"; shift 2 ;;
    --vp-client-config-path) vp_conf="$2"; shift 2 ;;
    --vp-server-private-key-file) vp_priv="$2"; shift 2 ;;
    --persist) shift; [[ -n "${1:-}" && "$1" != -* ]] && { persist_file="$1"; shift; } ;;
    --export) mode_export=1; shift ;;
    -h|--help)
      printf 'result:success; message:Справка выведена в stderr\n'
      printf '%s\n' "06_setvpservice.sh --vpservice-type wireguard|amneziawg --vp-port N --vp-client-cert-path PATH --vp-client-config-path PATH" >&2
      exit 0
      ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

vpservice_type="$(printf '%s' "$vpservice_type" | tr '[:upper:]' '[:lower:]')"
[[ "$vpservice_type" == "wireguard" || "$vpservice_type" == "amneziawg" ]] || die "Некорректный --vpservice-type"

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_wg="${_self_dir}/06_setwireguard.sh"
[[ -f "$_wg" ]] || die "Не найден $_wg"

args=( --wg-client-cert-path "$vp_cert" --wg-client-config-path "$vp_conf" --persist "$persist_file" --export )
[[ -n "$vp_port" ]] && args+=( --wg-port "$vp_port" )
[[ -n "$vp_address" ]] && args+=( --wg-address "$vp_address" )
[[ -n "$vp_wan_iface" ]] && args+=( --wg-wan-interface "$vp_wan_iface" )
[[ -n "$vp_priv" ]] && args+=( --wg-server-private-key-file "$vp_priv" )

out="$(bash "$_wg" "${args[@]}" 2>&1)" || { printf '%s\n' "$out" >&2; die "Ошибка запуска 06_setwireguard.sh"; }
line="$(awk '/^result:/{l=$0} END{print l}' <<<"$out")"
[[ -n "$line" ]] || die "Не получен result от 06_setwireguard.sh"

vp_port_parsed="$(awk -F';' '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i ~ /^wg_port:/){sub(/^wg_port:/,"",$i); print $i; exit}}}' <<<"$line")"
vp_pub="$(awk -F';' '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i ~ /^wg_server_public_key_path:/){sub(/^wg_server_public_key_path:/,"",$i); print $i; exit}}}' <<<"$line")"
vp_priv_path="$(awk -F';' '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i ~ /^wg_private_key_path:/){sub(/^wg_private_key_path:/,"",$i); print $i; exit}}}' <<<"$line")"
vp_iface="$(awk -F';' '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i ~ /^wg_interface:/){sub(/^wg_interface:/,"",$i); print $i; exit}}}' <<<"$line")"

{
  printf '\n# VPCONFIGURE_VP (06_setvpservice.sh)\n'
  printf 'export VPCONFIGURE_VPSERVER_TYPE=%q\n' "$vpservice_type"
  printf 'export VPCONFIGURE_VP_PORT=%q\n' "${vp_port_parsed:-$vp_port}"
  printf 'export VPCONFIGURE_VP_CLIENT_CERT_PATH=%q\n' "$vp_cert"
  printf 'export VPCONFIGURE_VP_CLIENT_CONFIG_PATH=%q\n' "$vp_conf"
  printf 'export VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH=%q\n' "$vp_pub"
  printf 'export VPCONFIGURE_VP_PRIVATE_KEY_PATH=%q\n' "$vp_priv_path"
  printf 'export VPCONFIGURE_VPSERVER_INTERFACE_NAME=%q\n' "$vp_iface"
} >>"$persist_file"

printf 'result:success; message:VPN-сервис установлен (%s); vpservice_type:%s; vp_port:%s; vp_client_cert_path:%s; vp_client_config_path:%s\n' \
  "$vpservice_type" "$vpservice_type" "${vp_port_parsed:-$vp_port}" "$vp_cert" "$vp_conf"
if [[ $mode_export -eq 1 ]]; then
  printf 'export VPCONFIGURE_VPSERVER_TYPE=%q\n' "$vpservice_type"
  printf 'export VPCONFIGURE_VP_PORT=%q\n' "${vp_port_parsed:-$vp_port}"
  printf 'export VPCONFIGURE_VP_CLIENT_CERT_PATH=%q\n' "$vp_cert"
  printf 'export VPCONFIGURE_VP_CLIENT_CONFIG_PATH=%q\n' "$vp_conf"
  printf 'export VPCONFIGURE_VP_SERVER_PUBLIC_KEY_PATH=%q\n' "$vp_pub"
  printf 'export VPCONFIGURE_VP_PRIVATE_KEY_PATH=%q\n' "$vp_priv_path"
  printf 'export VPCONFIGURE_VPSERVER_INTERFACE_NAME=%q\n' "$vp_iface"
fi

