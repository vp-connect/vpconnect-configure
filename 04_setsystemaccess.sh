#!/usr/bin/env bash
# 04_setsystemaccess
#
# Пароль root, порт SSH, публичный ключ для root (только centos-ветка).
# Файрвол: управление выполняется ТОЛЬКО при флаге --enable-firewall.
# При включённом флаге: firewalld (установка через dnf/yum, запуск и enable).
# При смене порта SSH: снять старые allow, добавить новый, reload (если активен).
# Каждый этап выполняется только если передан соответствующий параметр CLI.
# vpconnect_install может вызывать скрипт, подставляя только нужные флаги.
#
# Сначала stdout: одна строка result:…; message:… и поля step_*; пояснения — stderr.
#
# Использование:
#   bash ./04_setsystemaccess.sh [--new-root-password PASS | --new-root-password-file PATH]
#                              [--new-ssh-port N]
#                              [--ssh-public-key LINE | --ssh-public-key-file PATH]
#                              [--enable-firewall]
#
# Нужна переменная VPCONFIGURE_GIT_BRANCH=centos из 01_getosversion.sh.

set -euo pipefail

SSH_DROP_IN='/etc/ssh/sshd_config.d/99-vpconnect-port.conf'

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
Настройка доступа: пароль root, порт sshd, ключ в authorized_keys (только centos-ветка).

  --new-root-password PASS       Новый пароль пользователя root (не сочетать с -file)
  --new-root-password-file PATH  Прочитать пароль из первой строки файла

  --new-ssh-port N               Порт sshd (1–65535), если отличается от текущего — drop-in, restart, правила firewall

  --ssh-public-key LINE          Одна строка OpenSSH public key (не сочетать с -file)
  --ssh-public-key-file PATH     Взять ключ из первой строки файла

  --enable-firewall              Включить firewalld и управлять правилами

  -h, --help                     Эта справка

Пример (vpconnect_install подставляет только нужные флаги):
  export VPCONFIGURE_GIT_BRANCH=centos
  bash ./04_setsystemaccess.sh --new-ssh-port 2222 --ssh-public-key-file /tmp/id.pub
EOF
}

require_root() {
  [[ "${EUID:-0}" -eq 0 ]] || die "Запускайте от root (нужны chpasswd, /etc/ssh, /root/.ssh)"
}

rhel_pkg_manager() {
  if command -v dnf >/dev/null 2>&1; then
    printf '%s' "dnf"
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    printf '%s' "yum"
    return 0
  fi
  return 1
}

ensure_firewalld_installed() {
  if command -v firewall-cmd >/dev/null 2>&1; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    return 0
  fi
  local pm
  pm=$(rhel_pkg_manager) || die "Не найден dnf/yum для установки firewalld"
  printf '%s\n' "firewalld не найден, устанавливаю (${pm})…" >&2
  "$pm" -y install firewalld >/dev/null 2>&1 || die "Не удалось установить firewalld через ${pm}"
  command -v firewall-cmd >/dev/null 2>&1 || die "После установки firewalld недоступен firewall-cmd"
  systemctl enable --now firewalld >/dev/null 2>&1 || die "Не удалось включить/запустить firewalld"
  printf '%s\n' "firewalld установлен и запущен." >&2
}

firewalld_remove_tcp_port() {
  local port=$1
  command -v firewall-cmd >/dev/null 2>&1 || return 0
  firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --remove-port="${port}/tcp" >/dev/null 2>&1 || true
}

update_firewalld_for_new_ssh_port() {
  local new_port=$1
  shift
  command -v firewall-cmd >/dev/null 2>&1 || return 0
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    printf '%s\n' "firewalld не активен — порт ${new_port}/tcp не применён автоматически." >&2
    return 0
  fi
  local oldp
  for oldp in "$@"; do
    [[ -z "$oldp" ]] && continue
    [[ "$oldp" == "$new_port" ]] && continue
    printf '%s\n' "firewalld: удаляю TCP ${oldp} (прежний SSH)…" >&2
    firewalld_remove_tcp_port "$oldp"
  done
  printf '%s\n' "firewalld: добавляю TCP ${new_port} (SSH)…" >&2
  firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null 2>&1 \
    || printf '%s\n' "Предупреждение: firewalld permanent add ${new_port}/tcp не выполнен." >&2
  firewall-cmd --add-port="${new_port}/tcp" >/dev/null 2>&1 \
    || printf '%s\n' "Предупреждение: firewalld runtime add ${new_port}/tcp не выполнен." >&2
  firewall-cmd --reload >/dev/null 2>&1 \
    || printf '%s\n' "Предупреждение: firewalld reload не выполнен." >&2
}

enable_firewall_if_requested() {
  local enabled=${1:-0}
  if [[ "$enabled" -ne 1 ]]; then
    return 0
  fi
  ensure_firewalld_installed
}

collect_sshd_ports_or_fail() {
  command -v sshd >/dev/null 2>&1 || return 1
  sshd -T 2>/dev/null | awk '/^port / { print $2 }'
}

sshd_has_port() {
  local want=$1
  local p
  while IFS= read -r p; do
    [[ "$p" == "$want" ]] && return 0
  done < <(sshd -T 2>/dev/null | awk '/^port / { print $2 }')
  return 1
}

restart_sshd_service() {
  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl restart ssh
  elif systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl restart sshd
  else
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null \
      || die "Не удалось перезапустить службу ssh/sshd"
  fi
}

apply_ssh_port() {
  local port=$1
  mkdir -p /etc/ssh/sshd_config.d
  cat >"$SSH_DROP_IN" <<EOF
Port ${port}
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
EOF
  restart_sshd_service
}

step_root_password=skipped
step_ssh_port=skipped
step_ssh_public_key=skipped

run_centos() {
  local opt_new_pw=''
  local opt_new_pw_file=''
  local opt_ssh_port=''
  local opt_pub_key=''
  local opt_pub_key_file=''
  local opt_enable_firewall=0
  local have_pw_arg=0 have_pw_file_arg=0 have_pub_arg=0 have_pub_file_arg=0

  while [[ $# -gt 0 ]]; do
    case $1 in
      --new-root-password)
        [[ $# -ge 2 ]] || die "После --new-root-password нужен пароль"
        opt_new_pw=$2
        have_pw_arg=1
        shift 2
        ;;
      --new-root-password-file)
        [[ $# -ge 2 ]] || die "После --new-root-password-file нужен путь"
        opt_new_pw_file=$2
        have_pw_file_arg=1
        shift 2
        ;;
      --new-ssh-port)
        [[ $# -ge 2 ]] || die "После --new-ssh-port нужен номер порта"
        opt_ssh_port=$2
        shift 2
        ;;
      --ssh-public-key)
        [[ $# -ge 2 ]] || die "После --ssh-public-key нужна строка ключа"
        opt_pub_key=$2
        have_pub_arg=1
        shift 2
        ;;
      --ssh-public-key-file)
        [[ $# -ge 2 ]] || die "После --ssh-public-key-file нужен путь"
        opt_pub_key_file=$2
        have_pub_file_arg=1
        shift 2
        ;;
      --enable-firewall)
        opt_enable_firewall=1
        shift
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

  [[ $have_pw_arg -eq 0 || $have_pw_file_arg -eq 0 ]] \
    || die "Укажите только один из --new-root-password и --new-root-password-file"
  [[ $have_pub_arg -eq 0 || $have_pub_file_arg -eq 0 ]] \
    || die "Укажите только один из --ssh-public-key и --ssh-public-key-file"

  local new_pw=''
  if [[ $have_pw_file_arg -eq 1 ]]; then
    [[ -f "$opt_new_pw_file" && -r "$opt_new_pw_file" ]] \
      || die "Файл пароля не найден или не читается: ${opt_new_pw_file}"
    IFS= read -r new_pw <"$opt_new_pw_file" || true
    new_pw="${new_pw%$'\r'}"
    [[ -n "$new_pw" ]] || die "Файл пароля пуст: ${opt_new_pw_file}"
  elif [[ $have_pw_arg -eq 1 ]]; then
    new_pw=$opt_new_pw
    [[ -n "$new_pw" ]] || die "Пустой пароль в --new-root-password"
  fi

  local pub_line=''
  if [[ $have_pub_file_arg -eq 1 ]]; then
    [[ -f "$opt_pub_key_file" && -r "$opt_pub_key_file" ]] \
      || die "Файл ключа не найден или не читается: ${opt_pub_key_file}"
    IFS= read -r pub_line <"$opt_pub_key_file" || true
    pub_line="${pub_line%$'\r'}"
    [[ -n "$pub_line" ]] || die "Файл ключа пуст: ${opt_pub_key_file}"
  elif [[ $have_pub_arg -eq 1 ]]; then
    pub_line=$opt_pub_key
    pub_line="${pub_line#"${pub_line%%[![:space:]]*}"}"
    pub_line="${pub_line%"${pub_line##*[![:space:]]}"}"
    [[ -n "$pub_line" ]] || die "Пустая строка в --ssh-public-key"
  fi

  if [[ -z "$new_pw" && -z "$opt_ssh_port" && -z "$pub_line" && "$opt_enable_firewall" -eq 0 ]]; then
    vp_result_line success "параметры не заданы, изменений нет" \
      "step_root_password:skipped" \
      "step_ssh_port:skipped" \
      "step_ssh_public_key:skipped"
    printf '%s\n' "Укажите хотя бы один из параметров или -h для справки." >&2
    return 0
  fi

  require_root
  enable_firewall_if_requested "$opt_enable_firewall"

  if [[ -n "$new_pw" ]]; then
    local ch_err
    if ch_err=$(printf 'root:%s\n' "$new_pw" | chpasswd 2>&1); then
      step_root_password=done
      printf '%s\n' "Пароль root обновлён (chpasswd)." >&2
    else
      step_root_password=failed
      die "chpasswd не выполнен: $(vp_sanitize_msg "$ch_err")"
    fi
  fi

  if [[ -n "$opt_ssh_port" ]]; then
    if ! [[ "$opt_ssh_port" =~ ^[0-9]+$ ]] || [[ "$opt_ssh_port" -lt 1 || "$opt_ssh_port" -gt 65535 ]]; then
      step_ssh_port=failed
      die "Некорректный порт SSH: ${opt_ssh_port} (нужно 1–65535)"
    fi
    if ! collect_sshd_ports_or_fail >/dev/null; then
      step_ssh_port=failed
      die "Команда sshd недоступна, не удалось определить текущий порт"
    fi
    if sshd_has_port "$opt_ssh_port"; then
      step_ssh_port=skipped_same
      printf '%s\n' "Порт ${opt_ssh_port} уже в эффективной конфигурации sshd, файл не менялся." >&2
    else
      local -a old_ssh_ports=()
      while IFS= read -r p; do
        [[ -n "$p" ]] && old_ssh_ports+=("$p")
      done < <(sshd -T 2>/dev/null | awk '/^port / { print $2 }' | sort -u)
      apply_ssh_port "$opt_ssh_port"
      step_ssh_port=done
      printf '%s\n' "Записан ${SSH_DROP_IN}, служба ssh перезапущена." >&2
      if [[ "$opt_enable_firewall" -eq 1 ]]; then
        update_firewalld_for_new_ssh_port "$opt_ssh_port" "${old_ssh_ports[@]}"
      fi
    fi
  fi

  if [[ -n "$pub_line" ]]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if grep -qxF "$pub_line" /root/.ssh/authorized_keys 2>/dev/null; then
      step_ssh_public_key=skipped_present
      printf '%s\n' "Ключ уже есть в /root/.ssh/authorized_keys." >&2
    else
      printf '%s\n' "$pub_line" >>/root/.ssh/authorized_keys
      step_ssh_public_key=done
      printf '%s\n' "Ключ добавлен в /root/.ssh/authorized_keys." >&2
    fi
  fi

  vp_result_line success "настройка доступа выполнена" \
    "step_root_password:${step_root_password}" \
    "step_ssh_port:${step_ssh_port}" \
    "step_ssh_public_key:${step_ssh_public_key}"
}

main() {
  : "${VPCONFIGURE_GIT_BRANCH:?Сначала 01_getosversion.sh}"

  local b
  b=$(printf '%s' "$VPCONFIGURE_GIT_BRANCH" | tr '[:upper:]' '[:lower:]')
  case "$b" in
    centos)
      run_centos "$@"
      ;;
    freebsd|debian)
      die "Этот скрипт в ветке centos поддерживает только VPCONFIGURE_GIT_BRANCH=centos (текущее: ${b})"
      ;;
    *)
      die "VPCONFIGURE_GIT_BRANCH=${b} недопустимо"
      ;;
  esac
}

main "$@"
