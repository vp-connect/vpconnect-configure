#!/usr/bin/env bash
set -euo pipefail

# 01_getosversion
#
# Определяет дистрибутив системы и задаёт VPCONFIGURE_GIT_BRANCH / печатает в stdout.
# Значение — семейство ОС (одна из трёх веток): freebsd, debian, centos.
#
# Поддерживаемые ОС (только актуальные / не EOL на момент политики проекта):
# * AlmaLinux 9, 10
# * Rocky Linux 8, 9
# * VzLinux / Virtuozzo 8
# * Debian 12, 13
# * Ubuntu LTS 22.04, 24.04, 26.04
# * FreeBSD 13, 14
# * Oracle Linux 8–10, EuroLinux 8–10, CloudLinux 8–10, RHEL 8–10, Fedora 39+
# * Amazon Linux 2023+ (не Amazon Linux 2)
# * CentOS Linux — не поддерживается (EOL); Scientific Linux — не поддерживается (EOL)
# Дополнительно (деривативы Debian/Ubuntu по ID_LIKE): linuxmint, pop, kali, raspbian, elementary, zorin, devuan
#
# Результат:
# * выставляет переменную окружения VPCONFIGURE_GIT_BRANCH
# * порядок stdout: сначала result:…; message:…; branch:… (при --export вторая строка — export …), потом только stderr (--persist и т.д.)
#
# Использование:
# * Ветка в stdout: result:success; message:OK; branch:<freebsd|debian|centos>
# * export: eval "$(./01_getosversion.sh --export)" — две строки stdout: result… и export …
# * Или: export VPCONFIGURE_GIT_BRANCH="$(./01_getosversion.sh | sed -n 's/.*branch:\([^; ]*\).*/\1/p')"
# * FreeBSD: bash из портов, запуск: bash ./01_getosversion.sh
# * или: source ./01_getosversion.sh  (экспортирует в текущую оболочку)
# * или: eval "$(./01_getosversion.sh --export)"  (экспортирует в текущую оболочку)
#
# Новая SSH-сессия не видит переменные из прошлой: они не хранятся сами по себе.
# Сохранить для новых сессий (рекомендуется один раз от root):
# * ./01_getosversion.sh --persist
# * или: ./01_getosversion.sh --persist /root/.vpconnect-configure.env
#   Запишет env-файл, хук в /etc/profile.d (login-shell) и строку в ~/.bashrc
#   (интерактивный SSH часто НЕ login-shell — без ~/.bashrc переменная не появится).

vp_sanitize_msg() {
  local s="$*"
  s="${s//;/,}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

# Одна строка на stdout: result:…; message:… [; ключ:значение …]
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

trim_quotes() {
  local s="${1:-}"
  s="${s%\"}"
  s="${s#\"}"
  s="${s%\'}"
  s="${s#\'}"
  printf '%s' "$s"
}

set_branch() {
  VPCONFIGURE_GIT_BRANCH="$1"
  export VPCONFIGURE_GIT_BRANCH
}

detect_linux() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"

  # shellcheck disable=SC1091
  . /etc/os-release

  local id version_id id_like
  id="$(trim_quotes "${ID:-}")"
  version_id="$(trim_quotes "${VERSION_ID:-}")"
  id_like="$(trim_quotes "${ID_LIKE:-}")"
  # /etc/os-release задаёт строчные ID, но на кастомных образах иногда нет — приводим к нижнему регистру.
  id="${id,,}"
  id_like="${id_like,,}"

  [[ -n "$id" ]] || die "OS ID is empty in /etc/os-release"
  [[ -n "$version_id" ]] || die "OS VERSION_ID is empty in /etc/os-release"

  case "$id" in
    ubuntu)
      case "$version_id" in
        22.04|24.04|26.04) set_branch "debian" ;;
        *) die "Unsupported Ubuntu version: $version_id (supported LTS: 22.04, 24.04, 26.04)" ;;
      esac
      ;;

    debian)
      case "$version_id" in
        12|13) set_branch "debian" ;;
        *) die "Unsupported Debian version: $version_id (supported: 12, 13)" ;;
      esac
      ;;

    linuxmint|pop|kali|raspbian|elementary|zorin|devuan)
      # Debian/Ubuntu family. VERSION_ID varies; trust ID_LIKE.
      case " $id_like " in
        *" debian "*|*" ubuntu "*)
          set_branch "debian"
          ;;
        *)
          die "Unsupported Debian-like distro: ID=$id VERSION_ID=$version_id (ID_LIKE=$id_like)"
          ;;
      esac
      ;;

    almalinux)
      case "$version_id" in
        9*|10*) set_branch "centos" ;;
        *) die "Unsupported AlmaLinux version: $version_id (supported: 9, 10)" ;;
      esac
      ;;

    rocky)
      case "$version_id" in
        8*|9*) set_branch "centos" ;;
        *) die "Unsupported Rocky Linux version: $version_id (supported: 8, 9)" ;;
      esac
      ;;

    centos)
      die "CentOS Linux is end-of-life; use Rocky Linux, AlmaLinux, Oracle Linux, or RHEL"
      ;;

    vzlinux|virtuozzo)
      case "$version_id" in
        8*) set_branch "centos" ;;
        *) die "Unsupported VzLinux/Virtuozzo version: $version_id (supported: 8.x, ID=$id)" ;;
      esac
      ;;

    ol|eurolinux|cloudlinux)
      case "$version_id" in
        8*|9*|10*) set_branch "centos" ;;
        *) die "Unsupported $id version: $version_id (supported: 8.x–10.x)" ;;
      esac
      ;;

    amzn)
      case "$version_id" in
        2) die "Amazon Linux 2 is not supported; use Amazon Linux 2023 or newer" ;;
        *) set_branch "centos" ;;
      esac
      ;;

    rhel)
      case "$version_id" in
        8*|9*|10*) set_branch "centos" ;;
        *) die "Unsupported RHEL version: $version_id (supported: 8, 9, 10)" ;;
      esac
      ;;

    fedora)
      case "$version_id" in
        3[9]|4[0-9]|5[0-9]|6[0-9]) set_branch "centos" ;;
        *) die "Unsupported Fedora version: $version_id (supported: 39+)" ;;
      esac
      ;;

    scientific)
      die "Scientific Linux is end-of-life; migrate to Rocky Linux or AlmaLinux"
      ;;

    *)
      # Клоны с нестандартным ID: только семейства Debian/Ubuntu или RHEL (без устаревшего centos в основе).
      case " $id_like " in
        *" debian "*|*" ubuntu "*)
          set_branch "debian"
          ;;
        *" rhel "*|*" fedora "*)
          set_branch "centos"
          ;;
        *" centos "*)
          die "Unsupported: ID_LIKE suggests CentOS Linux (EOL); use Rocky Linux, AlmaLinux, or Oracle Linux"
          ;;
        *)
          die "Unsupported Linux distro: ID=$id VERSION_ID=$version_id (ID_LIKE=$id_like)"
          ;;
      esac
      ;;
  esac
}

detect_freebsd() {
  local major
  # Примеры freebsd-version: "13.4-RELEASE-p1", "14.2-RELEASE" (12 не поддерживается)
  major="$(freebsd-version 2>/dev/null | sed -E 's/^([0-9]+).*/\1/' || true)"
  [[ -n "$major" ]] || major="$(uname -r | sed -E 's/^([0-9]+).*/\1/' || true)"
  [[ -n "$major" ]] || die "Cannot detect FreeBSD version"

  case "$major" in
    13|14) set_branch "freebsd" ;;
    *) die "Unsupported FreeBSD version: $major (supported: 13, 14)" ;;
  esac
}

write_persist_env_file() {
  local f="$1"
  local d
  d="$(dirname -- "$f")"
  [[ -d "$d" ]] || mkdir -p -- "$d"
  umask 077
  {
    printf '# Generated by 01_getosversion.sh --persist\n'
    printf 'export VPCONFIGURE_GIT_BRANCH=%q\n' "$VPCONFIGURE_GIT_BRANCH"
  } >"$f"
  chmod 600 -- "$f" 2>/dev/null || true
}

install_login_profile_hook() {
  local env_file="$1"
  local hook="/etc/profile.d/vpconnect-configure.sh"
  [[ -d /etc/profile.d ]] || return 1
  umask 022
  {
    printf '# Generated by 01_getosversion.sh --persist (login shells)\n'
    printf '[ -r %q ] && . %q\n' "$env_file" "$env_file"
  } >"$hook"
  chmod 644 -- "$hook" 2>/dev/null || true
  return 0
}

# Интерактивный SSH bash по умолчанию часто читает только ~/.bashrc, не /etc/profile.d.
install_bashrc_hook() {
  local env_file="$1"
  local bashrc="${HOME:-/root}/.bashrc"
  local marker="# vpconnect-configure env (01_getosversion.sh --persist)"

  if [[ -f "$bashrc" ]] && grep -qF "$marker" "$bashrc" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n%s\n' "$marker"
    printf '[ -r %q ] && . %q\n' "$env_file" "$env_file"
  } >>"$bashrc"
  return 0
}

main() {
  local mode="auto"
  local persist=0
  local persist_file="/root/.vpconnect-configure.env"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --export)
        mode="export"
        shift
        ;;
      --print)
        mode="print"
        shift
        ;;
      --persist)
        persist=1
        shift
        if [[ -n "${1:-}" && "$1" != -* ]]; then
          persist_file="$1"
          shift
        fi
        ;;
      -h|--help)
        vp_result_line success "Справка ниже в stderr"
        sed -n '1,45p' "${BASH_SOURCE[0]}" >&2
        return 0
        ;;
      *)
        die "Unknown argument: $1 (try --help)"
        ;;
    esac
  done

  local sys
  sys="$(uname -s)"
  case "$sys" in
    Linux) detect_linux ;;
    FreeBSD) detect_freebsd ;;
    *) die "Unsupported OS kernel: $sys" ;;
  esac

  [[ -n "${VPCONFIGURE_GIT_BRANCH:-}" ]] || die "VPCONFIGURE_GIT_BRANCH is empty after detection"

  # Сначала stdout: result (и при --export — строка export), потом любые сообщения в stderr (--persist и т.д.).
  if [[ "$mode" == "export" ]]; then
    vp_result_line success "OK" "branch:${VPCONFIGURE_GIT_BRANCH}"
    printf 'export VPCONFIGURE_GIT_BRANCH=%q\n' "$VPCONFIGURE_GIT_BRANCH"
  else
    vp_result_line success "OK" "branch:${VPCONFIGURE_GIT_BRANCH}"
  fi

  if [[ "$persist" -eq 1 ]]; then
    write_persist_env_file "$persist_file"
    install_bashrc_hook "$persist_file"
    if install_login_profile_hook "$persist_file"; then
      printf 'Saved %q; hooks: ~/.bashrc and /etc/profile.d/vpconnect-configure.sh\n' "$persist_file" >&2
    else
      printf 'Saved %q; hook: ~/.bashrc (no /etc/profile.d on this system)\n' "$persist_file" >&2
    fi
  fi
}

main "$@"
