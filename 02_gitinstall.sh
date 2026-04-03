#!/usr/bin/env bash
set -euo pipefail

# 02_gitinstall
#
# Устанавливает git по VPCONFIGURE_GIT_BRANCH (freebsd | debian | centos).
# Сначала 01_getosversion.sh → парсить branch: из строки result на stdout.
# Сначала stdout: result:…; message:…, затем при необходимости Note в stderr.

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

require_branch_var() {
  local b="${VPCONFIGURE_GIT_BRANCH:-}"
  [[ -n "$b" ]] || die "VPCONFIGURE_GIT_BRANCH не задана, сначала 01_getosversion.sh (возьмите branch: из строки result)"
  b="${b,,}"
  case "$b" in
    freebsd|debian|centos) ;;
    *) die "Неверная VPCONFIGURE_GIT_BRANCH: ${VPCONFIGURE_GIT_BRANCH:-} (нужно freebsd, debian или centos)" ;;
  esac
  printf '%s' "$b"
}

assert_branch_matches_os() {
  local branch="$1"
  local sys
  sys="$(uname -s)"
  case "$branch" in
    freebsd)
      [[ "$sys" == FreeBSD ]] || die "VPCONFIGURE_GIT_BRANCH=freebsd, но uname: $sys"
      ;;
    debian|centos)
      [[ "$sys" == Linux ]] || die "VPCONFIGURE_GIT_BRANCH=$branch, но uname: $sys (ожидался Linux)"
      ;;
  esac
}

install_debian_family() {
  export DEBIAN_FRONTEND=noninteractive
  # Весь вывод пакетного менеджера — в stderr, чтобы первая строка stdout оставалась result:… для парсера.
  apt-get update -y >&2
  apt-get install -y git >&2
}

install_rhel_family() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y git >&2
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git >&2
  else
    die "Нет dnf и yum (семейство centos / RHEL)"
  fi
}

install_freebsd() {
  env ASSUME_ALWAYS_YES=yes pkg install -y git >&2
}

main() {
  local branch
  local post_note=""
  branch="$(require_branch_var)"
  assert_branch_matches_os "$branch"

  case "$branch" in
    debian) install_debian_family ;;
    centos) install_rhel_family ;;
    freebsd)
      if ! command -v pkg >/dev/null 2>&1; then
        post_note="pkg not in PATH, on minimal FreeBSD run: /usr/sbin/pkg bootstrap -f"
      fi
      install_freebsd
      ;;
  esac

  command -v git >/dev/null 2>&1 || die "git не появился в PATH после установки"
  local ver
  ver="$(git --version | tr ';' ',')"
  vp_result_line success "git установлен" "version:${ver}"
  if [[ -n "$post_note" ]]; then
    printf 'Note: %s\n' "$post_note" >&2
  fi
}

main "$@"
