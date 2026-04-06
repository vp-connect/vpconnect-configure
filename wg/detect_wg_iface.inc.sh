# shellcheck shell=bash
# Включается из 06_setwireguard.sh и wg/*.sh (source …/detect_wg_iface.inc.sh).
# Имя интерфейса WG не задаётся вручную в 06: по умолчанию wg0; если на сервере уже
# есть другой интерфейс/конфиг — определяется автоматически.

detect_wg_interface_name() {
  local -a ifaces=()
  if command -v wg >/dev/null 2>&1; then
    read -r -a ifaces <<< "$(wg show interfaces 2>/dev/null || true)"
  fi
  if [[ ${#ifaces[@]} -gt 0 ]]; then
    local i
    for i in "${ifaces[@]}"; do
      [[ "$i" == wg0 ]] && {
        printf 'wg0'
        return
      }
    done
    printf '%s' "$(printf '%s\n' "${ifaces[@]}" | sort -V | head -1)"
    return
  fi
  local -a confs=()
  shopt -s nullglob
  confs=(/etc/wireguard/wg*.conf)
  shopt -u nullglob
  if [[ ${#confs[@]} -eq 1 ]]; then
    printf '%s' "$(basename "${confs[0]}" .conf)"
    return
  fi
  printf 'wg0'
}
